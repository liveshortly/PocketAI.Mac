import SwiftUI

@main
struct PocketAIApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environment(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.pendingCommand = .newChat }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { openWindow(id: "command-palette") }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Focus Composer") { model.pendingCommand = .focusComposer }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Stop Generation") { model.pendingCommand = .stopGeneration }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Stop Everything") { model.stopEverything() }
                    .keyboardShortcut(".", modifiers: [.command, .option])
            }
        }

        MenuBarExtra("PocketAI", systemImage: model.serverStatus.running ? "bolt.horizontal.fill" : "bolt.horizontal") {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Command Palette", id: "command-palette") {
            CommandPaletteView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
