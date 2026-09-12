import SwiftUI

struct HomeView: View {
    @AppStorage(WinArcRuntimeLog.showLiveKey)
    private var showLiveLog = false
    @EnvironmentObject private var store: WinArcStore
    let onCreateContainer: () -> Void
    let onImportGame: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.18, blue: 0.36),
                            Color(red: 0.08, green: 0.08, blue: 0.13)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    VStack(alignment: .leading, spacing: 13) {
                        Text("Windows games.\nYour way.")
                            .font(.system(size: 40, weight: .bold, design: .rounded))

                        Text(store.containers.isEmpty
                             ? "先创建一个容器，然后把 Windows 游戏导入 WinArc。"
                             : "从容器导入游戏，然后在游戏库中单独管理每款游戏。")
                            .foregroundStyle(.white.opacity(0.66))

                        Button(action: store.containers.isEmpty ? onCreateContainer : onImportGame) {
                            Label(
                                store.containers.isEmpty ? "创建容器" : "导入游戏",
                                systemImage: store.containers.isEmpty ? "plus" : "square.and.arrow.down"
                            )
                            .fontWeight(.semibold)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(.white)
                            .foregroundStyle(.black)
                            .clipShape(Capsule())
                        }
                        .padding(.top, 3)
                    }
                    .padding(28)
                }
                .frame(height: 285)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                RuntimeStatusView()

                if showLiveLog {
                    RuntimeLiveLogPanel()
                        .winArcGlass()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Wine Desktop", systemImage: "rectangle.on.rectangle")
                            .font(.system(size: 16, weight: .semibold))

                        Spacer()

                        Text("1280 × 720")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(WinArcTheme.secondary)
                    }

                    WineDesktopSurfaceView()
                        .frame(minHeight: 260, idealHeight: 340, maxHeight: 420)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        }

                    Text("启动 wineserver 后再点“启动 Wine 桌面”。这里直接显示 Winios 合成结果。")
                        .font(.caption)
                        .foregroundStyle(WinArcTheme.secondary)
                }
                .padding(18)
                .winArcGlass()

                if store.games.isEmpty {
                    HStack(spacing: 16) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 28))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("游戏库还没有内容")
                                .font(.headline)
                            Text("导入第一个游戏后，“库”会自动出现在顶部。")
                                .foregroundStyle(WinArcTheme.secondary)
                        }
                        Spacer()
                    }
                    .padding(20)
                    .winArcGlass()
                } else {
                    Text("最近")
                        .font(.system(size: 22, weight: .bold))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(store.games.prefix(6)) { game in
                                GameCard(game: game)
                                    .frame(width: 245)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
    }
}
