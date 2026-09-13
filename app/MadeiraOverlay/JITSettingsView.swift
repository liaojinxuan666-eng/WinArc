import SwiftUI

struct JITSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var jit = WinArcJITManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    ownershipCard
                    diagnosticsCard
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

                Toggle(
                    "启动时检测",
                    isOn: $jit.quickCheckOnLaunch
                )
                .toggleStyle(.switch)
            }
        }
        .padding(20)
        .winArcGlass()
    }

    private var ownershipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runtime 所有权")
                .font(.headline)

            diagnosticRow("JIT / Pool", "Madeira 原生")
            diagnosticRow("Debugger prepare", "Madeira 原生")
            diagnosticRow("Debugger detach", "Madeira 原生")
            diagnosticRow("PE 页权限", "Madeira/Wine 原生")
            diagnosticRow("FEX", "Madeira 原生")

            Text(
                "WinArc 这里只检测状态和提供管理入口，不再覆盖 Madeira 的 JIT、Pool、页权限或 FEX 执行逻辑。"
            )
            .font(.footnote)
            .foregroundStyle(WinArcTheme.secondary)
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
                "Physical Footprint",
                "\(jit.physicalFootprintMB) MB"
            )
            diagnosticRow(
                "Runtime Path",
                "Madeira → FEX → Wine → DXMT"
            )
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
                .multilineTextAlignment(.trailing)
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
