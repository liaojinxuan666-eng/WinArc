import SwiftUI

struct SettingsView: View {
    @State private var showingRuntimeLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置")
                    .font(.system(size: 32, weight: .bold))

                VStack(alignment: .leading, spacing: 16) {
                    Label("横屏优先", systemImage: "rectangle.landscape")
                    Divider()
                    Label("容器默认设置由“容器”页管理", systemImage: "shippingbox")
                    Divider()
                    Label("游戏独立设置：在“库”长按游戏", systemImage: "gamecontroller")
                }
                .padding(22)
                .winArcGlass()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("运行日志", systemImage: "doc.text.magnifyingglass")
                            .font(.headline)

                        Spacer()

                        Button("查看") {
                            WinArcRuntimeLog.install()
                            showingRuntimeLog = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text("Wine / wineserver / Winios 的 stdout、stderr 和 WinArc 启动阶段标记会持续写入文件；即使 App 闪退，重新打开后日志仍保留。")
                        .font(.footnote)
                        .foregroundStyle(WinArcTheme.secondary)

                    Text("文件：Documents/WinArcLogs/winarc-runtime.log")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.42))
                }
                .padding(22)
                .winArcGlass()

                Text("WinArc Shell v0.0.1")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .sheet(isPresented: $showingRuntimeLog) {
            RuntimeLogView()
        }
    }
}
