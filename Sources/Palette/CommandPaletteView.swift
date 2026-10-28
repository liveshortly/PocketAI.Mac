import PocketKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// ⌘K: one field that reaches every chat, project, live session and action.
/// Arrow keys move, ⏎ runs, Esc closes — no mouse needed anywhere.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @State private var chats: [ConversationSummary] = []
    @State private var projects: [Project] = []
    @State private var sessions: [LSSession] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(PocketColor.accent)
                    .font(.pocket(.caption))
                TextField("Jump to a chat, project, session or action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.pocket(.body))
                    .focused($focused)
                    .onSubmit(run)
                    .onChange(of: query) { _, _ in highlighted = 0 }
            }
            .padding(PocketSpacing.s12)
            HUDRule()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, selected: index == highlighted)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    highlighted = index
                                    run()
                                }
                        }
                        if results.isEmpty {
                            Text("Nothing matches “\(query)”")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textTertiary)
                                .padding(PocketSpacing.s12)
                        }
                    }
                }
                .frame(maxHeight: 340)
                .onChange(of: highlighted) { _, index in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
                }
            }
            HUDRule()
            HStack {
                HUDLabel("↑↓ move · ⏎ open · esc close")
                Spacer()
                HUDLabel("\(results.count) results")
            }
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, PocketSpacing.s8)
        }
        .frame(width: 580)
        .background(PocketColor.bgSurface)
        .task { load() }
        .onAppear { focused = true }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(max(0, results.count - 1), highlighted + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Items

    struct Item: Identifiable {
        enum Kind { case chat, project, session, action }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let symbol: String
        let live: Bool
        let run: () -> Void
    }

    private var results: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var items: [Item] = []

        items.append(contentsOf: actions.filter { fuzzyMatch(query: q, in: $0.title) })
        items.append(contentsOf: chats.filter {
            fuzzyMatch(query: q, in: $0.title ?? "")
        }.prefix(q.isEmpty ? 6 : 20).map { summary in
            Item(
                id: "chat-\(summary.id)", kind: .chat,
                title: summary.title?.isEmpty == false ? summary.title! : "Untitled chat",
                subtitle: hudRelative(summary.updatedAt), symbol: "bubble.left", live: false
            ) {
                app.selection = .chat(summary.id)
            }
        })
        items.append(contentsOf: projects.filter {
            fuzzyMatch(query: q, in: $0.name)
        }.map { project in
            Item(
                id: "project-\(project.id)", kind: .project, title: project.name,
                subtitle: "Project", symbol: "folder", live: false
            ) {
                app.selection = .project(project.id)
            }
        })
        items.append(contentsOf: sessions.filter {
            fuzzyMatch(query: q, in: $0.title)
        }.map { session in
            Item(
                id: "session-\(session.id)", kind: .session,
                title: session.title.isEmpty ? "Untitled session" : session.title,
                subtitle: session.isLive ? "LiveShortly · live" : "LiveShortly",
                symbol: "dot.radiowaves.left.and.right", live: session.isLive
            ) {
                app.selection = .session(session.id)
            }
        })
        return items
    }

    private var actions: [Item] {
        var list: [Item] = [
            Item(
                id: "action-new-chat", kind: .action, title: "New chat",
                subtitle: "⌘N", symbol: "plus.circle", live: false
            ) { app.newChat() },
            Item(
                id: "action-models", kind: .action, title: "Model library",
                subtitle: "Download and switch models", symbol: "cpu", live: false
            ) { app.selection = .models },
            Item(
                id: "action-images", kind: .action, title: "Generate an image",
                subtitle: "On-device SDXL Turbo", symbol: "photo", live: false
            ) { app.selection = .images },
            Item(
                id: "action-devices", kind: .action, title: "Devices",
                subtitle: "Pair an iPhone", symbol: "iphone", live: false
            ) { app.selection = .devices },
            Item(
                id: "action-server", kind: .action, title: "Local server",
                subtitle: app.serverStatus.running ? "Running" : "Stopped",
                symbol: "server.rack", live: app.serverStatus.running
            ) { app.selection = .server },
            Item(
                id: "action-privacy", kind: .action, title: "Privacy",
                subtitle: "Offline mode and logs", symbol: "hand.raised", live: false
            ) { app.selection = .privacy },
        ]
        if app.liveShortly.isConnected {
            list.insert(
                Item(
                    id: "action-new-session", kind: .action, title: "New LiveShortly session",
                    subtitle: "⇧⌘N", symbol: "bolt", live: false
                ) { app.pendingCommand = .newLiveSession },
                at: 1)
        }
        return list
    }

    private func run() {
        guard results.indices.contains(highlighted) else { return }
        results[highlighted].run()
        dismiss()
    }

    private func load() {
        chats = app.core.conversations(
            query: ConversationQuery(search: nil, archived: false, limit: 100, offset: 0))
        projects = app.core.listProjects()
        if let client = app.liveShortly.client {
            Task { sessions = (try? await client.sessions(limit: 30)) ?? [] }
        }
    }
}

/// Subsequence match, the way every command palette worth using behaves:
/// "nct" finds "New chat", "serv" finds "Local server". Case-insensitive, and
/// an empty query matches everything.
func fuzzyMatch(query: String, in candidate: String) -> Bool {
    let needle = Array(query.lowercased())
    guard !needle.isEmpty else { return true }
    var index = needle.startIndex
    for character in candidate.lowercased() where character == needle[index] {
        index = needle.index(after: index)
        if index == needle.endIndex { return true }
    }
    return false
}

struct PaletteRow: View {
    let item: CommandPaletteView.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: item.symbol)
                .foregroundStyle(selected ? PocketColor.accent : PocketColor.textTertiary)
                .frame(width: 18)
            Text(item.title)
                .font(.pocket(.body))
                .lineLimit(1)
            if item.live { HUDLiveBadge() }
            Spacer(minLength: PocketSpacing.s8)
            Text(item.subtitle)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, PocketSpacing.s12)
        .padding(.vertical, PocketSpacing.s8)
        .background(selected ? PocketColor.accentSoft : Color.clear)
    }
}
