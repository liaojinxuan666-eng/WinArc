#!/usr/bin/env python3
"""Overlay WinArc's product UI onto a Madeira app checkout without touching
Madeira's working runtime implementation.

Usage:
  python3 app/madeira-ui-overlay.py /path/to/Madeira /path/to/WinArc

The donor ContentView is retained as MadeiraLegacyContentView so its runtime
controls, Metal host, input path and diagnostics remain available during the
migration.  The @main app is switched to RootView + WinArcStore.
"""
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
needle = "struct ContentView: View {"
if "struct MadeiraLegacyContentView: View {" not in source:
    if needle not in source:
        raise SystemExit("Madeira ContentView declaration not found")
    source = source.replace(needle, "struct MadeiraLegacyContentView: View {", 1)

# Keep source files separate in WinArc itself; concatenate only into Madeira's
# already-tracked ContentView.swift so we do not have to rewrite its pbxproj.
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

chunks: list[str] = []
for path in ui_files:
    if not path.exists():
        raise SystemExit(f"missing WinArc UI source: {path}")
    text = path.read_text(encoding="utf-8")
    # Imports are moved to the generated-file header; leaving imports between
    # declarations makes Swift parser behaviour unnecessarily version-sensitive.
    text = re.sub(r"(?m)^import\s+[^\n]+\n", "", text)
    chunks.append(f"\n// ===== WinArc overlay: {path.name} =====\n{text.rstrip()}\n")

marker = "// ===== WINARC_MADEIRA_UI_OVERLAY ====="
if marker in source:
    source = source.split(marker, 1)[0].rstrip() + "\n"

header = "import UniformTypeIdentifiers\nimport Foundation\n"
if not source.startswith("import UniformTypeIdentifiers"):
    source = header + source

source = source.rstrip() + f"\n\n{marker}\n" + "\n".join(chunks) + "\n"
content_path.write_text(source, encoding="utf-8")

app_path.write_text(
    '''import SwiftUI\n\n@main\nstruct MadeiraApp: App {\n    @StateObject private var store = WinArcStore()\n\n    var body: some Scene {\n        WindowGroup {\n            RootView()\n                .environmentObject(store)\n                .preferredColorScheme(.dark)\n        }\n    }\n}\n''',
    encoding="utf-8",
)

if plist_path.exists():
    with plist_path.open("rb") as f:
        plist = plistlib.load(f)
    plist["CFBundleDisplayName"] = "WinArc"
    plist["UIRequiresFullScreen"] = True
    plist["UISupportedInterfaceOrientations"] = [
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]
    with plist_path.open("wb") as f:
        plistlib.dump(plist, f, sort_keys=False)

# Hard gates: the app root must be WinArc while the donor runtime console stays.
generated = content_path.read_text(encoding="utf-8")
main = app_path.read_text(encoding="utf-8")
assert "struct MadeiraLegacyContentView: View" in generated
assert "struct RootView: View" in generated
assert "final class WinArcStore: ObservableObject" in generated
assert "RootView()" in main
assert "ContentView()" not in main

print("WINARC_MADEIRA_UI_OVERLAY=PASS")
print(f"MADEIRA_APP_ROOT={app_path}")
print(f"MADEIRA_UI_SOURCE={content_path}")
