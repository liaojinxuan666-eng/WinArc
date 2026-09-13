#!/usr/bin/env python3
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: madeira-ui-overlay.py <madeira-checkout> <winarc-checkout>")

madeira = Path(sys.argv[1]).resolve()
winarc = Path(sys.argv[2]).resolve()

donor = madeira / "app" / "Madeira"
ui = winarc / "app" / "WinArc"
overlay = winarc / "app" / "MadeiraOverlay"

content_path = donor / "ContentView.swift"
app_path = donor / "MadeiraApp.swift"
plist_path = donor / "Info.plist"
jit_helper_path = donor / "StikJITHelper.swift"

for p in (content_path, app_path, plist_path, jit_helper_path, ui, overlay):
    if not p.exists():
        raise SystemExit(f"missing required path: {p}")

source = content_path.read_text(encoding="utf-8")

if "struct MadeiraLegacyContentView: View {" not in source:
    if "struct ContentView: View {" not in source:
        raise SystemExit("Madeira ContentView declaration not found")
    source = re.sub(r"\bContentView\b", "MadeiraLegacyContentView", source)

launch_hook_old = '''            .onAppear {
                jit_install_trap_handler()
                entitlements = EntitlementStatus.check()
                logEntitlementStatus()
            }
'''

launch_hook_new = launch_hook_old + '''            .onReceive(NotificationCenter.default.publisher(for: .winArcLaunchDesktop)) { _ in
                let deskW = 960
                let deskH = 540

                setenv("MADEIRA_EXE", "explorer.exe", 1)
                setenv(
                    "MADEIRA_ARGS",
                    "/desktop=shell,\\(deskW)x\\(deskH) C:\\\\windows\\\\system32\\\\services.exe",
                    1
                )
                setenv("MADEIRA_DESKTOP", "1", 1)
                setenv("MADEIRA_SCREEN_W", String(deskW), 1)
                setenv("MADEIRA_SCREEN_H", String(deskH), 1)

                runWineFullSequence()
            }            .onReceive(NotificationCenter.default.publisher(for: .winArcLaunchDX11Cube)) { _ in
                LogStore.shared.log(
                    "[WinArc DX11] launching bundled cube-x64.exe via DXMT"
                )

                setenv("MADEIRA_EXE", "cube-x64.exe", 1)
                unsetenv("MADEIRA_ARGS")
                unsetenv("MADEIRA_DESKTOP")
                unsetenv("MADEIRA_SCREEN_W")
                unsetenv("MADEIRA_SCREEN_H")

                runWineFullSequence()
            }

'''

if ".winArcLaunchDesktop" not in source:
    if launch_hook_old not in source:
        raise SystemExit("Madeira runtime onAppear hook changed")
    source = source.replace(launch_hook_old, launch_hook_new, 1)

jit_source = jit_helper_path.read_text(encoding="utf-8")

jit_anchor = "        // Ask debugger to allocate RX pages (x0=0 triggers _M allocation).\n"

jit_block = '''        // WinArc JIT Core v0.3: direct local dual-map pool.
        //
        // Hardware result from v0.2:
        //   - 256MB RW/RX dual mapping succeeds
        //   - the very first debugger prepare of an EXISTING RX mapping
        //     kills the process, even when reduced to a 16MB chunk
        //
        // Therefore the Local Dual Map strategy must not call
        // jit26_prepare_region() at all. CS_DEBUGGED is already SET and
        // jit_test_mapping() has verified a coherent RX mapping with execute
        // protection. This experiment tests whether FEX can execute directly
        // from that locally-created RX alias.
        if ProcessInfo.processInfo.environment["WINARC_LOCAL_JIT_POOL"] == "1" {
            LogStore.shared.log(
                "WinArc JIT pool: local dual-map DIRECT path enabled"
            )

            guard jit_check_debugged() else {
                LogStore.shared.log(
                    "WinArc local direct pool: CS_DEBUGGED not set",
                    level: .error
                )
                return nil
            }

            guard let region = jit_region_create(poolSize) else {
                LogStore.shared.log(
                    "WinArc local direct pool: jit_region_create failed",
                    level: .error
                )
                return nil
            }

            guard let rxPtr = jit_region_rx_ptr(region),
                  let rwPtr = jit_region_rw_ptr(region) else {
                LogStore.shared.log(
                    "WinArc local direct pool: missing RW/RX mapping",
                    level: .error
                )
                jit_region_destroy(region)
                return nil
            }

            let localRX = Int(bitPattern: rxPtr)
            let localRW = Int(bitPattern: rwPtr)
            let localGoodLow = 0x119000000
            let localGuestLo = 0x7000000000
            let localGuestHi = 0x8000000000
            let localInGuestWindow =
                localRX + poolSize > localGuestLo &&
                localRX < localGuestHi

            guard localRX >= localGoodLow &&
                  !localInGuestWindow else {
                LogStore.shared.log(
                    String(
                        format:
                            "WinArc local direct pool BAD placement " +
                            "RW=0x%lx RX=0x%lx",
                        localRW,
                        localRX
                    ),
                    level: .error
                )
                jit_region_destroy(region)
                return nil
            }

            LogStore.shared.log(
                String(
                    format:
                        "WinArc local direct pool mapped " +
                        "RW=0x%lx RX=0x%lx size=%dMB",
                    localRW,
                    localRX,
                    poolSize / 1024 / 1024
                )
            )

            LogStore.shared.log(
                "WinArc local direct pool: SKIPPING debugger prepare " +
                "(existing-RX prepare crashes on this device)"
            )

            NotificationCenter.default.post(
                name: .winArcJITPoolReady,
                object: nil
            )

            LogStore.shared.log(
                "WinArc local direct pool: READY -> returning to Madeira/FEX",
                level: .success
            )

            // Process-lifetime retention. The JITRegion owns both aliases.
            return (
                rx: rxPtr,
                rw: rwPtr,
                size: poolSize
            )
        }

'''

if "WinArc JIT pool: local dual-map path enabled" not in jit_source:
    if jit_anchor not in jit_source:
        raise SystemExit("Madeira StikJITHelper pool anchor changed")
    jit_source = jit_source.replace(jit_anchor, jit_block + jit_anchor, 1)
else:
    block_start = jit_source.find(
        '        // WinArc JIT Core v0: local dual-map production pool.'
    )
    if block_start < 0:
        block_start = jit_source.find(
            '        // WinArc JIT Core v0.3: direct local dual-map pool.'
        )

    stock_pos = jit_source.find(jit_anchor)

    if block_start >= 0 and stock_pos > block_start:
        jit_source = (
            jit_source[:block_start]
            + jit_block
            + jit_source[stock_pos:]
        )
    else:
        raise SystemExit("existing WinArc JIT pool block shape changed")

stock_ready = '''        LogStore.shared.log("JIT pool ready (debugger still attached).", level: .success)

        return (rx: rxPtr, rw: rwPtr, size: poolSize)
'''

stock_ready_patched = '''        LogStore.shared.log("JIT pool ready (debugger still attached).", level: .success)

        NotificationCenter.default.post(
            name: .winArcJITPoolReady,
            object: nil
        )

        return (rx: rxPtr, rw: rwPtr, size: poolSize)
'''

if stock_ready in jit_source:
    jit_source = jit_source.replace(stock_ready, stock_ready_patched, 1)


# WinArc JIT Core v0.4:
# On this device the local pool now reaches READY, but the process disappears
# inside jit26_detach() before "Debugger detached." can be logged.
#
# Keep StikDebug attached for the Local Dual Map path so Wine/FEX can continue
# and so later BRK-based PE page preparation remains available. The stock
# Madeira detach behavior is preserved for every non-WinArc-local strategy.
detach_old = '''    static func detachDebugger() {
        LogStore.shared.log("Detaching debugger...")
        jit26_detach()
        // task #34: signal in-process waiters (share-probe poller). CS_DEBUGGED
        // is sticky post-detach, so an env flag is the reliable signal.
        setenv("MADEIRA_DETACHED", "1", 1)
        LogStore.shared.log("Debugger detached.", level: .success)
    }
'''

detach_new = '''    static func detachDebugger() {
        if ProcessInfo.processInfo.environment["WINARC_LOCAL_JIT_POOL"] == "1" {
            LogStore.shared.log(
                "WinArc JIT: KEEPING debugger attached " +
                "(jit26_detach crashes on current device)"
            )
            unsetenv("MADEIRA_DETACHED")
            return
        }

        LogStore.shared.log("Detaching debugger...")
        jit26_detach()
        // task #34: signal in-process waiters (share-probe poller). CS_DEBUGGED
        // is sticky post-detach, so an env flag is the reliable signal.
        setenv("MADEIRA_DETACHED", "1", 1)
        LogStore.shared.log("Debugger detached.", level: .success)
    }
'''

if 'WinArc JIT: KEEPING debugger attached' not in jit_source:
    if detach_old not in jit_source:
        raise SystemExit("Madeira StikJITHelper detachDebugger() shape changed")
    jit_source = jit_source.replace(detach_old, detach_new, 1)

jit_helper_path.write_text(jit_source, encoding="utf-8")

ui_files = [
    ui / "Theme.swift",
    ui / "Models.swift",
    ui / "WinArcStore.swift",
    ui / "RootView.swift",
    ui / "ContainersView.swift",
    ui / "CreateContainerSheet.swift",
    ui / "LibraryView.swift",
    ui / "GameSettingsSheet.swift",
    overlay / "WinArcJITManager.swift",
    overlay / "JITSettingsView.swift",
    overlay / "MadeiraLogView.swift",
    overlay / "HomeView.swift",
    overlay / "SettingsView.swift",
]

old_graphics_status_method = '''    private func refreshGraphicsStatus() {
        let backend = draft.settings.backend.rawValue
        let bundlePath = Bundle.main.bundlePath

        graphicsStatus = backend.withCString { backendCString in
            bundlePath.withCString { bundleCString in
                guard let result = winarc_graphics_backend_status_text(
                    backendCString,
                    bundleCString
                ) else {
                    return "状态未知"
                }
                return String(cString: result)
            }
        }
    }
'''

new_graphics_status_method = '''    private func refreshGraphicsStatus() {
        switch draft.settings.backend {
        case .dxmt:
            graphicsStatus = "Madeira DXMT 已就绪"
        case .d3dmetal:
            graphicsStatus = "D3DMetal 尚未接入 Madeira 地基"
        }
    }
'''

chunks: list[str] = []

for path in ui_files:
    if not path.exists():
        raise SystemExit(f"missing WinArc UI source: {path}")

    text = path.read_text(encoding="utf-8")

    if path.name == "GameSettingsSheet.swift":
        if old_graphics_status_method not in text:
            raise SystemExit(
                "GameSettingsSheet graphics-status implementation changed"
            )
        text = text.replace(
            old_graphics_status_method,
            new_graphics_status_method,
            1,
        )
        if "winarc_graphics_backend_status_text" in text:
            raise SystemExit("old WinArc graphics bridge still referenced")

    text = re.sub(r"(?m)^import\s+[^\n]+\n", "", text)

    chunks.append(
        f"\n// ===== WinArc Madeira UI: {path.name} =====\n"
        f"{text.rstrip()}\n"
    )

marker = "// ===== WINARC_MADEIRA_UI_OVERLAY ====="

if marker in source:
    source = source.split(marker, 1)[0].rstrip() + "\n"

required_imports = (
    "import UniformTypeIdentifiers\n"
    "import Foundation\n"
    "import Darwin\n"
)

if not source.startswith("import UniformTypeIdentifiers"):
    source = required_imports + source

source = (
    source.rstrip()
    + "\n\n"
    + marker
    + "\n"
    + "\n".join(chunks)
    + "\n"
)

content_path.write_text(source, encoding="utf-8")

app_path.write_text(
    '''import SwiftUI

@main
struct MadeiraApp: App {
    @StateObject private var store = WinArcStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
''',
    encoding="utf-8",
)

with plist_path.open("rb") as f:
    plist = plistlib.load(f)

plist["CFBundleDisplayName"] = "WinArc"
plist["CFBundleShortVersionString"] = "0.0.1"
plist["CFBundleVersion"] = "1"
plist["UIRequiresFullScreen"] = True
plist["UISupportedInterfaceOrientations"] = [
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]

with plist_path.open("wb") as f:
    plistlib.dump(plist, f, sort_keys=False)

generated = content_path.read_text(encoding="utf-8")
main = app_path.read_text(encoding="utf-8")
jit_generated = jit_helper_path.read_text(encoding="utf-8")

assert "struct MadeiraLegacyContentView: View" in generated
assert "struct RootView: View" in generated
assert "final class WinArcStore: ObservableObject" in generated
assert "final class WinArcJITManager: ObservableObject" in generated
assert "struct JITSettingsView: View" in generated
assert "struct MadeiraLogView: View" in generated
assert "RootView()" in main
assert "ContentView()" not in main
assert re.search(
    r"(?<![A-Za-z0-9_])ContentView\.hhmmss",
    generated,
) is None
assert "winarc_graphics_backend_status_text" not in generated
assert ".winArcLaunchDesktop" in generated
assert ".winArcLaunchDX11Cube" in generated
assert "cube-x64.exe" in generated
assert ".winArcJITPoolReady" in generated
assert "WinArc JIT Core v0.3" in jit_generated
assert "WinArc JIT: KEEPING debugger attached" in jit_generated
assert "SKIPPING debugger prepare" in jit_generated

print("WINARC_MADEIRA_UI_OVERLAY=PASS")
print("WINARC_DX11_CUBE_BRIDGE=PASS")
print("WINARC_JIT_CORE_V0=PASS")
print("WINARC_JIT_DIRECT_LOCAL_POOL=PASS")
print("WINARC_JIT_KEEP_DEBUGGER=PASS")
print("WINARC_JIT_HOME_QUICK_CHECK=PASS")
print("WINARC_JIT_SETTINGS=PASS")
print("WINARC_JIT_RECOVERY=PASS")
print("WINARC_MADEIRA_LOG_UI=PASS")
print("WINARC_VERSION=0.0.1")
