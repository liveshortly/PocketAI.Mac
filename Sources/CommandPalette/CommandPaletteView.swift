import SwiftUI
import PocketKit
import PocketUI

/// MAC-02: ⌘K command palette - fuzzy search over chats, models, and a
/// handful of fixed actions. A separate `Window` scene (not a sheet) so
/// it can be summoned from anywhere, including when no PocketAI window
/// is currently key.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var catalog: [CatalogEntry] = []

    private enum Item: Identifiable {
        case conversation(ConversationSummary)
        case model(CatalogEntry)
        case action(String, () -> Void)

        var id: String {
            switch self {
            case .conversation(let c): return "c-\(c.id)"
            case .model(let m): return "m-\(m.manifest.id)"
            case .action(let title, _): return "a-\(title)"
            }
        }

        var title: String {
            switch self {
            case .conversation(let c): return c.title ?? "New chat"
            case .model(let m): return m.manifest.displayName
            case .action(let title, _): return title
            }
        }

        var subtitle: String {
            switch self {
            case .conversation: return "Chat"
            case .model(let m): return "Model · \(m.manifest.family)"
            case .action: return "Action"
            }
        }
    }

    private var actions: [Item] {
        [
            .action("New Chat") { model.pendingCommand = .newChat },
            .action("Stop Everything") { model.stopEverything() },
            .action(model.serverStatus.running ? "Stop Server" : "Start Server") {
                model.serverStatus.running ? model.stopServer() : model.startServer(lan: model.serverStatus.lanEnabled)
            },
            .action(model.core.isOffline() ? "Turn Off Offline Mode" : "Turn On Offline Mode") {
                model.core.setOfflineMode(on: !model.core.isOffline())
            },
        ]
    }

    private var items: [Item] {
        let all: [Item] = conversations.map { .conversation($0) } + catalog.map { .model($0) } + actions
        guard !query.isEmpty else { return all }
        return all.filter { fuzzyMatch(query: query, in: $0.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search chats, models, actions…", text: $query)
                .textFieldStyle(.plain)
                .font(.pocket(.title))
                .padding(PocketSpacing.s16)

            Divider()

            List(items) { item in
                Button {
                    activate(item)
                } label: {
                    VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                        Text(item.title).font(.pocket(.body))
                        Text(item.subtitle).font(.pocket(.caption)).foregroundStyle(PocketColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 480, height: 360)
        .task {
            conversations = model.core.conversations(query: ConversationQuery(search: nil, archived: false, limit: 20, offset: 0))
            catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
        }
    }

    private func activate(_ item: Item) {
        switch item {
        case .conversation(let c): model.pendingCommand = .openConversation(c.id)
        case .model: break // Models screen isn't addressable by id from here yet; selecting just closes the palette.
        case .action(_, let perform): perform()
        }
        dismiss()
    }
}

/// Subsequence match, case-insensitive: every character of `query` must
/// appear in `text`, in order, not necessarily adjacent - e.g. "ntc" or
/// "rust" both match "Explain this Rust borrow checker error".
private func fuzzyMatch(query: String, in text: String) -> Bool {
    var remaining = Substring(query.lowercased())
    guard let first = remaining.first else { return true }
    var needle = first
    for ch in text.lowercased() {
        if ch == needle {
            remaining.removeFirst()
            guard let next = remaining.first else { return true }
            needle = next
        }
    }
    return remaining.isEmpty
}
