import SwiftUI
import PocketKit
import PocketUI

/// MAC-02: ⌘K command palette - Spotlight-grade quick switcher over chats, models, and actions.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var catalog: [CatalogEntry] = []
    @State private var selectedIndex: Int = 0

    private enum ItemType {
        case action
        case conversation
        case model
    }

    private struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let type: ItemType
        let action: () -> Void
    }

    private var allActions: [PaletteItem] {
        [
            PaletteItem(
                id: "act-new-chat",
                title: "New Chat",
                subtitle: "Start a fresh conversation",
                icon: "square.and.pencil",
                type: .action
            ) {
                model.selectedTab = .chats
                model.pendingCommand = .newChat
            },
            PaletteItem(
                id: "act-projects",
                title: "Open Projects",
                subtitle: "Ground answers in project documents",
                icon: "folder",
                type: .action
            ) {
                model.selectedTab = .projects
                model.pendingCommand = .openTab(.projects)
            },
            PaletteItem(
                id: "act-models",
                title: "Open Models Catalog",
                subtitle: "Browse and download on-device models",
                icon: "cpu",
                type: .action
            ) {
                model.selectedTab = .models
                model.pendingCommand = .openTab(.models)
            },
            PaletteItem(
                id: "act-server",
                title: "Open Server",
                subtitle: "Manage OpenAI-compatible local API",
                icon: "server.rack",
                type: .action
            ) {
                model.selectedTab = .server
                model.pendingCommand = .openTab(.server)
            },
            PaletteItem(
                id: "act-devices",
                title: "Open Devices",
                subtitle: "Manage paired iPhones and local clients",
                icon: "iphone",
                type: .action
            ) {
                model.selectedTab = .devices
                model.pendingCommand = .openTab(.devices)
            },
            PaletteItem(
                id: "act-privacy",
                title: "Open Privacy & Audit",
                subtitle: "View Network Proof and audit trails",
                icon: "hand.raised",
                type: .action
            ) {
                model.selectedTab = .privacy
                model.pendingCommand = .openTab(.privacy)
            },
            PaletteItem(
                id: "act-image-gen",
                title: "Generate Image",
                subtitle: "On-device SDXL Turbo generator",
                icon: "sparkles",
                type: .action
            ) {
                openWindow(id: "image-generation")
            },
            PaletteItem(
                id: "act-stop-all",
                title: "Stop Everything",
                subtitle: "Cancel all active replies and stop local server",
                icon: "stop.circle.fill",
                type: .action
            ) {
                model.stopEverything()
            },
            PaletteItem(
                id: "act-toggle-server",
                title: model.serverStatus.running ? "Stop Local Server" : "Start Local Server",
                subtitle: model.serverStatus.running ? "Deactivate port :\(model.serverStatus.port)" : "Expose a local OpenAI-compatible endpoint",
                icon: "bolt.horizontal",
                type: .action
            ) {
                model.serverStatus.running ? model.stopServer() : model.startServer(lan: model.serverStatus.lanEnabled)
            },
            PaletteItem(
                id: "act-toggle-offline",
                title: model.core.isOffline() ? "Turn Off Offline Mode" : "Turn On Offline Mode",
                subtitle: model.core.isOffline() ? "Resume background catalog updates" : "Block all internet egress",
                icon: "airplane",
                type: .action
            ) {
                model.core.setOfflineMode(on: !model.core.isOffline())
            },
        ]
    }

    private var filteredItems: [PaletteItem] {
        var result: [PaletteItem] = []

        // Actions
        let matchedActions = query.isEmpty ? allActions : allActions.filter { fuzzyMatch(query: query, in: $0.title) || fuzzyMatch(query: query, in: $0.subtitle) }
        result.append(contentsOf: matchedActions)

        // Conversations
        let convItems = conversations.compactMap { conv -> PaletteItem? in
            let title = conv.title ?? "New chat"
            guard query.isEmpty || fuzzyMatch(query: query, in: title) else { return nil }
            return PaletteItem(
                id: "conv-\(conv.id)",
                title: title,
                subtitle: "Conversation",
                icon: "bubble.left",
                type: .conversation
            ) {
                model.selectedTab = .chats
                model.pendingCommand = .openConversation(conv.id)
            }
        }
        result.append(contentsOf: convItems)

        // Models
        let modelItems = catalog.compactMap { entry -> PaletteItem? in
            let title = entry.manifest.displayName
            guard query.isEmpty || fuzzyMatch(query: query, in: title) || fuzzyMatch(query: query, in: entry.manifest.family) else { return nil }
            return PaletteItem(
                id: "model-\(entry.manifest.id)",
                title: title,
                subtitle: "\(entry.manifest.family) · \(entry.manifest.quant)",
                icon: "cpu",
                type: .model
            ) {
                model.currentModelId = entry.manifest.id
                model.selectedTab = .models
                model.pendingCommand = .openTab(.models)
            }
        }
        result.append(contentsOf: modelItems)

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(PocketColor.accent)

                TextField("Search chats, models, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                Text("ESC")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PocketColor.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(PocketColor.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgRaised)

            Divider()

            // Results List
            if filteredItems.isEmpty {
                VStack(spacing: PocketSpacing.s8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(PocketColor.textTertiary)
                    Text("No results for “\(query)”")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                let isSelected = index == selectedIndex
                                Button {
                                    activate(item)
                                } label: {
                                    HStack(spacing: PocketSpacing.s12) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(isSelected ? PocketColor.accent : PocketColor.textSecondary)
                                            .frame(width: 24, height: 24)
                                            .background(isSelected ? PocketColor.accentSoft : PocketColor.bgSunken)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title)
                                                .font(.pocket(.body))
                                                .fontWeight(isSelected ? .semibold : .regular)
                                                .foregroundStyle(PocketColor.textPrimary)
                                                .lineLimit(1)

                                            Text(item.subtitle)
                                                .font(.pocket(.caption))
                                                .foregroundStyle(PocketColor.textSecondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        if isSelected {
                                            Image(systemName: "return")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(PocketColor.accent)
                                        }
                                    }
                                    .padding(.horizontal, PocketSpacing.s12)
                                    .padding(.vertical, PocketSpacing.s8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isSelected ? PocketColor.accentSoft.opacity(0.6) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        .padding(PocketSpacing.s8)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        if newIndex >= 0 && newIndex < filteredItems.count {
                            proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack(spacing: PocketSpacing.s16) {
                HStack(spacing: 4) {
                    Text("↑↓")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketColor.textTertiary)
                    Text("Navigate")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                HStack(spacing: 4) {
                    Text("↵")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketColor.textTertiary)
                    Text("Open")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    PocketMarkView(state: .idle, size: 12)
                    Text("PocketAI Spotlight")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgCanvas)
        }
        .frame(width: 520, height: 380)
        .background(PocketColor.bgSurface)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredItems.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.return) {
            if selectedIndex >= 0 && selectedIndex < filteredItems.count {
                activate(filteredItems[selectedIndex])
            }
            return .handled
        }
        .onChange(of: query) {
            selectedIndex = 0
        }
        .task {
            conversations = model.core.conversations(query: ConversationQuery(search: nil, archived: false, limit: 20, offset: 0))
            catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
        }
    }

    private func activate(_ item: PaletteItem) {
        item.action()
        dismiss()
    }
}

/// Subsequence match, case-insensitive: every character of `query` must
/// appear in `text`, in order, not necessarily adjacent.
public func fuzzyMatch(query: String, in text: String) -> Bool {
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
