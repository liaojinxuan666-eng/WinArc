#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "WINARC_JIT_CORE_V1"

if len(sys.argv) != 2:
    raise SystemExit("usage: winarc-runtime-patch.py <madeira-checkout>")

root = Path(sys.argv[1]).resolve()
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

if MARKER in helper and MARKER in alloc_c and MARKER in alloc_h and MARKER in content:
    print("WINARC_JIT_CORE_V1=ALREADY_APPLIED")
    raise SystemExit(0)

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
// CS_DEBUGGED and "currently traced" are intentionally separate.
// Some JIT methods leave CS_DEBUGGED usable after their debugger has detached.
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
alloc_c = alloc_c.replace(trap_anchor, trace_impl + trap_anchor, 1)

old_trap_check = '''    if (jit_check_debugged()) {
        jit_log("Debugger attached — skipping SIGTRAP handler (debugger handles BRK)");
        return;
    }
'''
new_trap_check = '''    if (jit_is_traced()) {
        jit_log("Debugger currently attached — skipping SIGTRAP handler (debugger handles BRK)");
        return;
    }
'''
if old_trap_check not in alloc_c:
    raise SystemExit("JITAllocator.c trap-install logic changed")
alloc_c = alloc_c.replace(old_trap_check, new_trap_check, 1)

native_pool_impl = r'''

// ===== WINARC_JIT_CORE_V1: native capability-backed pool =====
// Thin wrapper around Madeira's existing jit_region_create() allocator.
// No Wine/FEX/DXMT patching and no jit26_* replacement.
static JITRegion *g_winarc_native_pool = NULL;

bool winarc_jit_native_pool_create(size_t size, void **rx_out, void **rw_out) {
    if (!rx_out || !rw_out || size == 0) return false;

    if (g_winarc_native_pool) {
        if (jit_region_size(g_winarc_native_pool) < size) return false;
        *rx_out = jit_region_rx_ptr(g_winarc_native_pool);
        *rw_out = jit_region_rw_ptr(g_winarc_native_pool);
        return *rx_out != NULL && *rw_out != NULL;
    }

    const uintptr_t good_low = 0x119000000ULL;
    const uintptr_t guest_lo = 0x7000000000ULL;
    const uintptr_t guest_hi = 0x8000000000ULL;

    for (int attempt = 0; attempt < 4; ++attempt) {
        JITRegion *region = jit_region_create(size);
        if (!region) continue;

        uintptr_t rx = (uintptr_t)jit_region_rx_ptr(region);
        uintptr_t end = rx + size;
        bool overflow = end < rx;
        bool overlaps_guest = !overflow && end > guest_lo && rx < guest_hi;
        bool placement_ok = !overflow && rx >= good_low && !overlaps_guest;

        if (!placement_ok) {
            jit_log("[WinArc JIT] reject native pool attempt=%d RX=%p size=%zu guest=%d overflow=%d",
                    attempt + 1, jit_region_rx_ptr(region), size,
                    overlaps_guest ? 1 : 0, overflow ? 1 : 0);
            jit_region_destroy(region);
            continue;
        }

        g_winarc_native_pool = region;
        *rx_out = jit_region_rx_ptr(region);
        *rw_out = jit_region_rw_ptr(region);
        jit_log("[WinArc JIT] native pool READY RX=%p RW=%p size=%zu",
                *rx_out, *rw_out, size);
        return true;
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
bool winarc_jit_native_pool_create(size_t size, void **rx_out, void **rw_out);
bool winarc_jit_native_pool_active(void);

#ifdef __cplusplus
'''
alloc_h = alloc_h.replace(header_anchor, header_add, 1)

if "import Darwin\n" not in helper:
    helper = helper.replace("import UIKit\n", "import UIKit\nimport Darwin\n", 1)

jit_core_swift = r'''

// ===== WINARC_JIT_CORE_V1 =====
// Capability-driven JIT selection. Provider names are secondary; actual
// execution and mapping capabilities decide the route.
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

    var hasExecutionGate: Bool { allowJIT || csDebugged }
    var nativeCandidate: Bool { hasExecutionGate && dualMap }
}

enum WinArcJITCore {
    private(set) static var backend: WinArcJITBackend = .unavailable
    private static var dualMapCache: Bool? = nil
    private static var legacyStikSession = false

    static func probe(deep: Bool = true) -> WinArcJITSnapshot {
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
            "CS_DEBUGGED=\(snapshot.csDebugged) traced=\(snapshot.traced) " +
            "dual-map=\(snapshot.dualMap) memory+=\(snapshot.increasedMemory) " +
            "64bitVA=\(snapshot.extendedVA) stik=\(snapshot.stikAvailable)"
        )
        return snapshot
    }

    private static func choose(_ snapshot: WinArcJITSnapshot) -> WinArcJITBackend {
        if snapshot.nativeCandidate { return .nativeDirect }
        if snapshot.stikAvailable { return .legacyStikDebug }
        return .unavailable
    }

    static func enable(completion: @escaping (Bool) -> Void) {
        let snapshot = probe(deep: true)
        let selected = choose(snapshot)

        switch selected {
        case .nativeDirect:
            backend = .nativeDirect
            setenv("WINARC_JIT_BACKEND", backend.rawValue, 1)
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
                    setenv("WINARC_JIT_BACKEND", backend.rawValue, 1)
                    LogStore.shared.log(
                        "[WinArc JIT Policy] StikDebug fallback attached",
                        level: .success
                    )
                } else {
                    backend = .unavailable
                    setenv("WINARC_JIT_BACKEND", backend.rawValue, 1)
                    LogStore.shared.log(
                        "[WinArc JIT Policy] StikDebug fallback failed",
                        level: .error
                    )
                }
                completion(success)
            }

        case .unavailable:
            backend = .unavailable
            setenv("WINARC_JIT_BACKEND", backend.rawValue, 1)
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
            setenv("WINARC_JIT_BACKEND", backend.rawValue, 1)
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
    ) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? {
        if backend == .unavailable {
            guard canStartRuntime() else { return nil }
        }

        switch backend {
        case .nativeDirect:
            var rx: UnsafeMutableRawPointer? = nil
            var rw: UnsafeMutableRawPointer? = nil
            let ok = winarc_jit_native_pool_create(poolSize, &rx, &rw)
            guard ok, let rx, let rw else {
                LogStore.shared.log("[WinArc JIT] native pool allocation failed", level: .error)
                return nil
            }
            LogStore.shared.log(
                "[WinArc JIT] native pool selected; StikDebug BRK allocator bypassed",
                level: .success
            )
            return (rx: rx, rw: rw, size: poolSize)

        case .legacyStikDebug:
            return StikJITHelper.allocatePool(poolSize: poolSize)

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
content = content.replace(button_old, button_new, 1)

smart_func = r'''    // ===== WINARC_JIT_CORE_V1 =====
    private func enableJITSmart() {
        jitStatus = .testing
        logStore.log("WinArc JIT: probing capabilities...")

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
    raise SystemExit("ContentView enableJITViaStikDebug anchor changed")
content = content.replace(func_anchor, smart_func + func_anchor, 1)

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
    raise SystemExit("ContentView runWineFullSequence JIT guard changed")
content = content.replace(guard_old, guard_new, 1)

pool_old = "let pool = StikJITHelper.allocatePool(poolSize: poolSizeMB * 1024 * 1024)"
pool_new = "let pool = WinArcJITCore.allocatePool(poolSize: poolSizeMB * 1024 * 1024)"
if pool_old not in content:
    raise SystemExit("ContentView pool allocation call changed")
content = content.replace(pool_old, pool_new, 1)

if "StikJITHelper.detachDebugger()" not in content:
    raise SystemExit("ContentView detach call not found")
content = content.replace("StikJITHelper.detachDebugger()", "WinArcJITCore.detachIfNeeded()")
content += "\n// WINARC_JIT_CORE_V1\n"

alloc_c_path.write_text(alloc_c, encoding="utf-8")
alloc_h_path.write_text(alloc_h, encoding="utf-8")
helper_path.write_text(helper, encoding="utf-8")
content_path.write_text(content, encoding="utf-8")

checks = {
    alloc_c_path: ["WINARC_JIT_CORE_V1", "bool jit_is_traced(void)", "winarc_jit_native_pool_create"],
    alloc_h_path: ["WINARC_JIT_CORE_V1", "winarc_jit_native_pool_create"],
    helper_path: ["WINARC_JIT_CORE_V1", "enum WinArcJITCore", "native-direct", "stikdebug-legacy"],
    content_path: ["WINARC_JIT_CORE_V1", "enableJITSmart()", "WinArcJITCore.allocatePool", "WinArcJITCore.detachIfNeeded"],
}
for path, needles in checks.items():
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"post-patch check failed: {path}: {needle}")

print("WINARC_JIT_CORE_V1=PASS")
print("WINARC_VERSION=0.0.1")
print("WINARC_JIT_POLICY=CAPABILITY_DRIVEN")
print("WINARC_JIT_NATIVE_POOL=MADEIRA_DUALMAP")
print("WINARC_JIT_STIKDEBUG=FALLBACK_ONLY")
print("WINARC_FEX_PATCHES=NONE")
print("WINARC_WINE_PATCHES=NONE")
print("WINARC_DXMT_PATCHES=NONE")
