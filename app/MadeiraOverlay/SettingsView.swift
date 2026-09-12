import SwiftUI

struct SettingsView: View {
    @State private var showMadeiraRuntime = false

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

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Madeira Runtime", systemImage: "wrench.and.screwdriver.fill")
                            .font(.headline)
                        Spacer()
                        Text("临时兼容入口")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WinArcTheme.secondary)
                    }

                    Text("第一步只把 WinArc 产品 UI 接到 Madeira App 上。Madeira 原运行控制台暂时保留在这里，后面再逐项把功能迁进 WinArc 自己的容器和游戏设置。")
                        .font(.footnote)
                        .foregroundStyle(WinArcTheme.secondary)

                    Button("打开运行控制") {
                        showMadeiraRuntime = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(22)
                .winArcGlass()

                Text("WinArc · Madeira base integration")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .fullScreenCover(isPresented: $showMadeiraRuntime) {
            NavigationStack {
                MadeiraLegacyContentView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("返回 WinArc") {
                                showMadeiraRuntime = false
                            }
                        }
                    }
            }
        }
    }
}
