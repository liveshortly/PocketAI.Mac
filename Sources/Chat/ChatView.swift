import PocketKit
import PocketUI
import SwiftUI
import UniformTypeIdentifiers

/// AGT-13: clears the "Running code…" row when the run's step arrives or the
/// reply ends. Its own modifier: `ChatView.body`'s chain is at the type-checker's limit.
private struct RunningCodeTracker: ViewModifier {
    @Environment(AppModel.self) private var app
    let chat: ChatModel?
    let conversationId: String

    func body(content: Content) -> some View {
        content
            .onChange(of: chat?.streamingSteps.last?.kind) { _, kind in
                if kind == "ran" { app.tools.approvals.finishRun(conversationId: conversationId) }
            }
            .onChange(of: chat?.isStreaming ?? false) { _, streaming in
                if !streaming { app.tools.approvals.finishRun(conversationId: conversationId) }
            }
    }
}

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
    @State private var scrollActivity = ScrollActivity()
    @State private var attachmentRefusal: String?
    @AppStorage("app.getpocketai.mac.autoSpeak") private var autoSpeak = false
    /// Bumped to ask the composer for the caret. `@FocusState` was never bound
    /// to anything here — the composer is an `NSTextView` — so it latched true
    /// and every later request was a no-op.
    @State private var focusRequest = 0

    let conversationId: String

    var body: some View {
        VStack(spacing: 0) {
            if let chat {
                statusStrip(chat)
                HUDRule()
                transcript(chat)
                toolApprovalArea
                composer(chat)
            } else {
                // Same loading treatment as LiveShortly (LSI-13): the animated
                // PocketAI mark, centered — not a system spinner (UI-28).
                PocketMarkView(state: .loading, size: 64)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .onAppear { scrollActivity.start() }
        .task(id: conversationId) {
            chat = app.chatModel(for: conversationId)
            chat?.load()
            focusRequest += 1
        }
        .onDisappear {
            dictation.stop()
            scrollActivity.stop()
        }
        .modifier(RunningCodeTracker(chat: chat, conversationId: conversationId))
        .onChange(of: chat?.tokensPerSecond ?? 0) { _, rate in
            app.activeTokPerSec = rate
        }
        .onChange(of: chat?.isStreaming ?? false) { wasStreaming, streaming in
            guard wasStreaming, !streaming else { return }
            // A reply landing moves nothing on screen that VoiceOver follows,
            // so say it happened.
            AccessibilityNotification.Announcement("Reply finished").post()
            // Read the finished reply when the user asked for that.
            guard autoSpeak, let last = chat?.messages.last, !last.isUser else { return }
            let text = last.plainText
            if !text.isEmpty { ReadAloud.shared.toggle(text, id: last.id) }
        }
        .onChange(of: chat?.errorText) { _, error in
            if let error, !error.isEmpty {
                AccessibilityNotification.Announcement(error).post()
            }
        }
        .onChange(of: app.commandSerial) { _, _ in
            guard let command = app.pendingCommand, let chat else { return }
            switch command {
            case .focusComposer:
                focusRequest += 1
                app.clearCommand()
            case .stopGeneration:
                chat.stop()
                app.clearCommand()
            case .regenerate:
                chat.regenerate()
                app.clearCommand()
            case .copyLastReply:
                app.clearCommand()
                guard let reply = chat.messages.last(where: { !$0.isUser })?.plainText,
                      !reply.isEmpty
                else {
                    app.toast("No reply to copy yet")
                    return
                }
                copyToPasteboard(reply)
                app.toast("Copied the last reply")
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
            // A button, not a tappable Text: the title was unreachable by
            // keyboard and invisible to VoiceOver as an action.
            Button { showRename = true } label: {
                Text(chat.title)
                    .font(.pocket(.headline))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chat title, \(chat.title)")
            .accessibilityHint("Rename this chat")
            .help("Rename this chat")
            if chat.isStreaming {
                HStack(spacing: PocketSpacing.s4) {
                    PocketMarkView(state: .thinking(tokPerSec: nil), size: 14)
                        .accessibilityHidden(true)
                    Text(chat.tokensPerSecond > 0 ? "\(chat.tokensPerSecond) tok/s" : "working")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    chat.tokensPerSecond > 0
                        ? "Generating, \(chat.tokensPerSecond) tokens per second"
                        : "Generating")
            }
            Spacer(minLength: 0)
            // UI-27 / MAC-17: per-chat thinking toggle, only for models that
            // actually reason — never a dead control.
            if chat.modelSupportsReasoning {
                thinkingToggle(chat)
            }
            // AGT-12: web tools. Apple's built-in model can't take tools.
            if chat.conversation?.modelId != AppModel.appleIntelligenceId {
                ToolsToggleChip(
                    isOn: Binding(get: { chat.toolsEnabled }, set: { chat.toolsEnabled = $0 })
                )
                .help(chat.toolsEnabled
                    ? "Tools on — the model can search the web and, if Settings allows, run code you approve"
                    : "Tools off — the model answers from what it knows")
            }
            modelPicker(chat)
            Menu {
                Button("Rename…") { showRename = true }
                Button("Regenerate reply") { chat.regenerate() }
                    .disabled(chat.isStreaming || chat.messages.isEmpty)
                Button("Export transcript…") { exportTranscript(chat) }
                    .disabled(chat.messages.isEmpty)
                Divider()
                // Both of these close the pane, so a refused call has to be
                // reported at window level or not at all — and the chat must
                // stay selected when it is still there.
                Button("Archive") {
                    do {
                        try app.core.archiveConversation(id: conversationId, archived: true)
                    } catch {
                        app.toast("Couldn't archive this chat: \(error.localizedDescription)")
                        return
                    }
                    app.selection = nil
                    NotificationCenter.default.post(
                        name: .pocketConversationsChanged, object: nil)
                }
                Button("Delete", role: .destructive) {
                    do {
                        try app.core.deleteConversation(id: conversationId)
                    } catch {
                        app.toast("Couldn't delete this chat: \(error.localizedDescription)")
                        return
                    }
                    app.forgetChatModel(conversationId)
                    app.selection = nil
                    NotificationCenter.default.post(
                        name: .pocketConversationsChanged, object: nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Chat actions")
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private func thinkingToggle(_ chat: ChatModel) -> some View {
        // UI-30: same on/off chip as the iPhone composer, so state reads at a
        // glance (and VoiceOver says "Thinking, on, toggle button").
        ThinkingToggleChip(
            isOn: Binding(
                get: { chat.thinkingEnabled },
                set: { chat.thinkingEnabled = $0 }
            )
        )
        .help(chat.thinkingEnabled
            ? "Thinking on — the model reasons before answering"
            : "Thinking off — the model answers directly")
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
                        Label(ModelNaming.short(entry.manifest.displayName), systemImage: "checkmark")
                    } else {
                        Text(ModelNaming.short(entry.manifest.displayName))
                    }
                }
            }
            Divider()
            Button("Browse models…") { app.selection = .models }
        } label: {
            HUDChip(text: modelName(chat), tint: PocketColor.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(chat.isStreaming)
        .accessibilityLabel("Model for this chat, \(modelName(chat))")
        .accessibilityHint("Choose a different model")
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
                            focusRequest += 1
                        }
                        .padding(.top, 80)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        let isLast = index == chat.messages.count - 1 && !chat.isStreaming
                        MessageRow(
                            message: message,
                            grouped: isGrouped(chat.messages, index),
                            isLast: isLast,
                            onRetry: isLast ? { chat.regenerate() } : nil,
                            onEdit: { text in
                                draft = text
                                focusRequest += 1
                            })
                        .id(message.id)
                    }
                    if chat.isStreaming {
                        StreamingRow(
                            text: chat.streamingText,
                            reasoning: chat.streamingReasoning,
                            steps: chat.streamingSteps)
                        .id("streaming")
                    }
                    if let error = chat.errorText {
                        ChatErrorRow(
                            message: error,
                            retry: { chat.regenerate() },
                            openModels: { app.reveal(.models) })
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
            // Open on the newest message, not the oldest. Without this the
            // first layout is top-anchored, the "tail" sentinel below is
            // off-screen, its onDisappear clears `pinnedToBottom`, and
            // follow() then refuses to catch up.
            .defaultScrollAnchor(.bottom)
            // Only follow the stream while the reader is already at the tail;
            // yanking the view down while they read back is the worst thing a
            // transcript can do.
            .onChange(of: chat.messages.count) { _, _ in follow(proxy) }
            .onChange(of: chat.streamingText) { _, _ in follow(proxy) }
            .onChange(of: scrollActivity.isScrolling) { _, scrolling in
                // Catch up once they stop, if they ended at the tail.
                if !scrolling, pinnedToBottom { scroll(proxy) }
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

    /// Follows the tail only while the reader is there AND not mid-gesture.
    private func follow(_ proxy: ScrollViewProxy) {
        guard pinnedToBottom, !scrollActivity.isScrolling else { return }
        scroll(proxy)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("tail", anchor: .bottom)
        }
    }

    // MARK: - Tool approval

    /// AGT-13: the "Run this?" card (or "Running code…" with Stop) for this
    /// chat. The card's buttons are the only way an answer reaches Core.
    @ViewBuilder
    private var toolApprovalArea: some View {
        let approvals = app.tools.approvals
        if let request = approvals.request(for: conversationId) {
            RunCodeCard(
                language: "JavaScript", place: "this Mac", code: request.code,
                onRun: { code, always in
                    approvals.answer(request.id, code == request.code ? .run : .runEdited(code: code), alwaysAllow: always)
                },
                onDeny: { approvals.answer(request.id, .deny) }
            )
            .padding(.horizontal, PocketSpacing.gutterMac)
            .padding(.vertical, PocketSpacing.s8)
            .id(request.id)
        } else if approvals.running.contains(conversationId) {
            RunningCodeRow { app.core.cancelConversation(id: conversationId) }
                .padding(.horizontal, PocketSpacing.gutterMac)
                .padding(.vertical, PocketSpacing.s8)
        }
    }

    // MARK: - Composer

    private func composer(_ chat: ChatModel) -> some View {
        VStack(spacing: 0) {
            HUDRule()
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                if let attachmentRefusal {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(PocketColor.statusWarn)
                            .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                                Text(url.lastPathComponent).lineLimit(1)
                                    .accessibilityLabel("Attachment \(url.lastPathComponent)")
                                Button {
                                    attachments.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove attachment \(url.lastPathComponent)")
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
                        focusRequest: focusRequest,
                        onSubmit: { submit(chat) },
                        onEscape: { escape(chat) },
                        onRecall: { chat.messages.last(where: \.isUser)?.plainText }
                    )
                    .frame(minHeight: 22)
                    .padding(.horizontal, PocketSpacing.s12)
                    .padding(.vertical, PocketSpacing.s8)
                    .hudPanel(PocketColor.bgCanvas)
                    if chat.isStreaming {
                        // Same 26 pt circle as Send, so the swap reads as one
                        // control changing state rather than a bare glyph.
                        Button {
                            chat.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.statusBad)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(PocketColor.statusBad.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop generating")
                        .help("Stop generating (esc)")
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
                        .disabled(!canSend)
                        // Plain buttons don't dim when disabled; a live-looking
                        // Send that does nothing reads as broken.
                        .opacity(canSend ? 1 : 0.4)
                        .accessibilityLabel("Send message")
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
                    .accessibilityLabel("Attach an image")
                    .accessibilityHint(attachmentsAllowed(chat) ? "" : visionWarning(chat))
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
                    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                    .help(dictation.isRecording ? "Stop dictation" : "Dictate")
                    if dictation.permissionDenied {
                        HUDLabel("mic access denied", tint: PocketColor.statusBad)
                    } else if chat.isStreaming {
                        HUDLabel("esc stop")
                    } else {
                        HUDLabel(draft.isEmpty
                            ? "⏎ send · ⇧⏎ newline · ↑ last message"
                            : "⏎ send · ⇧⏎ newline")
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

    /// Newline-only drafts count as empty — `ChatModel.send` refuses them.
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Esc stops this chat's reply, else ends dictation; otherwise AppKit's
    /// own Esc handling runs.
    private func escape(_ chat: ChatModel) -> Bool {
        if chat.isStreaming {
            chat.stop()
            return true
        }
        if dictation.isRecording {
            dictation.stop()
            return true
        }
        return false
    }

    private func submit(_ chat: ChatModel) {
        dictation.stop()
        let text = draft
        let files = attachments
        guard canSend else { return }
        // Clear only once the turn is actually under way. Clearing first threw
        // away what was typed whenever `send` refused it — no model installed,
        // or a reply still arriving.
        guard chat.send(text, attachments: files) else { return }
        draft = ""
        attachments = []
        // Sending while scrolled back left your own message off-screen and
        // the reply arriving unseen; a send always returns to the tail.
        pinnedToBottom = true
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
            // A toast like Archive/Delete failures; the old inline line
            // under the composer never went away.
            app.toast("Couldn't save the transcript: \(error.localizedDescription)")
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
    @Environment(AppModel.self) private var app
    let onSuggestion: (String) -> Void

    private let suggestions = [
        "Explain this error message",
        "Summarise the text I paste next",
        "Draft a commit message for these changes",
    ]

    var body: some View {
        VStack(spacing: PocketSpacing.s12) {
            PocketMarkView(state: .idle, size: 40)
                .accessibilityHidden(true)
            if needsModel {
                // Skipped onboarding: say so up front instead of letting the
                // first send fail with "no model installed".
                Text("Get a model to start chatting")
                    .font(.pocket(.title))
                    .accessibilityAddTraits(.isHeader)
                Text("Models run on this Mac. One download and you can chat offline.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                Button("Browse models") { app.reveal(.models) }
                    .buttonStyle(.hudProminent)
                    .padding(.top, PocketSpacing.s4)
            } else {
                Text("Ask anything — it runs on this Mac")
                    .font(.pocket(.title))
                    .accessibilityAddTraits(.isHeader)
                Text("No account, no cloud. Your chats never leave this machine.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                suggestionChips
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var needsModel: Bool {
        app.currentModelId != AppModel.appleIntelligenceId && app.installedChatModels().isEmpty
    }

    private var suggestionChips: some View {
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
}
