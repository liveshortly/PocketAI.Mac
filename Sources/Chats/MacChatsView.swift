import SwiftUI
import AppKit
import PocketLiveShortly
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
    /// A LiveShortly session shown in the detail pane (mutually exclusive
    /// with a local conversation selection).
    @State private var lsSessionId: String?
    @State private var lsNewSession = false

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

                        Menu {
                            Button {
                                newChat()
                            } label: {
                                Label("New chat", systemImage: "square.and.pencil")
                            }
                            if AppleFoundationModelsEngine.isAvailable {
                                Button {
                                    newChat(modelId: AppleFoundationModelsEngine.modelId)
                                } label: {
                                    Label("Apple Intelligence", systemImage: "apple.logo")
                                }
                            }
                            if model.liveShortly.isConnected {
                                Button {
                                    lsNewSession = true
                                } label: {
                                    Label("LiveShortly session…", systemImage: "dot.radiowaves.left.and.right")
                                }
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(PocketColor.accent)
                                .padding(6)
                                .background(PocketColor.accentSoft)
                                .clipShape(Circle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
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

                // List of conversations (a connected LiveShortly account keeps
                // the List alive even with zero local chats — its sessions are
                // content too).
                if conversations.isEmpty && !model.liveShortly.isConnected {
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
                        LSSessionsSection(
                            account: model.liveShortly,
                            onOpen: { id in
                                lsSessionId = id
                                selectedId = nil
                            },
                            onNewSession: { lsNewSession = true })
                        ForEach(groupedConversations, id: \.title) { group in
                            Section {
                                ForEach(group.items, id: \.id) { conv in
                                    conversationRow(conv)
                                        .tag(conv.id)
                                }
                            } header: {
                                Text(group.title.uppercased())
                                    .font(.pocket(.caption))
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
            if let lsSessionId, selectedId == nil {
                NavigationStack {
                    LSSessionView(account: model.liveShortly, sessionID: lsSessionId)
                }
                .id(lsSessionId)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PocketColor.bgSurface)
            } else if let selectedId {
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
        .onChange(of: selectedId) {
            if selectedId != nil { lsSessionId = nil }
        }
        .sheet(isPresented: $lsNewSession) {
            LSNewSessionSheet(account: model.liveShortly)
        }
        .inspector(isPresented: Binding(
            get: { model.showChatInspector },
            set: { model.showChatInspector = $0 }
        )) {
            if let selectedId {
                MacChatInspectorView(conversationId: selectedId, onReload: { reload() })
            } else {
                ContentUnavailableView(
                    "No conversation",
                    systemImage: "sidebar.right",
                    description: Text("Select a chat to see its details.")
                )
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 310, max: 380)
        .task {
            reload()
            if selectedId == nil, let first = conversations.first {
                selectedId = first.id
            }
            // Consume a command issued while this tab was hidden (⌘N from
            // another tab sets pendingCommand before this view exists; an
            // onChange alone never fires for it).
            consumeCommand(model.pendingCommand)
        }
        .onChange(of: searchText) { reload() }
        .onChange(of: model.pendingCommand) { _, command in
            consumeCommand(command)
        }
    }

    private func consumeCommand(_ command: AppModel.Command?) {
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

    private func newChat(firstMessage: String? = nil, modelId: String? = nil) {
        guard let conversation = try? model.core.createConversation(NewConversation(title: nil, projectId: nil, modelId: modelId)) else { return }
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
    /// Identifies the stream whose cleanup may run; a Stop + immediate Retry
    /// must not let the old stream's teardown clobber the new one.
    @State private var activeStreamId = UUID()
    /// This conversation's bound model, loaded by ID in reload().
    @State private var conversationModelId: String?
    /// Catalog snapshot refreshed in reload() — never call core.catalog() per
    /// render (it re-parses the bundled JSON).
    @State private var cachedCatalog: [CatalogEntry] = []
    @State private var isDictating = false
    @State private var isDropTargetActive = false
    /// Auto-scroll only follows new tokens while the user is pinned to the
    /// bottom; scrolling up reveals a jump-to-latest control instead.
    @State private var isPinnedToBottom = true
    @State private var showJumpToBottom = false
    /// Bumped on every streamed delta so the pinned auto-scroll tracks tokens
    /// (the message count doesn't change while a single reply streams).
    @State private var streamTick = 0
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
            consumeCommand(model.pendingCommand)
            if let firstMessage = pendingFirstMessages.removeValue(forKey: conversationId) {
                composerText = firstMessage
                send()
            }
        }
        .onChange(of: model.pendingCommand) { _, command in
            consumeCommand(command)
        }
        .onDisappear {
            // Switching chats mid-reply (.id(selectedId) tears this view down):
            // stop the engine and the stream task instead of leaking them.
            if isGenerating {
                model.core.cancelConversation(id: conversationId)
                isGenerating = false
            }
            sendTask?.cancel()
            sendTask = nil
        }
    }

    private func consumeCommand(_ command: AppModel.Command?) {
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let grouped = index > 0 && messages[index - 1].role == message.role
                        messageBlock(message, isGrouped: grouped)
                            // Consecutive same-role messages sit tight; a new
                            // speaker gets a clear gap between groups.
                            .padding(.top, index == 0 ? 0 : (grouped ? PocketSpacing.s8 : PocketSpacing.s24))
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
                        .padding(.top, PocketSpacing.s24)
                    }

                    // Bottom anchor for smooth scroll-to-latest.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, PocketSpacing.gutterMac)
                .padding(.vertical, PocketSpacing.s20)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                // Near the bottom (within one line's slack) counts as pinned.
                geo.contentOffset.y >= geo.contentSize.height - geo.containerSize.height - 40
            } action: { _, nearBottom in
                isPinnedToBottom = nearBottom
                withAnimation(.easeInOut(duration: 0.15)) { showJumpToBottom = !nearBottom }
            }
            .onChange(of: messages.count) {
                if isPinnedToBottom {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            .onChange(of: streamTick) {
                // No animation per-token: jumps look smoother than spring stacking.
                if isPinnedToBottom { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if showJumpToBottom {
                    Button {
                        isPinnedToBottom = true
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PocketColor.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(PocketColor.bgRaised)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(PocketColor.lineHairline, lineWidth: 0.8))
                            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, PocketSpacing.s8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .help("Scroll to latest")
                }
            }
        }
    }

    private static let bottomAnchor = "bottom-anchor"

    @ViewBuilder
    private func messageBlock(_ message: Message, isGrouped: Bool) -> some View {
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
                            Button("Regenerate Reply") {
                                regenerateLastTurn()
                            }
                        }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                // Assistant header — hidden for a message grouped under the
                // previous assistant turn so a reply reads as one block.
                if !isGrouped {
                    HStack(spacing: PocketSpacing.s8) {
                        PocketMarkView(state: message.status == .streaming ? .working(tokPerSec: model.activeTokPerSec > 0 ? Double(model.activeTokPerSec) : nil) : .idle, size: 18)

                        Text("PocketAI")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)

                        Text(formatMessageTime(message.createdAt))
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)

                        Spacer()

                        switch message.status {
                        case .streaming:
                            HStack(spacing: PocketSpacing.s4) {
                                Text("Generating")
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.accent)
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        case .cancelled:
                            Text("Stopped")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                        case .error:
                            Text("Failed")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.statusBad)
                        case .done:
                            EmptyView()
                        }
                    }
                }

                // Assistant message body + a blinking caret while streaming.
                // MessageView owns the reasoning ("Thinking…"/"Thought for a
                // moment") disclosure and the copy/retry/speak + stats footer
                // so the affordances stay consistent app-wide.
                HStack(alignment: .bottom, spacing: PocketSpacing.s4) {
                    MessageView(
                        text: text,
                        reasoning: message.reasoning,
                        isThinking: message.status == .streaming,
                        statsText: statsText(message),
                        onCopy: { copyToPasteboard(text) },
                        onRetry: { regenerateLastTurn() },
                        onSpeak: { speak(text) }
                    )
                    if message.status == .streaming {
                        StreamingCaret()
                    }
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func statsText(_ message: Message) -> String? {
        guard let stats = message.stats else { return nil }
        return "\(stats.decodeTps) tok/s · \(stats.completionTokens) tokens"
    }

    private var composerSection: some View {
        VStack(spacing: 0) {
            // Pulse Status Bar when generating
            if isGenerating {
                HStack(spacing: PocketSpacing.s8) {
                    PocketMarkView(state: .working(tokPerSec: model.activeTokPerSec > 0 ? Double(model.activeTokPerSec) : nil), size: 14)
                    Text("Generating with \(chatModelDisplayName)…")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.accent)
                    Spacer()
                    if model.activeTokPerSec > 0 {
                        Text("\(model.activeTokPerSec) tok/s")
                            .font(.pocket(.metric))
                            .foregroundStyle(PocketColor.accent)
                    }
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
        cachedCatalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        // Resolve directly by ID — never page-scan conversations(), which
        // misses older chats past the default window.
        if let convo = model.core.conversation(id: conversationId) {
            title = convo.title
            conversationModelId = convo.modelId
        }
    }

    /// The chat's own bound model name; the global default only while unbound.
    private var chatModelDisplayName: String {
        guard let id = conversationModelId,
              let entry = cachedCatalog.first(where: { $0.manifest.id == id }) else {
            return model.currentModelDisplayName
        }
        return entry.manifest.displayName
    }

    /// Is this model actually runnable right now? Used to self-heal a
    /// conversation bound to a since-deleted model.
    private func isModelUsable(_ id: String) -> Bool {
        if id.hasPrefix("mac:") { return true }
        if id == AppleFoundationModelsEngine.modelId { return AppleFoundationModelsEngine.isAvailable }
        return cachedCatalog.contains { $0.manifest.id == id && $0.state == .installed }
    }

    private func send() {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerText = ""
        errorText = nil
        isGenerating = true
        model.activeTokPerSec = 0
        let streamId = UUID()
        activeStreamId = streamId
        // Bind a model only when this conversation is unbound or its bound
        // model is no longer runnable — never overwrite a valid per-chat
        // choice with the global default on send.
        let boundUsable = conversationModelId.map(isModelUsable) ?? false
        if !boundUsable, isModelUsable(model.currentModelId) {
            try? model.core.setConversationModel(id: conversationId, modelId: model.currentModelId)
            conversationModelId = model.currentModelId
        }
        // Instant local echo: the user's bubble appears the moment they hit
        // send — never after model load. The .done reload replaces it with the
        // persisted row.
        messages.removeAll { $0.id == Self.localEchoId }
        messages.append(Message(
            id: Self.localEchoId, conversationId: conversationId, role: "user",
            parts: [.text(text: trimmed)], reasoning: nil, stats: nil, modelId: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000), status: .done
        ))
        // And an empty streaming bubble right away, so the reply visibly
        // "starts" while the model is still loading.
        upsertStreamingPlaceholder(text: "")
        sendTask = Task {
            await consumeStream(
                model.core.sendMessage(conversationId: conversationId, input: UserInput(parts: [.text(text: trimmed)])),
                streamId: streamId
            )
        }
    }

    private static let localEchoId = "local-echo-user"

    /// Shared consumption for a send or a regenerate stream.
    @MainActor
    private func consumeStream(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>, streamId: UUID) async {
        var partialText = ""
        var partialReasoning = ""
        let start = Date()
        var charCount = 0
        do {
            for try await event in stream {
                switch event {
                case .delta(let delta):
                    partialText += delta.text
                    partialReasoning += delta.reasoning
                    charCount += delta.text.count + delta.reasoning.count
                    // Honest instruments: live rate from the real stream
                    // (~4 chars/token); exact tok/s replaces it on .done.
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed > 0.2 { model.activeTokPerSec = Int((Double(charCount) / 4.0) / elapsed) }
                    upsertStreamingPlaceholder(text: partialText, reasoning: partialReasoning)
                case .done(let final):
                    if let tps = final.stats?.decodeTps { model.activeTokPerSec = Int(tps) }
                    reload()
                }
            }
        } catch {
            if activeStreamId == streamId { errorText = friendlyError(error) }
        }
        // Only the stream that still owns the screen may clean up — a Stop
        // followed by an immediate Retry must not be clobbered by the old
        // stream's late teardown.
        guard activeStreamId == streamId else { return }
        isGenerating = false
        reload()
    }

    /// Actionable guidance for the most common first-run failure (no model),
    /// instead of a generic "Something went wrong".
    private func friendlyError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("no model") || desc.contains("not installed") || desc.contains("not exist")
            || desc.contains("config.json") || desc.contains("no engine") || desc.contains("notfound") {
            return "No model is ready yet. Download one in Models to start chatting on this Mac."
        }
        if desc.contains("not entitled") || desc.contains("notentitled") {
            return "This needs PocketAI Pro. Unlock it in Settings."
        }
        return "Something went wrong: \(error.localizedDescription)"
    }

    private func stopGeneration() {
        // Reach the engine so a synchronous generate actually stops, then tear
        // down the stream task.
        model.core.cancelConversation(id: conversationId)
        sendTask?.cancel()
        sendTask = nil
        activeStreamId = UUID() // orphan the old stream's cleanup
        isGenerating = false
        reload() // pick up the persisted .cancelled row, not a stuck "Generating" placeholder
        // The core persists the cancelled row when the engine actually stops,
        // which can land just after the immediate reload — refresh once more.
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !isGenerating { reload() }
        }
    }

    /// Regenerates the latest assistant reply: the core drops the failed or
    /// stopped attempt and re-runs from existing history — never a duplicated
    /// user message.
    private func regenerateLastTurn() {
        guard !isGenerating else { return }
        guard messages.contains(where: { $0.role == "user" }) else { return }
        errorText = nil
        isGenerating = true
        model.activeTokPerSec = 0
        let streamId = UUID()
        activeStreamId = streamId
        reload() // show the dropped assistant attempt disappearing
        upsertStreamingPlaceholder(text: "")
        sendTask = Task {
            await consumeStream(model.core.regenerate(conversationId: conversationId), streamId: streamId)
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

    private func upsertStreamingPlaceholder(text: String, reasoning: String = "") {
        let placeholderId = "streaming-placeholder"
        let message = Message(
            id: placeholderId, conversationId: conversationId, role: "assistant",
            parts: [.text(text: text)], reasoning: reasoning.isEmpty ? nil : reasoning,
            stats: nil, modelId: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000), status: .streaming
        )
        if let index = messages.firstIndex(where: { $0.id == placeholderId }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        streamTick &+= 1
    }

    private func formatMessageTime(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// A blinking block caret shown at the tail of a streaming reply. Pure
/// decoration tied to the live `.streaming` status — it carries no fabricated
/// progress; when the stream ends the caret is simply removed.
private struct StreamingCaret: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(PocketColor.accent)
            .frame(width: 2, height: 16)
            .opacity(on ? 1 : 0)
            .padding(.bottom, 3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}
