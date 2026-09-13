#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: madeira-runtime-patch.py <madeira-checkout>")

madeira = Path(sys.argv[1]).resolve()
virtual = madeira / "build" / "ntdll-unix" / "virtual_ios.c"

if not virtual.exists():
    raise SystemExit(f"missing Madeira virtual_ios.c: {virtual}")

src = virtual.read_text(encoding="utf-8")

marker = "WINARC_PE16K_DIRECT_EXEC_BYPASS"

if marker not in src:
    anchor = '''        /* Try normal mprotect first (works on non-TXM devices). On iOS TXM,
         * mprotect with PROT_EXEC may *appear* to succeed (return 0) without
         * actually granting EXEC — pages stay RW only. Verify by querying the
         * actual page protection via Mach vm_region_64; only return early if
         * EXEC was truly granted. */
'''

    if anchor not in src:
        raise SystemExit(
            "Madeira virtual_ios.c direct-exec anchor changed"
        )

    injected = '''        /* WINARC_PE16K_DIRECT_EXEC_BYPASS
         *
         * WinArc's local dual-map JIT mode already has an executable RX pool.
         * Do NOT first ask iOS/TXM to add PROT_EXEC to the original Wine PE
         * mapping. On 16KB iOS host pages, one host page can contain both a
         * Windows 4KB executable page and a Windows 4KB writable/.data page.
         *
         * Device evidence: after an executable transition on cube.exe,
         * 0x140038000 became prot=0/max=0 even though Wine's vprot still said
         * READ/WRITECOPY. The later .data store then could not be healed:
         * mprotect(..., RW) returned EACCES.
         *
         * In WinArc local-pool mode, execution belongs to the pool RX alias
         * anyway. Skip the speculative direct-exec attempt and go straight to
         * Madeira's existing pool-copy / existing-mapping logic below. That
         * logic keeps writable PE state on the original VA and executable
         * code on the pool RX alias, which is exactly what a mixed 16KB page
         * needs.
         */
        const char *winarc_local_pool_env = getenv("WINARC_LOCAL_JIT_POOL");
        int winarc_force_pool_exec =
            winarc_local_pool_env && winarc_local_pool_env[0] == '1';

        if (winarc_force_pool_exec)
        {
            static int winarc_exec_bypass_n;
            if (winarc_exec_bypass_n < 48)
            {
                dprintf(
                    2,
                    "[WinArc PE16K] bypass direct PROT_EXEC #%d "
                    "base=%p size=0x%lx prot=%c%c%c -> pool path\\n",
                    ++winarc_exec_bypass_n,
                    base,
                    (unsigned long)size,
                    (unix_prot & PROT_READ) ? 'r' : '-',
                    (unix_prot & PROT_WRITE) ? 'w' : '-',
                    (unix_prot & PROT_EXEC) ? 'x' : '-'
                );
            }
        }

''' + anchor

    src = src.replace(anchor, injected, 1)

    old_if = "        if (!mprotect( base, size, unix_prot ))\n"
    new_if = (
        "        if (!winarc_force_pool_exec && "
        "!mprotect( base, size, unix_prot ))\n"
    )

    anchor_pos = src.find(marker)
    if anchor_pos < 0:
        raise SystemExit("WinArc PE16K marker insertion failed")

    if_pos = src.find(old_if, anchor_pos)
    if if_pos < 0:
        raise SystemExit(
            "Madeira virtual_ios.c direct mprotect call changed"
        )

    src = src[:if_pos] + src[if_pos:].replace(old_if, new_if, 1)

if marker not in src:
    raise SystemExit("WINARC_PE16K_DIRECT_EXEC_BYPASS missing")

if (
    "if (!winarc_force_pool_exec && "
    "!mprotect( base, size, unix_prot ))"
    not in src
):
    raise SystemExit("WinArc direct-exec bypass condition missing")

virtual.write_text(src, encoding="utf-8")

print("WINARC_MADEIRA_RUNTIME_PATCH=PASS")
print("WINARC_PE16K_DIRECT_EXEC_BYPASS=PASS")
