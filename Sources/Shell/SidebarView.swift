import AppKit
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var renaming: ConversationSummary?
    @State private var confirmDelete: ConversationSummary?
    @State private var newProject = false
    @State private var pendingEndSession: LSSession?
    @State private var pendingDeleteSession: LSSession?
    /// Why the last session action didn't take. Ending and deleting both
    /// dropped their error, and delete removed the row even when the server
    /// had refused — so the list told a story the server disagreed with.
    @State private var sessionActionError: String?

    /// The sidebar shows only the newest few of each kind; the rest live
    /// in the full lists (and ⌘K reaches any of them directly).
    private static let recentLimit = 5

    /// The account's shared, self-polling session list (LSI-17). Was a local
    /// copy fetched once behind a 15 s guard, so new sessions never showed.
    private var feed: LSSessionFeed { app.liveShortly.feed }
    private var sessions: [LSSession] { feed.sessions }

    var body: some View {
        @Bindable var app = app
        // No `selection:` binding: the system selection capsule follows the
        // macOS accent (blue for most people) and greys the label, so rows
        // draw their own green accent selection instead (MAC-22, UI-38).
        List {
            chatsSection
            if !projects.isEmpty || app.selection.isProject {
                projectsSection
            }
            liveShortlySection
            if app.liveShortly.isConnected, !feed.shared.isEmpty {
                sharedSection
            }
            toolsSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgSurface)
        .searchable(text: $app.sidebarSearch, placement: .sidebar, prompt: "Search chats")
        .onChange(of: app.sidebarSearch) { _, _ in reloadConversations() }
        .safeAreaInset(edge: .bottom) { footer }
        .task { reloadAll() }
        .task { await feed.run() }
        .onChange(of: scenePhase, initial: true) { _, phase in feed.phase = phase }
        .onChange(of: app.selection) { _, _ in reloadConversations() }
        .onChange(of: app.liveShortly.isConnected) { _, connected in
            // Connecting from Settings should fill this section straight away,
            // not on the next launch.
            if connected { Task { await feed.reload() } }
        }
        .onChange(of: app.commandSerial) { _, _ in
            switch app.pendingCommand {
            case .newLiveSession:
                // ⇧⌘N also fires from Settings; the form needs the focus.
                app.reveal(.newSession())
                app.clearCommand()
            case .refresh:
                // Re-fetch both lists; a session or chat can land after load.
                reloadAll()
            default:
                break
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
            "End “\(pendingEndSession?.title ?? "session")”? The agent stops where it is.",
            isPresented: Binding(
                get: { pendingEndSession != nil },
                set: { if !$0 { pendingEndSession = nil } }),
            titleVisibility: .visible
        ) {
            Button("End session", role: .destructive) {
                guard let target = pendingEndSession, let client = app.liveShortly.client
                else { return }
                Task {
                    do {
                        try await client.stop(target.id)
                        sessionActionError = nil
                    } catch {
                        sessionActionError =
                            "Couldn't end that session: \(error.localizedDescription)"
                    }
                    await feed.reload()
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeleteSession?.title ?? "session")”? This cannot be undone.",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { if !$0 { pendingDeleteSession = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete session", role: .destructive) {
                guard let target = pendingDeleteSession, let client = app.liveShortly.client
                else { return }
                Task {
                    do {
                        try await client.deleteSession(target.id)
                        sessionActionError = nil
                        if app.selection == .session(target.id) { app.selection = nil }
                        feed.remove(target.id)
                    } catch {
                        sessionActionError =
                            "Couldn't delete that session: \(error.localizedDescription)"
                    }
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
                do {
                    try app.core.deleteConversation(id: target.id)
                    app.forgetChatModel(target.id)
                    if app.selection == .chat(target.id) { app.selection = nil }
                } catch {
                    // Leave it selected: it is still there.
                    app.toast("Couldn't delete that chat: \(error.localizedDescription)")
                }
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
                    .sidebarRow(.chat(summary.id))
                    .contextMenu {
                        Button("Rename…") { renaming = summary }
                        Button("Archive") {
                            do {
                                try app.core.archiveConversation(id: summary.id, archived: true)
                            } catch {
                                app.toast(
                                    "Couldn't archive that chat: \(error.localizedDescription)")
                            }
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
                    .sidebarRow(.allChats, muted: true)
            }
        } header: {
            HUDLabel("Chats")
        }
    }

    private var projectsSection: some View {
        Section {
            ForEach(projects, id: \.id) { project in
                Label(project.name, systemImage: "folder")
                    .sidebarRow(.project(project.id))
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
                ForEach(visibleSessions, id: \.id) { session in
                    SessionRow(session: session)
                        .sidebarRow(.session(session.id))
                        .contextMenu {
                            Button("Open") { app.selection = .session(session.id) }
                            if let link = app.liveShortly.client?.sessionLink(session.id) {
                                Button("Copy link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        link.absoluteString, forType: .string)
                                }
                            }
                            Divider()
                            if session.isLive {
                                Button("End session", role: .destructive) {
                                    pendingEndSession = session
                                }
                            }
                            Button("Delete session", role: .destructive) {
                                pendingDeleteSession = session
                            }
                        }
                }
                if sessions.count > Self.recentLimit {
                    Label(
                        "All sessions (\(sessions.count))",
                        systemImage: "list.bullet")
                        .font(.pocket(.footnote))
                        .sidebarRow(.allSessions, muted: true)
                }
                if sessions.isEmpty {
                    Text(feed.loadError.map { "Couldn't load sessions: \($0)" }
                        ?? (feed.loaded ? "No sessions yet" : "Loading…"))
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                Label("New session", systemImage: "plus")
                    .font(.pocket(.footnote))
                    .sidebarRow(.newSession(), muted: true)
                if let error = feed.loadError, !sessions.isEmpty {
                    Text("Couldn't refresh: \(error)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                        .lineLimit(2)
                }
                if let sessionActionError {
                    Text(sessionActionError)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text("Not connected on this Mac")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                    SettingsLink {
                        Label("Connect LiveShortly…", systemImage: "link")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.accent)
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

    /// LSI-19: sessions other people shared with me, from the same feed poll.
    /// No end/delete here — those are the owner's.
    private var sharedSection: some View {
        Section {
            ForEach(feed.orderedShared, id: \.id) { session in
                SessionRow(session: session)
                    .sidebarRow(.session(session.id))
                    .contextMenu {
                        Button("Open") { app.selection = .session(session.id) }
                        if let link = app.liveShortly.client?.sessionLink(session.id) {
                            Button("Copy link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    link.absoluteString, forType: .string)
                            }
                        }
                    }
            }
        } header: {
            HStack {
                HUDLabel("Shared with me")
                Spacer()
                if feed.newSharedCount > 0 {
                    HUDLabel("\(feed.newSharedCount) new", tint: PocketColor.accent)
                }
            }
        }
    }

    private var toolsSection: some View {
        Section {
            Label("Models", systemImage: "cpu").sidebarRow(.models)
            Label("Images", systemImage: "photo").sidebarRow(.images)
            Label("Devices", systemImage: "iphone").sidebarRow(.devices)
            Label("Local server", systemImage: "server.rack").sidebarRow(.server)
            Label {
                Text("LiveShortly")
            } icon: {
                LSSessionMark(isLive: LSDaemonController.shared.isRunning, size: 16)
            }
            .sidebarRow(.liveShortly)
            Label("Privacy", systemImage: "hand.raised").sidebarRow(.privacy)
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
                // The dot carries the server state visually and is hidden from
                // VoiceOver, so this line has to say it.
                Text(app.currentModelDisplayName)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                    .lineLimit(1)
                    .accessibilityLabel(
                        "Current model \(app.currentModelDisplayName), local server "
                        + (app.serverStatus.running ? "running" : "stopped"))
                Spacer(minLength: 0)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, PocketSpacing.s8)
        }
        .background(PocketColor.bgSurface)
    }

    // MARK: - Data

    /// The newest few, live first — plus the open session pinned on top when
    /// it would otherwise fall below the cut, so it stays highlighted.
    private var visibleSessions: [LSSession] {
        let ordered = feed.ordered
        let top = ordered.prefix(Self.recentLimit)
        guard case .session(let id)? = app.selection, !top.contains(where: { $0.id == id }),
              let open = ordered.first(where: { $0.id == id })
        else { return Array(top) }
        return [open] + ordered.prefix(Self.recentLimit - 1)
    }

    private func reloadAll() {
        reloadConversations()
        reloadProjects()
        Task { await feed.reload() }
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
        // Title and timestamp as one row, not two unrelated strings.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(summary.title?.isEmpty == false ? summary.title! : "Untitled chat"), "
            + hudRelative(summary.updatedAt))
    }
}

/// One LiveShortly session row, live ones badged.
struct SessionRow: View {
    let session: LSSession

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            LSSessionMark(session: session, size: 22)
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
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.accentOnAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(PocketColor.accent))
                    .accessibilityLabel("\(unread) new events")
            }
            if session.isLive { HUDDot(pulsing: true) }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowLabel)
    }

    /// The whole row in one sentence — the live dot and the unread capsule are
    /// otherwise either silent or read out of order.
    private var rowLabel: String {
        var parts = [session.title.isEmpty ? "Untitled session" : session.title]
        parts.append(session.isStarting ? "starting" : session.isLive ? "live" : "ended")
        if unread > 0 { parts.append("\(unread) new events") }
        parts.append(subtitle)
        return parts.joined(separator: ", ")
    }

    /// Events since this session was last opened here. Sessions never opened
    /// on this Mac stay quiet rather than all shouting at once.
    private var unread: Int {
        let seen = LSSeen.count(session.id)
        guard seen > 0 else { return 0 }
        return max(0, session.eventCount - seen)
    }

    private var subtitle: String {
        if session.isStarting { return "Starting…" }
        if let shared = session.sharedLine { return shared }
        if let last = session.lastEvent, !last.snippet.isEmpty {
            return (last.type == "response" ? "◆ " : "› ") + last.snippet
        }
        var bits: [String] = []
        if let framework = session.framework, !framework.isEmpty { bits.append(framework) }
        bits.append("\(session.eventCount) events")
        return bits.joined(separator: " · ")
    }
}

/// A sidebar row that selects `destination` and draws its own selection: an
/// `accent.soft` rounded fill, label in `text.primary`, icon in `accent`. The
/// macOS accent setting never shows here.
private struct SidebarRow: ViewModifier {
    @Environment(AppModel.self) private var app
    let destination: AppModel.Destination
    /// Secondary rows ("All chats", "New session") read tertiary until selected.
    let muted: Bool

    func body(content: Content) -> some View {
        let selected = app.selection == destination
        return Button {
            app.selection = destination
        } label: {
            content
                .labelStyle(SidebarLabelStyle(selected: selected, muted: muted))
                .foregroundStyle(
                    muted && !selected ? PocketColor.textTertiary : PocketColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                        .fill(selected ? PocketColor.accentSoft : Color.clear))
                // Keep text aligned with the section headers; the fill bleeds
                // into the row inset instead.
                .padding(.horizontal, -6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One icon style for every sidebar row: outline symbols at regular weight in
/// the same 16 pt box, `accent` when the row is selected.
private struct SidebarLabelStyle: LabelStyle {
    let selected: Bool
    let muted: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: PocketSpacing.s8) {
            configuration.icon
                .font(.system(size: 13, weight: .regular))
                .symbolVariant(.none)
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 16)
            configuration.title
        }
    }

    private var iconColor: Color {
        if selected { return PocketColor.accent }
        return muted ? PocketColor.textTertiary : PocketColor.textSecondary
    }
}

private extension View {
    func sidebarRow(_ destination: AppModel.Destination, muted: Bool = false) -> some View {
        modifier(SidebarRow(destination: destination, muted: muted))
    }
}

extension AppModel.Destination? {
    var isProject: Bool {
        if case .project = self { return true }
        return false
    }

    /// True only for a local conversation — the one destination where
    /// regenerating a reply means anything.
    var isChat: Bool {
        if case .chat = self { return true }
        return false
    }
}

extension Notification.Name {
    /// Posted when a conversation is created, renamed or deleted so the
    /// sidebar refreshes without polling.
    static let pocketConversationsChanged = Notification.Name("pocket.conversationsChanged")
}

extension ConversationSummary: @retroactive Identifiable {}
