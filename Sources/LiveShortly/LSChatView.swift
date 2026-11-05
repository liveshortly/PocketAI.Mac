import AppKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// A LiveShortly session rendered in the app's own chat idiom: same status
/// strip, same transcript shapes, same composer as a local chat. Watching an
/// agent and talking to a model should not feel like two different products.
struct LSChatView: View {
    @Environment(AppModel.self) private var app
    @State private var session: LSSessionModel?
    @State private var draft = ""
    @State private var showRename = false
    /// The probe being reviewed, captured when the sheet opens.
    @State private var reviewing: LSEvent?
    @State private var dictation = Dictation()
    @State private var scrollActivity = ScrollActivity()
    @State private var pinnedToBottom = true
    @State private var showShare = false
    @State private var confirmEnd = false
    @State private var confirmDelete = false
    /// Counter, not a flag — see `ComposerTextView.focusRequest`.
    @State private var focusRequest = 0

    let sessionID: String

    var body: some View {
        VStack(spacing: 0) {
            if let session, session.loaded {
                statusStrip(session)
                HUDRule()
                transcript(session)
                if let probe = session.pendingProbe, session.canControl {
                    LSPermissionBar(
                        probe: probe,
                        toolCall: session.toolCall(before: probe),
                        onReview: { reviewing = probe },
                        onDecide: { await session.decide($0) })
                    .padding(.horizontal, PocketSpacing.s16)
                    .padding(.bottom, PocketSpacing.s8)
                }
                if session.canComment {
                    composer(session)
                } else {
                    endedFooter(session)
                }
            } else if app.liveShortly.client == nil {
                // UI-80: `.task` bails without a client, so this used to spin
                // on "Loading session…" forever when signed out.
                VStack(spacing: PocketSpacing.s8) {
                    PocketMarkView(state: .offline, size: 40)
                        .accessibilityHidden(true)
                    Text("LiveShortly isn't connected on this Mac")
                        .font(.pocket(.headline))
                    SettingsLink {
                        Text("Connect LiveShortly…")
                    }
                    .buttonStyle(.hud)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Same loading treatment as LSSessionView / Mac ChatView (UI-28/33).
                VStack(spacing: PocketSpacing.s8) {
                    PocketMarkView(state: .loading, size: 64)
                        .accessibilityHidden(true) // the adjacent text carries the status
                    Text("Loading session…")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        // Keyed on the client too, so connecting in Settings loads this
        // session without leaving and coming back (UI-80).
        .task(id: "\(sessionID)|\(app.liveShortly.client != nil)") {
            guard let client = app.liveShortly.client else { return }
            let model = LSSessionModel(
                sessionID: sessionID, client: client, myHandle: app.liveShortly.handle)
            session = model
            await model.open()
            focusRequest += 1
        }
        .onAppear { scrollActivity.start() }
        .onDisappear {
            dictation.stop()
            scrollActivity.stop()
            if let session {
                LSSeen.mark(
                    sessionID, max(session.detail?.eventCount ?? 0, session.events.count))
            }
            session?.stop()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { now in
            session?.expireTypers(now)
        }
        // A session ending and a permission landing both change what this
        // screen means without moving focus.
        .onChange(of: session?.isLive ?? false) { wasLive, live in
            if wasLive, !live {
                AccessibilityNotification.Announcement("Session ended").post()
            }
        }
        .onChange(of: session?.pendingProbe?.id) { _, probe in
            if probe != nil {
                AccessibilityNotification.Announcement(
                    "The agent is asking for permission").post()
            }
        }
        .onChange(of: app.commandSerial) { _, _ in
            // ⌘L is a global menu item; a session composer is still a composer.
            if app.pendingCommand == .focusComposer {
                focusRequest += 1
                app.clearCommand()
            }
        }
        .sheet(isPresented: $showRename) {
            if let session {
                RenameSheet(title: session.title) { session.rename($0) }
            }
        }
        .sheet(isPresented: $showShare) {
            if let session {
                LSShareSheet(
                    sessionID: sessionID,
                    detail: Binding(get: { session.detail }, set: { session.detail = $0 }))
                .environment(app)
            }
        }
        .sheet(item: $reviewing) { probe in
            LSProbeDetailView(
                probe: probe,
                toolCall: session?.toolCall(before: probe),
                onDecide: { decision in
                    guard let session else { return false }
                    return await session.decide(decision)
                })
        }
        .confirmationDialog(
            "End this session? The agent stops where it is.",
            isPresented: $confirmEnd, titleVisibility: .visible
        ) {
            Button("End session", role: .destructive) { session?.endSession() }
        }
        .confirmationDialog(
            "Delete this session permanently? This cannot be undone.",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete session", role: .destructive) {
                Task {
                    if await session?.delete() == true { app.selection = nil }
                }
            }
        }
    }

    // MARK: - Chrome

    private func statusStrip(_ session: LSSessionModel) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            // A button when it does something, plain text when it does not —
            // a tappable Text was mouse-only and silent to VoiceOver.
            if session.detail?.isOwner == true {
                Button { showRename = true } label: {
                    Text(session.title)
                        .font(.pocket(.headline))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Session title, \(session.title)")
                .accessibilityHint("Rename this session")
                .help("Rename this session")
            } else {
                Text(session.title)
                    .font(.pocket(.headline))
                    .lineLimit(1)
            }
            if session.isLive {
                HUDLiveBadge()
                if session.agentBusy {
                    HStack(spacing: PocketSpacing.s4) {
                        PocketMarkView(state: .thinking(tokPerSec: nil), size: 14)
                            .accessibilityHidden(true)
                        Text(session.activityLabel)
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Agent is \(session.activityLabel)")
                }
            } else {
                HUDChip(text: "ENDED")
            }
            if session.reconnecting {
                // Status, not failure: the stream comes back on its own (LSI-18).
                Text("Reconnecting…")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            if session.watchers > 1 {
                HUDLabel(String(localized: "\(session.watchers) watching"))
            }
            // Who can see this is worth knowing without opening a dialog.
            if let visibility = session.detail?.visibility, visibility != "private" {
                HUDChip(text: visibility.uppercased(), tint: PocketColor.accent)
                    .help("Anyone with the link can open this session")
            }
            if session.detail?.publishedAt != nil {
                HUDChip(text: "ON FEED", tint: PocketColor.accent)
            }
            if let chip = session.detail?.sharedChip {
                HUDChip(text: chip)
            }
            Spacer(minLength: 0)
            if let framework = session.detail?.framework, framework == "claude-code",
               session.isLive, session.canControl {
                Menu {
                    ForEach(LS.claudeModels, id: \.self) { model in
                        Button(model) { session.setModel(model) }
                    }
                } label: {
                    HUDChip(text: session.detail?.model ?? "model", tint: PocketColor.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Agent model, \(session.detail?.model ?? "default")")
                .accessibilityHint("Switch the agent's model")
            }
            if session.detail?.isOwner == true {
                Button {
                    showShare = true
                } label: {
                    Label("Share", systemImage: "person.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketColor.textTertiary)
                .help("Share this session")
            }
            Menu {
                if session.detail?.isOwner == true {
                    Button("Rename…") { showRename = true }
                }
                if let link = app.liveShortly.client?.sessionLink(sessionID) {
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    }
                }
                if session.detail?.isOwner == true {
                    Button("Share…") { showShare = true }
                    Divider()
                    if session.isLive {
                        Button("End session", role: .destructive) { confirmEnd = true }
                    }
                    Button("Delete session", role: .destructive) { confirmDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Session actions")
            .help("Session actions")
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private func transcript(_ session: LSSessionModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    if session.items.isEmpty, !session.accessLost {
                        emptyState(session)
                    }
                    ForEach(session.items) { item in
                        LSItemView(
                            item: item,
                            running: session.isLive && session.agentBusy
                                && item.id == session.items.last?.id,
                            myHandle: app.liveShortly.handle)
                    }
                    // A standing "working" row for the whole time the agent is
                    // busy. Hanging the indicator off the last tool run left a
                    // dead gap between sending and the agent's first step.
                    if session.isLive, session.agentBusy {
                        HStack(spacing: PocketSpacing.s8) {
                            HUDLabel("◆ assistant", tint: PocketColor.accent)
                            PocketMarkView(state: .thinking(tokPerSec: nil), size: 14)
                                .accessibilityHidden(true)
                            Text(session.activityLabel)
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("working")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Agent is \(session.activityLabel)")
                    }
                    if let error = session.errorText {
                        HStack(alignment: .top, spacing: PocketSpacing.s8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(PocketColor.statusWarn)
                                .accessibilityHidden(true)
                            Text(app.liveShortly.describeAccess(error))
                                .font(.pocket(.footnote))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Reconnect") {
                                Task { await session.open() }
                            }
                            .buttonStyle(.hud)
                        }
                        .padding(PocketSpacing.s12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hudPanel(PocketColor.statusWarn.opacity(0.10))
                    }
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
            .onChange(of: session.items.count) { _, _ in follow(proxy) }
            .onChange(of: session.agentBusy) { _, _ in follow(proxy) }
            // Open on the newest event, not the oldest — same reason as
            // Chat/ChatView.swift: a top-anchored first layout hides the
            // "tail" sentinel and clears `pinnedToBottom`.
            .defaultScrollAnchor(.bottom)
            .onChange(of: scrollActivity.isScrolling) { _, scrolling in
                if !scrolling, pinnedToBottom { scrollToTail(proxy) }
            }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom {
                    Button {
                        pinnedToBottom = true
                        scrollToTail(proxy)
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

    private func emptyState(_ session: LSSessionModel) -> some View {
        VStack(spacing: PocketSpacing.s12) {
            PocketMarkView(
                state: session.isLive ? .live : .offline, size: 40)
                .accessibilityHidden(true)
            Text(session.isLive ? "Session is live" : "No activity was recorded")
                .font(.pocket(.title))
            Text(
                session.isLive
                    ? "Say something below, or watch the agent start up."
                    : "This session ended without producing any events."
            )
            .font(.pocket(.footnote))
            .foregroundStyle(PocketColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func composer(_ session: LSSessionModel) -> some View {
        VStack(spacing: 0) {
            HUDRule()
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                if let typing = session.typingLine {
                    HUDLabel(typing)
                }
                HStack(alignment: .bottom, spacing: PocketSpacing.s8) {
                    ComposerTextView(
                        text: $draft,
                        placeholder: session.canControl
                            ? "Message this session…" : "Comment on this session…",
                        focusRequest: focusRequest,
                        onSubmit: { send(session) },
                        onEdit: { session.noteTyping() }
                    )
                    .frame(minHeight: 22)
                    .padding(.horizontal, PocketSpacing.s12)
                    .padding(.vertical, PocketSpacing.s8)
                    .hudPanel(PocketColor.bgCanvas)

                    Button {
                        dictation.toggle(base: draft) { draft = $0 }
                    } label: {
                        Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                            .foregroundStyle(
                                dictation.isRecording
                                    ? PocketColor.statusBad : PocketColor.textTertiary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                    .help(dictation.isRecording ? "Stop dictation" : "Dictate")

                    Button {
                        send(session)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.accentOnAccent)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(PocketColor.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send to this session")
                    .help("Send (⏎)")
                }
                HUDLabel("⏎ send · ⇧⏎ newline · goes to the agent as a viewer message")
            }
            .padding(PocketSpacing.s12)
        }
        .background(PocketColor.bgSurface)
    }

    private func endedFooter(_ session: LSSessionModel) -> some View {
        HStack {
            Text(session.isLive ? "Read only — you can watch but not comment."
                 : "Session ended — read only.")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PocketSpacing.s12)
        .background(PocketColor.bgSurface)
    }

    /// Follow the tail only when the reader is there and not mid-gesture.
    private func follow(_ proxy: ScrollViewProxy) {
        guard pinnedToBottom, !scrollActivity.isScrolling else { return }
        scrollToTail(proxy)
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("tail", anchor: .bottom) }
    }

    private func send(_ session: LSSessionModel) {
        dictation.stop()
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        session.send(text)
    }
}

/// One transcript row, matching the local chat's shapes: viewer messages as
/// right-aligned cards, agent prose full width, tool activity folded.
struct LSItemView: View {
    let item: LSItem
    let running: Bool
    var myHandle: String

    var body: some View {
        switch item.kind {
        case .day(let date):
            HStack(spacing: PocketSpacing.s8) {
                HUDRule()
                Text(date.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .fixedSize()
                HUDRule()
            }
        case .work(let run):
            LSWorkRun(run: run, running: running)
        case .single(let event):
            single(event)
        }
    }

    @ViewBuilder private func single(_ event: LSEvent) -> some View {
        switch event.eventType {
        case "prompt", "viewer_comment":
            let mine = event.payload["username"]?.stringValue == myHandle
            LSBubbleRow(event: event, viewer: event.eventType == "viewer_comment" && !mine,
                        grouped: item.grouped)
        case "response":
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                if !item.grouped {
                    HStack(spacing: PocketSpacing.s8) {
                        HUDLabel("◆ agent", tint: PocketColor.accent)
                        Text(event.ts.formatted(date: .omitted, time: .shortened))
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                }
                MarkdownText(lsBodyText(event))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Agent, \(event.ts.formatted(date: .omitted, time: .shortened)), "
                + lsBodyText(event))
        case "input_requested", "viewer_decision":
            Text(systemLine(event))
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        default:
            EmptyView()
        }
    }

    private func systemLine(_ event: LSEvent) -> String {
        switch event.eventType {
        case "input_requested":
            let kind = event.payload["kind"]?.stringValue == "permission" ? "permission" : "input"
            return "awaiting \(kind)"
        case "viewer_decision":
            let who = event.payload["username"]?.stringValue ?? "viewer"
            let what = event.payload["decision"]?.stringValue == "deny" ? "denied" : "allowed"
            return "\(who) \(what) the request"
        default:
            return event.eventType
        }
    }
}

struct LSBubbleRow: View {
    let event: LSEvent
    let viewer: Bool
    var grouped = false

    var body: some View {
        VStack(alignment: .trailing, spacing: PocketSpacing.s4) {
            if !grouped {
                HStack(spacing: PocketSpacing.s8) {
                    HUDLabel(
                        lsHandleText(event),
                        tint: viewer ? PocketColor.statusInfo : PocketColor.accent)
                    Text(event.ts.formatted(date: .omitted, time: .shortened))
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            Text(lsBodyText(event))
                .font(.pocket(.body))
                .textSelection(.enabled)
                .padding(.horizontal, PocketSpacing.s12)
                .padding(.vertical, PocketSpacing.s8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(viewer
                            ? PocketColor.statusInfo.opacity(0.12)
                            : PocketColor.accent.opacity(0.12)))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(lsHandleText(event)), \(event.ts.formatted(date: .omitted, time: .shortened)), "
            + lsBodyText(event))
    }
}

/// Folded tool activity — the same gray block the iPhone shows, sized for a
/// wide window.
struct LSWorkRun: View {
    let run: [LSEvent]
    let running: Bool
    @State private var expanded = false

    private static let collapsedTail = 6

    private var shown: [LSEvent] {
        expanded || run.count <= Self.collapsedTail ? run : Array(run.suffix(Self.collapsedTail))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "gearshape.2")
                        .font(.pocket(.caption))
                        .accessibilityHidden(true)
                    HUDLabel("agent activity · \(run.count) step\(run.count == 1 ? "" : "s")")
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Agent activity, \(run.count) step\(run.count == 1 ? "" : "s")")
            .accessibilityHint(expanded ? "Collapse these steps" : "Expand these steps")
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.top, PocketSpacing.s8)
            .padding(.bottom, PocketSpacing.s4)

            VStack(alignment: .leading, spacing: 2) {
                if !expanded, run.count > Self.collapsedTail {
                    HUDLabel(String(localized: "… \(run.count - Self.collapsedTail) earlier steps"))
                }
                ForEach(shown) { event in
                    Text(line(event))
                        .font(.pocket(.mono))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(expanded ? 6 : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if running {
                    HStack(spacing: PocketSpacing.s4) {
                        PocketMarkView(state: .thinking(tokPerSec: nil), size: 12)
                            .accessibilityHidden(true)
                        HUDLabel("running")
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.bottom, PocketSpacing.s8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(PocketColor.bgSunken)
    }

    private func line(_ event: LSEvent) -> String {
        let tool = event.payload["tool"]?.stringValue
        switch event.eventType {
        case "tool_call":
            if let command = event.payload["command"]?.stringValue, !command.isEmpty {
                return "› \(tool ?? "Bash") \(command)"
            }
            return "› \(tool ?? "tool")"
        case "pre_tool":
            return "› \(event.payload["action"]?.stringValue ?? "running") \(tool ?? "")"
        case "file_write":
            return "› \(tool ?? "Edit") \(event.payload["file"]?.stringValue ?? "")"
        case "output":
            let text = lsBodyText(event)
            return text.isEmpty ? "› output" : "  \(text)"
        default:
            let text = lsBodyText(event)
            return text.isEmpty ? "› \(event.eventType)" : "› \(text)"
        }
    }
}

extension LSEvent: @retroactive Identifiable {}
