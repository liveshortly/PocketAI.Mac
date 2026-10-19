import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PocketKit
import PocketUI

/// MAC-03: Chats and chat detail (M-CHAT).
/// Award-winning macOS native chat experience:
/// - Refined grouped list with relative timestamps, hover actions, and search
/// - Centered reading column (max 740 pt) with generous line height and markdown craft
/// - Collapsible reasoning thought disclosures, code blocks with copy affordance
/// - Streaming cursor animation and live generation status
/// - Floating material composer with multiline expansion and drag-and-drop file attachment
/// - Integrated right-hand Inspector (⌥⌘I) for model, system prompt, and stats
struct MacChatsView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var selectedId: String?
    @State private var hoveredConversationId: String?

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
            // Left: Conversations List Column
            VStack(spacing: 0) {
                // Header & Search
                VStack(spacing: PocketSpacing.s8) {
                    HStack {
                        Text("Chats")
                            .font(.pocket(.title))
                            .fontWeight(.semibold)

                        Spacer()

                        Button {
                            newChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(PocketColor.accent)
                                .padding(6)
                                .background(PocketColor.accentSoft)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("New Chat (⌘N)")
                    }
                    .padding(.horizontal, PocketSpacing.s12)
                    .padding(.top, PocketSpacing.s12)

                    // Capsule search field
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PocketColor.textTertiary)

                        TextField("Search chats…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.pocket(.callout))

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(PocketColor.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, PocketSpacing.s8)
                    .padding(.vertical, 6)
                    .background(PocketColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(PocketColor.lineHairline, lineWidth: 0.5)
                    )
                    .padding(.horizontal, PocketSpacing.s12)
                    .padding(.bottom, PocketSpacing.s4)
                }

                Divider()

                // List of conversations
                if conversations.isEmpty {
                    VStack(spacing: PocketSpacing.s12) {
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 32))
                            .foregroundStyle(PocketColor.textTertiary)
                        Text("No chats yet")
                            .font(.pocket(.body))
                            .foregroundStyle(PocketColor.textSecondary)
                        Button("Start a chat") {
                            newChat()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketColor.accent)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(selection: $selectedId) {
                        ForEach(groupedConversations, id: \.title) { group in
                            Section {
                                ForEach(group.items, id: \.id) { conv in
                                    conversationRow(conv)
                                        .tag(conv.id)
                                }
                            } header: {
                                Text(group.title.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(PocketColor.textTertiary)
                                    .padding(.top, PocketSpacing.s4)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 320)
            .background(PocketColor.bgCanvas)

            // Right: Conversation Detail Column
            if let selectedId {
                MacChatDetailView(conversationId: selectedId, onNewChat: { newChat() })
                    .id(selectedId)
            } else {
                EmptyState(
                    title: "Start a chat",
                    suggestions: [
                        "Explain this Rust borrow checker error",
                        "Summarize this quarterly report table",
                        "Why is my SwiftUI view re-rendering?",
                        "Draft a reply to this email"
                    ],
                    onTapSuggestion: { suggestion in newChat(firstMessage: suggestion) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PocketColor.bgSurface)
            }
        }
        .inspector(isPresented: Binding(
            get: { model.showChatInspector && selectedId != nil },
            set: { model.showChatInspector = $0 }
        )) {
            if let selectedId {
                MacChatInspectorView(conversationId: selectedId, onReload: { reload() })
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 310, max: 380)
        .task {
            reload()
            if selectedId == nil, let first = conversations.first {
                selectedId = first.id
            }
        }
        .onChange(of: searchText) { reload() }
        .onChange(of: model.pendingCommand) { _, command in
            switch command {
            case .newChat:
                newChat()
                model.pendingCommand = nil
            case .openConversation(let id):
                selectedId = id
                model.pendingCommand = nil
            case .focusComposer, .stopGeneration, .openTab, .toggleInspector, .none:
                break
            }
        }
    }

    @ViewBuilder
    private func conversationRow(_ conv: ConversationSummary) -> some View {
        let isSelected = selectedId == conv.id
        let isHovered = hoveredConversationId == conv.id
        let relativeTime = Self.relativeFormatter.localizedString(
            for: Date(timeIntervalSince1970: Double(conv.updatedAt) / 1000),
            relativeTo: Date()
        )

        HStack(alignment: .top, spacing: PocketSpacing.s8) {
            VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                Text(conv.title ?? "New chat")
                    .font(.pocket(.headline))
                    .foregroundStyle(isSelected ? PocketColor.textPrimary : PocketColor.textPrimary)
                    .lineLimit(1)

                Text(relativeTime)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }

            Spacer()

            if isHovered {
                HStack(spacing: PocketSpacing.s4) {
                    Button {
                        archive(conv)
                    } label: {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Archive")

                    Button(role: .destructive) {
                        delete(conv)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(PocketColor.statusBad)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
        }
        .padding(.vertical, PocketSpacing.s4)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredConversationId = hovering ? conv.id : nil
        }
        .contextMenu {
            Button("Archive") { archive(conv) }
            Divider()
            Button("Delete", role: .destructive) { delete(conv) }
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
        if selectedId == conversation.id {
            selectedId = conversations.first(where: { $0.id != conversation.id })?.id
        }
        reload()
    }

    private func archive(_ conversation: ConversationSummary) {
        try? model.core.archiveConversation(id: conversation.id, archived: true)
        if selectedId == conversation.id {
            selectedId = conversations.first(where: { $0.id != conversation.id })?.id
        }
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
    let onNewChat: () -> Void

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
    @State private var hoveredMessageId: String?
    @State private var copiedMessageId: String?
    @State private var isDropTargetActive = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            PocketColor.bgSurface
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Messages Scroll Area
                if messages.isEmpty && !isGenerating {
                    emptyConversationState
                } else {
                    messagesScrollView
                }

                // Bottom Composer and Pulse
                composerSection
            }

            if isDropTargetActive {
                dropOverlay
            }
        }
        .navigationTitle("")
        .dropDestination(for: URL.self) { urls, _ in
            isDropTargetActive = false
            handleDroppedURLs(urls)
            return true
        } isTargeted: { targeted in
            isDropTargetActive = targeted
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
            case .newChat, .openConversation, .openTab, .toggleInspector, .none:
                break
            }
        }
    }

    private var emptyConversationState: some View {
        ScrollView {
            VStack(spacing: PocketSpacing.s24) {
                Spacer(minLength: 60)

                PocketMarkView(state: .idle, size: 56)

                VStack(spacing: PocketSpacing.s4) {
                    Text("How can I help you today?")
                        .font(.pocket(.title))
                        .fontWeight(.semibold)
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("Running locally with \(model.currentModelDisplayName)")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                // Suggestion Cards
                VStack(spacing: PocketSpacing.s8) {
                    suggestionCard(
                        icon: "curlybraces",
                        title: "Explain Rust Borrow Checker",
                        subtitle: "Understand lifetime syntax and ownership principles",
                        prompt: "Explain this Rust borrow checker error: cannot borrow `x` as mutable more than once at a time."
                    )
                    suggestionCard(
                        icon: "doc.text.magnifyingglass",
                        title: "Summarize a Report",
                        subtitle: "Extract executive summary and actionable takeaways",
                        prompt: "Summarize this quarterly financial report and highlight the key revenue drivers."
                    )
                    suggestionCard(
                        icon: "swift",
                        title: "Debug SwiftUI Performance",
                        subtitle: "Diagnose unnecessary view redraws and state bugs",
                        prompt: "Why is my SwiftUI view body re-evaluating on unrelated state changes?"
                    )
                    suggestionCard(
                        icon: "envelope",
                        title: "Draft an Email Reply",
                        subtitle: "Polite, concise, and professional tone",
                        prompt: "Draft a polite and concise response declining a vendor proposal while keeping the relationship open."
                    )
                }
                .frame(maxWidth: 580)
                .padding(.top, PocketSpacing.s8)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, PocketSpacing.gutterMac)
            .frame(maxWidth: .infinity)
        }
    }

    private func suggestionCard(icon: String, title: String, subtitle: String, prompt: String) -> some View {
        Button {
            composerText = prompt
            send()
        } label: {
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PocketColor.accent)
                    .frame(width: 32, height: 32)
                    .background(PocketColor.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text(subtitle)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PocketSpacing.s24) {
                    ForEach(messages, id: \.id) { message in
                        messageBlock(message)
                            .id(message.id)
                    }

                    if let errorText {
                        HStack(spacing: PocketSpacing.s8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(PocketColor.statusBad)
                            Text(errorText)
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.statusBad)
                        }
                        .padding(PocketSpacing.s12)
                        .background(PocketColor.statusBad.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, PocketSpacing.gutterMac)
                .padding(.vertical, PocketSpacing.s20)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBlock(_ message: Message) -> some View {
        let isHovered = hoveredMessageId == message.id
        let text = message.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()

        if message.role == "user" {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: PocketSpacing.s4) {
                    UserBubble(text: text)
                        .contextMenu {
                            Button("Copy Prompt") {
                                copyToPasteboard(text)
                            }
                            Button("Retry with This Message") {
                                composerText = text
                                send()
                            }
                        }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                // Assistant header
                HStack(spacing: PocketSpacing.s8) {
                    PocketMarkView(state: message.status == .streaming ? .working(tokPerSec: 28) : .idle, size: 18)

                    Text("PocketAI")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)

                    Text(formatMessageTime(message.createdAt))
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)

                    Spacer()

                    if message.status == .streaming {
                        HStack(spacing: PocketSpacing.s4) {
                            Text("Generating")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.accent)
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }

                // Reasoning thought if present
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup {
                        Text(reasoning)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                            .padding(PocketSpacing.s8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack(spacing: PocketSpacing.s4) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 11))
                            Text("Thinking process")
                                .font(.pocket(.caption))
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(PocketColor.textSecondary)
                    }
                    .padding(PocketSpacing.s8)
                    .background(PocketColor.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                // Assistant message body
                MessageView(
                    text: text,
                    reasoning: nil,
                    onCopy: { copyToPasteboard(text) },
                    onRetry: { retryLastTurn() },
                    onSpeak: { speak(text) }
                )

                // Hover Actions Row
                if isHovered && message.status != .streaming {
                    HStack(spacing: PocketSpacing.s8) {
                        Button {
                            copyToPasteboard(text)
                            copiedMessageId = message.id
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                if copiedMessageId == message.id { copiedMessageId = nil }
                            }
                        } label: {
                            Label(copiedMessageId == message.id ? "Copied" : "Copy", systemImage: copiedMessageId == message.id ? "checkmark" : "doc.on.doc")
                                .font(.pocket(.caption))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            retryLastTurn()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.pocket(.caption))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            speak(text)
                        } label: {
                            Label("Speak", systemImage: "speaker.wave.2")
                                .font(.pocket(.caption))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        if let stats = message.stats {
                            Text("\(stats.decodeTps) tok/s · \(stats.completionTokens) tokens")
                                .font(.pocket(.metric))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                    }
                    .padding(.top, PocketSpacing.s4)
                    .transition(.opacity)
                }
            }
            .padding(.vertical, PocketSpacing.s4)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    hoveredMessageId = hovering ? message.id : nil
                }
            }
        }
    }

    private var composerSection: some View {
        VStack(spacing: 0) {
            // Pulse Status Bar when generating
            if isGenerating {
                HStack(spacing: PocketSpacing.s8) {
                    PocketMarkView(state: .working(tokPerSec: 28), size: 14)
                    Text("Generating with \(model.currentModelDisplayName)…")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.accent)
                    Spacer()
                    Text("28 tok/s")
                        .font(.pocket(.metric))
                        .foregroundStyle(PocketColor.accent)
                }
                .padding(.horizontal, PocketSpacing.s16)
                .padding(.vertical, 6)
                .frame(maxWidth: 740)
            }

            // Floating Composer Capsule
            HStack(alignment: .bottom, spacing: PocketSpacing.s8) {
                // Attach menu
                Menu {
                    Button {
                        handleAttachment(.file)
                    } label: {
                        Label("Attach File…", systemImage: "doc")
                    }

                    Button {
                        handleAttachment(.photo)
                    } label: {
                        Label("Attach Photo…", systemImage: "photo")
                    }

                    Button {
                        model.selectedTab = .projects
                    } label: {
                        Label("Reference Project…", systemImage: "folder")
                    }

                    Divider()

                    Button {
                        openWindow(id: "image-generation")
                    } label: {
                        Label("Generate Image…", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PocketColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(PocketColor.bgRaised)
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 32)
                .padding(.bottom, 4)

                // Multiline text input
                TextField("Ask PocketAI anything… (⌘L)", text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.pocket(.body))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.vertical, 8)
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) {
                            send()
                        }
                    }

                // Action buttons: Mic or Send/Stop
                if isGenerating {
                    Button {
                        stopGeneration()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(PocketColor.accentOnAccent)
                            .frame(width: 32, height: 32)
                            .background(PocketColor.accent)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .help("Stop Generation (⌘.)")
                } else if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        toggleVoiceDictation()
                    } label: {
                        Image(systemName: isDictating ? "waveform" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isDictating ? PocketColor.accent : PocketColor.textTertiary)
                            .frame(width: 32, height: 32)
                            .background(PocketColor.bgRaised)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .help("Voice Input")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(PocketColor.accentOnAccent)
                            .frame(width: 32, height: 32)
                            .background(PocketColor.accent)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                    .help("Send Message (Return)")
                }
            }
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, PocketSpacing.s4)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(PocketColor.bgRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
            .frame(maxWidth: 740)
            .padding(.horizontal, PocketSpacing.gutterMac)
            .padding(.bottom, PocketSpacing.s16)
        }
        .frame(maxWidth: .infinity)
    }

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            VStack(spacing: PocketSpacing.s12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 44))
                    .foregroundStyle(PocketColor.accent)
                Text("Drop files or images to attach")
                    .font(.pocket(.title))
                    .fontWeight(.semibold)
                    .foregroundStyle(PocketColor.textPrimary)
            }
            .padding(PocketSpacing.s32)
            .background(PocketColor.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PocketColor.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            )
        }
    }

    private func reload() {
        messages = model.core.messages(conversationId: conversationId)
        title = model.core.conversations(query: ConversationQuery(search: nil, archived: nil, limit: 0, offset: 0))
            .first { $0.id == conversationId }?.title
    }

    private func send() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerText = ""
        errorText = nil
        isGenerating = true
        sendTask = Task {
            var partialText = ""
            do {
                for try await event in model.core.sendMessage(conversationId: conversationId, input: UserInput(parts: [.text(text: trimmed)])) {
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
        composerFocused = true
        isDictating.toggle()
        if isDictating {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private func formatMessageTime(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
