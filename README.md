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

Revision 9 adds the next link gate (iPhoneOS CI validation pending):

- Isolate four server globals from the NTDLL client copies: `native_machine`,
  `server_start_time`, `supported_machines`, and `supported_machines_count`.
  Rewrite both definitions and references in a separate copy of the server archive.
- Inspect every archive member for ARM64/iPhoneOS, defined entry symbols,
  duplicate external state, and remaining imports.
- Force-load all seven reference archives into a relocatable Mach-O object
  together with WinArc's own entry-address boundary. Package the result as
  `libWinArcWineReference.a` for internal integration.
- Keep executable linking and runtime execution explicitly **NOT_RUN**.
  A relocatable link permits unresolved imports; it is not a runnable app.
- Stop rebuilding the already-verified Revision 6 baseline on every CI run.
  `WINARC_VERIFY_LEGACY=1 bash wine/bootstrap-wine.sh` retains that optional check.

The archive audit was checked against the actual Revision 8 CI artifacts:
all four state collisions were detected before isolation and absent afterward.
The remaining imports include Apple system functions and missing host/display/
DXMT hooks; they are recorded in `winarc-reference-link-audit.json` and, after
linking, `winarc-reference-unresolved.txt`. They are not replaced with success stubs.

Next: implement the host boundary and pass a strict executable link before
attempting Wine process startup. Juice and upstream Wine remain references
for the compatible final implementation; Madeira app/UI code is not imported.

Local validation: `python3 -m unittest discover -s tests -p 'test_*.py'`.
The existing `wine/bootstrap-wine.sh` remains the only build entry point.

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
