import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PocketKit
import PocketUI

/// MAC-03: Chats and chat detail (M-CHAT).
/// Grouped conversations (Today / Last 7 days / Older), centered reading column (max 760 pt),
/// hover actions on messages (copy, speak, retry), drag-and-drop files/images into composer.
struct MacChatsView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var selectedId: String?

    private var groupedConversations: [(title: String, items: [ConversationSummary])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        var today: [ConversationSummary] = []
        var last7Days: [ConversationSummary] = []
        var older: [ConversationSummary] = []

        for conv in conversations {
            let date = Date(timeIntervalSince1970: Double(conv.updatedAt) / 1000)
            if date >= startOfToday {
                today.append(conv)
            } else if date >= sevenDaysAgo {
                last7Days.append(conv)
            } else {
                older.append(conv)
            }
        }

        var groups: [(title: String, items: [ConversationSummary])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !last7Days.isEmpty { groups.append(("Last 7 Days", last7Days)) }
        if !older.isEmpty { groups.append(("Older", older)) }
        return groups
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search chats", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(PocketSpacing.s12)

                List(selection: $selectedId) {
                    ForEach(groupedConversations, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items, id: \.id) { conversation in
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
                        }
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
            case .focusComposer, .stopGeneration, .openTab, .none:
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
    @Environment(\.openWindow) private var openWindow

    @State private var title: String?
    @State private var messages: [Message] = []
    @State private var composerText = ""
    @State private var isGenerating = false {
        didSet { model.isGenerating = isGenerating }
    }
    @State private var errorText: String?
    @State private var sendTask: Task<Void, Never>?
    @State private var isDictating = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Wider reading column (max 760 pt), centered per MAC-03
                    LazyVStack(alignment: .leading, spacing: PocketSpacing.s16) {
                        ForEach(messages, id: \.id) { message in
                            messageRow(message).id(message.id)
                        }
                        if let errorText {
                            Text(errorText).font(.pocket(.footnote)).foregroundStyle(PocketColor.statusBad)
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(PocketSpacing.s16)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            VStack(spacing: 0) {
                PulseStrip(state: isGenerating ? .generating(modelName: "This Mac", location: "On this Mac", tokPerSec: 28) : .idle, onTap: {})
                    .padding(.horizontal, PocketSpacing.s16)
                    .frame(maxWidth: 760)

                Composer(
                    text: $composerText,
                    modelChipLabel: nil,
                    isFocused: false,
                    isGenerating: isGenerating,
                    onAttach: { kind in handleAttachment(kind) },
                    onMic: { toggleVoiceDictation() },
                    onSend: { send() },
                    onStop: { stopGeneration() },
                    externalFocus: $composerFocused
                )
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 760)
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title ?? "New chat")
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
            return true
        }
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
            case .newChat, .openConversation, .openTab, .none:
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
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Retry with This Message") {
                        composerText = text
                        send()
                    }
                }
        } else {
            MessageView(
                text: text,
                reasoning: message.reasoning,
                onCopy: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                onRetry: {
                    retryLastTurn()
                },
                onSpeak: {
                    speak(text)
                }
            )
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

    private func retryLastTurn() {
        if let lastUserMessage = messages.last(where: { $0.role == "user" }) {
            let userText = lastUserMessage.parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined()
            composerText = userText
            send()
        }
    }

    private func speak(_ text: String) {
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(text)
    }

    private func toggleVoiceDictation() {
        // Toggle dictation: focus the composer and trigger system dictation if available
        composerFocused = true
        isDictating.toggle()
        if isDictating {
            // Initiate system speech recognition / dictation prompt
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    private func handleAttachment(_ kind: Composer.AttachmentKind) {
        switch kind {
        case .photo:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image, .png, .jpeg, .tiff]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                composerText += "\n[Attached image: \(url.lastPathComponent)]\n"
            }
        case .file:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf, .plainText, .sourceCode, UTType(filenameExtension: "docx") ?? .data]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                handleDroppedURLs([url])
            }
        case .projectDocument:
            model.selectedTab = .projects
        case .image:
            openWindow(id: "image-generation")
        case .camera:
            break
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        for url in urls {
            if let extracted = try? DocumentTextExtractor.extract(fileURL: url) {
                let allText = extracted.map(\.text).joined(separator: "\n")
                let header = "\n--- Document: \(url.lastPathComponent) ---\n"
                composerText += header + allText + "\n"
            } else if ["png", "jpg", "jpeg", "webp", "gif"].contains(url.pathExtension.lowercased()) {
                composerText += "\n[Attached image: \(url.lastPathComponent)]\n"
            }
        }
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
