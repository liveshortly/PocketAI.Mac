import SwiftUI
import AppKit
import PocketKit
import PocketUI

/// Right-hand inspector (⌥⌘I) for conversation details, model specs,
/// system prompt configuration, and session statistics.
struct MacChatInspectorView: View {
    let conversationId: String
    let onReload: () -> Void
    @Environment(AppModel.self) private var model

    @State private var title: String = ""
    @State private var isEditingTitle: Bool = false
    @State private var messageCount: Int = 0
    @State private var estimatedTokens: Int = 0
    @State private var showDeleteConfirm: Bool = false
    @State private var exportStatus: String?
    /// This conversation's own bound model (loaded via `conversation(id:)`),
    /// not the global default.
    @State private var conversationModelId: String?
    /// Catalog snapshot loaded once in `loadDetails()` — never per render.
    @State private var cachedCatalog: [CatalogEntry] = []

    /// The model this chat will actually use: its own binding, falling back to
    /// the global default only while unbound.
    private var effectiveModelId: String {
        if let bound = conversationModelId, !bound.isEmpty { return bound }
        return model.currentModelId
    }

    /// The real catalog entry for the chat's model (nil if it isn't in the
    /// catalog), so specs come from the manifest/fit — never hardcoded.
    private var currentEntry: CatalogEntry? {
        cachedCatalog.first { $0.manifest.id == effectiveModelId }
    }

    private var installedModels: [CatalogEntry] {
        cachedCatalog.filter { $0.state == .installed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s20) {
                // Conversation Header / Title
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("CONVERSATION")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)

                    HStack {
                        TextField("Conversation title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.pocket(.headline))
                            .onSubmit {
                                saveTitle()
                            }

                        Button {
                            saveTitle()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(PocketColor.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(PocketSpacing.s8)
                    .background(PocketColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(PocketColor.lineHairline, lineWidth: 0.5)
                    )
                }

                Divider()

                // Active Model & Settings
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("MODEL & RUNTIME")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)

                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        HStack {
                            PocketMarkView(state: model.isGenerating ? .working(tokPerSec: model.activeTokPerSec > 0 ? Double(model.activeTokPerSec) : nil) : .idle, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(currentEntry?.manifest.displayName ?? effectiveModelId)
                                    .font(.pocket(.body))
                                    .fontWeight(.medium)
                                if let entry = currentEntry {
                                    Text("\(entry.manifest.format) · \(entry.manifest.quant)")
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textSecondary)
                                }
                            }
                            Spacer()
                            if let entry = currentEntry {
                                FitBadge(kind: fitKind(entry.fit.verdict), reason: entry.fit.reason)
                            }
                        }

                        // Per-chat model picker: binds this conversation only,
                        // never the global default.
                        if !installedModels.isEmpty {
                            Picker("Model for this chat", selection: Binding(
                                get: { effectiveModelId },
                                set: { newId in
                                    try? model.core.setConversationModel(id: conversationId, modelId: newId)
                                    conversationModelId = newId
                                }
                            )) {
                                ForEach(installedModels, id: \.manifest.id) { entry in
                                    Text(entry.manifest.displayName).tag(entry.manifest.id)
                                }
                                if !installedModels.contains(where: { $0.manifest.id == effectiveModelId }) {
                                    Text(currentEntry?.manifest.displayName ?? effectiveModelId).tag(effectiveModelId)
                                }
                            }
                            .font(.pocket(.footnote))
                        }

                        Divider()

                        HStack {
                            Text("Context Window")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer()
                            Text(currentEntry.map { "\($0.manifest.contextLength) tokens" } ?? "—")
                                .font(.pocket(.metric))
                        }

                        HStack {
                            Text("Execution Engine")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer()
                            Text(currentEntry.map { "\($0.manifest.format)" } ?? "—")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                    }
                    .padding(PocketSpacing.s12)
                    .background(PocketColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(PocketColor.lineHairline, lineWidth: 0.5)
                    )
                }

                Divider()

                // System prompt editor removed: no FFI setter for a per-chat
                // system prompt exists yet, so the field only edited local state.



                // Metrics & Stats
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("SESSION METRICS")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)

                    VStack(spacing: PocketSpacing.s8) {
                        HStack {
                            Text("Messages")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer()
                            Text("\(messageCount)")
                                .font(.pocket(.metric))
                        }

                        HStack {
                            Text("Approx. Tokens")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer()
                            Text("\(estimatedTokens)")
                                .font(.pocket(.metric))
                        }

                        HStack {
                            Text("Generation Speed")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer()
                            Text(model.isGenerating && model.activeTokPerSec > 0 ? "\(model.activeTokPerSec) tok/s" : "Not measured")
                                .font(.pocket(.metric))
                                .foregroundStyle(model.isGenerating && model.activeTokPerSec > 0 ? PocketColor.accent : PocketColor.textTertiary)
                        }
                    }
                    .padding(PocketSpacing.s12)
                    .background(PocketColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(PocketColor.lineHairline, lineWidth: 0.5)
                    )
                }

                Divider()

                // Actions
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("ACTIONS")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)

                    Button {
                        exportConversationMarkdown()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export as Markdown…")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    if let exportStatus {
                        Text(exportStatus)
                            .font(.pocket(.caption))
                            .foregroundStyle(exportStatus.hasPrefix("Export failed") ? PocketColor.statusBad : PocketColor.statusOk)
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Chat")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(PocketColor.statusBad)
                }
            }
            .padding(PocketSpacing.s16)
        }
        .frame(minWidth: 290, idealWidth: 320)
        .background(PocketColor.bgCanvas)
        .task {
            loadDetails()
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) {
                try? model.core.deleteConversation(id: conversationId)
                model.showChatInspector = false
                onReload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This conversation and all its messages will be permanently removed.")
        }
    }

    private func fitKind(_ verdict: FitVerdict) -> FitBadgeKind {
        switch verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }

    private func loadDetails() {
        // Resolve directly by ID — never page-scan conversations().
        if let convo = model.core.conversation(id: conversationId) {
            title = convo.title ?? "New chat"
            conversationModelId = convo.modelId
        }
        cachedCatalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        let msgs = model.core.messages(conversationId: conversationId)
        messageCount = msgs.count
        estimatedTokens = msgs.reduce(0) { total, msg in
            let chars = msg.parts.reduce(0) { acc, part in
                if case .text(let t) = part { return acc + t.count }
                return acc
            }
            return total + (chars / 4)
        }
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? model.core.renameConversation(id: conversationId, title: trimmed)
            onReload()
        }
    }

    private func exportConversationMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title.isEmpty ? "conversation" : title).md"
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            let msgs = model.core.messages(conversationId: conversationId)
            var md = "# \(title)\n\n"
            for msg in msgs {
                let role = msg.role.capitalized
                let content = msg.parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined()
                md += "### \(role)\n\n\(content)\n\n"
            }
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                exportStatus = "Exported to \(url.lastPathComponent)"
            } catch {
                exportStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
