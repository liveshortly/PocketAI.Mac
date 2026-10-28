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
            chat = ChatModel(conversationId: conversationId, core: app.core)
            composerFocused = true
        }
        .onChange(of: chat?.isStreaming ?? false) { _, streaming in
            app.isGenerating = streaming
        }
        .onChange(of: chat?.tokensPerSecond ?? 0) { _, rate in
            app.activeTokPerSec = rate
        }
        .onChange(of: app.pendingCommand) { _, command in
            guard let command, let chat else { return }
            switch command {
            case .focusComposer:
                composerFocused = true
                app.pendingCommand = nil
            case .stopGeneration:
                chat.stop()
                app.pendingCommand = nil
            case .regenerate:
                chat.regenerate()
                app.pendingCommand = nil
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
                Divider()
                Button("Archive") {
                    try? app.core.archiveConversation(id: conversationId, archived: true)
                    app.selection = nil
                    NotificationCenter.default.post(
                        name: .pocketConversationsChanged, object: nil)
                }
                Button("Delete", role: .destructive) {
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
    }

    private func modelName(_ chat: ChatModel) -> String {
        let id = chat.conversation?.modelId ?? app.currentModelId
        return app.installedChatModels().first { $0.manifest.id == id }?.manifest.displayName
            ?? app.currentModelDisplayName
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
                    ForEach(chat.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if chat.isStreaming {
                        StreamingRow(
                            text: chat.streamingText,
                            reasoning: chat.streamingReasoning)
                        .id("streaming")
                    }
                    if let error = chat.errorText {
                        Text(error)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                            .padding(PocketSpacing.s12)
                            .hudPanel(PocketColor.statusBad.opacity(0.08))
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.horizontal, PocketSpacing.s24)
                .padding(.vertical, PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: chat.streamingText) { _, _ in scroll(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .help("Attach an image")
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
