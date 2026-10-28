import PocketKit
import PocketUI
import SwiftUI
import UniformTypeIdentifiers

/// A project: its instructions, the documents its chats can draw on, and the
/// chats that belong to it.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var app
    let projectId: String

    @State private var project: Project?
    @State private var documents: [Document] = []
    @State private var chats: [ConversationSummary] = []
    @State private var instructions = ""
    @State private var instructionsDirty = false
    @State private var showRename = false
    @State private var confirmDelete = false
    @State private var importError: String?
    /// Kept apart from `importError` so it cannot surface under Documents.
    @State private var instructionsNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            HUDRule()
            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    instructionsCard
                    documentsCard
                    chatsCard
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task(id: projectId) { reload() }
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
                try? app.core.deleteProject(id: projectId)
                app.selection = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "folder")
                .foregroundStyle(PocketColor.accent)
            Text(project?.name ?? "Project")
                .font(.pocket(.headline))
            Spacer(minLength: 0)
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
                                try? app.core.deleteDocument(id: doc.id)
                                reload()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(PocketColor.textTertiary)
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
                            }
                            .padding(PocketSpacing.s8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
        chats = app.core.conversations(
            query: ConversationQuery(search: nil, archived: false, limit: 100, offset: 0)
        ).filter { summary in
            app.core.conversation(id: summary.id)?.projectId == projectId
        }
    }

    /// The core exposes `renameProject` but no update for instructions, so an
    /// edit lives in this window only — same limitation the iPhone app has.
    /// Said plainly rather than shown as a save that silently does nothing.
    private func saveInstructions() {
        if var updated = project {
            let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.instructions = trimmed.isEmpty ? nil : trimmed
            project = updated
        }
        instructionsDirty = false
        instructionsNote = """
            Kept for this window only — the core has no call to store project \
            instructions yet, so this does not survive a relaunch.
            """
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
