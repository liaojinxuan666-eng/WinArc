import Foundation
import SwiftUI

@MainActor
final class WinArcStore: ObservableObject {
    @Published var containers: [ContainerProfile] = []
    @Published var games: [GameEntry] = []
    @Published var selectedContainerID: UUID?

    private let stateURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("WinArc", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        stateURL = folder.appendingPathComponent("state.json")
        load()
        selectedContainerID = containers.first?.id
    }

    var selectedContainer: ContainerProfile? {
        guard let id = selectedContainerID else { return nil }
        return containers.first { $0.id == id }
    }

    @discardableResult
    func createContainer(name: String, windowsVersion: String = "Windows 10", backend: GraphicsBackend = .dxmt) -> ContainerProfile {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ContainerProfile(
            name: clean.isEmpty ? "Container \(containers.count + 1)" : clean,
            windowsVersion: windowsVersion,
            defaultBackend: backend
        )
        containers.append(profile)
        selectedContainerID = profile.id
        save()
        return profile
    }

    func deleteContainer(_ container: ContainerProfile) {
        games.removeAll { $0.containerID == container.id }
        containers.removeAll { $0.id == container.id }
        if selectedContainerID == container.id {
            selectedContainerID = containers.first?.id
        }
        save()
    }

    func addGame(url: URL, to containerID: UUID) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        var settings = GameSettings()
        settings.backend = containers.first { $0.id == containerID }?.defaultBackend ?? .dxmt

        games.append(GameEntry(
            name: url.deletingPathExtension().lastPathComponent,
            executableBookmark: bookmark,
            executableName: url.lastPathComponent,
            containerID: containerID,
            settings: settings
        ))
        save()
    }

    func updateGame(_ game: GameEntry) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index] = game
        save()
    }

    func deleteGame(_ game: GameEntry) {
        games.removeAll { $0.id == game.id }
        save()
    }

    func containerName(for id: UUID) -> String {
        containers.first { $0.id == id }?.name ?? "Unknown Container"
    }

    func save() {
        if let data = try? JSONEncoder().encode(PersistedState(containers: containers, games: games)) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        containers = state.containers
        games = state.games
    }
}
