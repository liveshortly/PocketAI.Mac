import PocketKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// Every chat, searchable. The sidebar shows only the newest few so it stays
/// scannable; this is where the rest lives.
struct AllChatsView: View {
    @Environment(AppModel.self) private var app
    @State private var chats: [ConversationSummary] = []
    @State private var query = ""
    @State private var includeArchived = false
    @State private var confirmDelete: ConversationSummary?
    @State private var selected: Set<String> = []
    @State private var confirmBulkDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PocketSpacing.s12) {
                Text("All chats")
                    .font(.pocket(.headline))
                HUDLabel("\(chats.count)")
                Spacer(minLength: 0)
                TextField("Search chats", text: $query)
                    .textFieldStyle(.plain)
                    .font(.pocket(.body))
                    .frame(width: 240)
                    .padding(.horizontal, PocketSpacing.s8)
                    .padding(.vertical, 5)
                    .hudPanel(PocketColor.bgCanvas)
                Toggle("Archived", isOn: $includeArchived)
                    .toggleStyle(.switch)
                    .font(.pocket(.caption))
                if selected.isEmpty {
                    Button("Select all") { selected = Set(chats.map(\.id)) }
                        .buttonStyle(.hud)
                        .disabled(chats.isEmpty)
                } else {
                    Button("Delete \(selected.count)") { confirmBulkDelete = true }
                        .buttonStyle(.hudDestructive)
                    Button("Clear") { selected = [] }
                        .buttonStyle(.hud)
                }
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.chats, id: \.id) { chat in
                        Button {
                            app.selection = .chat(chat.id)
                        } label: {
                            HStack(spacing: PocketSpacing.s12) {
                                Button {
                                    if selected.contains(chat.id) {
                                        selected.remove(chat.id)
                                    } else {
                                        selected.insert(chat.id)
                                    }
                                } label: {
                                    Image(systemName: selected.contains(chat.id)
                                        ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(chat.id)
                                            ? PocketColor.accent : PocketColor.lineStrong)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    selected.contains(chat.id) ? "Deselect" : "Select")
                                .accessibilityAddTraits(
                                    selected.contains(chat.id) ? [.isSelected] : [])
                                Image(systemName: "bubble.left")
                                    .foregroundStyle(PocketColor.textTertiary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chat.title?.isEmpty == false
                                        ? chat.title! : "Untitled chat")
                                        .font(.pocket(.body))
                                    Text(hudRelative(chat.updatedAt))
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textTertiary)
                                }
                                Spacer(minLength: 0)
                                if chat.archived { HUDChip(text: "ARCHIVED") }
                            }
                            .padding(.horizontal, PocketSpacing.s12)
                            .padding(.vertical, PocketSpacing.s8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Open \(chat.title?.isEmpty == false ? chat.title! : "Untitled chat")"
                            + ", \(hudRelative(chat.updatedAt))"
                            + (chat.archived ? ", archived" : ""))
                        .contextMenu {
                            Button(chat.archived ? "Unarchive" : "Archive") {
                                do {
                                    try app.core.archiveConversation(
                                        id: chat.id, archived: !chat.archived)
                                } catch {
                                    app.toast(
                                        chat.archived
                                        ? "Couldn't unarchive that chat: \(error.localizedDescription)"
                                        : "Couldn't archive that chat: \(error.localizedDescription)")
                                }
                                reload()
                            }
                            Button("Delete", role: .destructive) { confirmDelete = chat }
                        }
                        HUDRule()
                            }
                        } header: {
                            HStack {
                                HUDLabel(section.title)
                                Spacer()
                                HUDLabel("\(section.chats.count)")
                            }
                            .padding(.horizontal, PocketSpacing.s12)
                            .padding(.vertical, PocketSpacing.s4)
                            .background(PocketColor.bgCanvas)
                        }
                    }
                    if chats.isEmpty {
                        Text(query.isEmpty ? "No chats yet" : "No chats match “\(query)”")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textTertiary)
                            .padding(PocketSpacing.s16)
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task { reload() }
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: includeArchived) { _, _ in reload() }
        .onChange(of: app.commandSerial) { _, _ in
            if app.pendingCommand == .refresh { reload() }
        }
        .confirmationDialog(
            "Delete \(selected.count) chat\(selected.count == 1 ? "" : "s")? This cannot be undone.",
            isPresented: $confirmBulkDelete, titleVisibility: .visible
        ) {
            Button("Delete \(selected.count)", role: .destructive) {
                // A bulk delete that half-worked used to look like a clean
                // one: the selection cleared either way. Keep what survived
                // selected and say how many refused.
                var failed: [String] = []
                var lastError = ""
                for id in selected {
                    do {
                        try app.core.deleteConversation(id: id)
                        app.forgetChatModel(id)
                    } catch {
                        failed.append(id)
                        lastError = error.localizedDescription
                    }
                }
                if case .chat(let open) = app.selection,
                   selected.contains(open), !failed.contains(open) {
                    app.selection = nil
                }
                selected = Set(failed)
                if !failed.isEmpty {
                    app.toast(
                        "Couldn't delete \(failed.count) of those chats: \(lastError)")
                }
                NotificationCenter.default.post(name: .pocketConversationsChanged, object: nil)
                reload()
            }
        }
        .confirmationDialog(
            "Delete “\(confirmDelete?.title ?? "chat")”? This cannot be undone.",
            isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete chat", role: .destructive) {
                guard let target = confirmDelete else { return }
                do {
                    try app.core.deleteConversation(id: target.id)
                    app.forgetChatModel(target.id)
                } catch {
                    app.toast("Couldn't delete that chat: \(error.localizedDescription)")
                }
                NotificationCenter.default.post(name: .pocketConversationsChanged, object: nil)
                reload()
            }
        }
    }

    /// Chats grouped the way people look for them — by when they were last
    /// touched, not as one long undifferentiated list.
    private var sections: [(title: String, chats: [ConversationSummary])] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday)!

        var buckets: [String: [ConversationSummary]] = [:]
        for chat in chats {
            let when = Date(timeIntervalSince1970: TimeInterval(chat.updatedAt))
            let title: String
            if when >= startOfToday {
                title = "Today"
            } else if when >= yesterday {
                title = "Yesterday"
            } else if when >= weekAgo {
                title = "Previous 7 days"
            } else if when >= monthAgo {
                title = "Previous 30 days"
            } else {
                title = "Older"
            }
            buckets[title, default: []].append(chat)
        }
        let order = ["Today", "Yesterday", "Previous 7 days", "Previous 30 days", "Older"]
        return order.compactMap { title in
            guard let group = buckets[title], !group.isEmpty else { return nil }
            return (title, group.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    private func reload() {
        let search = query.trimmingCharacters(in: .whitespaces)
        chats = app.core.conversations(
            query: ConversationQuery(
                search: search.isEmpty ? nil : search,
                archived: includeArchived ? nil : false,
                limit: 500,
                offset: 0))
    }
}

/// Every LiveShortly session, searchable — live ones first.
struct AllSessionsView: View {
    @Environment(AppModel.self) private var app
    @State private var sessions: [LSSession] = []
    @State private var query = ""
    @State private var loading = true
    @State private var errorText: String?
    @State private var actions = SessionActionState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PocketSpacing.s12) {
                Text("All sessions")
                    .font(.pocket(.headline))
                HUDLabel("\(sessions.count)")
                Spacer(minLength: 0)
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.pocket(.body))
                    .frame(width: 240)
                    .padding(.horizontal, PocketSpacing.s8)
                    .padding(.vertical, 5)
                    .hudPanel(PocketColor.bgCanvas)
                Button("New session") { app.selection = .newSession() }
                    .buttonStyle(.hudProminent)
                    .disabled(app.liveShortly.client == nil)
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.id) { session in
                        // UI-86: the sidebar's row and menu — unread count,
                        // "Starting…", shared-by line, copy link / end / delete.
                        Button {
                            app.selection = .session(session.id)
                        } label: {
                            SessionRow(session: session)
                                .padding(.horizontal, PocketSpacing.s12)
                                .padding(.vertical, PocketSpacing.s8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sessionContextMenu(session, state: actions)
                        HUDRule()
                    }
                    if loading {
                        PocketMarkView(state: .loading, size: 24)
                            .accessibilityLabel("Loading sessions")
                            .padding(PocketSpacing.s16)
                    } else if filtered.isEmpty {
                        // UI-80: signed out is not "no sessions".
                        Text(app.liveShortly.client == nil
                            ? "LiveShortly isn't connected on this Mac. Connect it in Settings."
                            : query.isEmpty
                            ? "No sessions yet" : "No sessions match “\(query)”")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textTertiary)
                            .padding(PocketSpacing.s16)
                    }
                    if let errorText = errorText ?? actions.error {
                        Text(errorText)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                            .padding(PocketSpacing.s16)
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .sessionActionDialogs(actions) { Task { await reload() } }
        .task { await reload() }
        // The shared feed polls (LSI-17); re-fetch the long list when a
        // session appears, goes away or changes state — not on every event.
        .onChange(of: app.liveShortly.feed.sessions.map { $0.id + $0.status }) { _, _ in
            Task { await reload() }
        }
        .onChange(of: app.commandSerial) { _, _ in
            if app.pendingCommand == .refresh { Task { await reload() } }
        }
    }

    private var filtered: [LSSession] {
        let search = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ordered = sessions.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            return $0.createdAt > $1.createdAt
        }
        guard !search.isEmpty else { return ordered }
        return ordered.filter {
            $0.title.lowercased().contains(search)
                || ($0.framework ?? "").lowercased().contains(search)
                || $0.ownerHandle.lowercased().contains(search)
                || $0.id.lowercased().contains(search)
        }
    }

    private func reload() async {
        guard let client = app.liveShortly.client else {
            loading = false
            return
        }
        do {
            // The full history, not the sidebar's window.
            sessions = try await client.sessions(limit: 200)
            errorText = nil
        } catch {
            errorText = "Couldn't load sessions: \(error.localizedDescription)"
        }
        loading = false
    }
}
