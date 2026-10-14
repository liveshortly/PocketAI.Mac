import SwiftUI

@main
struct PocketAIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environment(model)
        }

        MenuBarExtra("PocketAI", systemImage: model.serverRunning ? "bolt.horizontal.fill" : "bolt.horizontal") {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
