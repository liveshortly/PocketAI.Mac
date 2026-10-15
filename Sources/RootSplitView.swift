import SwiftUI
import PocketKit
import PocketUI

/// Mac shell per 02-design-system.md: NavigationSplitView sidebar + content.
/// Screens are placeholders until UI-04/L6 feature cards land; this proves
/// PocketUI tokens and the PocketMark chip render on macOS against a real
/// `CoreClient`.
struct RootSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = Self.initialSelection

    /// `-PocketInitialTab <name>` (e.g. "Models") picks the sidebar's
    /// starting selection - useful for QA screenshots of a tab that
    /// isn't the default, without relying on scripted sidebar clicks.
    private static var initialSelection: SidebarItem? {
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-PocketInitialTab"),
           ProcessInfo.processInfo.arguments.count > index + 1 {
            return SidebarItem(rawValue: ProcessInfo.processInfo.arguments[index + 1])
        }
        return .chats
    }

    enum SidebarItem: String, Identifiable, CaseIterable {
        case chats = "Chats"
        case models = "Models"
        case server = "Server"
        case devices = "Devices"
        case settings = "Settings"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right"
            case .models: return "cpu"
            case .server: return "server.rack"
            case .devices: return "iphone"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("PocketAI")
        } detail: {
            switch selection {
            case .chats, .none:
                MacChatsView()
            case .models:
                MacModelsView()
            case .server:
                MacServerView()
            case .devices:
                MacDevicesView()
            case .some(let item):
                Text(item.rawValue).font(.pocket(.title))
            }
        }
    }
}

/// MAC-08: menu bar popover. Model switcher isn't wired - there's no
/// "current default model" concept exposed by `CoreClient` yet - so this
/// covers Pulse, server + LAN toggle, connected devices, Open PocketAI,
/// and Stop everything (with confirmation).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showStopConfirm = false

    private var status: ServerStatus { model.serverStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(spacing: PocketSpacing.s8) {
                PocketMarkView(state: status.running ? .working(tokPerSec: nil) : .idle, size: 24)
                Text("PocketAI").font(.pocket(.headline))
            }

            Toggle("Server running", isOn: Binding(
                get: { status.running },
                set: { on in on ? model.startServer(lan: status.lanEnabled) : model.stopServer() }
            ))
            Toggle("Serve on local network", isOn: Binding(
                get: { status.lanEnabled },
                set: { lan in if status.running { model.startServer(lan: lan) } }
            ))
            .disabled(!status.running)

            if status.running {
                Text("\(status.connectedDevices) connected device\(status.connectedDevices == 1 ? "" : "s")")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            Divider()

            Button("Open PocketAI") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
            Button("Stop Everything") { showStopConfirm = true }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(PocketSpacing.s16)
        .frame(width: 240)
        .confirmationDialog(
            "Stop everything?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Everything", role: .destructive) { model.stopEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops any in-progress replies and turns off the server.")
        }
        .task { model.refreshServerStatus() }
    }
}
