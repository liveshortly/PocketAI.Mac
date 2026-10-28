import PocketKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// Sidebar: chats, projects, LiveShortly sessions, then the tool surfaces.
/// One list, HUD section labels, hairline separation — no nested disclosure
/// triangles, because every section here is worth seeing at once.
struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var conversations: [ConversationSummary] = []
    @State private var projects: [Project] = []
    @State private var sessions: [LSSession] = []
    @State private var renaming: ConversationSummary?
    @State private var confirmDelete: ConversationSummary?
    @State private var newProject = false
    @State private var lastSessionLoad: Date?

    /// The sidebar shows only the newest few of each kind; the rest live
    /// in the full lists (and ⌘K reaches any of them directly).
    private static let recentLimit = 5

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            chatsSection
            if !projects.isEmpty || app.selection.isProject {
                projectsSection
            }
            liveShortlySection
            toolsSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgSurface)
        .searchable(text: $app.sidebarSearch, placement: .sidebar, prompt: "Search chats")
        .onChange(of: app.sidebarSearch) { _, _ in reloadConversations() }
        .safeAreaInset(edge: .bottom) { footer }
        .task { reloadAll() }
        .onChange(of: app.selection) { _, _ in reloadConversations() }
        .onChange(of: app.liveShortly.isConnected) { _, connected in
            // Connecting from Settings should fill this section straight away,
            // not on the next launch.
            guard connected else {
                sessions = []
                return
            }
            lastSessionLoad = nil
            reloadSessions()
        }
        .onChange(of: app.pendingCommand) { _, command in
            if command == .newLiveSession {
                app.selection = .newSession
                app.pendingCommand = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .pocketConversationsChanged)
        ) { _ in reloadConversations() }
        .sheet(item: $renaming) { summary in
            RenameSheet(title: summary.title ?? "") { newTitle in
                try? app.core.renameConversation(id: summary.id, title: newTitle)
                reloadConversations()
            }
        }
        .sheet(isPresented: $newProject) {
            NewProjectSheet { name, instructions in
                if let project = try? app.core.createProject(
                    name: name, instructions: instructions) {
                    reloadProjects()
                    app.selection = .project(project.id)
                }
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
                if app.selection == .chat(target.id) { app.selection = nil }
                reloadConversations()
            }
        }
    }

    // MARK: - Sections

    private var chatsSection: some View {
        Section {
            NewChatMenu()

            ForEach(conversations.prefix(Self.recentLimit), id: \.id) { summary in
                ChatRow(summary: summary)
                    .tag(AppModel.Destination.chat(summary.id))
                    .contextMenu {
                        Button("Rename…") { renaming = summary }
                        Button("Archive") {
                            try? app.core.archiveConversation(id: summary.id, archived: true)
                            reloadConversations()
                        }
                        Divider()
                        Button("Delete", role: .destructive) { confirmDelete = summary }
                    }
            }
            if conversations.isEmpty {
                Text(app.sidebarSearch.isEmpty ? "No chats yet" : "No matches")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            if conversations.count > Self.recentLimit {
                Label(
                    "All chats (\(conversations.count))",
                    systemImage: "list.bullet")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .tag(AppModel.Destination.allChats)
            }
        } header: {
            HUDLabel("Chats")
        }
    }

    private var projectsSection: some View {
        Section {
            ForEach(projects, id: \.id) { project in
                Label(project.name, systemImage: "folder")
                    .tag(AppModel.Destination.project(project.id))
            }
            Button {
                newProject = true
            } label: {
                Label("New project", systemImage: "plus")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .buttonStyle(.plain)
        } header: {
            HUDLabel("Projects")
        }
    }

    /// Always present, the way the Chats tab shows it on the phone. When the
    /// Mac has not been connected yet it says so and offers the way in —
    /// otherwise the integration is invisible here and looks missing.
    private var liveShortlySection: some View {
        Section {
            if app.liveShortly.isConnected {
                ForEach(orderedSessions.prefix(Self.recentLimit), id: \.id) { session in
                    SessionRow(session: session)
                        .tag(AppModel.Destination.session(session.id))
                }
                if sessions.count > Self.recentLimit {
                    Label(
                        "All sessions (\(sessions.count))",
                        systemImage: "list.bullet")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                        .tag(AppModel.Destination.allSessions)
                }
                if sessions.isEmpty {
                    Text("No sessions yet")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                Label("New session", systemImage: "plus")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .tag(AppModel.Destination.newSession)
            } else {
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text("Not connected on this Mac")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                    SettingsLink {
                        Label("Connect LiveShortly…", systemImage: "link")
                            .font(.pocket(.footnote))
                            .foregroundStyle(LSColor.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                HUDLabel("LiveShortly")
                Spacer()
                if sessions.contains(where: \.isLive) { HUDLiveBadge() }
            }
        }
    }

    private var toolsSection: some View {
        Section {
            Label("Models", systemImage: "cpu").tag(AppModel.Destination.models)
            Label("Images", systemImage: "photo").tag(AppModel.Destination.images)
            Label("Devices", systemImage: "iphone").tag(AppModel.Destination.devices)
            Label("Local server", systemImage: "server.rack").tag(AppModel.Destination.server)
            Label("Privacy", systemImage: "hand.raised").tag(AppModel.Destination.privacy)
        } header: {
            HUDLabel("Tools")
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HUDRule()
            HStack(spacing: PocketSpacing.s8) {
                HUDDot(
                    tint: app.serverStatus.running
                        ? PocketColor.statusOk : PocketColor.textTertiary,
                    pulsing: app.serverStatus.running)
                Text(app.currentModelDisplayName)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, PocketSpacing.s8)
        }
        .background(PocketColor.bgSurface)
    }

    // MARK: - Data

    private var orderedSessions: [LSSession] {
        sessions.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            return $0.createdAt > $1.createdAt
        }
    }

    private func reloadAll() {
        reloadConversations()
        reloadProjects()
        reloadSessions()
    }

    private func reloadConversations() {
        let search = app.sidebarSearch.trimmingCharacters(in: .whitespaces)
        conversations = app.core.conversations(
            query: ConversationQuery(
                search: search.isEmpty ? nil : search,
                archived: false,
                limit: 60,
                offset: 0))
    }

    private func reloadProjects() {
        projects = app.core.listProjects()
    }

    private func reloadSessions() {
        guard let client = app.liveShortly.client else { return }
        // 15s staleness guard: the sidebar reloads on every selection change.
        if let last = lastSessionLoad, Date().timeIntervalSince(last) < 15 { return }
        lastSessionLoad = Date()
        Task {
            sessions = (try? await client.sessions(limit: 30)) ?? []
        }
    }
}

/// One chat row: title plus the last thing that happened in it.
struct ChatRow: View {
    @Environment(AppModel.self) private var app
    let summary: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summary.title?.isEmpty == false ? summary.title! : "Untitled chat")
                .font(.pocket(.body))
                .lineLimit(1)
            Text(hudRelative(summary.updatedAt))
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
        .padding(.vertical, 1)
    }
}

/// One LiveShortly session row, live ones badged.
struct SessionRow: View {
    let session: LSSession

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title.isEmpty ? "Untitled session" : session.title)
                    .font(.pocket(.body))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.isLive { HUDDot(pulsing: true) }
        }
        .padding(.vertical, 1)
    }

    private var subtitle: String {
        if let last = session.lastEvent, !last.snippet.isEmpty {
            return (last.type == "response" ? "◆ " : "› ") + last.snippet
        }
        var bits: [String] = []
        if let framework = session.framework, !framework.isEmpty { bits.append(framework) }
        bits.append("\(session.eventCount) events")
        return bits.joined(separator: " · ")
    }
}

extension AppModel.Destination? {
    var isProject: Bool {
        if case .project = self { return true }
        return false
    }
}

extension Notification.Name {
    /// Posted when a conversation is created, renamed or deleted so the
    /// sidebar refreshes without polling.
    static let pocketConversationsChanged = Notification.Name("pocket.conversationsChanged")
}

extension ConversationSummary: @retroactive Identifiable {}
