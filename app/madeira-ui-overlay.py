#!/usr/bin/env python3
from __future__ import annotations

import plistlib
import re
import subprocess
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
jit_allocator_path = donor / "JITAllocator.c"
provider_patch_path = winarc / "app" / "madeira-jit-provider-patch.py"

for p in (
    content_path,
    app_path,
    plist_path,
    jit_helper_path,
    jit_allocator_path,
    provider_patch_path,
    ui,
    overlay,
):
    if not p.exists():
        raise SystemExit(f"missing required path: {p}")

# Route lock: StikJITHelper, FEX, Wine and DXMT stay stock. The only
# permitted JIT integration change is the provider adapter in JITAllocator.c.
jit_helper_original = jit_helper_path.read_bytes()

provider = subprocess.run(
    [sys.executable, str(provider_patch_path), str(madeira)],
    check=False,
    capture_output=True,
    text=True,
)
if provider.stdout:
    print(provider.stdout, end="")
if provider.stderr:
    print(provider.stderr, end="", file=sys.stderr)
if provider.returncode != 0:
    raise SystemExit(
        f"WinArc JIT provider patch failed with exit {provider.returncode}"
    )
if "WINARC_INPROCESS_JIT_PROVIDER_V1=PASS" not in provider.stdout:
    raise SystemExit("WinArc JIT provider patch did not report PASS")
if "WINARC_INPROCESS_JIT_PROVIDER_V1" not in jit_allocator_path.read_text(
    encoding="utf-8"
):
    raise SystemExit("WinArc JIT provider marker missing from JITAllocator.c")

source = content_path.read_text(encoding="utf-8")

if "struct MadeiraLegacyContentView: View {" not in source:
    if "struct ContentView: View {" not in source:
        raise SystemExit("Madeira ContentView declaration not found")
    source = re.sub(r"\bContentView\b", "MadeiraLegacyContentView", source)

launch_hook_old = """            .onAppear {
                jit_install_trap_handler()
                entitlements = EntitlementStatus.check()
                logEntitlementStatus()
            }
"""

launch_hook_new = launch_hook_old + """            .onReceive(NotificationCenter.default.publisher(for: .winArcLaunchDesktop)) { _ in
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .winArcLaunchDX11Cube)) { _ in
                // A/B isolation only:
                // keep the currently working WinArc JIT Provider + Madeira
                // runtime unchanged, but use Madeira's native ARM64 DX11 cube
                // so FEX / ARM64EC are removed from this one test.
                //
                // WineProcessBridge's stock default is cube.exe and classifies
                // cube.exe into the aarch64-windows bundle.
                LogStore.shared.log(
                    "[WinArc DX11 A/B] Madeira stock ARM64 cube.exe path (no FEX)"
                )

                setenv("MADEIRA_EXE", "cube.exe", 1)
                unsetenv("MADEIRA_ARGS")
                unsetenv("MADEIRA_DESKTOP")
                unsetenv("MADEIRA_SCREEN_W")
                unsetenv("MADEIRA_SCREEN_H")

                runWineFullSequence()
            }

"""

if ".winArcLaunchDesktop" not in source:
    if launch_hook_old not in source:
        raise SystemExit("Madeira runtime onAppear hook changed")
    source = source.replace(launch_hook_old, launch_hook_new, 1)

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

old_graphics_status_method = """    private func refreshGraphicsStatus() {
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
"""

new_graphics_status_method = """    private func refreshGraphicsStatus() {
        switch draft.settings.backend {
        case .dxmt:
            graphicsStatus = "Madeira DXMT 已就绪"
        case .d3dmetal:
            graphicsStatus = "D3DMetal 计划保留，等待 DXMT 基线稳定后接入"
        }
    }
"""

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
    """import SwiftUI

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
""",
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
assert "[WinArc DX11 A/B] Madeira stock ARM64 cube.exe path (no FEX)" in generated
assert 'setenv("MADEIRA_EXE", "cube.exe", 1)' in generated
assert "runWineFullSequence()" in generated

# Route lock: the overlay is not allowed to mutate Madeira's JIT helper.
assert jit_helper_path.read_bytes() == jit_helper_original
assert "WinArc JIT Core v0.3" not in jit_helper_path.read_text(encoding="utf-8")
assert "WINARC_LOCAL_JIT_POOL" not in jit_helper_path.read_text(encoding="utf-8")

print("WINARC_MADEIRA_UI_OVERLAY=PASS")
print("WINARC_MADEIRA_STIKJITHELPER_UNTOUCHED=PASS")
print("WINARC_JIT_PROVIDER=INPROCESS")
print("WINARC_DX11_STOCK_PATH=PASS")
print("WINARC_DX11_ISOLATION=ARM64_STOCK_NO_FEX")
print("WINARC_D3DMETAL_PLAN=PRESERVED")
print("WINARC_WINE_LITE_PLAN=PRESERVED")
print("WINARC_MADEIRA_LOG_UI=PASS")
print("WINARC_VERSION=0.0.1")
