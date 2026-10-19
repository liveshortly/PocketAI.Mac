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
    @State private var systemPrompt: String = ""
    @State private var isEditingTitle: Bool = false
    @State private var messageCount: Int = 0
    @State private var estimatedTokens: Int = 0
    @State private var showDeleteConfirm: Bool = false
    @State private var exportSuccess: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s20) {
                // Conversation Header / Title
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("CONVERSATION")
                        .font(.system(size: 11, weight: .semibold))
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PocketColor.textTertiary)

                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        HStack {
                            PocketMarkView(state: model.isGenerating ? .working(tokPerSec: 28) : .idle, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.currentModelDisplayName)
                                    .font(.pocket(.body))
                                    .fontWeight(.medium)
                                Text("MLX · 4-bit Quantized")
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }
                            Spacer()
                            FitBadge(kind: .runsWell, reason: "Fits comfortably in memory.")
                        }

                        Divider()

                        HStack {
                            Text("Context Window")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer()
                            Text("32,768 tokens")
                                .font(.pocket(.metric))
                        }

                        HStack {
                            Text("Execution Engine")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer()
                            Text("Apple Silicon GPU (Metal)")
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

                // System Prompt
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("SYSTEM PROMPT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PocketColor.textTertiary)

                    TextEditor(text: $systemPrompt)
                        .font(.pocket(.footnote))
                        .frame(height: 90)
                        .padding(PocketSpacing.s8)
                        .background(PocketColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(PocketColor.lineHairline, lineWidth: 0.5)
                        )

                    Text("Custom instructions given to the model for this chat.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }

                Divider()

                // Metrics & Stats
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("SESSION METRICS")
                        .font(.system(size: 11, weight: .semibold))
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
                            Text(model.isGenerating ? "\(model.activeTokPerSec) tok/s" : "28 tok/s")
                                .font(.pocket(.metric))
                                .foregroundStyle(PocketColor.accent)
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
                        .font(.system(size: 11, weight: .semibold))
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

    private func loadDetails() {
        let convs = model.core.conversations(query: ConversationQuery(search: nil, archived: nil, limit: 0, offset: 0))
        if let current = convs.first(where: { $0.id == conversationId }) {
            title = current.title ?? "New chat"
        }
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
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
