import Foundation
import Darwin

enum WinArcJITStatus: String {
    case checking
    case ready
    case needsValidation
    case unavailable
}


enum WinArcJITMode: String, CaseIterable, Identifiable {
    case automatic
    case stable
    case performance
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Madeira 原生（推荐）"
        case .stable: return "Madeira 原生"
        case .performance: return "Madeira 原生"
        case .custom: return "Madeira 原生"
        }
    }
}

enum WinArcJITStrategy: String, CaseIterable, Identifiable {
    case localDualMap
    case debuggerAlloc

    var id: String { rawValue }

    var title: String { "Madeira Stock" }
}

extension Notification.Name {
    static let winArcLaunchDesktop = Notification.Name("WinArcLaunchDesktop")
}

@MainActor
final class WinArcJITManager: ObservableObject {
    static let shared = WinArcJITManager()

    @Published private(set) var status: WinArcJITStatus = .checking
    @Published private(set) var debuggerAttached = false
    @Published private(set) var physicalFootprintMB = 0
    @Published private(set) var lastMessage = "等待检测"

    // Compatibility surface for older WinArc UI code. These values are
    // management-only and never alter Madeira's runtime.
    @Published private(set) var dualMappingAvailable = false
    @Published private(set) var executionValidated = false
    @Published private(set) var recoveredFromFailedLaunch = false
    @Published private(set) var lastKnownGoodText = "Madeira Stock"
    @Published var mode: WinArcJITMode = .automatic
    @Published var strategy: WinArcJITStrategy = .localDualMap
    @Published var customPoolMB: Int = 256

    @Published var quickCheckOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(
                quickCheckOnLaunch,
                forKey: "WinArcJIT.quickCheck"
            )
        }
    }

    @Published private(set) var isRunningQuickCheck = false
    @Published private(set) var isRunningFullTest = false
    @Published private(set) var isPreparingRuntime = false

    private var quickCheckHasRun = false

    private init() {
        quickCheckOnLaunch =
            UserDefaults.standard.object(forKey: "WinArcJIT.quickCheck") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "WinArcJIT.quickCheck")

        LogStore.shared.log(
            "[WinArc JIT] management-only mode; Madeira owns JIT runtime"
        )
        prepareMadeiraStockRuntime()
        updateFootprint()
    }

    var statusTitle: String {
        switch status {
        case .checking: return "检测中"
        case .ready: return "已就绪"
        case .needsValidation: return "等待 Madeira"
        case .unavailable: return "不可用"
        }
    }

    var effectivePoolMB: Int { 256 }
    var effectiveStrategy: WinArcJITStrategy { .localDualMap }

    func runQuickCheckIfNeeded() {
        guard quickCheckOnLaunch else {
            status = .needsValidation
            lastMessage = "轻量检测已关闭；运行时由 Madeira 原生 JIT 管理"
            updateFootprint()
            return
        }

        guard !quickCheckHasRun else { return }
        runQuickCheck()
    }

    func runQuickCheck() {
        guard !isRunningQuickCheck, !isPreparingRuntime else { return }

        quickCheckHasRun = true
        isRunningQuickCheck = true
        status = .checking
        lastMessage = "正在检查 Debugger/JIT 状态…"
        updateFootprint()

        LogStore.shared.log("[WinArc JIT QuickCheck] BEGIN")

        DispatchQueue.global(qos: .userInitiated).async {
            let debugged = jit_check_debugged()

            LogStore.shared.log(
                "[WinArc JIT QuickCheck] CS_DEBUGGED=\(debugged)"
            )

            DispatchQueue.main.async {
                self.debuggerAttached = debugged
                self.isRunningQuickCheck = false
                self.updateFootprint()

                if debugged {
                    self.status = .ready
                    self.lastMessage =
                        "Debugger/JIT 已就绪；执行、Pool 与 detach 交给 Madeira 原生 Runtime"
                } else {
                    self.status = .unavailable
                    self.lastMessage = "未检测到可用 JIT Debugger"
                }
            }
        }
    }

    func validateForRuntimeLaunch(
        completion: @escaping (Bool) -> Void
    ) {
        guard !isPreparingRuntime, !isRunningQuickCheck else {
            completion(false)
            return
        }

        isPreparingRuntime = true
        status = .checking
        lastMessage = "正在检查 Madeira 原生 Runtime 启动条件…"

        prepareMadeiraStockRuntime()
        updateFootprint()

        LogStore.shared.log(
            "[WinArc JIT Launch] stock Madeira preflight BEGIN"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let debugged = jit_check_debugged()

            LogStore.shared.log(
                "[WinArc JIT Launch] CS_DEBUGGED=\(debugged)"
            )

            DispatchQueue.main.async {
                self.debuggerAttached = debugged
                self.isPreparingRuntime = false
                self.updateFootprint()

                guard debugged else {
                    self.status = .unavailable
                    self.lastMessage = "未检测到可用 JIT Debugger"
                    completion(false)
                    return
                }

                self.status = .ready
                self.lastMessage =
                    "检查通过；启动将直接使用 Madeira 原生 JIT/FEX/Wine/DXMT 路径"

                LogStore.shared.log(
                    "[WinArc JIT Launch] PASS -> Madeira stock runtime",
                    level: .success
                )

                completion(true)
            }
        }
    }

    func runFullSelfTest(completion: ((Bool) -> Void)? = nil) {
        // The old WinArc return-42 execution test is intentionally disabled:
        // it is not part of the product runtime and previously changed the
        // behavior we were trying to validate.
        lastMessage = "高级执行 Self Test 已停用；由 Madeira 原生 Runtime 完成实际 JIT 验证"
        LogStore.shared.log(
            "[WinArc JIT] custom execution self-test disabled; Madeira owns execution"
        )
        completion?(debuggerAttached)
    }

    func applyConfiguration() {
        prepareMadeiraStockRuntime()
        lastMessage = "WinArc 不覆盖 JIT 配置；Madeira 原生 Runtime 保持生效"
    }

    func restoreLastKnownGood() {
        prepareMadeiraStockRuntime()
        lastMessage = "已恢复 Madeira 原生 Runtime 基线"
    }

    func prepareMadeiraStockRuntime() {
        unsetenv("WINARC_LOCAL_JIT_POOL")
        unsetenv("WINARC_WINE_PE16K")
        unsetenv("WINARC_PE16K_DIRECT_EXEC_BYPASS")

        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        // Madeira itself supports Documents/madeira-pool.txt as a runtime
        // pool-size override. Keep the stock allocator/prepare/detach path,
        // but use a conservative 256MB pool on this device class instead of
        // Madeira's 896MB Steam/CEF-oriented default.
        let poolOverride = docs.appendingPathComponent("madeira-pool.txt")
        try? "256\n".write(
            to: poolOverride,
            atomically: true,
            encoding: .utf8
        )

        LogStore.shared.log(
            "[WinArc Runtime] Madeira stock JIT path; native pool override=256MB"
        )
    }

    private func updateFootprint() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size /
            MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }

        if result == KERN_SUCCESS {
            physicalFootprintMB = Int(
                info.phys_footprint / (1024 * 1024)
            )
        }
    }
}
