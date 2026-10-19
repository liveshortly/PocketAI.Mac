import SwiftUI
import UniformTypeIdentifiers
import PocketKit
import PocketUI

/// MAC-12: Projects layout for Mac (UI-16 components).
/// Split layout with projects list on the left and project details + documents table on the right.
/// Drag-and-drop document import, rich document badges, and seamless chat in project.
public struct MacProjectsView: View {
    @Environment(AppModel.self) private var model

    @State private var projects: [Project] = []
    @State private var selectedProjectId: String?
    @State private var isShowingNewProject = false
    @State private var newProjectName = ""
    @State private var newProjectInstructions = ""

    public init() {}

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId }
    }

    public var body: some View {
        HSplitView {
            // Left: Projects List
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Projects")
                        .font(.pocket(.title))
                        .fontWeight(.semibold)

                    Spacer()

                    Button {
                        isShowingNewProject = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PocketColor.accent)
                            .padding(6)
                            .background(PocketColor.accentSoft)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("New Project (⇧⌘P)")
                }
                .padding(.horizontal, PocketSpacing.s12)
                .padding(.top, PocketSpacing.s12)
                .padding(.bottom, PocketSpacing.s8)

                Divider()

                if projects.isEmpty {
                    VStack(spacing: PocketSpacing.s12) {
                        Spacer()
                        Image(systemName: "folder")
                            .font(.system(size: 32))
                            .foregroundStyle(PocketColor.textTertiary)
                        Text("No projects yet")
                            .font(.pocket(.body))
                            .foregroundStyle(PocketColor.textSecondary)
                        Button("Create Project") { isShowingNewProject = true }
                            .buttonStyle(.borderedProminent)
                            .tint(PocketColor.accent)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(projects, id: \.id, selection: $selectedProjectId) { project in
                        projectRow(project)
                            .tag(project.id)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
            .background(PocketColor.bgCanvas)

            // Right: Project Detail
            if let selectedProject {
                MacProjectDetailView(project: selectedProject, onReload: { reload() })
                    .id(selectedProject.id)
            } else {
                VStack(spacing: PocketSpacing.s16) {
                    PocketMarkView(state: .idle, size: 48)
                    Text("Select or create a project")
                        .font(.pocket(.title))
                        .fontWeight(.semibold)
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("Organize custom system instructions and grounding documents.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)

                    Button("Create Project") { isShowingNewProject = true }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketColor.accent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PocketColor.bgSurface)
            }
        }
        .task { reload() }
        .sheet(isPresented: $isShowingNewProject) {
            newProjectSheet
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(PocketColor.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                    .lineLimit(1)

                if let inst = project.instructions, !inst.isEmpty {
                    Text(inst)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, PocketSpacing.s4)
        .contextMenu {
            Button("Delete Project", role: .destructive) {
                deleteProject(id: project.id)
            }
        }
    }

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s16) {
            Text("New Project")
                .font(.pocket(.title))
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                Text("Project Name")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)

                TextField("e.g. iOS Architecture, Legal Brief", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                Text("Custom Instructions (optional)")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)

                TextEditor(text: $newProjectInstructions)
                    .font(.pocket(.body))
                    .frame(height: 110)
                    .padding(PocketSpacing.s4)
                    .background(PocketColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                    )
            }

            HStack {
                Button("Cancel") {
                    isShowingNewProject = false
                    newProjectName = ""
                    newProjectInstructions = ""
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Create Project") {
                    let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let inst = newProjectInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let proj = try? model.core.createProject(name: trimmed, instructions: inst.isEmpty ? nil : inst) {
                        reload()
                        selectedProjectId = proj.id
                    }
                    isShowingNewProject = false
                    newProjectName = ""
                    newProjectInstructions = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
                .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, PocketSpacing.s8)
        }
        .padding(PocketSpacing.s24)
        .frame(width: 460)
        .background(PocketColor.bgCanvas)
    }

    private func reload() {
        projects = model.core.listProjects()
        if selectedProjectId == nil, let first = projects.first {
            selectedProjectId = first.id
        }
    }

    private func deleteProject(id: String) {
        try? model.core.deleteProject(id: id)
        if selectedProjectId == id {
            selectedProjectId = nil
        }
        reload()
    }
}

private struct MacProjectDetailView: View {
    let project: Project
    let onReload: () -> Void
    @Environment(AppModel.self) private var model

    @State private var documents: [Document] = []
    @State private var isImporting = false
    @State private var importError: String?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                        Text(project.name)
                            .font(.pocket(.title))
                            .fontWeight(.bold)
                            .foregroundStyle(PocketColor.textPrimary)

                        if let instructions = project.instructions, !instructions.isEmpty {
                            Text(instructions)
                                .font(.pocket(.callout))
                                .foregroundStyle(PocketColor.textSecondary)
                        } else {
                            Text("No custom instructions specified.")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                    }

                    Spacer()

                    Button {
                        startChatInProject()
                    } label: {
                        Label("New Chat in Project", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.pocketPrimary)
                    .controlSize(.large)
                }
            }
            .padding(PocketSpacing.s20)
            .background(PocketColor.bgRaised)

            Divider()

            // Documents Table Header Bar
            HStack {
                HStack(spacing: PocketSpacing.s8) {
                    Text("DOCUMENTS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PocketColor.textTertiary)

                    Text("(\(documents.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PocketColor.accent)
                }

                Spacer()

                Button {
                    importDocument()
                } label: {
                    Label("Add Document…", systemImage: "plus")
                        .font(.pocket(.footnote))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isImporting)
            }
            .padding(.horizontal, PocketSpacing.s20)
            .padding(.vertical, PocketSpacing.s12)
            .background(PocketColor.bgCanvas)

            if let importError {
                HStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PocketColor.statusBad)
                    Text(importError)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                }
                .padding(.horizontal, PocketSpacing.s20)
                .padding(.vertical, PocketSpacing.s4)
            }

            Divider()

            // Documents Table or Empty State
            if documents.isEmpty {
                emptyDocumentsDropZone
            } else {
                documentsTable
            }
        }
        .background(PocketColor.bgSurface)
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedFiles(urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .task { reloadDocs() }
    }

    private var emptyDocumentsDropZone: some View {
        VStack(spacing: PocketSpacing.s16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(isTargeted ? PocketColor.accentSoft : PocketColor.bgSunken)
                    .frame(width: 72, height: 72)

                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(isTargeted ? PocketColor.accent : PocketColor.textTertiary)
            }

            VStack(spacing: PocketSpacing.s4) {
                Text(isTargeted ? "Drop Files to Ground Project" : "No documents grounded yet")
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)

                Text("Drag and drop PDFs, Markdown, text files, or source code here to index them locally.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                importDocument()
            } label: {
                Label("Choose Documents…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketColor.accent)
            .padding(.top, PocketSpacing.s4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isTargeted ? PocketColor.accent : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                .padding(PocketSpacing.s16)
        )
    }

    private var documentsTable: some View {
        Table(documents) {
            TableColumn("Document Name") { doc in
                HStack(spacing: PocketSpacing.s8) {
                    Image(systemName: docIcon(for: doc.mime))
                        .foregroundStyle(docIconColor(for: doc.mime))
                        .font(.system(size: 15))

                    Text(doc.name)
                        .font(.pocket(.body))
                        .fontWeight(.medium)
                }
            }
            TableColumn("Size") { doc in
                Text(ByteCountFormatter.string(fromByteCount: Int64(doc.bytes), countStyle: .file))
                    .font(.pocket(.metric))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            TableColumn("Extracted Characters") { doc in
                Text("\(doc.textChars) chars")
                    .font(.pocket(.metric))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            TableColumn("Indexing Status") { doc in
                HStack(spacing: PocketSpacing.s4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PocketColor.statusOk)
                        .font(.system(size: 11))
                    Text(doc.state)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusOk)
                }
            }
            TableColumn("Actions") { doc in
                Button(role: .destructive) {
                    deleteDocument(id: doc.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete document")
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
    }

    private func reloadDocs() {
        documents = model.core.listDocuments(projectId: project.id)
    }

    private func deleteDocument(id: String) {
        try? model.core.deleteDocument(id: id)
        reloadDocs()
    }

    private func startChatInProject() {
        if let conversation = try? model.core.createConversation(NewConversation(title: "\(project.name) Chat", projectId: project.id, modelId: nil)) {
            model.selectedTab = .chats
            model.pendingCommand = .openConversation(conversation.id)
        }
    }

    private func importDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .pdf, .plainText, .sourceCode,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "md") ?? .plainText,
        ]

        if panel.runModal() == .OK {
            handleDroppedFiles(panel.urls)
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importError = nil
        Task.detached {
            for url in urls {
                do {
                    let extracted = try DocumentTextExtractor.extract(fileURL: url)
                    let pages = extracted.map { DocumentPage(page: UInt32($0.page), text: $0.text) }
                    let filename = url.lastPathComponent
                    let ext = url.pathExtension.lowercased()
                    let mime = ext == "pdf" ? "application/pdf" : (ext == "docx" ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document" : "text/plain")

                    _ = try await MainActor.run {
                        try model.core.addDocument(projectId: project.id, name: filename, mime: mime, pages: pages)
                    }
                } catch {
                    await MainActor.run {
                        self.importError = "Failed to import “\(url.lastPathComponent)”: \(error.localizedDescription)"
                    }
                }
            }
            await MainActor.run {
                self.isImporting = false
                self.reloadDocs()
            }
        }
    }

    private func docIcon(for mime: String) -> String {
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("word") { return "doc.text" }
        if mime.contains("markdown") || mime.contains("plain") { return "doc.plaintext" }
        return "curlybraces"
    }

    private func docIconColor(for mime: String) -> Color {
        if mime.contains("pdf") { return PocketColor.statusBad }
        if mime.contains("word") { return PocketColor.statusInfo }
        if mime.contains("plain") { return PocketColor.accent }
        return PocketColor.statusWarn
    }
}

extension Document: @retroactive Identifiable {}
