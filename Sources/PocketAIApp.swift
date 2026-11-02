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
        // Sparkle's own convention: "Check for Updates…" sits just under the
        // About item in the app menu.
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand()
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { app.newChat() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New LiveShortly Session…") { app.post(.newLiveSession) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!app.liveShortly.isConnected)
        }
        CommandGroup(after: .toolbar) {
            // The palette is a sheet on the shell, so the shell has to be the
            // key window first — otherwise ⌘K from Settings opens it behind.
            Button("Command Palette…") {
                app.focusShell()
                app.showCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)
            // Re-fetch whatever this window is showing. Paired devices and new
            // sessions can land after a screen has loaded.
            Button("Refresh") { app.post(.refresh) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Pair a Device…") { app.pairDevice() }
            Divider()
        }
        CommandMenu("Chat") {
            Button("Focus Composer") { app.post(.focusComposer) }
                .keyboardShortcut("l", modifiers: .command)
            // Reaches every generating chat, not just the visible one — a
            // reply can still be arriving in a conversation you switched away
            // from.
            Button("Stop Generating") { app.stopAllGeneration() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!app.isGenerating)
            // Only a chat can regenerate: no view consumes this anywhere else,
            // so outside one the item used to look live and do nothing.
            Button("Regenerate Reply") { app.post(.regenerate) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.isGenerating || !app.selection.isChat)
            Divider()
            // Menu items fire whichever window is focused, Settings included.
            Button("Model Library") { app.reveal(.models) }
            Button("Devices") { app.reveal(.devices) }
            Button("Local Server") { app.reveal(.server) }
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
