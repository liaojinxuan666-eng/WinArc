import SwiftUI

extension Notification.Name {
    static let winArcLaunchDesktop = Notification.Name("WinArcLaunchDesktop")
}

struct HomeView: View {
    @EnvironmentObject private var store: WinArcStore
    let onCreateContainer: () -> Void
    let onImportGame: () -> Void

    @State private var showMadeiraRuntime = false

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

                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.blue.opacity(0.16))
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Windows 桌面测试")
                            .font(.system(size: 17, weight: .semibold))
                        Text("WinArc UI → Madeira Runtime → Wine Desktop")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WinArcTheme.secondary)
                        Text("先验证完整 Wine 桌面启动链；成功后游戏库直接接到同一条运行链。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                    }

                    Spacer()

                    Button("启动桌面") {
                        showMadeiraRuntime = true
                    }
                    .buttonStyle(.borderedProminent)
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
        .fullScreenCover(isPresented: $showMadeiraRuntime) {
            ZStack(alignment: .topLeading) {
                MadeiraLegacyContentView()
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            NotificationCenter.default.post(
                                name: .winArcLaunchDesktop,
                                object: nil
                            )
                        }
                    }

                Button {
                    showMadeiraRuntime = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .padding(.top, 8)
                .zIndex(100)
            }
            .background(Color.black)
        }
    }
}
