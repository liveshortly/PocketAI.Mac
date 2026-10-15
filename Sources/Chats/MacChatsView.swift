import SwiftUI
import PocketKit
import PocketUI

/// MAC-03: Chats and chat detail (M-CHAT). A list|detail split within the
/// "Chats" sidebar destination, mirroring the iPhone's UI-08/UI-09 screens
/// against the same `CoreClient` surface.
struct MacChatsView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var selectedId: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search chats", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(PocketSpacing.s12)
                List(conversations, id: \.id, selection: $selectedId) { conversation in
                    VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                        Text(conversation.title ?? "New chat").font(.pocket(.body))
                        Text(Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: Double(conversation.updatedAt) / 1000), relativeTo: Date()))
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Archive") { archive(conversation) }
                        Button("Delete", role: .destructive) { delete(conversation) }
                    }
                }
                .listStyle(.sidebar)
                Button {
                    newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .padding(PocketSpacing.s8)
            }
            .frame(minWidth: 220, idealWidth: 260)

            if let selectedId {
                MacChatDetailView(conversationId: selectedId)
                    .id(selectedId)
            } else {
                EmptyState(
                    title: "Start a chat",
                    suggestions: ["Summarize a long email", "Explain a concept simply", "Draft a quick reply"],
                    onTapSuggestion: { suggestion in newChat(firstMessage: suggestion) }
                )
            }
        }
        .task { reload() }
        .onChange(of: searchText) { reload() }
        .onChange(of: model.pendingCommand) { _, command in
            switch command {
            case .newChat:
                newChat()
                model.pendingCommand = nil
            case .openConversation(let id):
                selectedId = id
                model.pendingCommand = nil
            case .focusComposer, .stopGeneration, .none:
                break
            }
        }
    }

    private func reload() {
        conversations = model.core.conversations(
            query: ConversationQuery(search: searchText.isEmpty ? nil : searchText, archived: false, limit: 0, offset: 0)
        )
    }

    private func newChat(firstMessage: String? = nil) {
        guard let conversation = try? model.core.createConversation(NewConversation(title: nil, projectId: nil, modelId: nil)) else { return }
        reload()
        selectedId = conversation.id
        if let firstMessage {
            // MacChatDetailView reads this back out of the environment-less
            // path via its own `.task` first-message check, same pattern
            // as the iPhone's ChatView.
            pendingFirstMessages[conversation.id] = firstMessage
        }
    }

    private func delete(_ conversation: ConversationSummary) {
        try? model.core.deleteConversation(id: conversation.id)
        if selectedId == conversation.id { selectedId = nil }
        reload()
    }

    private func archive(_ conversation: ConversationSummary) {
        try? model.core.archiveConversation(id: conversation.id, archived: true)
        reload()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// A tiny in-memory handoff for "send this suggestion as the first
/// message" - keyed by conversation id, consumed once by
/// `MacChatDetailView` and removed.
@MainActor var pendingFirstMessages: [String: String] = [:]

private struct MacChatDetailView: View {
    let conversationId: String
    @Environment(AppModel.self) private var model

    @State private var title: String?
    @State private var messages: [Message] = []
    @State private var composerText = ""
    @State private var isGenerating = false
    @State private var errorText: String?
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PocketSpacing.s16) {
                        ForEach(messages, id: \.id) { message in
                            messageRow(message).id(message.id)
                        }
                        if let errorText {
                            Text(errorText).font(.pocket(.footnote)).foregroundStyle(PocketColor.statusBad)
                        }
                    }
                    .padding(PocketSpacing.s16)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            PulseStrip(state: isGenerating ? .generating(modelName: "This Mac", location: "On this Mac", tokPerSec: 0) : .idle, onTap: {})
                .padding(.horizontal, PocketSpacing.s16)

            Composer(
                text: $composerText, modelChipLabel: nil, isFocused: false, isGenerating: isGenerating,
                onAttach: { _ in }, onMic: {}, onSend: { send() }, onStop: { stopGeneration() },
                externalFocus: $composerFocused
            )
            .padding(PocketSpacing.s16)
        }
        .navigationTitle(title ?? "New chat")
        .task {
            reload()
            if let firstMessage = pendingFirstMessages.removeValue(forKey: conversationId) {
                composerText = firstMessage
                send()
            }
        }
        .onChange(of: model.pendingCommand) { _, command in
            switch command {
            case .focusComposer:
                composerFocused = true
                model.pendingCommand = nil
            case .stopGeneration:
                stopGeneration()
                model.pendingCommand = nil
            case .newChat, .openConversation, .none:
                break
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: Message) -> some View {
        let text = message.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()
        if message.role == "user" {
            UserBubble(text: text)
        } else {
            MessageView(text: text, reasoning: message.reasoning, onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        }
    }

    private func reload() {
        messages = model.core.messages(conversationId: conversationId)
        title = model.core.conversations(query: ConversationQuery(search: nil, archived: nil, limit: 0, offset: 0))
            .first { $0.id == conversationId }?.title
    }

    private func send() {
        guard !composerText.isEmpty else { return }
        let text = composerText
        composerText = ""
        errorText = nil
        isGenerating = true
        sendTask = Task {
            var partialText = ""
            do {
                for try await event in model.core.sendMessage(conversationId: conversationId, input: UserInput(parts: [.text(text: text)])) {
                    if Task.isCancelled { return }
                    switch event {
                    case .delta(let delta):
                        partialText += delta.text
                        upsertStreamingPlaceholder(text: partialText)
                    case .done:
                        reload()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorText = "Something went wrong: \(error.localizedDescription)"
                }
            }
            isGenerating = false
        }
    }

    private func stopGeneration() {
        sendTask?.cancel()
        sendTask = nil
        isGenerating = false
    }

    private func upsertStreamingPlaceholder(text: String) {
        let placeholderId = "streaming-placeholder"
        let message = Message(
            id: placeholderId, conversationId: conversationId, role: "assistant",
            parts: [.text(text: text)], reasoning: nil, stats: nil, modelId: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000), status: .streaming
        )
        if let index = messages.firstIndex(where: { $0.id == placeholderId }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }
}
