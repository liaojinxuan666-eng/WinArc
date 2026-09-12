import Foundation

enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    case dxmt = "DXMT"
    case d3dmetal = "D3DMetal"
    var id: String { rawValue }
}

enum ResolutionScale: String, Codable, CaseIterable, Identifiable {
    case x50 = "50%"
    case x75 = "75%"
    case x100 = "100%"
    case x125 = "125%"
    case x150 = "150%"
    var id: String { rawValue }
}

struct ContainerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var windowsVersion = "Windows 10"
    var defaultBackend: GraphicsBackend = .dxmt
}

struct GameSettings: Codable, Hashable {
    var backend: GraphicsBackend = .dxmt
    var resolutionScale: ResolutionScale = .x100
    var fpsLimit: Int = 60
    var useMetalHud = false
    var environmentVariables = ""
}

struct GameEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var executableBookmark: Data?
    var executableName: String
    var containerID: UUID
    var addedAt = Date()
    var settings = GameSettings()
}

struct PersistedState: Codable {
    var containers: [ContainerProfile]
    var games: [GameEntry]
}
