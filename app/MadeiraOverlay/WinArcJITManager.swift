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
        case .automatic: return "自动（推荐）"
        case .stable: return "稳定"
        case .performance: return "性能"
        case .custom: return "自定义"
        }
    }
}

enum WinArcJITStrategy: String, CaseIterable, Identifiable {
    case localDualMap
    case debuggerAlloc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localDualMap: return "In-Process Provider"
        case .debuggerAlloc: return "Madeira BRK（诊断）"
        }
    }
}

extension Notification.Name {
    static let winArcLaunchDesktop = Notification.Name("WinArcLaunchDesktop")
}

@MainActor
final class WinArcJITManager: ObservableObject {
    static let shared = WinArcJITManager()

    @Published private(set) var status: WinArcJITStatus = .checking
    @Published private(set) var debuggerAttached = false
    @Published private(set) var dualMappingAvailable = false
    @Published private(set) var executionValidated = false
    @Published private(set) var physicalFootprintMB = 0
    @Published private(set) var lastMessage = "等待检测"
    @Published private(set) var recoveredFromFailedLaunch = false
    @Published private(set) var lastKnownGoodText =
        "Madeira + In-Process Provider"

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

        prepareMadeiraStockRuntime()

        LogStore.shared.log(
            "[WinArc JIT] provider=inprocess; Madeira FEX/Wine/DXMT remain stock"
        )

        updateFootprint()
    }

    var statusTitle: String {
        switch status {
        case .checking: return "检测中"
        case .ready: return "已就绪"
        case .needsValidation: return "待验证"
        case .unavailable: return "不可用"
        }
    }

    var effectivePoolMB: Int { 256 }
    var effectiveStrategy: WinArcJITStrategy { .localDualMap }

    func runQuickCheckIfNeeded() {
        guard quickCheckOnLaunch else {
            status = .needsValidation
            lastMessage = "自动检测已关闭"
            updateFootprint()
            return
        }

        guard !quickCheckHasRun else { return }
        runQuickCheck()
    }

    func runQuickCheck() {
        guard !isRunningQuickCheck, !isPreparingRuntime else { return }

        prepareMadeiraStockRuntime()

        quickCheckHasRun = true
        isRunningQuickCheck = true
        status = .checking
        lastMessage = "正在检查设备 JIT 与 Madeira 双映射能力…"
        updateFootprint()

        LogStore.shared.log("[WinArc JIT QuickCheck] BEGIN")

        DispatchQueue.global(qos: .userInitiated).async {
            let debugged = jit_check_debugged()
            let mapping = debugged ? jit_test_mapping() : false

            LogStore.shared.log(
                "[WinArc JIT QuickCheck] CS_DEBUGGED=\(debugged) mapping=\(mapping)"
            )

            DispatchQueue.main.async {
                self.debuggerAttached = debugged
                self.dualMappingAvailable = mapping
                self.isRunningQuickCheck = false
                self.updateFootprint()

                guard debugged else {
                    self.status = .unavailable
                    self.lastMessage = "设备当前没有可用 JIT / CS_DEBUGGED"
                    return
                }

                guard mapping else {
                    self.status = .unavailable
                    self.lastMessage =
                        "设备 JIT 已存在，但 Madeira RW/RX 双映射检测失败"
                    return
                }

                self.status = .ready
                self.lastMessage =
                    "设备 JIT + Madeira In-Process Provider 已就绪"
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

        prepareMadeiraStockRuntime()

        isPreparingRuntime = true
        status = .checking
        lastMessage = "正在验证 In-Process JIT Provider…"
        updateFootprint()

        LogStore.shared.log(
            "[WinArc JIT Launch] in-process provider preflight BEGIN"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let debugged = jit_check_debugged()
            let mapping = debugged ? jit_test_mapping() : false

            LogStore.shared.log(
                "[WinArc JIT Launch] CS_DEBUGGED=\(debugged) mapping=\(mapping)"
            )

            DispatchQueue.main.async {
                self.debuggerAttached = debugged
                self.dualMappingAvailable = mapping
                self.isPreparingRuntime = false
                self.updateFootprint()

                guard debugged else {
                    self.status = .unavailable
                    self.lastMessage = "未检测到设备 JIT / CS_DEBUGGED"
                    completion(false)
                    return
                }

                guard mapping else {
                    self.status = .unavailable
                    self.lastMessage =
                        "Madeira 双映射 Provider 不可用，已阻止 Runtime 启动"
                    completion(false)
                    return
                }

                self.status = .ready
                self.lastMessage =
                    "Provider 检查通过；进入 Madeira FEX → Wine → DXMT"

                LogStore.shared.log(
                    "[WinArc JIT Launch] PASS -> in-process provider -> Madeira runtime",
                    level: .success
                )

                completion(true)
            }
        }
    }

    func runFullSelfTest(completion: ((Bool) -> Void)? = nil) {
        lastMessage =
            "高级 BRK Self Test 已停用；不让诊断路径改变产品 Runtime"
        LogStore.shared.log(
            "[WinArc JIT] debugger BRK self-test disabled in provider mode"
        )
        completion?(debuggerAttached && dualMappingAvailable)
    }

    func applyConfiguration() {
        prepareMadeiraStockRuntime()
        lastMessage =
            "已应用 In-Process Provider；Madeira FEX/Wine/DXMT 未改动"
    }

    func restoreLastKnownGood() {
        mode = .automatic
        strategy = .localDualMap
        customPoolMB = 256
        prepareMadeiraStockRuntime()
        lastMessage =
            "已恢复 WinArc Provider + Madeira Runtime 基线"
    }

    func prepareMadeiraStockRuntime() {
        unsetenv("WINARC_LOCAL_JIT_POOL")
        unsetenv("WINARC_WINE_PE16K")
        unsetenv("WINARC_PE16K_DIRECT_EXEC_BYPASS")

        setenv("WINARC_JIT_PROVIDER", "inprocess", 1)

        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let poolOverride = docs.appendingPathComponent("madeira-pool.txt")
        try? "256\n".write(
            to: poolOverride,
            atomically: true,
            encoding: .utf8
        )

        LogStore.shared.log(
            "[WinArc Runtime] provider=inprocess; Madeira pool=256MB; "
            + "FEX/Wine/DXMT stock"
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
