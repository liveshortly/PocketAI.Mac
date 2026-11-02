import PocketKit
import PocketLiveShortly
import PocketUI
import SwiftUI
import UniformTypeIdentifiers

/// A project: its instructions, the documents its chats can draw on, and the
/// chats that belong to it.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var app
    let projectId: String

    @State private var project: Project?
    @State private var documents: [PocketKit.Document] = []
    @State private var chats: [ConversationSummary] = []
    @State private var instructions = ""
    @State private var instructionsDirty = false
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var importError: String?
    /// Kept apart from `importError` so it cannot surface under Documents.
    @State private var instructionsNote: String?
    @State private var linkedSessions: [LSSession] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            HUDRule()
            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    instructionsCard
                    documentsCard
                    chatsCard
                    sessionsCard
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task(id: projectId) { reload() }
        .onChange(of: app.commandSerial) { _, _ in
            if app.pendingCommand == .refresh { reload() }
        }
        .sheet(isPresented: $showRename) {
            RenameSheet(title: project?.name ?? "") { newName in
                try? app.core.renameProject(id: projectId, name: newName)
                reload()
            }
        }
        .confirmationDialog(
            "Delete “\(project?.name ?? "project")”? Its documents are removed; its chats are kept.",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete project", role: .destructive) {
                // Same teardown trap as the chat deletes: clearing the
                // selection first meant a refused delete looked like a
                // successful one.
                do {
                    try app.core.deleteProject(id: projectId)
                    app.selection = nil
                } catch {
                    app.toast("Couldn't delete that project: \(error.localizedDescription)")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "folder")
                .foregroundStyle(PocketColor.accent)
                .accessibilityHidden(true)
            Text(project?.name ?? "Project")
                .font(.pocket(.headline))
            Spacer(minLength: 0)
            if app.liveShortly.isConnected {
                Button("New agent session") {
                    app.selection = .newSession(projectId: projectId)
                }
                .buttonStyle(.hud)
            }
            Button("New chat here") {
                app.newChat(projectId: projectId)
                NotificationCenter.default.post(name: .pocketConversationsChanged, object: nil)
            }
            .buttonStyle(.hudProminent)
            Menu {
                Button("Rename…") { showRename = true }
                Button("Delete project…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Project actions")
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack {
                HUDLabel("Instructions")
                Spacer()
                if instructionsDirty {
                    Button("Save") { saveInstructions() }
                        .buttonStyle(.hud)
                }
            }
            TextEditor(text: $instructions)
                .font(.pocket(.body))
                .scrollContentBackground(.hidden)
                .frame(height: 110)
                .padding(PocketSpacing.s8)
                .hudPanel(PocketColor.bgCanvas)
                .onChange(of: instructions) { _, value in
                    // Seeding from the stored project is not an edit.
                    instructionsDirty = value != (project?.instructions ?? "")
                }
            Text("Every chat in this project starts with these instructions.")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
            if let instructionsNote {
                Text(instructionsNote)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var documentsCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack {
                HUDLabel("Documents · \(documents.count)")
                Spacer()
                Button("Add files…") { addDocuments() }
                    .buttonStyle(.hud)
            }
            if documents.isEmpty {
                Text("No documents yet. Add PDFs or text files and this project's chats can cite them.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .padding(PocketSpacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPanel()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, doc in
                        if index > 0 { HUDRule() }
                        HStack(spacing: PocketSpacing.s8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(PocketColor.textTertiary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.name)
                                    .font(.pocket(.body))
                                    .lineLimit(1)
                                Text("\(hudBytes(doc.bytes)) · \(doc.textChars) chars · \(doc.state)")
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textTertiary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                // A refused delete left the row in place with
                                // nothing said; the reason goes under the list.
                                do {
                                    try app.core.deleteDocument(id: doc.id)
                                    importError = nil
                                } catch {
                                    importError = "Couldn't remove \(doc.name): "
                                        + error.localizedDescription
                                }
                                reload()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(PocketColor.textTertiary)
                            .accessibilityLabel("Remove \(doc.name) from this project")
                        }
                        .padding(PocketSpacing.s8)
                    }
                }
                .hudPanel()
            }
            if let importError {
                Text(importError)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
            }
        }
    }

    private var chatsCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Chats in this project · \(chats.count)")
            if chats.isEmpty {
                Text("No chats yet — start one and it stays scoped to this project.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .padding(PocketSpacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPanel()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                        if index > 0 { HUDRule() }
                        Button {
                            app.selection = .chat(chat.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chat.title?.isEmpty == false ? chat.title! : "Untitled chat")
                                        .font(.pocket(.body))
                                    Text(hudRelative(chat.updatedAt))
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textTertiary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(PocketColor.textTertiary)
                                    .font(.pocket(.caption))
                                    .accessibilityHidden(true)
                            }
                            .padding(PocketSpacing.s8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Open \(chat.title?.isEmpty == false ? chat.title! : "Untitled chat")"
                            + ", \(hudRelative(chat.updatedAt))")
                    }
                }
                .hudPanel()
            }
        }
    }

    /// LiveShortly sessions filed under this project. The link is local to
    /// this Mac — the server does not know about projects.
    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("LiveShortly sessions · \(linkedSessions.count)")
            if !app.liveShortly.isConnected {
                Text("Connect LiveShortly in Settings to run agent sessions for this project.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .padding(PocketSpacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPanel()
            } else if linkedSessions.isEmpty {
                Text("No sessions yet — start one and it stays filed under this project.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .padding(PocketSpacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPanel()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(linkedSessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { HUDRule() }
                        Button {
                            app.selection = .session(session.id)
                        } label: {
                            HStack(spacing: PocketSpacing.s8) {
                                LSSessionMark(isLive: session.isLive, size: 22)
                                    .accessibilityHidden(true)
                                Text(session.title.isEmpty ? "Untitled session" : session.title)
                                    .font(.pocket(.body))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if session.isLive { HUDLiveBadge() }
                            }
                            .padding(PocketSpacing.s8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Open \(session.title.isEmpty ? "Untitled session" : session.title)"
                            + ", \(session.isLive ? "live" : "ended")")
                        .contextMenu {
                            Button("Remove from project") {
                                ProjectSessions.unlink(session.id, from: projectId)
                                reloadSessions()
                            }
                        }
                    }
                }
                .hudPanel()
            }
        }
    }

    // MARK: - Data

    private func reload() {
        project = app.core.listProjects().first { $0.id == projectId }
        instructions = project?.instructions ?? ""
        instructionsDirty = false
        instructionsNote = nil
        documents = app.core.listDocuments(projectId: projectId)
        reloadSessions()
        chats = app.core.conversations(
            query: ConversationQuery(search: nil, archived: false, limit: 100, offset: 0)
        ).filter { summary in
            app.core.conversation(id: summary.id)?.projectId == projectId
        }
    }

    /// Resolves the linked ids to live session records, dropping any the
    /// server no longer has (deleted elsewhere).
    private func reloadSessions() {
        let ids = Set(ProjectSessions.ids(for: projectId))
        guard !ids.isEmpty, let client = app.liveShortly.client else {
            linkedSessions = []
            return
        }
        Task {
            let all = (try? await client.sessions(limit: 200)) ?? []
            linkedSessions = all.filter { ids.contains($0.id) }
                .sorted { $0.isLive && !$1.isLive }
        }
    }

    /// The core exposes `renameProject` but no update for instructions, so an
    /// edit lives in this window only — same limitation the iPhone app has.
    /// Said plainly rather than shown as a save that silently does nothing.
    private func saveInstructions() {
        guard let id = project?.id else { return }
        do {
            try app.core.setProjectInstructions(id: id, instructions: instructions)
            reload()
            instructionsDirty = false
            instructionsNote = nil
        } catch {
            // Stays dirty: the text on screen is not what the store holds,
            // and the whole point of these instructions is that the model
            // actually receives them.
            instructionsNote = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func addDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .plainText, .text, .sourceCode, .json]
        guard panel.runModal() == .OK else { return }
        importError = nil
        let urls = panel.urls
        Task {
            for url in urls {
                do {
                    // Extraction reads and parses whole files — off the main
                    // actor so a large PDF never stalls the window.
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"
                    let name = url.lastPathComponent
                    let core = app.core
                    let id = projectId
                    _ = try await Task.detached {
                        let extracted = try DocumentTextExtractor.extract(fileURL: url)
                        let pages = extracted.map {
                            DocumentPage(page: UInt32(max(0, $0.page)), text: $0.text)
                        }
                        return try core.addDocument(
                            projectId: id, name: name, mime: mime, pages: pages)
                    }.value
                } catch {
                    importError =
                        "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            reload()
        }
    }
}
