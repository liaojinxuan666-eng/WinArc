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

for p in (content_path, app_path, ui, overlay):
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
            }
'''

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
            raise SystemExit("GameSettingsSheet graphics-status implementation changed")
        text = text.replace(old_graphics_status_method, new_graphics_status_method, 1)
        if "winarc_graphics_backend_status_text" in text:
            raise SystemExit("old WinArc graphics bridge still referenced")

    text = re.sub(r"(?m)^import\s+[^\n]+\n", "", text)
    chunks.append(f"\n// ===== WinArc Madeira UI: {path.name} =====\n{text.rstrip()}\n")

marker = "// ===== WINARC_MADEIRA_UI_OVERLAY ====="
if marker in source:
    source = source.split(marker, 1)[0].rstrip() + "\n"

header = "import UniformTypeIdentifiers\nimport Foundation\n"
if not source.startswith("import UniformTypeIdentifiers"):
    source = header + source

source = source.rstrip() + f"\n\n{marker}\n" + "\n".join(chunks) + "\n"
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

if plist_path.exists():
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
assert "RootView()" in main
assert "ContentView()" not in main
assert re.search(r"(?<![A-Za-z0-9_])ContentView\.hhmmss", generated) is None
assert "winarc_graphics_backend_status_text" not in generated
assert ".winArcLaunchDesktop" in generated

print("WINARC_MADEIRA_UI_OVERLAY=PASS")
print("WINARC_MADEIRA_DESKTOP_BRIDGE=PASS")
print("WINARC_VERSION=0.0.1")
print(f"MADEIRA_APP_ROOT={app_path}")
print(f"MADEIRA_UI_SOURCE={content_path}")
