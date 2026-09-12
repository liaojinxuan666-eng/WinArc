# WinArc

WinArc is an independent Windows compatibility/runtime project for iOS.

## Current status

The Wine bring-up path currently uses Madeira's Wine implementation only as a temporary iOS reference/build source. WinArc is **not** a Madeira fork, and Madeira's app/UI/product structure is not part of WinArc.

Verified milestone:

- WinArc Wine bootstrap Revision 8: PASS
- Madeira Wine reference build: PASS
- ARM64 iPhoneOS native Wine archives produced successfully
- `libwineserver.a`: PASS
- `libntdll_unix.a`: PASS
- `libwin32u_unix.a`: PASS
- Wine `__wine_main` symbol verified
- WinArc remains an independent project

Current engineering stage:

```text
MADEIRA_WINE_REFERENCE_LINK
```

Next step: link the proven Wine native archives into WinArc's own in-process bring-up boundary, then move toward the first usable WinArc version.

## Wine strategy

Madeira Wine is used only for internal bring-up/reference work.

The formal WinArc Wine path will return to a compatible Wine/Juice baseline and reimplement the required iOS runtime work there instead of shipping Madeira's GPL Wine fork as the final base.

Target runtime direction:

```text
WinArc App
├─ Wine runtime
│  ├─ wineserver thread
│  ├─ ntdll Unix layer
│  └─ win32u Unix layer
├─ x86/x64 execution layer
├─ graphics backends
└─ WinArc UI / management layer
```

## Graphics roadmap

The first usable WinArc version will prioritize:

1. DXMT
2. D3DMetal backend interface

## Project boundaries

WinArc is its own project.

Madeira is currently used only as a Wine/iOS technical reference and temporary bring-up source. Madeira's application, UI, and product structure are not imported into WinArc.
