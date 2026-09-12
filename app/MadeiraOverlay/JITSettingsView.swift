import SwiftUI

struct JITSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var jit = WinArcJITManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    modeCard
                    advancedCard
                    diagnosticsCard
                    recoveryCard
                }
                .padding(20)
            }
            .background(WinArcTheme.background.ignoresSafeArea())
            .navigationTitle("JIT")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("JIT 状态", systemImage: "bolt.fill")
                    .font(.headline)

                Spacer()

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(jit.statusTitle)
                        .font(.caption.weight(.semibold))
                }
            }

            Text(jit.lastMessage)
                .font(.footnote)
                .foregroundStyle(WinArcTheme.secondary)

            HStack(spacing: 10) {
                Button("快速检测") {
                    jit.runQuickCheck()
                }
                .buttonStyle(.bordered)

                Button(
                    jit.isRunningFullTest ? "检测中…" : "完整 Self Test"
                ) {
                    jit.runFullSelfTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(jit.isRunningFullTest)
            }
        }
        .padding(20)
        .winArcGlass()
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模式")
                .font(.headline)

            Picker("JIT 模式", selection: $jit.mode) {
                ForEach(WinArcJITMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle(
                "进入 WinArc 时进行轻量 JIT 检测",
                isOn: $jit.quickCheckOnLaunch
            )

            HStack {
                Text("当前有效配置")
                    .foregroundStyle(WinArcTheme.secondary)
                Spacer()
                Text(
                    "\(jit.effectiveStrategy.title) · " +
                    "\(jit.effectivePoolMB)MB"
                )
                .font(.system(.footnote, design: .monospaced))
            }
        }
        .padding(20)
        .winArcGlass()
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("高级设置")
                .font(.headline)

            Picker("JIT 策略", selection: $jit.strategy) {
                ForEach(WinArcJITStrategy.allCases) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            .disabled(jit.mode != .custom)

            if jit.mode == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("JIT Pool")
                        Spacer()
                        Text("\(jit.customPoolMB) MB")
                            .font(.system(.body, design: .monospaced))
                    }

                    Slider(
                        value: Binding(
                            get: { Double(jit.customPoolMB) },
                            set: {
                                let stepped =
                                    Int(($0 / 64).rounded()) * 64
                                jit.customPoolMB = stepped
                            }
                        ),
                        in: 256...768,
                        step: 64
                    )
                }
            }

            if jit.effectiveStrategy == .debuggerAlloc {
                Label(
                    "当前设备曾在 Debugger 大块分配路径发生启动中断；仅用于调试。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            } else {
                Label(
                    "默认使用本地 RW/RX 双映射，再让 Debugger 只准备 RX。",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.footnote)
                .foregroundStyle(.green)
            }

            Button("立即应用") {
                jit.applyConfiguration()
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .winArcGlass()
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("诊断")
                .font(.headline)

            diagnosticRow(
                "Debugger",
                jit.debuggerAttached ? "已连接" : "未连接"
            )
            diagnosticRow(
                "RW/RX Dual Map",
                jit.dualMappingAvailable ? "通过" : "未验证"
            )
            diagnosticRow(
                "Execution",
                jit.executionValidated ? "通过" : "未验证"
            )
            diagnosticRow(
                "Physical Footprint",
                "\(jit.physicalFootprintMB) MB"
            )
            diagnosticRow(
                "Configured Pool",
                "\(jit.effectivePoolMB) MB"
            )
            diagnosticRow(
                "Last Known Good",
                jit.lastKnownGoodText
            )
        }
        .padding(20)
        .winArcGlass()
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("稳定性与恢复")
                .font(.headline)

            Text(
                "WinArc 会在运行时 Pool 成功建立后保存稳定配置；" +
                "如果下一次启动发现上一轮在 JIT 建立阶段中断，" +
                "会自动回退。"
            )
            .font(.footnote)
            .foregroundStyle(WinArcTheme.secondary)

            Button("恢复上一次稳定配置") {
                jit.restoreLastKnownGood()
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .winArcGlass()
    }

    private func diagnosticRow(
        _ name: String,
        _ value: String
    ) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(WinArcTheme.secondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
        }
    }

    private var statusColor: Color {
        switch jit.status {
        case .checking: return .gray
        case .ready: return .green
        case .needsValidation: return .yellow
        case .unavailable: return .red
        }
    }
}
