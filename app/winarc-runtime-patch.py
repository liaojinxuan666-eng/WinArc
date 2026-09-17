#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

JIT_MARKER = "WINARC_JIT_CORE_V1"
WINE_MARKER = "WINARC_PE_SOURCE_PROTECT_V2"

args = sys.argv[1:]
if len(args) not in (1, 2):
    raise SystemExit("usage: winarc-runtime-patch.py <madeira-checkout> [--wine-only|--fex-only]")

root = Path(args[0]).resolve()
wine_only = len(args) == 2 and args[1] == "--wine-only"
fex_only = len(args) == 2 and args[1] == "--fex-only"
if len(args) == 2 and not (wine_only or fex_only):
    raise SystemExit(f"unknown mode: {args[1]}")

if fex_only:
    # This is the PE translator, not the native FEXBridge test context.
    # Rebuild arm64ecfex and replace xtajit64.dll after applying this mode.
    path = root / "FEX/Source/Windows/Common/CPUFeatures.cpp"
    source = path.read_text(encoding="utf-8")
    start = source.index("#ifdef FEX_IOS_HOST\n", source.index("CPUFeatures::FetchHostFeatures"))
    end = source.index("#else", start)
    block = source[start:end]
    marker = "WINARC_FEX_BASELINE_V1"
    if marker not in block:
        for feature in ("FlagM", "FlagM2", "AFP"):
            old = f"  HostFeatures.Supports{feature} = true;"
            if block.count(old) != 1:
                raise SystemExit(f"FEX host feature anchor changed: {feature}")
            block = block.replace(old, f"  HostFeatures.Supports{feature} = false;")
        anchor = "  HostFeatures.HostType = HostType;"
        if block.count(anchor) != 1:
            raise SystemExit("FEX HostType anchor changed")
        block = block.replace(anchor, anchor + '\n  // WINARC_FEX_BASELINE_V1: optional extensions require positive detection.\n'
                              '  LogMan::Msg::IFmt("WINARC_FEX_BASELINE_V1 FlagM=0 FlagM2=0 AFP=0");')
        source = source[:start] + block + source[end:]
        path.write_text(source, encoding="utf-8")
    for feature in ("FlagM", "FlagM2", "AFP"):
        if f"HostFeatures.Supports{feature} = false;" not in block:
            raise SystemExit(f"FEX baseline verification failed: {feature}")
    print("WINARC_FEX_BASELINE_V1=PASS")
    raise SystemExit(0)

wine_path = root / "build" / "ntdll-unix" / "virtual_ios.c"
if not wine_path.is_file():
    raise SystemExit(f"missing Madeira Wine source: {wine_path}")

wine = wine_path.read_text(encoding="utf-8")

if WINE_MARKER not in wine:
    helper_anchor = '''volatile int ios_in_mach_exc;

static inline int mprotect_exec( void *base, size_t size, int unix_prot )
'''
    if helper_anchor not in wine:
        raise SystemExit("virtual_ios.c mprotect_exec anchor changed")

    helper = r'''volatile int ios_in_mach_exc;

/* ===== WINARC_PE_SOURCE_PROTECT_V2 =====
 *
 * Wine tracks PE protection at 4KB granularity, while iOS has 16KB host pages.
 * One host page can therefore contain both executable bytes and WRITECOPY/data.
 * PE execution is redirected to Madeira's JIT-pool copy; the original PE VA
 * stays as the loader/data/identity address space and must not be flattened by
 * a direct RX/RWX mprotect of the whole 16KB host page.
 */
static int winarc_is_sec_image_range( void *base, size_t size )
{
    struct file_view *view;
    if (!size) return 0;
    view = find_view( base, 1 );
    return view && (view->protect & SEC_IMAGE);
}

/* Restore physical source pages from the union of Wine's logical 4KB vprot.
 * EXEC is intentionally removed from the source mapping; instruction fetches
 * use the JIT-pool copy.  Mixed code/data host pages therefore become RW, while
 * pure code host pages become R.
 */
static void winarc_restore_pe_source_protection( void *base, size_t size,
                                                  const char *site )
{
    uintptr_t b = (uintptr_t)base;
    uintptr_t e = b + size;
    uintptr_t p, end;
    static unsigned int log_n;

    if (!size || e < b) return;

    p = b & ~(uintptr_t)host_page_mask;
    end = (e + host_page_mask) & ~(uintptr_t)host_page_mask;

    for (; p < end; p += host_page_size)
    {
        BYTE vprot = get_host_page_vprot( (void *)p );
        int want = get_unix_prot( vprot ) & ~PROT_EXEC;
        int rc = mprotect( (void *)p, host_page_size, want );
        kern_return_t kr = KERN_SUCCESS;
        mach_vm_address_t q = (mach_vm_address_t)p;
        mach_vm_size_t qsize = 0;
        vm_region_basic_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        int have_info = 0, satisfied = 0;
        vm_prot_t need = 0;

        if (want & PROT_READ)  need |= VM_PROT_READ;
        if (want & PROT_WRITE) need |= VM_PROT_WRITE;

        if (mach_vm_region( mach_task_self(), &q, &qsize, VM_REGION_BASIC_INFO_64,
                            (vm_region_info_t)&info, &count, &obj ) == KERN_SUCCESS &&
            q <= (mach_vm_address_t)p &&
            q + qsize > (mach_vm_address_t)p)
        {
            have_info = 1;
            satisfied = (rc == 0) && ((info.protection & need) == need);
            if (want == PROT_NONE) satisfied = (rc == 0) && !info.protection;
        }

        if (!satisfied && want != PROT_NONE)
        {
            kr = vm_protect( mach_task_self(), (vm_address_t)p,
                             (vm_size_t)host_page_size, FALSE, need );

            if (kr != KERN_SUCCESS && (need & VM_PROT_WRITE))
                kr = vm_protect( mach_task_self(), (vm_address_t)p,
                                 (vm_size_t)host_page_size, FALSE,
                                 need | VM_PROT_COPY );

            q = (mach_vm_address_t)p;
            qsize = 0;
            count = VM_REGION_BASIC_INFO_COUNT_64;
            obj = MACH_PORT_NULL;
            if (mach_vm_region( mach_task_self(), &q, &qsize,
                                VM_REGION_BASIC_INFO_64,
                                (vm_region_info_t)&info, &count, &obj )
                == KERN_SUCCESS)
                have_info = 1;
        }

        if (!ios_in_mach_exc && log_n < 32)
        {
            ++log_n;
            dprintf( 2,
                     "[WinArc PE Protect] %s host=%p vprot=0x%x want=%c%c "
                     "mprotect=%d vmkr=%d actual=%s0x%x max=%s0x%x rev=v2\n",
                     site ? site : "?",
                     (void *)p, (unsigned)vprot,
                     (want & PROT_READ) ? 'r' : '-',
                     (want & PROT_WRITE) ? 'w' : '-',
                     rc, (int)kr,
                     have_info ? "" : "?", have_info ? info.protection : 0,
                     have_info ? "" : "?", have_info ? info.max_protection : 0 );
        }
    }
}

static inline int mprotect_exec( void *base, size_t size, int unix_prot )
'''
    wine = wine.replace(helper_anchor, helper, 1)

    # V2 root fix: Madeira's force_exec_prot runs BEFORE the iOS JIT-pool
    # branch. V1 intercepted only the later explicit PROT_EXEC path, so a
    # normal R/RW SEC_IMAGE request could be force-upgraded to RX/RWX first
    # and permanently collapse an iOS 16KB host page to prot/max_prot == 0.
    force_anchor = r'''    if (force_exec_prot && (unix_prot & PROT_READ) && !(unix_prot & PROT_EXEC))
    {
        if (!ios_in_mach_exc)                   /* ml374: see ios_in_mach_exc */
            TRACE( "forcing exec permission on %p-%p\n", base, (char *)base + size - 1 );
        if (!mprotect( base, size, unix_prot | PROT_EXEC )) return 0;
        /* exec + write may legitimately fail, in that case fall back to write only */
        if (!(unix_prot & PROT_WRITE)) return -1;
    }

#ifdef WINE_IOS
'''
    force_repl = r'''#ifdef WINE_IOS
    /* ===== WINARC_PE_SOURCE_PROTECT_V2 =====
     * The original SEC_IMAGE mapping is never an execution source on iOS;
     * the JIT-pool copy is. Suppress force_exec_prot BEFORE it can poison
     * the source mapping's 16KB host page.
     */
    if (force_exec_prot && (unix_prot & PROT_READ) &&
        !(unix_prot & PROT_EXEC) &&
        winarc_is_sec_image_range( base, size ))
    {
        static unsigned int force_skip_n;
        if (!ios_in_mach_exc && force_skip_n++ < 32)
            dprintf( 2,
                     "[WinArc PE Protect] suppress force_exec on SEC_IMAGE "
                     "%p+0x%lx requested=%c%c-; source remains non-exec rev=v2\n",
                     base, (unsigned long)size,
                     (unix_prot & PROT_READ)  ? 'r' : '-',
                     (unix_prot & PROT_WRITE) ? 'w' : '-' );
    }
    else
#endif
    if (force_exec_prot && (unix_prot & PROT_READ) && !(unix_prot & PROT_EXEC))
    {
        if (!ios_in_mach_exc)                   /* ml374: see ios_in_mach_exc */
            TRACE( "forcing exec permission on %p-%p\n", base, (char *)base + size - 1 );
        if (!mprotect( base, size, unix_prot | PROT_EXEC )) return 0;
        /* exec + write may legitimately fail, in that case fall back to write only */
        if (!(unix_prot & PROT_WRITE)) return -1;
    }

#ifdef WINE_IOS
'''
    if force_anchor not in wine:
        raise SystemExit("virtual_ios.c force_exec_prot anchor changed")
    wine = wine.replace(force_anchor, force_repl, 1)

    # Scope the executable path by code, not by a prose comment whose UTF-8
    # punctuation was corrupted during transfer. Require a unique body match.
    normal_anchor = r'''        if (!mprotect( base, size, unix_prot ))
        {
            mach_vm_address_t addr = (mach_vm_address_t)base;
'''
    normal_repl = r'''        /* WinArc: SEC_IMAGE executable ranges always use the JIT-pool copy.
         * Do not let direct RX/RWX mprotect touch the original PE mapping:
         * iOS has 16KB host pages while PE protection is 4KB-granular. */
        if (winarc_is_sec_image_range( base, size ))
        {
            static unsigned int skip_n;
            if (!ios_in_mach_exc && skip_n++ < 24)
                dprintf( 2, "[WinArc PE Protect] skip direct EXEC mprotect for SEC_IMAGE "
                             "%p+0x%lx prot=%c%c%c; routing execution to pool copy\n",
                         base, (unsigned long)size,
                         (unix_prot & PROT_READ)  ? 'r' : '-',
                         (unix_prot & PROT_WRITE) ? 'w' : '-',
                         (unix_prot & PROT_EXEC)  ? 'x' : '-' );
        }
        else if (!mprotect( base, size, unix_prot ))
        {
            mach_vm_address_t addr = (mach_vm_address_t)base;
'''
    function_start = wine.index("static inline int mprotect_exec(")
    ios_start = wine.index("#ifdef WINE_IOS", function_start)
    exec_start = wine.index("    if (unix_prot & PROT_EXEC)\n    {", ios_start)
    scope_end = wine.index("static BOOL set_vprot(", exec_start)
    matches = wine[exec_start:scope_end].count(normal_anchor)
    if matches != 1:
        raise SystemExit(f"virtual_ios.c normal EXEC mprotect block changed or ambiguous ({matches})")
    normal_pos = wine.index(normal_anchor, exec_start, scope_end)
    wine = wine[:normal_pos] + normal_repl + wine[normal_pos + len(normal_anchor):]

    existing_write_anchor = r'''                    if (unix_prot & PROT_WRITE)
                    {
                        kern_return_t kr = vm_protect(mach_task_self(),
                            (vm_address_t)base, size, FALSE,
                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                        if (kr == KERN_SUCCESS) {
                            ERR("iOS vm_protect RW+COPY OK at %p+0x%lx (was rwx)\n",
                                base, (unsigned long)size);
                            return 0;
                        }
                        ERR("iOS vm_protect RW failed kr=%d at %p+0x%lx (was rwx)\n",
                            kr, base, (unsigned long)size);
                    }
'''
    existing_write_repl = r'''                    if (unix_prot & PROT_WRITE)
                    {
                        /* WinArc rev3: this image already executes from the JIT-pool copy.
                         * Avoid Madeira's 4KB RW+COPY transition on the original PE source.
                         * Restore the full iOS host page from Wine's logical vprot union;
                         * mixed code/data becomes RW while EXEC remains pool-only. */
                        static unsigned int winarc_existing_write_n;
                        if (!ios_in_mach_exc && winarc_existing_write_n++ < 32)
                            dprintf( 2,
                                     "[WinArc PE Protect] existing-image WRITE %p+0x%lx "
                                     "-> host-page union restore; no direct RW+COPY rev=3\n",
                                     base, (unsigned long)size );
                        winarc_restore_pe_source_protection( base, size, "existing-image-write" );
                        return 0;
                    }
'''
    if wine.count(existing_write_anchor) != 1:
        raise SystemExit("virtual_ios.c existing-image WRITE anchor changed or is ambiguous")
    wine = wine.replace(existing_write_anchor, existing_write_repl, 1)

    existing_read_anchor = r'''                    mprotect( base, size, PROT_READ );
                    return 0;
'''
    existing_read_repl = r'''                    winarc_restore_pe_source_protection( base, size, "existing-image-read" );
                    return 0;
'''
    if wine.count(existing_read_anchor) < 1:
        raise SystemExit("virtual_ios.c existing-image READ anchor changed")

    write_pos = wine.index("existing-image WRITE")
    read_pos = wine.find(existing_read_anchor, write_pos)
    if read_pos < 0:
        raise SystemExit("virtual_ios.c existing-image READ tail not found after WRITE branch")

    wine = (
        wine[:read_pos]
        + existing_read_repl
        + wine[read_pos + len(existing_read_anchor):]
    )

    final_anchor = r'''            /* Leave original code section as read-only */
            mprotect( base, size, PROT_READ );
            return 0;
'''
    final_repl = r'''            /* WinArc: execution now lives in the pool copy. Restore the
             * ORIGINAL PE mapping from Wine's logical 4KB page protection union
             * instead of flattening a mixed 16KB host page to read-only. */
            winarc_restore_pe_source_protection( base, size, "new-image" );
            return 0;
'''
    if final_anchor not in wine:
        raise SystemExit("virtual_ios.c final PE source-protection anchor changed")
    wine = wine.replace(final_anchor, final_repl, 1)

    wine_path.write_text(wine, encoding="utf-8")

# Stage 1 of hybrid memory: audit existing PE source restores. Wine's vprot
# table remains authoritative; this does not enable a software MMU or change
# rev3 protection requests. Checked access and native ABI integration follow.
memory_helper = r'''/* WINARC_MEMORY_AUDIT_V1_BEGIN */
enum winarc_memory_reason
{
    WINARC_MEM_MIXED = 1,
    WINARC_MEM_UNCOMMITTED = 2,
    WINARC_MEM_GUARD = 4,
    WINARC_MEM_COPY = 8,
    WINARC_MEM_WRITEWATCH = 16,
    WINARC_MEM_CODE = 32,
    WINARC_MEM_GEOMETRY = 64
};

struct winarc_memory_policy
{
    unsigned int reasons;
    unsigned int pages;
    int first_data_prot;
};

/* A data-only direct candidate must have identical effective R/W permissions
 * on every guest page and no outstanding guest-side semantics. Execute pages
 * require separate guest-ISA/native-ISA classification; do not infer it here.
 */
static void winarc_memory_add_page( struct winarc_memory_policy *state, BYTE vprot )
{
    int data_prot = get_unix_prot( vprot ) & ~PROT_EXEC;
    if (state->pages && data_prot != state->first_data_prot)
        state->reasons |= WINARC_MEM_MIXED;
    if (!state->pages) state->first_data_prot = data_prot;
    ++state->pages;
    if (!(vprot & VPROT_COMMITTED)) state->reasons |= WINARC_MEM_UNCOMMITTED;
    if (vprot & VPROT_GUARD) state->reasons |= WINARC_MEM_GUARD;
    if (vprot & VPROT_WRITECOPY) state->reasons |= WINARC_MEM_COPY;
    if (vprot & VPROT_WRITEWATCH) state->reasons |= WINARC_MEM_WRITEWATCH;
    if (vprot & VPROT_EXEC) state->reasons |= WINARC_MEM_CODE;
}

static struct winarc_memory_policy winarc_memory_describe_host_page( uintptr_t host )
{
    struct winarc_memory_policy state = {0};
    size_t offset;
    if (!page_size || !host_page_size || host_page_size % page_size ||
        host % host_page_size || host > ~(uintptr_t)0 - host_page_size)
    {
        state.reasons = WINARC_MEM_GEOMETRY;
        return state;
    }
    for (offset = 0; offset < host_page_size; offset += page_size)
        winarc_memory_add_page( &state, get_page_vprot( (void *)(host + offset) ) );
    return state;
}
/* WINARC_MEMORY_AUDIT_V1_END */

'''

memory_marker = "WINARC_MEMORY_AUDIT_V1_BEGIN"
if memory_marker not in wine:
    restore_anchor = "/* Restore physical source pages from the union of Wine's logical 4KB vprot."
    log_anchor = """            ++log_n;
            dprintf( 2,
                     "[WinArc PE Protect] %s host=%p vprot=0x%x want=%c%c """
    if wine.count(restore_anchor) != 1 or wine.count(log_anchor) != 1:
        raise SystemExit("WinArc memory audit integration anchors changed")
    wine = wine.replace(restore_anchor, memory_helper + restore_anchor, 1)
    log_repl = """            struct winarc_memory_policy policy = winarc_memory_describe_host_page( p );
            ++log_n;
            dprintf( 2, "[WinArc Memory] mode=audit scope=pe-source host=%p guest_pages=%u "
                         "route=%s reasons=0x%x access_checks=disabled\\n",
                     (void *)p, policy.pages,
                     policy.reasons ? "checked-required" : "direct-data-candidate",
                     policy.reasons );
            dprintf( 2,
                     "[WinArc PE Protect] %s host=%p vprot=0x%x want=%c%c """
    wine = wine.replace(log_anchor, log_repl, 1)
    wine_path.write_text(wine, encoding="utf-8")

wine_check = wine_path.read_text(encoding="utf-8")

for needle in (
    WINE_MARKER,
    "winarc_is_sec_image_range",
    "winarc_restore_pe_source_protection",
    "skip direct EXEC mprotect for SEC_IMAGE",
    "suppress force_exec on SEC_IMAGE",
    'winarc_restore_pe_source_protection( base, size, "new-image" )',
    "existing-image WRITE",
    "no direct RW+COPY rev=3",
    memory_marker,
    "access_checks=disabled",
):
    if needle not in wine_check:
        raise SystemExit(f"Wine PE-protect post-check failed: {needle}")

print("WINARC_WINE_PE_SOURCE_PROTECT_V2=PASS")
print("WINARC_MEMORY_MODE=AUDIT_V1")

if wine_only:
    print("WINARC_VERSION=0.0.1")
    print("WINARC_WINE_PATCHES=PE_SOURCE_PROTECT_V2")
    print("WINARC_FEX_PATCHES=NONE")
    print("WINARC_DXMT_PATCHES=NONE")
    raise SystemExit(0)

app = root / "app" / "Madeira"
content_path = app / "ContentView.swift"
helper_path = app / "StikJITHelper.swift"
alloc_c_path = app / "JITAllocator.c"
alloc_h_path = app / "JITAllocator.h"

for path in (content_path, helper_path, alloc_c_path, alloc_h_path):
    if not path.is_file():
        raise SystemExit(f"missing Madeira source: {path}")

content = content_path.read_text(encoding="utf-8")
helper = helper_path.read_text(encoding="utf-8")
alloc_c = alloc_c_path.read_text(encoding="utf-8")
alloc_h = alloc_h_path.read_text(encoding="utf-8")

jit_already = (
    JIT_MARKER in helper
    and JIT_MARKER in alloc_c
    and JIT_MARKER in alloc_h
    and JIT_MARKER in content
)

if not jit_already:
    include_anchor = "#include <errno.h>\n"

    if include_anchor not in alloc_c:
        raise SystemExit("JITAllocator.c include anchor changed")

    alloc_c = alloc_c.replace(
        include_anchor,
        include_anchor + "#include <sys/sysctl.h>\n#include <sys/proc.h>\n",
        1,
    )

    trap_anchor = "// SIGTRAP handler: skips BRK instruction (PC += 4) and zeros x0.\n"

    if trap_anchor not in alloc_c:
        raise SystemExit("JITAllocator.c SIGTRAP anchor changed")

    trace_impl = r'''
// ===== WINARC_JIT_CORE_V1: capability probe =====
bool jit_is_traced(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    memset(&info, 0, sizeof(info));

    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return false;
    }

    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

'''

    alloc_c = alloc_c.replace(
        trap_anchor,
        trace_impl + trap_anchor,
        1,
    )

    old_trap_check = '''    if (jit_check_debugged()) {
        jit_log("Debugger attached \u2014 skipping SIGTRAP handler (debugger handles BRK)");
        return;
    }
'''

    new_trap_check = '''    if (jit_is_traced()) {
        jit_log("Debugger currently attached \u2014 skipping SIGTRAP handler (debugger handles BRK)");
        return;
    }
'''

    if old_trap_check not in alloc_c:
        raise SystemExit("JITAllocator.c trap-install logic changed")

    alloc_c = alloc_c.replace(
        old_trap_check,
        new_trap_check,
        1,
    )

    native_pool_impl = r'''

// ===== WINARC_JIT_CORE_V1: native capability-backed pool =====
static JITRegion *g_winarc_native_pool = NULL;
static vm_address_t g_winarc_pin_chunks[32];
static int g_winarc_pin_count = 0;
static bool g_winarc_pin_frontier_ready = false;

static bool winarc_jit_prepare_low_frontier(void) {
    if (g_winarc_pin_frontier_ready) return true;

    const vm_address_t target = (vm_address_t)0x119000000ULL;
    const vm_size_t chunk_size =
        (vm_size_t)(16ULL * 1024ULL * 1024ULL);

    for (int i = g_winarc_pin_count; i < 32; ++i) {
        vm_address_t addr = 0;

        kern_return_t kr = vm_allocate(
            mach_task_self(),
            &addr,
            chunk_size,
            VM_FLAGS_ANYWHERE
        );

        if (kr != KERN_SUCCESS) {
            jit_log(
                "[WinArc JIT] low-VA pin failed chunk=%d kr=%d",
                i,
                kr
            );
            return false;
        }

        g_winarc_pin_chunks[g_winarc_pin_count++] = addr;

        jit_log(
            "[WinArc JIT] low-VA pin chunk=%d addr=0x%llx end=0x%llx",
            i,
            (unsigned long long)addr,
            (unsigned long long)(addr + chunk_size)
        );

        if (addr + chunk_size >= target) {
            g_winarc_pin_frontier_ready = true;

            jit_log(
                "[WinArc JIT] low-VA frontier READY at 0x%llx target=0x%llx",
                (unsigned long long)(addr + chunk_size),
                (unsigned long long)target
            );

            return true;
        }
    }

    jit_log(
        "[WinArc JIT] low-VA frontier did not reach 0x%llx after %d chunks",
        (unsigned long long)target,
        g_winarc_pin_count
    );

    return false;
}

bool winarc_jit_native_pool_create(
    size_t size,
    void **rx_out,
    void **rw_out
) {
    if (!rx_out || !rw_out || size == 0)
        return false;

    if (g_winarc_native_pool) {
        if (jit_region_size(g_winarc_native_pool) < size)
            return false;

        *rx_out = jit_region_rx_ptr(g_winarc_native_pool);
        *rw_out = jit_region_rw_ptr(g_winarc_native_pool);

        return *rx_out != NULL && *rw_out != NULL;
    }

    const uintptr_t good_low = 0x119000000ULL;
    const uintptr_t guest_lo = 0x7000000000ULL;
    const uintptr_t guest_hi = 0x8000000000ULL;

    if (!winarc_jit_prepare_low_frontier()) {
        jit_log(
            "[WinArc JIT] native pool aborted: low-VA frontier prep failed"
        );

        *rx_out = NULL;
        *rw_out = NULL;

        return false;
    }

    for (int attempt = 0; attempt < 2; ++attempt) {
        JITRegion *region = jit_region_create(size);

        if (!region) {
            jit_log(
                "[WinArc JIT] native pool create failed attempt=%d",
                attempt + 1
            );
            continue;
        }

        uintptr_t rx = (uintptr_t)jit_region_rx_ptr(region);
        uintptr_t end = rx + size;

        bool overflow = end < rx;
        bool too_low = !overflow && rx < good_low;
        bool overlaps_guest =
            !overflow &&
            end > guest_lo &&
            rx < guest_hi;

        if (!overflow && !too_low && !overlaps_guest) {
            g_winarc_native_pool = region;

            *rx_out = jit_region_rx_ptr(region);
            *rw_out = jit_region_rw_ptr(region);

            jit_log(
                "[WinArc JIT] native pool READY RX=%p RW=%p size=%zu",
                *rx_out,
                *rw_out,
                size
            );

            return true;
        }

        const char *reason =
            overflow
                ? "overflow"
                : (too_low
                    ? "mode-A-low"
                    : "guest-64G-window");

        jit_log(
            "[WinArc JIT] reject native pool attempt=%d RX=%p size=%zu reason=%s",
            attempt + 1,
            jit_region_rx_ptr(region),
            size,
            reason
        );

        jit_region_destroy(region);

        if (overlaps_guest || overflow)
            break;

        if (too_low && g_winarc_pin_count < 32) {
            vm_address_t addr = 0;

            const vm_size_t chunk_size =
                (vm_size_t)(16ULL * 1024ULL * 1024ULL);

            kern_return_t kr = vm_allocate(
                mach_task_self(),
                &addr,
                chunk_size,
                VM_FLAGS_ANYWHERE
            );

            if (kr == KERN_SUCCESS) {
                g_winarc_pin_chunks[g_winarc_pin_count++] = addr;

                jit_log(
                    "[WinArc JIT] extra low-VA pin addr=0x%llx",
                    (unsigned long long)addr
                );
            } else {
                jit_log(
                    "[WinArc JIT] extra low-VA pin failed kr=%d",
                    kr
                );
                break;
            }
        }
    }

    *rx_out = NULL;
    *rw_out = NULL;

    return false;
}

bool winarc_jit_native_pool_active(void) {
    return g_winarc_native_pool != NULL;
}
'''

    alloc_c = alloc_c.rstrip() + native_pool_impl + "\n"

    header_anchor = '''void jit_set_log_callback(jit_log_callback_t callback);

#ifdef __cplusplus
'''

    if header_anchor not in alloc_h:
        raise SystemExit("JITAllocator.h footer anchor changed")

    header_add = '''void jit_set_log_callback(jit_log_callback_t callback);

// ===== WINARC_JIT_CORE_V1 =====
bool jit_is_traced(void);
bool winarc_jit_native_pool_create(
    size_t size,
    void **rx_out,
    void **rw_out
);
bool winarc_jit_native_pool_active(void);

#ifdef __cplusplus
'''

    alloc_h = alloc_h.replace(
        header_anchor,
        header_add,
        1,
    )

    if "import Darwin\n" not in helper:
        helper = helper.replace(
            "import UIKit\n",
            "import UIKit\nimport Darwin\n",
            1,
        )

    jit_core_swift = r'''

// ===== WINARC_JIT_CORE_V1 =====

enum WinArcJITBackend: String {
    case nativeDirect = "native-direct"
    case legacyStikDebug = "stikdebug-legacy"
    case unavailable = "unavailable"
}

struct WinArcJITSnapshot {
    let allowJIT: Bool
    let csDebugged: Bool
    let traced: Bool
    let dualMap: Bool
    let increasedMemory: Bool
    let extendedVA: Bool
    let stikAvailable: Bool

    var hasExecutionGate: Bool {
        allowJIT || csDebugged
    }

    var nativeCandidate: Bool {
        hasExecutionGate && dualMap
    }
}

enum WinArcJITCore {
    private(set) static var backend: WinArcJITBackend = .unavailable

    private static var dualMapCache: Bool? = nil
    private static var legacyStikSession = false

    static func probe(
        deep: Bool = true
    ) -> WinArcJITSnapshot {
        let ent = EntitlementStatus.check()
        let cs = jit_check_debugged()
        let traced = jit_is_traced()

        let dual: Bool

        if let cached = dualMapCache {
            dual = cached
        } else if deep {
            dual = jit_test_mapping()
            dualMapCache = dual
        } else {
            dual = false
        }

        let snapshot = WinArcJITSnapshot(
            allowJIT: ent.jitAllowed,
            csDebugged: cs,
            traced: traced,
            dualMap: dual,
            increasedMemory: ent.increasedMemory,
            extendedVA: ent.extendedVA,
            stikAvailable: StikJITHelper.isAvailable
        )

        LogStore.shared.log(
            "[WinArc JIT Probe] allow-jit=\(snapshot.allowJIT) " +
            "CS_DEBUGGED=\(snapshot.csDebugged) " +
            "traced=\(snapshot.traced) " +
            "dual-map=\(snapshot.dualMap) " +
            "memory+=\(snapshot.increasedMemory) " +
            "64bitVA=\(snapshot.extendedVA) " +
            "stik=\(snapshot.stikAvailable)"
        )

        return snapshot
    }

    private static func choose(
        _ snapshot: WinArcJITSnapshot
    ) -> WinArcJITBackend {
        if snapshot.nativeCandidate {
            return .nativeDirect
        }

        if snapshot.stikAvailable {
            return .legacyStikDebug
        }

        return .unavailable
    }

    static func enable(
        completion: @escaping (Bool) -> Void
    ) {
        let snapshot = probe(deep: true)
        let selected = choose(snapshot)

        switch selected {
        case .nativeDirect:
            backend = .nativeDirect

            setenv(
                "WINARC_JIT_BACKEND",
                backend.rawValue,
                1
            )

            LogStore.shared.log(
                "[WinArc JIT Policy] selected=native-direct; no StikDebug launch",
                level: .success
            )

            completion(true)

        case .legacyStikDebug:
            LogStore.shared.log(
                "[WinArc JIT Policy] no existing execution gate; using StikDebug fallback"
            )

            StikJITHelper.enableJIT { success in
                if success {
                    legacyStikSession = true
                    backend = .legacyStikDebug

                    setenv(
                        "WINARC_JIT_BACKEND",
                        backend.rawValue,
                        1
                    )

                    LogStore.shared.log(
                        "[WinArc JIT Policy] StikDebug fallback attached",
                        level: .success
                    )
                } else {
                    backend = .unavailable

                    setenv(
                        "WINARC_JIT_BACKEND",
                        backend.rawValue,
                        1
                    )

                    LogStore.shared.log(
                        "[WinArc JIT Policy] StikDebug fallback failed",
                        level: .error
                    )
                }

                completion(success)
            }

        case .unavailable:
            backend = .unavailable

            setenv(
                "WINARC_JIT_BACKEND",
                backend.rawValue,
                1
            )

            LogStore.shared.log(
                "[WinArc JIT Policy] no usable JIT capability/provider found",
                level: .error
            )

            completion(false)
        }
    }

    static func canStartRuntime() -> Bool {
        if legacyStikSession && jit_check_debugged() {
            backend = .legacyStikDebug
            return true
        }

        let snapshot = probe(deep: true)

        if choose(snapshot) == .nativeDirect {
            backend = .nativeDirect

            setenv(
                "WINARC_JIT_BACKEND",
                backend.rawValue,
                1
            )

            return true
        }

        LogStore.shared.log(
            "[WinArc JIT] runtime not ready; press Enable JIT to request fallback",
            level: .error
        )

        return false
    }

    static func allocatePool(
        poolSize: Int
    ) -> (
        rx: UnsafeMutableRawPointer,
        rw: UnsafeMutableRawPointer,
        size: Int
    )? {
        if backend == .unavailable {
            guard canStartRuntime() else {
                return nil
            }
        }

        switch backend {
        case .nativeDirect:
            var rx: UnsafeMutableRawPointer? = nil
            var rw: UnsafeMutableRawPointer? = nil

            let ok = winarc_jit_native_pool_create(
                poolSize,
                &rx,
                &rw
            )

            guard ok, let rx, let rw else {
                LogStore.shared.log(
                    "[WinArc JIT] native pool allocation failed",
                    level: .error
                )

                return nil
            }

            LogStore.shared.log(
                "[WinArc JIT] native pool selected; StikDebug BRK allocator bypassed",
                level: .success
            )

            return (
                rx: rx,
                rw: rw,
                size: poolSize
            )

        case .legacyStikDebug:
            return StikJITHelper.allocatePool(
                poolSize: poolSize
            )

        case .unavailable:
            return nil
        }
    }

    static func detachIfNeeded() {
        switch backend {
        case .legacyStikDebug:
            if legacyStikSession {
                StikJITHelper.detachDebugger()
                legacyStikSession = false
            }

        case .nativeDirect, .unavailable:
            break
        }
    }
}
'''

    helper = helper.rstrip() + jit_core_swift + "\n"

    button_old = '''                Button("Enable JIT") {
                    enableJITViaStikDebug()
                }
'''

    button_new = '''                Button("Enable JIT") {
                    enableJITSmart()
                }
'''

    if button_old not in content:
        raise SystemExit("ContentView Enable JIT button changed")

    content = content.replace(
        button_old,
        button_new,
        1,
    )

    smart_func = r'''    // ===== WINARC_JIT_CORE_V1 =====
    private func enableJITSmart() {
        jitStatus = .testing

        logStore.log(
            "WinArc JIT: probing capabilities..."
        )

        WinArcJITCore.enable { success in
            DispatchQueue.main.async {
                if success {
                    jitStatus = .available

                    logStore.log(
                        "WinArc JIT ready: \(WinArcJITCore.backend.rawValue)",
                        level: .success
                    )
                } else {
                    jitStatus = .unavailable

                    logStore.log(
                        "No usable JIT route. Existing capability and StikDebug fallback both unavailable.",
                        level: .error
                    )
                }
            }
        }
    }

'''

    func_anchor = "    private func enableJITViaStikDebug() {\n"

    if func_anchor not in content:
        raise SystemExit(
            "ContentView enableJITViaStikDebug anchor changed"
        )

    content = content.replace(
        func_anchor,
        smart_func + func_anchor,
        1,
    )

    guard_old = '''        guard jit_check_debugged() else {
            logStore.log("JIT not enabled. Press 'Enable JIT' first.", level: .error)
            return
        }
'''

    guard_new = '''        guard WinArcJITCore.canStartRuntime() else {
            logStore.log("WinArc JIT is not ready. Press 'Enable JIT' first.", level: .error)
            return
        }
'''

    if guard_old not in content:
        raise SystemExit(
            "ContentView runWineFullSequence JIT guard changed"
        )

    content = content.replace(
        guard_old,
        guard_new,
        1,
    )

    pool_old = (
        "let pool = "
        "StikJITHelper.allocatePool("
        "poolSize: poolSizeMB * 1024 * 1024)"
    )

    pool_new = (
        "let pool = "
        "WinArcJITCore.allocatePool("
        "poolSize: poolSizeMB * 1024 * 1024)"
    )

    if pool_old not in content:
        raise SystemExit(
            "ContentView pool allocation call changed"
        )

    content = content.replace(
        pool_old,
        pool_new,
        1,
    )

    pool_fail_old = '''                logStore.log("JIT pool allocation FAILED \u2014 not starting Wine.", level: .error)
                logStore.log("  All placements landed in the forbidden guest 64G window.", level: .info)
                logStore.log("  Force-quit and relaunch: placement is chosen by the kernel", level: .info)
                logStore.log("  and depends on current memory layout, so a fresh process", level: .info)
                logStore.log("  usually lands somewhere valid.", level: .info)
'''

    pool_fail_new = '''                logStore.log("JIT pool allocation FAILED \u2014 not starting Wine.", level: .error)
                logStore.log("  See [WinArc JIT] lines above for the exact placement reason.", level: .info)
                logStore.log("  native-direct rejects mode-A-low and guest-window placements.", level: .info)
                logStore.log("  Do not infer the cause from the final nil alone.", level: .info)
'''

    if pool_fail_old not in content:
        raise SystemExit(
            "ContentView pool failure text changed"
        )

    content = content.replace(
        pool_fail_old,
        pool_fail_new,
        1,
    )

    if "StikJITHelper.detachDebugger()" not in content:
        raise SystemExit(
            "ContentView detach call not found"
        )

    content = content.replace(
        "StikJITHelper.detachDebugger()",
        "WinArcJITCore.detachIfNeeded()",
    )

    content += "\n// WINARC_JIT_CORE_V1\n"

    alloc_c_path.write_text(
        alloc_c,
        encoding="utf-8",
    )

    alloc_h_path.write_text(
        alloc_h,
        encoding="utf-8",
    )

    helper_path.write_text(
        helper,
        encoding="utf-8",
    )

    content_path.write_text(
        content,
        encoding="utf-8",
    )

checks = {
    alloc_c_path: [
        JIT_MARKER,
        "bool jit_is_traced(void)",
        "winarc_jit_native_pool_create",
    ],
    alloc_h_path: [
        JIT_MARKER,
        "winarc_jit_native_pool_create",
    ],
    helper_path: [
        JIT_MARKER,
        "enum WinArcJITCore",
        "native-direct",
        "stikdebug-legacy",
    ],
    content_path: [
        JIT_MARKER,
        "enableJITSmart()",
        "WinArcJITCore.allocatePool",
        "WinArcJITCore.detachIfNeeded",
    ],
}

for path, needles in checks.items():
    text = path.read_text(encoding="utf-8")

    for needle in needles:
        if needle not in text:
            raise SystemExit(
                f"post-patch check failed: {path}: {needle}"
            )

print("WINARC_JIT_CORE_V1=PASS")
print("WINARC_VERSION=0.0.1")
print("WINARC_JIT_POLICY=CAPABILITY_DRIVEN")
print("WINARC_JIT_NATIVE_POOL=MADEIRA_DUALMAP")
print("WINARC_JIT_STIKDEBUG=FALLBACK_ONLY")
print("WINARC_WINE_PATCHES=PE_SOURCE_PROTECT_V2")
print("WINARC_FEX_PATCHES=NONE")
print("WINARC_DXMT_PATCHES=NONE")
