import SwiftUI
import PocketUI

/// Mac shell per 02-design-system.md: NavigationSplitView sidebar + content.
/// Screens are placeholders until UI-04/L6 feature cards land; this proves
/// PocketUI tokens and the PocketMark chip render on macOS against a real
/// `CoreClient`.
struct RootSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .chats

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
                ChatsDetail()
            case .some(let item):
                Text(item.rawValue).font(.pocket(.title))
            }
        }
    }
}

private struct ChatsDetail: View {
    @Environment(AppModel.self) private var model
    @State private var streamed = ""
    @State private var isStreaming = false

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            PocketMarkView(state: isStreaming ? .working(tokPerSec: 60) : .idle, size: 64)
            Text(streamed.isEmpty ? "Click to stream a mock reply" : streamed)
                .font(.pocket(.body))
                .foregroundStyle(PocketColor.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PocketColor.bgCanvas)
        .contentShape(Rectangle())
        .onTapGesture { Task { await stream() } }
    }

    private func stream() async {
        guard !isStreaming else { return }
        isStreaming = true
        streamed = ""
        do {
            for try await chunk in model.core.mockGenerate(seed: 0, tokensPerSec: 60) {
                streamed += chunk
            }
        } catch {
            streamed = "Error: \(error)"
        }
        isStreaming = false
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            Text("PocketAI").font(.pocket(.headline))
            Toggle("Serve on LAN", isOn: $model.serverRunning)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(PocketSpacing.s16)
        .frame(width: 220)
    }
}
