import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: WinArcStore
    @State private var editingGame: GameEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("游戏库")
                        .font(.system(size: 32, weight: .bold))
                    Text("长按任意游戏，可以单独修改该游戏的运行设置。")
                        .foregroundStyle(WinArcTheme.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                    ForEach(store.games) { game in
                        GameCard(game: game)
                            .contextMenu {
                                Button {
                                    editingGame = game
                                } label: {
                                    Label("此游戏设置", systemImage: "slider.horizontal.3")
                                }

                                Button(role: .destructive) {
                                    store.deleteGame(game)
                                } label: {
                                    Label("从库中移除", systemImage: "trash")
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.45) {
                                editingGame = game
                            }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .sheet(item: $editingGame) { game in
            GameSettingsSheet(game: game)
        }
    }
}

struct GameCard: View {
    @EnvironmentObject private var store: WinArcStore
    let game: GameEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [Color.blue.opacity(0.32), Color.purple.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 45))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .frame(height: 140)

            VStack(alignment: .leading, spacing: 6) {
                Text(game.name)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                Text(store.containerName(for: game.containerID))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.50))
                Text("\(game.settings.backend.rawValue) · \(game.settings.resolutionScale.rawValue) · \(game.settings.fpsLimit) FPS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.40))
            }
            .padding(14)
        }
        .background(WinArcTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(WinArcTheme.stroke, lineWidth: 1)
        )
    }
}
