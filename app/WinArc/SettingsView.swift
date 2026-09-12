import SwiftUI

struct SettingsView: View {
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

                Text("WinArc Shell v0.0.1")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}
