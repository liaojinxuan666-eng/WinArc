import SwiftUI

@main
struct WinArcApp: App {
    @StateObject private var store = WinArcStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
