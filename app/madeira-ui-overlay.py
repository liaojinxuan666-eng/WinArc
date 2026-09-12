#!/usr/bin/env python3
"""
Attach WinArc's product UI to the Madeira app while preserving
Madeira's runtime implementation.

Usage:
  python3 app/madeira-ui-overlay.py /path/to/Madeira /path/to/WinArc
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


if len(sys.argv) != 3:
    raise SystemExit(
        "usage: madeira-ui-overlay.py <madeira-checkout> <winarc-checkout>"
    )


madeira = Path(sys.argv[1]).resolve()
winarc = Path(sys.argv[2]).resolve()

donor = madeira / "app" / "Madeira"
ui = winarc / "app" / "WinArc"
overlay = winarc / "app" / "MadeiraOverlay"

content_path = donor / "ContentView.swift"
app_path = donor / "MadeiraApp.swift"
plist_path = donor / "Info.plist"


for path in (
    content_path,
    app_path,
    ui,
    overlay,
):
    if not path.exists():
        raise SystemExit(
            f"missing required path: {path}"
        )


# ============================================================
# Preserve Madeira runtime UI under a new internal name.
# ============================================================

source = content_path.read_text(
    encoding="utf-8"
)

old_root = "struct ContentView: View {"
new_root = "struct MadeiraLegacyContentView: View {"


if new_root not in source:
    if old_root not in source:
        raise SystemExit(
            "Madeira ContentView declaration not found"
        )

    # Rename the declaration.
    source = source.replace(
        old_root,
        new_root,
        1,
    )

    # Madeira's ContentView contains internal references such as:
    #
    #     ContentView.hhmmss
    #
    # Once the type itself has been renamed these references must
    # follow the new type name as well.
    #
    # This replacement happens BEFORE WinArc sources are appended,
    # therefore WinArc's own view names are not affected.
    source = re.sub(
        r"\bContentView\b",
        "MadeiraLegacyContentView",
        source,
    )


# ============================================================
# WinArc UI source list
# ============================================================

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


# ============================================================
# Madeira-backed GameSettings compatibility adjustment
# ============================================================

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
        raise SystemExit(
            f"missing WinArc UI source: {path}"
        )

    text = path.read_text(
        encoding="utf-8"
    )

    # GameSettingsSheet in the old WinArc app queried
    # WinArcRuntime's GraphicsBackendBridge directly.
    #
    # Madeira is now the runtime foundation, so that old bridge
    # must not be referenced from the Madeira app.
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
            raise SystemExit(
                "old WinArc graphics bridge still referenced"
            )

    # Imports are collected at the generated source header.
    text = re.sub(
        r"(?m)^import\s+[^\n]+\n",
        "",
        text,
    )

    chunks.append(
        "\n"
        f"// ===== WinArc Madeira UI: {path.name} =====\n"
        f"{text.rstrip()}\n"
    )


# ============================================================
# Avoid accidentally appending WinArc twice
# ============================================================

marker = "// ===== WINARC_MADEIRA_UI_OVERLAY ====="


if marker in source:
    source = (
        source
        .split(marker, 1)[0]
        .rstrip()
        + "\n"
    )


# ============================================================
# Generated Swift source header
# ============================================================

required_imports = (
    "import UniformTypeIdentifiers\n"
    "import Foundation\n"
)


if not source.startswith(
    "import UniformTypeIdentifiers"
):
    source = (
        required_imports
        + source
    )


# ============================================================
# Append WinArc product UI
# ============================================================

source = (
    source.rstrip()
    + "\n\n"
    + marker
    + "\n"
    + "\n".join(chunks)
    + "\n"
)


content_path.write_text(
    source,
    encoding="utf-8",
)


# ============================================================
# WinArc becomes the app root.
# Madeira remains the runtime foundation.
# ============================================================

app_source = '''import SwiftUI

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
'''


app_path.write_text(
    app_source,
    encoding="utf-8",
)


# ============================================================
# Product identity / orientation
# ============================================================

if plist_path.exists():
    with plist_path.open("rb") as file:
        plist = plistlib.load(file)

    plist["CFBundleDisplayName"] = "WinArc"
    plist["UIRequiresFullScreen"] = True

    plist["UISupportedInterfaceOrientations"] = [
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ]

    with plist_path.open("wb") as file:
        plistlib.dump(
            plist,
            file,
            sort_keys=False,
        )


# ============================================================
# Hard integration gates
# ============================================================

generated = content_path.read_text(
    encoding="utf-8"
)

main = app_path.read_text(
    encoding="utf-8"
)


assert (
    "struct MadeiraLegacyContentView: View"
    in generated
)

assert (
    "struct RootView: View"
    in generated
)

assert (
    "final class WinArcStore: ObservableObject"
    in generated
)

assert (
    "RootView()"
    in main
)

assert (
    "ContentView()"
    not in main
)

assert (
    "ContentView.hhmmss"
    not in generated
)

assert (
    "winarc_graphics_backend_status_text"
    not in generated
)


print(
    "WINARC_MADEIRA_UI_OVERLAY=PASS"
)

print(
    "WINARC_MADEIRA_CONTENTVIEW_RENAME=PASS"
)

print(
    "WINARC_OLD_GRAPHICS_BRIDGE_REMOVED=PASS"
)

print(
    f"MADEIRA_APP_ROOT={app_path}"
)

print(
    f"MADEIRA_UI_SOURCE={content_path}"
)