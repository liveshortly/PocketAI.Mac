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
                    .tint(PocketColor.accent)
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
                                try? app.core.archiveConversation(
                                    id: chat.id, archived: !chat.archived)
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
                for id in selected {
                    app.forgetChatModel(id)
                    try? app.core.deleteConversation(id: id)
                }
                if case .chat(let open) = app.selection, selected.contains(open) {
                    app.selection = nil
                }
                selected = []
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
                app.forgetChatModel(target.id)
                try? app.core.deleteConversation(id: target.id)
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
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.id) { session in
                        Button {
                            app.selection = .session(session.id)
                        } label: {
                            HStack(spacing: PocketSpacing.s12) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(
                                        session.isLive
                                            ? LSColor.accent : PocketColor.textTertiary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.title.isEmpty
                                        ? "Untitled session" : session.title)
                                        .font(.pocket(.body))
                                    Text(subtitle(session))
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if session.isLive { HUDLiveBadge() }
                            }
                            .padding(.horizontal, PocketSpacing.s12)
                            .padding(.vertical, PocketSpacing.s8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Open \(session.title.isEmpty ? "Untitled session" : session.title)"
                            + ", \(session.isLive ? "live" : "ended"), \(subtitle(session))")
                        HUDRule()
                    }
                    if loading {
                        ProgressView().padding(PocketSpacing.s16)
                    } else if filtered.isEmpty {
                        Text(query.isEmpty
                            ? "No sessions yet" : "No sessions match “\(query)”")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textTertiary)
                            .padding(PocketSpacing.s16)
                    }
                    if let errorText {
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
        .task { await reload() }
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

    private func subtitle(_ session: LSSession) -> String {
        if let last = session.lastEvent, !last.snippet.isEmpty {
            return (last.type == "response" ? "◆ " : "› ") + last.snippet
        }
        var bits: [String] = []
        if let framework = session.framework, !framework.isEmpty { bits.append(framework) }
        bits.append("\(session.eventCount) events")
        if !session.isLive, let ended = session.endedAt {
            bits.append("ended \(ended.formatted(.relative(presentation: .named)))")
        }
        return bits.joined(separator: " · ")
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
