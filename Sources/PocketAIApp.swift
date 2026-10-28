import PocketKit
import PocketUI
import SwiftUI

@main
struct PocketAIApp: App {
    @State private var app = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 540)
                .background(PocketColor.bgCanvas)
                .preferredColorScheme(nil)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(app: app) }

        // Menu bar presence: quick-ask without bringing the main window
        // forward, and the shortcuts people reach for from another app.
        MenuBarExtra("PocketAI", systemImage: "diamond.fill") {
            MenuBarContent()
                .environment(app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
                .frame(width: 620, height: 460)
        }
    }
}

/// App menus. Every item posts onto `AppModel.pendingCommand` so the focused
/// view, not the menu, decides what the action means.
struct AppCommands: Commands {
    @Bindable var app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { app.newChat() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New LiveShortly Session…") { app.pendingCommand = .newLiveSession }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!app.liveShortly.isConnected)
        }
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { app.showCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Button(app.showInspector ? "Hide Inspector" : "Show Inspector") {
                app.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Chat") {
            Button("Focus Composer") { app.pendingCommand = .focusComposer }
                .keyboardShortcut("l", modifiers: .command)
            Button("Stop Generating") { app.pendingCommand = .stopGeneration }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.isGenerating)
            Button("Regenerate Reply") { app.pendingCommand = .regenerate }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.isGenerating)
            Divider()
            Button("Model Library") { app.selection = .models }
            Button("Devices") { app.selection = .devices }
            Button("Local Server") { app.selection = .server }
        }
    }
}

/// The menu bar popover: ask from anywhere, plus the state worth knowing at a
/// glance (model, server, live sessions).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        QuickAskPanel()
            .environment(app)
            .frame(width: 420)
    }
}
