import PocketKit
import PocketLiveShortly
import PocketUI
import SwiftUI

@main
struct PocketAIApp: App {
    @State private var app = AppModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 820, minHeight: 540)
                .background(PocketColor.bgCanvas)
                .preferredColorScheme(nil)
                .tint(PocketColor.accent)
                .onAppear { GeneralSettings.applyAppearance() }
                // LSI-19: liveshortly.com/session/<id> and pocketai://session/<id>
                // open that session; one this account can't see says so there.
                .onOpenURL { url in
                    // COM-10: pocketai://activate?key=… opens Licence with a confirm.
                    if let key = ActivateLink.key(in: url) {
                        UserDefaults.standard.set("license", forKey: SettingsView.tabKey)
                        app.pendingActivationKey = key
                        openSettings()
                        return
                    }
                    if let id = LSSessionLink.sessionID(in: url, server: app.liveShortly.serverURL) {
                        app.selection = .session(id)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(app: app) }

        // Menu bar presence: quick-ask without bringing the main window
        // forward, and the shortcuts people reach for from another app.
        MenuBarExtra("PocketAI", image: "MenuBarIcon") {
            MenuBarContent()
                .environment(app)
                .tint(PocketColor.accent)
                // UI-140: failures from Quick Ask and the menu-bar panel were
                // toasted into the main window, often closed or behind.
                .pocketToast($app.currentToast, duration: .seconds(6))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
                .frame(width: 620, height: 460)
                .tint(PocketColor.accent)
                .pocketToast($app.currentToast, duration: .seconds(6))
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
                .disabled(!app.hasOnboarded)
            Button("New LiveShortly Session…") { app.post(.newLiveSession) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!app.hasOnboarded || !app.liveShortly.isConnected)
        }
        CommandGroup(after: .toolbar) {
            // The palette is a sheet on the shell, so the shell has to be the
            // key window first — otherwise ⌘K from Settings opens it behind.
            Button("Command Palette…") {
                app.focusShell()
                app.showCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!app.hasOnboarded)
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
            // ⌘C stays the text-selection copy; this takes the whole reply.
            Button("Copy Last Reply") { app.post(.copyLastReply) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!app.selection.isChat)
            Divider()
            // Menu items fire whichever window is focused, Settings included.
            // UI-139: named as the sidebar names them, and every sidebar
            // tool is reachable (Images and Privacy were missing).
            Button("Models") { app.reveal(.models) }
                .disabled(!app.hasOnboarded)
            Button("Images") { app.reveal(.images) }
                .disabled(!app.hasOnboarded)
            Button("Devices") { app.reveal(.devices) }
                .disabled(!app.hasOnboarded)
            Button("Local Server") { app.reveal(.server) }
                .disabled(!app.hasOnboarded)
            Button("Privacy") { app.reveal(.privacy) }
                .disabled(!app.hasOnboarded)
        }
    }
}

/// The menu bar popover: ask from anywhere, plus the state worth knowing at a
/// glance (model, server, live sessions).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if app.hasOnboarded {
                QuickAskPanel()
                    .environment(app)
            } else {
                // UI-47: asking before onboarding made chats the user could
                // not see once the window came up.
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("Finish setting up PocketAI")
                        .font(.pocket(.headline))
                        .accessibilityAddTraits(.isHeader)
                    Text("Pick a model in the PocketAI window to start asking from here.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                    Button("Open PocketAI") { app.focusShell() }
                        .buttonStyle(.hudProminent)
                }
                .padding(PocketSpacing.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PocketColor.bgSurface)
            }
        }
        .frame(width: 420)
    }
}
