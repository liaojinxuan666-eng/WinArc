import SwiftUI

struct SettingsView: View {
    @StateObject private var jit = WinArcJITManager.shared
    @State private var showMadeiraRuntime = false
    @State private var showJITSettings = false
    @State private var showLogs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置")
                    .font(.system(size: 32, weight: .bold))

                VStack(alignment: .leading, spacing: 16) {
                    Label(
                        "横屏优先",
                        systemImage: "rectangle.landscape"
                    )
                    Divider()
                    Label(
                        "容器默认设置由“容器”页管理",
                        systemImage: "shippingbox"
                    )
                    Divider()
                    Label(
                        "游戏独立设置：在“库”长按游戏",
                        systemImage: "gamecontroller"
                    )
                }
                .padding(22)
                .winArcGlass()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(
                            "JIT",
                            systemImage: "bolt.fill"
                        )
                        .font(.headline)

                        Spacer()

                        Text(jit.statusTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }

                    Text(
                        "\(jit.effectiveStrategy.title) · " +
                        "\(jit.effectivePoolMB)MB · " +
                        "\(jit.physicalFootprintMB)MB footprint"
                    )
                    .font(.footnote)
                    .foregroundStyle(WinArcTheme.secondary)

                    HStack(spacing: 10) {
                        Button("JIT 设置") {
                            showJITSettings = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("运行日志") {
                            showLogs = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(22)
                .winArcGlass()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(
                            "Madeira Runtime",
                            systemImage:
                                "wrench.and.screwdriver.fill"
                        )
                        .font(.headline)

                        Spacer()

                        Text("调试入口")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WinArcTheme.secondary)
                    }

                    Text(
                        "Madeira 原运行控制台暂时保留作为底层诊断入口；" +
                        "普通启动逐步迁移到 WinArc 自己的 Runtime/JIT 管理。"
                    )
                    .font(.footnote)
                    .foregroundStyle(WinArcTheme.secondary)

                    Button("打开运行控制") {
                        showMadeiraRuntime = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(22)
                .winArcGlass()

                Text("WinArc 0.0.1 · Madeira base integration")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .onAppear {
            jit.runQuickCheckIfNeeded()
        }
        .sheet(isPresented: $showJITSettings) {
            JITSettingsView()
        }
        .sheet(isPresented: $showLogs) {
            MadeiraLogView()
        }
        .fullScreenCover(isPresented: $showMadeiraRuntime) {
            MadeiraLegacyContentView()
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
