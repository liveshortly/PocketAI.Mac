import PocketKit
import PocketUI
import SwiftUI
import UniformTypeIdentifiers

/// One conversation: status strip, transcript, composer. The transcript idiom
/// matches the iPhone app — user turns as right-aligned cards, assistant turns
/// as full-width prose with fenced code lifted into `CodeBlock`.
struct ChatView: View {
    @Environment(AppModel.self) private var app
    @State private var chat: ChatModel?
    @State private var draft = ""
    @State private var attachments: [URL] = []
    @State private var showRename = false
    @State private var isDropTargeted = false
    @State private var dictation = Dictation()
    @State private var pinnedToBottom = true
    @State private var attachmentRefusal: String?
    @State private var chatExportError: String?
    @AppStorage("app.getpocketai.mac.autoSpeak") private var autoSpeak = false
    @FocusState private var composerFocused: Bool

    let conversationId: String

    var body: some View {
        VStack(spacing: 0) {
            if let chat {
                statusStrip(chat)
                HUDRule()
                transcript(chat)
                composer(chat)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task(id: conversationId) {
            chat = app.chatModel(for: conversationId)
            chat?.load()
            composerFocused = true
        }
        .onDisappear { dictation.stop() }
        .onChange(of: chat?.tokensPerSecond ?? 0) { _, rate in
            app.activeTokPerSec = rate
        }
        .onChange(of: chat?.isStreaming ?? false) { wasStreaming, streaming in
            // Read the finished reply when the user asked for that.
            guard autoSpeak, wasStreaming, !streaming,
                  let last = chat?.messages.last, !last.isUser
            else { return }
            let text = last.plainText
            if !text.isEmpty { ReadAloud.shared.toggle(text, id: last.id) }
        }
        .onChange(of: app.commandSerial) { _, _ in
            guard let command = app.pendingCommand, let chat else { return }
            switch command {
            case .focusComposer:
                composerFocused = true
                app.clearCommand()
            case .stopGeneration:
                chat.stop()
                app.clearCommand()
            case .regenerate:
                chat.regenerate()
                app.clearCommand()
            default:
                break
            }
        }
        .sheet(isPresented: $showRename) {
            if let chat {
                RenameSheet(title: chat.title) { chat.rename($0) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let chat, chat.modelSupportsVision else {
                attachmentRefusal = chat.map(visionWarning)
                return false
            }
            loadDroppedFiles(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                    .stroke(PocketColor.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(PocketSpacing.s8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Status strip

    private func statusStrip(_ chat: ChatModel) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Text(chat.title)
                .font(.pocket(.headline))
                .lineLimit(1)
                .onTapGesture { showRename = true }
            if chat.isStreaming {
                HStack(spacing: PocketSpacing.s4) {
                    PocketMarkView(state: .working(tokPerSec: nil), size: 14)
                    Text(chat.tokensPerSecond > 0 ? "\(chat.tokensPerSecond) tok/s" : "working")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
            modelPicker(chat)
            Menu {
                Button("Rename…") { showRename = true }
                Button("Regenerate reply") { chat.regenerate() }
                    .disabled(chat.isStreaming || chat.messages.isEmpty)
                Button("Export transcript…") { exportTranscript(chat) }
                    .disabled(chat.messages.isEmpty)
                Divider()
                Button("Archive") {
                    try? app.core.archiveConversation(id: conversationId, archived: true)
                    app.selection = nil
                    NotificationCenter.default.post(
                        name: .pocketConversationsChanged, object: nil)
                }
                Button("Delete", role: .destructive) {
                    app.forgetChatModel(conversationId)
                    try? app.core.deleteConversation(id: conversationId)
                    app.selection = nil
                    NotificationCenter.default.post(
                        name: .pocketConversationsChanged, object: nil)
                }
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

    private func modelPicker(_ chat: ChatModel) -> some View {
        Menu {
            if app.appleIntelligenceAvailable {
                Button {
                    chat.setModel(AppModel.appleIntelligenceId)
                    app.currentModelId = AppModel.appleIntelligenceId
                } label: {
                    if (chat.conversation?.modelId ?? app.currentModelId)
                        == AppModel.appleIntelligenceId {
                        Label("Apple Intelligence", systemImage: "checkmark")
                    } else {
                        Text("Apple Intelligence · no download")
                    }
                }
            }
            ForEach(app.installedChatModels(), id: \.manifest.id) { entry in
                Button {
                    chat.setModel(entry.manifest.id)
                    app.currentModelId = entry.manifest.id
                } label: {
                    if entry.manifest.id == (chat.conversation?.modelId ?? app.currentModelId) {
                        Label(entry.manifest.displayName, systemImage: "checkmark")
                    } else {
                        Text(entry.manifest.displayName)
                    }
                }
            }
            Divider()
            Button("Model library…") { app.selection = .models }
        } label: {
            HUDChip(text: modelName(chat), tint: PocketColor.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(chat.isStreaming)
        .help(chat.isStreaming ? "Stop generating to switch models" : "Model for this chat")
    }

    private func modelName(_ chat: ChatModel) -> String {
        app.displayName(forModelId: chat.conversation?.modelId ?? app.currentModelId)
    }

    // MARK: - Transcript

    private func transcript(_ chat: ChatModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    if chat.isEmpty {
                        ChatEmptyState { suggestion in
                            draft = suggestion
                            composerFocused = true
                        }
                        .padding(.top, 80)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        MessageRow(
                            message: message,
                            grouped: isGrouped(chat.messages, index))
                        .id(message.id)
                    }
                    if chat.isStreaming {
                        StreamingRow(
                            text: chat.streamingText,
                            reasoning: chat.streamingReasoning)
                        .id("streaming")
                    }
                    if let error = chat.errorText {
                        ChatErrorRow(message: error) { chat.regenerate() }
                    }
                    // Whether this sentinel is on screen tells us if the
                    // reader is at the tail — `onScrollGeometryChange` would
                    // be cleaner but is macOS 15 only.
                    Color.clear
                        .frame(height: 1)
                        .id("tail")
                        .onAppear { pinnedToBottom = true }
                        .onDisappear { pinnedToBottom = false }
                }
                .padding(.horizontal, PocketSpacing.s24)
                .padding(.vertical, PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Only follow the stream while the reader is already at the tail;
            // yanking the view down while they read back is the worst thing a
            // transcript can do.
            .onChange(of: chat.messages.count) { _, _ in
                if pinnedToBottom { scroll(proxy) }
            }
            .onChange(of: chat.streamingText) { _, _ in
                if pinnedToBottom { scroll(proxy) }
            }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom {
                    Button {
                        pinnedToBottom = true
                        scroll(proxy)
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.pocket(.caption))
                            .padding(.horizontal, PocketSpacing.s12)
                            .padding(.vertical, 6)
                            .hudPanel(PocketColor.bgRaised)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, PocketSpacing.s12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// True when this turn continues the previous author's run, so the row can
    /// drop its repeated header.
    private func isGrouped(_ messages: [Message], _ index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = messages[index - 1]
        let current = messages[index]
        return previous.role == current.role
            && current.createdAt - previous.createdAt < 300
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("tail", anchor: .bottom)
        }
    }

    // MARK: - Composer

    private func composer(_ chat: ChatModel) -> some View {
        VStack(spacing: 0) {
            HUDRule()
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                if let chatExportError {
                    Text(chatExportError)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                }
                if let attachmentRefusal {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(PocketColor.statusWarn)
                        Text(attachmentRefusal)
                            .font(.pocket(.caption))
                        Spacer(minLength: 0)
                        Button("Dismiss") { self.attachmentRefusal = nil }
                            .buttonStyle(.plain)
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                    .padding(PocketSpacing.s8)
                    .hudPanel(PocketColor.statusWarn.opacity(0.10))
                }
                if !attachments.isEmpty {
                    HStack(spacing: PocketSpacing.s8) {
                        ForEach(attachments, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button {
                                    attachments.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .hudPanel(PocketColor.bgSunken)
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: PocketSpacing.s8) {
                    ComposerTextView(
                        text: $draft,
                        isFocused: composerFocused,
                        onSubmit: { submit(chat) }
                    )
                    .frame(minHeight: 22)
                    .padding(.horizontal, PocketSpacing.s12)
                    .padding(.vertical, PocketSpacing.s8)
                    .hudPanel(PocketColor.bgCanvas)
                    if chat.isStreaming {
                        Button {
                            chat.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PocketColor.statusBad)
                        .help("Stop generating (⌘.)")
                    } else {
                        Button {
                            submit(chat)
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.accentOnAccent)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(PocketColor.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                            && attachments.isEmpty)
                        .help("Send (⏎)")
                    }
                }
                HStack(spacing: PocketSpacing.s8) {
                    Button {
                        pickAttachment()
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketColor.textTertiary)
                    .disabled(!attachmentsAllowed(chat))
                    .help(attachmentsAllowed(chat)
                        ? "Attach an image" : visionWarning(chat))
                    Button {
                        dictation.toggle(base: draft) { draft = $0 }
                    } label: {
                        Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                            .foregroundStyle(
                                dictation.isRecording
                                    ? PocketColor.statusBad : PocketColor.textTertiary)
                            .background(
                                Circle()
                                    .fill(PocketColor.statusBad.opacity(
                                        dictation.isRecording ? 0.18 * dictation.level + 0.08 : 0))
                                    .frame(width: 22, height: 22))
                    }
                    .buttonStyle(.plain)
                    .help(dictation.isRecording ? "Stop dictation" : "Dictate")
                    if dictation.permissionDenied {
                        HUDLabel("mic access denied", tint: PocketColor.statusBad)
                    } else {
                        HUDLabel("⏎ send · ⇧⏎ newline")
                    }
                    Spacer(minLength: 0)
                    if let stats = chat.lastStats, !chat.isStreaming {
                        HUDLabel("\(Int(stats.decodeTps)) tok/s · \(stats.completionTokens) tokens")
                    }
                }
            }
            .padding(PocketSpacing.s12)
        }
        .background(PocketColor.bgSurface)
    }

    private func submit(_ chat: ChatModel) {
        dictation.stop()
        let text = draft
        let files = attachments
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty || !files.isEmpty else { return }
        draft = ""
        attachments = []
        chat.send(text, attachments: files)
    }

    /// Images only make sense for a model that can read them; say so here
    /// rather than letting the engine fail after the send.
    private func attachmentsAllowed(_ chat: ChatModel) -> Bool { chat.modelSupportsVision }

    private func visionWarning(_ chat: ChatModel) -> String {
        if let suggestion = chat.suggestedVisionModel {
            return "This model can't read images. Switch to \(suggestion) to attach one."
        }
        return "This model can't read images. Install a vision model to attach one."
    }

    /// Writes the conversation out as Markdown. The desktop is where a
    /// transcript actually leaves the app.
    private func exportTranscript(_ chat: ChatModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = chat.title
            .replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = ["# \(chat.title)", ""]
        for message in chat.messages {
            let when = Date(timeIntervalSince1970: TimeInterval(message.createdAt))
                .formatted(date: .abbreviated, time: .shortened)
            lines.append("## \(message.isUser ? "You" : "Assistant") · \(when)")
            lines.append("")
            let body = message.plainText
            if !body.isEmpty { lines.append(body) }
            for path in message.imagePaths { lines.append("![attachment](\(path))") }
            lines.append("")
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            chatExportError = "Couldn't save the transcript: \(error.localizedDescription)"
        }
    }

    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            attachments.append(contentsOf: panel.urls)
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, UTType(filenameExtension: url.pathExtension)?
                    .conforms(to: .image) == true else { return }
                Task { @MainActor in attachments.append(url) }
            }
        }
    }
}

/// Opening state of a fresh chat: says what this app is for rather than
/// leaving a blank pane.
struct ChatEmptyState: View {
    let onSuggestion: (String) -> Void

    private let suggestions = [
        "Explain this error message",
        "Summarise the text I paste next",
        "Draft a commit message for these changes",
    ]

    var body: some View {
        VStack(spacing: PocketSpacing.s12) {
            PocketMarkView(state: .idle, size: 40)
            Text("Ask anything — it runs on this Mac")
                .font(.pocket(.title))
            Text("No account, no cloud. Your chats never leave this machine.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
            HStack(spacing: PocketSpacing.s8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSuggestion(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.pocket(.caption))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .hudPanel()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, PocketSpacing.s4)
        }
        .frame(maxWidth: .infinity)
    }
}
