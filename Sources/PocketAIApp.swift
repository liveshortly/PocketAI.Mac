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
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    model.selectedTab = .chats
                    model.pendingCommand = .newChat
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Project") {
                    model.selectedTab = .projects
                    model.pendingCommand = .openTab(.projects)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Generate Image") {
                    openWindow(id: "image-generation")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { openWindow(id: "command-palette") }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Focus Composer") { model.pendingCommand = .focusComposer }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Toggle Inspector") {
                    model.showChatInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Stop Generation") { model.pendingCommand = .stopGeneration }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Stop Everything") { model.stopEverything() }
                    .keyboardShortcut(".", modifiers: [.command, .option])
            }
        }

        MenuBarExtra(
            "PocketAI",
            systemImage: model.isGenerating
                ? "bolt.horizontal.circle.fill"
                : (model.serverStatus.running ? "bolt.horizontal.fill" : "bolt.horizontal")
        ) {
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

        Window("Image Generation", id: "image-generation") {
            MacImageGenView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
