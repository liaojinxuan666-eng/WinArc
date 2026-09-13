#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "WINARC_INPROCESS_JIT_PROVIDER_V1"

if len(sys.argv) != 2:
    raise SystemExit("usage: madeira-jit-provider-patch.py <madeira-checkout>")

madeira = Path(sys.argv[1]).resolve()
target = madeira / "app" / "Madeira" / "JITAllocator.c"
stik = madeira / "app" / "Madeira" / "StikJITHelper.swift"

if not target.is_file():
    raise SystemExit(f"missing Madeira JITAllocator.c: {target}")
if not stik.is_file():
    raise SystemExit(f"missing Madeira StikJITHelper.swift: {stik}")

stik_before = stik.read_bytes()
src = target.read_text(encoding="utf-8")

if MARKER in src:
    if stik.read_bytes() != stik_before:
        raise SystemExit("StikJITHelper changed unexpectedly")
    print("WINARC_INPROCESS_JIT_PROVIDER_V1=PASS")
    print("WINARC_STIKJITHELPER_UNTOUCHED=PASS")
    raise SystemExit(0)

state_anchor = "static jit_log_callback_t g_log_callback = NULL;\n"

state_block = r'''
/*
 * WINARC_INPROCESS_JIT_PROVIDER_V1
 *
 * Provider adapter only. Madeira/FEX/Wine/DXMT stay intact.
 *
 * Madeira's stock jit26_prepare_region() is a BRK RPC to StikDebug.
 * WinArc provider mode replaces only that provider boundary and uses
 * Madeira's own jit_region_create() dual-map allocator.
 */
#define WINARC_PROVIDER_MAX_REGIONS 32
static JITRegion *winarc_provider_regions[WINARC_PROVIDER_MAX_REGIONS];
static size_t winarc_provider_region_count;
static pthread_mutex_t winarc_provider_lock = PTHREAD_MUTEX_INITIALIZER;

static int winarc_inprocess_provider_enabled(void)
{
    const char *v = getenv("WINARC_JIT_PROVIDER");
    return v && !strcmp(v, "inprocess");
}

static void *winarc_inprocess_prepare_region(void *addr, size_t len)
{
    if (!len)
    {
        jit_log("[WinArc JIT Provider] refused zero-length request");
        return NULL;
    }

    if (addr)
    {
        kern_return_t kr = vm_protect(
            mach_task_self(),
            (vm_address_t)addr,
            (vm_size_t)len,
            FALSE,
            VM_PROT_READ | VM_PROT_EXECUTE
        );

        if (kr != KERN_SUCCESS)
        {
            jit_log(
                "[WinArc JIT Provider] existing RX prepare failed "
                "addr=%p size=%zu kr=%d",
                addr, len, kr
            );
            return NULL;
        }

        sys_icache_invalidate(addr, len);
        jit_log(
            "[WinArc JIT Provider] existing RX prepared addr=%p size=%zu",
            addr, len
        );
        return addr;
    }

    JITRegion *region = jit_region_create(len);
    if (!region)
    {
        jit_log(
            "[WinArc JIT Provider] Madeira jit_region_create failed size=%zu",
            len
        );
        return NULL;
    }

    void *rx = jit_region_rx_ptr(region);
    void *rw = jit_region_rw_ptr(region);
    if (!rx || !rw)
    {
        jit_log("[WinArc JIT Provider] Madeira region missing RW/RX alias");
        jit_region_destroy(region);
        return NULL;
    }

    pthread_mutex_lock(&winarc_provider_lock);
    if (winarc_provider_region_count >= WINARC_PROVIDER_MAX_REGIONS)
    {
        pthread_mutex_unlock(&winarc_provider_lock);
        jit_log("[WinArc JIT Provider] retained-region table full");
        jit_region_destroy(region);
        return NULL;
    }

    winarc_provider_regions[winarc_provider_region_count++] = region;
    size_t slot = winarc_provider_region_count;
    pthread_mutex_unlock(&winarc_provider_lock);

    jit_log(
        "[WinArc JIT Provider] READY slot=%zu RX=%p RW=%p size=%zu",
        slot, rx, rw, len
    );
    return rx;
}
'''

if state_anchor not in src:
    raise SystemExit("Madeira JITAllocator state anchor changed")

src = src.replace(state_anchor, state_anchor + state_block + "\n", 1)

prepare_anchor = '''__attribute__((noinline, optnone))
void *jit26_prepare_region(void *addr, size_t len) {
'''

prepare_new = prepare_anchor + '''    if (winarc_inprocess_provider_enabled())
        return winarc_inprocess_prepare_region(addr, len);

'''

if prepare_anchor not in src:
    raise SystemExit("Madeira jit26_prepare_region() shape changed")
src = src.replace(prepare_anchor, prepare_new, 1)

detach_anchor = '''__attribute__((noinline, optnone))
void jit26_detach(void) {
'''

detach_new = detach_anchor + '''    if (winarc_inprocess_provider_enabled())
    {
        jit_log(
            "[WinArc JIT Provider] detach = no-op "
            "(device JIT state remains owned by provider)"
        );
        return;
    }

'''

if detach_anchor not in src:
    raise SystemExit("Madeira jit26_detach() shape changed")
src = src.replace(detach_anchor, detach_new, 1)

if MARKER not in src:
    raise SystemExit("provider marker missing after patch")
if "return winarc_inprocess_prepare_region(addr, len);" not in src:
    raise SystemExit("provider prepare bypass missing")
if "[WinArc JIT Provider] detach = no-op" not in src:
    raise SystemExit("provider detach bypass missing")
if 'brk #0xf00d' not in src:
    raise SystemExit("stock Madeira BRK fallback disappeared")

target.write_text(src, encoding="utf-8")

if stik.read_bytes() != stik_before:
    raise SystemExit("route violation: StikJITHelper was modified")

print("WINARC_INPROCESS_JIT_PROVIDER_V1=PASS")
print("WINARC_JIT_PROVIDER_SCOPE=JITAllocator.c_ONLY")
print("WINARC_STIKJITHELPER_UNTOUCHED=PASS")
