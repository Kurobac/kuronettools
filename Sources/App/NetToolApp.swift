import SwiftUI

@main
@MainActor
struct NetToolApp: App {
    @State private var logStore = AppLogStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(logStore)
                .task {
                    logStore.recordLaunchIfNeeded()
                }
        }
    }
}
