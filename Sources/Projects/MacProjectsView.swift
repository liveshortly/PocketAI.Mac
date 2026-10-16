import SwiftUI
import UniformTypeIdentifiers
import PocketKit
import PocketUI

/// MAC-12: Projects layout for Mac (UI-16 components).
/// Split layout with projects list on the left and project details + documents table on the right.
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
            VStack(spacing: 0) {
                List(projects, id: \.id, selection: $selectedProjectId) { project in
                    VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                        Text(project.name).font(.pocket(.headline))
                        if let inst = project.instructions, !inst.isEmpty {
                            Text(inst)
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(project.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            deleteProject(id: project.id)
                        }
                    }
                }
                .listStyle(.sidebar)

                HStack {
                    Button {
                        isShowingNewProject = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .padding(PocketSpacing.s8)
                    Spacer()
                }
            }
            .frame(minWidth: 200, idealWidth: 240)

            if let selectedProject {
                MacProjectDetailView(project: selectedProject, onReload: { reload() })
                    .id(selectedProject.id)
            } else {
                VStack(spacing: PocketSpacing.s16) {
                    PocketMarkView(state: .idle, size: 48)
                    Text("Select or create a project")
                        .font(.pocket(.title))
                        .foregroundStyle(PocketColor.textSecondary)
                    Button("Create Project") { isShowingNewProject = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { reload() }
        .sheet(isPresented: $isShowingNewProject) {
            newProjectSheet
        }
    }

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s16) {
            Text("New Project").font(.pocket(.title))

            TextField("Project Name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                Text("Instructions (optional)").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                TextEditor(text: $newProjectInstructions)
                    .font(.pocket(.body))
                    .frame(height: 100)
                    .border(PocketColor.lineHairline, width: 1)
            }

            HStack {
                Button("Cancel") {
                    isShowingNewProject = false
                    newProjectName = ""
                    newProjectInstructions = ""
                }
                Spacer()
                Button("Create") {
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
                .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(PocketSpacing.s24)
        .frame(width: 440)
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
    @State private var isEditingInstructions = false
    @State private var instructionsText = ""
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                HStack {
                    Text(project.name).font(.pocket(.title))
                    Spacer()
                    Button {
                        startChatInProject()
                    } label: {
                        Label("New Chat in Project", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let instructions = project.instructions, !instructions.isEmpty {
                    Text(instructions)
                        .font(.pocket(.body))
                        .foregroundStyle(PocketColor.textSecondary)
                }
            }
            .padding(PocketSpacing.s16)

            Divider()

            // Documents Table Header
            HStack {
                Text("Documents (\(documents.count))").font(.pocket(.headline))
                Spacer()
                Button {
                    importDocument()
                } label: {
                    Label("Add Document", systemImage: "doc.badge.plus")
                }
                .disabled(isImporting)
            }
            .padding(PocketSpacing.s16)

            if let importError {
                Text(importError)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
                    .padding(.horizontal, PocketSpacing.s16)
            }

            // Documents Table
            if documents.isEmpty {
                VStack(spacing: PocketSpacing.s12) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 36))
                        .foregroundStyle(PocketColor.textTertiary)
                    Text("No documents yet").font(.pocket(.body)).foregroundStyle(PocketColor.textSecondary)
                    Text("Add PDFs, markdown, text, or source code files to ground answers in your project.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(documents) {
                    TableColumn("Name") { doc in
                        Label(doc.name, systemImage: docIcon(for: doc.mime))
                    }
                    TableColumn("Size") { doc in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(doc.bytes), countStyle: .file))
                    }
                    TableColumn("Characters") { doc in
                        Text("\(doc.textChars)")
                    }
                    TableColumn("Status") { doc in
                        Text(doc.state)
                            .foregroundStyle(PocketColor.statusOk)
                    }
                    TableColumn("Actions") { doc in
                        Button(role: .destructive) {
                            deleteDocument(id: doc.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task { reloadDocs() }
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
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .pdf, .plainText, .sourceCode,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "md") ?? .plainText,
        ]

        if panel.runModal() == .OK, let url = panel.url {
            isImporting = true
            importError = nil
            Task.detached {
                do {
                    let extracted = try DocumentTextExtractor.extract(fileURL: url)
                    let pages = extracted.map { DocumentPage(page: UInt32($0.page), text: $0.text) }
                    let filename = url.lastPathComponent
                    let ext = url.pathExtension.lowercased()
                    let mime = ext == "pdf" ? "application/pdf" : (ext == "docx" ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document" : "text/plain")

                    _ = try await MainActor.run {
                        try model.core.addDocument(projectId: project.id, name: filename, mime: mime, pages: pages)
                    }
                    await MainActor.run {
                        self.isImporting = false
                        self.reloadDocs()
                    }
                } catch {
                    await MainActor.run {
                        self.isImporting = false
                        self.importError = "Failed to import document: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func docIcon(for mime: String) -> String {
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("word") { return "doc.text" }
        return "doc.plaintext"
    }
}

extension Document: @retroactive Identifiable {}
