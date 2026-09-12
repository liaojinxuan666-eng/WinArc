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
        case .localDualMap: return "WinArc Local Dual Map"
        case .debuggerAlloc: return "Debugger Alloc"
        }
    }
}

extension Notification.Name {
    static let winArcLaunchDesktop = Notification.Name("WinArcLaunchDesktop")
    static let winArcJITPoolReady = Notification.Name("WinArcJITPoolReady")
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
    @Published private(set) var lastKnownGoodText = "尚无"

    @Published var mode: WinArcJITMode { didSet { persistPreferences() } }
    @Published var strategy: WinArcJITStrategy { didSet { persistPreferences() } }

    @Published var customPoolMB: Int {
        didSet {
            let clamped = min(max(customPoolMB, 256), 768)
            if clamped != customPoolMB {
                customPoolMB = clamped
                return
            }
            persistPreferences()
        }
    }

    @Published var quickCheckOnLaunch: Bool { didSet { persistPreferences() } }

    @Published private(set) var isRunningQuickCheck = false
    @Published private(set) var isRunningFullTest = false
    @Published private(set) var isPreparingRuntime = false

    private let defaults = UserDefaults.standard
    private var quickCheckHasRun = false

    private enum Key {
        static let mode = "WinArcJIT.mode"
        static let strategy = "WinArcJIT.strategy"
        static let customPool = "WinArcJIT.customPool"
        static let quickCheck = "WinArcJIT.quickCheck"
        static let pendingLaunch = "WinArcJIT.pendingLaunch"
        static let lastGoodMode = "WinArcJIT.lastGood.mode"
        static let lastGoodStrategy = "WinArcJIT.lastGood.strategy"
        static let lastGoodPool = "WinArcJIT.lastGood.pool"
    }

    private init() {
        mode = WinArcJITMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .automatic
        strategy = WinArcJITStrategy(rawValue: defaults.string(forKey: Key.strategy) ?? "") ?? .localDualMap

        let savedPool = defaults.integer(forKey: Key.customPool)
        customPoolMB = savedPool == 0 ? 256 : min(max(savedPool, 256), 768)

        quickCheckOnLaunch = defaults.object(forKey: Key.quickCheck) == nil
            ? true
            : defaults.bool(forKey: Key.quickCheck)

        _ = LogStore.shared
        LogStore.shared.log("[WinArc JIT] persistent diagnostics armed")

        refreshLastKnownGoodText()
        recoverFromInterruptedLaunchIfNeeded()

        NotificationCenter.default.addObserver(
            forName: .winArcJITPoolReady,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markRuntimePoolReady()
            }
        }
    }

    var effectivePoolMB: Int {
        switch mode {
        case .automatic: return 256
        case .stable: return 256
        case .performance: return 384
        case .custom: return customPoolMB
        }
    }

    var effectiveStrategy: WinArcJITStrategy {
        switch mode {
        case .automatic, .stable, .performance: return .localDualMap
        case .custom: return strategy
        }
    }

    var statusTitle: String {
        switch status {
        case .checking: return "检测中"
        case .ready: return "已就绪"
        case .needsValidation: return "基础就绪"
        case .unavailable: return "不可用"
        }
    }

    func runQuickCheckIfNeeded() {
        guard quickCheckOnLaunch else {
            status = .needsValidation
            lastMessage = "自动快速检测已关闭"
            updateFootprint()
            return
        }
        guard !quickCheckHasRun else { return }
        runQuickCheck()
    }

    func runQuickCheck() {
        guard !isRunningQuickCheck, !isRunningFullTest, !isPreparingRuntime else { return }

        quickCheckHasRun = true
        isRunningQuickCheck = true
        status = .checking
        lastMessage = "正在检查 Debugger、双映射与内存状态…"
        updateFootprint()
        LogStore.shared.log("[WinArc JIT QuickCheck] BEGIN")

        DispatchQueue.global(qos: .userInitiated).async {
            let debugged = jit_check_debugged()
            LogStore.shared.log("[WinArc JIT QuickCheck] CS_DEBUGGED=\(debugged)")

            let mapping = jit_test_mapping()
            LogStore.shared.log("[WinArc JIT QuickCheck] mapping=\(mapping)")

            DispatchQueue.main.async {
                self.debuggerAttached = debugged
                self.dualMappingAvailable = mapping
                self.updateFootprint()
                self.isRunningQuickCheck = false

                if !debugged {
                    self.executionValidated = false
                    self.status = .unavailable
                    self.lastMessage = "未检测到可用 JIT Debugger"
                } else if !mapping {
                    self.executionValidated = false
                    self.status = .unavailable
                    self.lastMessage = "RW/RX 双映射检测失败"
                } else if self.executionValidated {
                    self.status = .ready
                    self.lastMessage = "JIT 环境已通过高级执行检测"
                } else {
                    self.status = .needsValidation
                    self.lastMessage = "基础环境正常，可启动 Runtime"
                }
            }
        }
    }

    func runFullSelfTest(completion: ((Bool) -> Void)? = nil) {
        guard !isRunningFullTest, !isRunningQuickCheck, !isPreparingRuntime else {
            completion?(false)
            return
        }

        applyConfiguration()
        isRunningFullTest = true
        status = .checking
        lastMessage = "正在执行高级 JIT return-42 测试…"
        updateFootprint()
        LogStore.shared.log("[WinArc JIT SelfTest] BEGIN")

        DispatchQueue.global(qos: .userInitiated).async {
            let debugged = jit_check_debugged()
            LogStore.shared.log("[WinArc JIT SelfTest] CS_DEBUGGED=\(debugged)")

            guard debugged else {
                LogStore.shared.log("[WinArc JIT SelfTest] no debugger", level: .error)
                DispatchQueue.main.async {
                    self.debuggerAttached = false
                    self.executionValidated = false
                    self.isRunningFullTest = false
                    self.status = .unavailable
                    self.lastMessage = "JIT Self Test：未检测到 Debugger"
                    self.updateFootprint()
                    completion?(false)
                }
                return
            }

            LogStore.shared.log("[WinArc JIT SelfTest] ENTER jit_test_execute")
            let result: Int64 = jit_test_execute()
            LogStore.shared.log("[WinArc JIT SelfTest] RETURN jit_test_execute=\(result)")

            DispatchQueue.main.async {
                self.debuggerAttached = true
                self.executionValidated = result == 42
                self.dualMappingAvailable = self.dualMappingAvailable || result == 42
                self.isRunningFullTest = false
                self.updateFootprint()

                if result == 42 {
                    self.status = .ready
                    self.lastMessage = "完整 JIT Self Test 通过"
                    completion?(true)
                } else {
                    self.status = .unavailable
                    self.lastMessage = "JIT Self Test 失败（\(result)）"
                    completion?(false)
                }
            }
        }
    }

    func validateForRuntimeLaunch(completion: @escaping (Bool) -> Void) {
        guard !isPreparingRuntime, !isRunningQuickCheck, !isRunningFullTest else {
            completion(false)
            return
        }

        isPreparingRuntime = true
        status = .checking
        lastMessage = "正在进行 JIT 启动前检查…"
        applyConfiguration()
        updateFootprint()
        LogStore.shared.log("[WinArc JIT Launch] preflight BEGIN")

        DispatchQueue.global(qos: .userInitiated).async {
            let debugged = jit_check_debugged()
            LogStore.shared.log("[WinArc JIT Launch] CS_DEBUGGED=\(debugged)")

            guard debugged else {
                DispatchQueue.main.async {
                    self.debuggerAttached = false
                    self.isPreparingRuntime = false
                    self.status = .unavailable
                    self.lastMessage = "未检测到可用 JIT Debugger"
                    completion(false)
                }
                return
            }

            let mapping = jit_test_mapping()
            LogStore.shared.log("[WinArc JIT Launch] mapping=\(mapping)")

            DispatchQueue.main.async {
                self.debuggerAttached = true
                self.dualMappingAvailable = mapping
                self.isPreparingRuntime = false
                self.updateFootprint()

                guard mapping else {
                    self.status = .unavailable
                    self.lastMessage = "RW/RX 双映射检测失败"
                    completion(false)
                    return
                }

                self.defaults.set(true, forKey: Key.pendingLaunch)
                self.status = .needsValidation
                self.lastMessage = "基础检测通过，准备 \(self.effectivePoolMB)MB Runtime Pool"
                LogStore.shared.log("[WinArc JIT Launch] preflight PASS; entering runtime")
                completion(true)
            }
        }
    }

    func applyConfiguration() {
        let pool = effectivePoolMB

        if effectiveStrategy == .localDualMap {
            setenv("WINARC_LOCAL_JIT_POOL", "1", 1)
        } else {
            unsetenv("WINARC_LOCAL_JIT_POOL")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let poolURL = docs.appendingPathComponent("madeira-pool.txt")
        try? "\(pool)\n".write(to: poolURL, atomically: true, encoding: .utf8)

        LogStore.shared.log(
            "[WinArc JIT Config] mode=\(mode.rawValue) strategy=\(effectiveStrategy.rawValue) pool=\(pool)MB"
        )
    }

    func restoreLastKnownGood() {
        guard
            let modeRaw = defaults.string(forKey: Key.lastGoodMode),
            let strategyRaw = defaults.string(forKey: Key.lastGoodStrategy),
            defaults.integer(forKey: Key.lastGoodPool) > 0
        else {
            mode = .automatic
            strategy = .localDualMap
            customPoolMB = 256
            lastMessage = "没有已保存的稳定配置，已恢复 WinArc 默认值"
            applyConfiguration()
            return
        }

        mode = WinArcJITMode(rawValue: modeRaw) ?? .automatic
        strategy = WinArcJITStrategy(rawValue: strategyRaw) ?? .localDualMap
        customPoolMB = defaults.integer(forKey: Key.lastGoodPool)
        lastMessage = "已恢复上一次稳定 JIT 配置"
        applyConfiguration()
    }

    private func markRuntimePoolReady() {
        defaults.set(false, forKey: Key.pendingLaunch)
        defaults.set(mode.rawValue, forKey: Key.lastGoodMode)
        defaults.set(effectiveStrategy.rawValue, forKey: Key.lastGoodStrategy)
        defaults.set(effectivePoolMB, forKey: Key.lastGoodPool)
        refreshLastKnownGoodText()

        status = .ready
        lastMessage = "JIT Pool \(effectivePoolMB)MB 已建立并保存为稳定配置"
        LogStore.shared.log(
            "[WinArc JIT Runtime] pool READY; saved Last Known Good",
            level: .success
        )
    }

    private func recoverFromInterruptedLaunchIfNeeded() {
        guard defaults.bool(forKey: Key.pendingLaunch) else { return }

        recoveredFromFailedLaunch = true
        defaults.set(false, forKey: Key.pendingLaunch)

        guard
            let modeRaw = defaults.string(forKey: Key.lastGoodMode),
            let strategyRaw = defaults.string(forKey: Key.lastGoodStrategy)
        else {
            mode = .automatic
            strategy = .localDualMap
            customPoolMB = 256
            lastMessage = "检测到上一次 JIT 启动中断，已回退到默认稳定配置"
            persistPreferences()
            LogStore.shared.log(
                "[WinArc JIT Recovery] interrupted launch; fallback to defaults",
                level: .error
            )
            return
        }

        mode = WinArcJITMode(rawValue: modeRaw) ?? .automatic
        strategy = WinArcJITStrategy(rawValue: strategyRaw) ?? .localDualMap
        let savedPool = defaults.integer(forKey: Key.lastGoodPool)
        customPoolMB = savedPool == 0 ? 256 : savedPool

        lastMessage = "检测到上一次 JIT 启动中断，已恢复上一次稳定配置"
        persistPreferences()
        LogStore.shared.log("[WinArc JIT Recovery] restored Last Known Good", level: .error)
    }

    private func persistPreferences() {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(strategy.rawValue, forKey: Key.strategy)
        defaults.set(customPoolMB, forKey: Key.customPool)
        defaults.set(quickCheckOnLaunch, forKey: Key.quickCheck)
    }

    private func refreshLastKnownGoodText() {
        guard let strategyRaw = defaults.string(forKey: Key.lastGoodStrategy) else {
            lastKnownGoodText = "尚无"
            return
        }

        let pool = defaults.integer(forKey: Key.lastGoodPool)
        let goodStrategy = WinArcJITStrategy(rawValue: strategyRaw)?.title ?? strategyRaw
        lastKnownGoodText = "\(goodStrategy) · \(pool)MB"
    }

    private func updateFootprint() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size /
            MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }

        if result == KERN_SUCCESS {
            physicalFootprintMB = Int(info.phys_footprint / (1024 * 1024))
        }
    }
}
