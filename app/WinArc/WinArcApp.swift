import SwiftUI

@main
struct WinArcApp: App {
    @StateObject private var store = WinArcStore()

    init() {
        WinArcRuntimeLog.configureForAppLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
