import PocketKit
import PocketUI
import SwiftUI

/// The menu bar panel: ask without leaving whatever app you are in. The reply
/// streams here; "Open in PocketAI" hands the same conversation to the window.
struct QuickAskPanel: View {
    @Environment(AppModel.self) private var app
    @State private var prompt = ""
    @State private var reply = ""
    @State private var isStreaming = false
    @State private var conversationId: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            header
            HStack(spacing: PocketSpacing.s8) {
                PocketMarkView(
                    state: isStreaming ? .thinking(tokPerSec: nil) : .idle, size: 18)
                    .accessibilityHidden(true)
                TextField("Ask PocketAI…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.pocket(.body))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(ask)
                if isStreaming {
                    Button {
                        stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketColor.statusBad)
                    .accessibilityLabel("Stop generating")
                }
            }
            .padding(PocketSpacing.s8)
            .hudPanel(PocketColor.bgCanvas)

            if !reply.isEmpty {
                ScrollView {
                    MarkdownText(reply, caret: isStreaming)
                        .padding(PocketSpacing.s8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .hudPanel(PocketColor.bgSunken)
            }
            if let errorText {
                Text(errorText)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
            }
            footer
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgSurface)
        .onAppear { focused = true }
        // Cancel the generation itself, not just our reader: otherwise the
        // model keeps decoding with nobody listening.
        .onDisappear { stop() }
    }

    private var header: some View {
        HStack(spacing: PocketSpacing.s8) {
            HUDLabel("PocketAI", tint: PocketColor.accent)
            Spacer()
            HUDLabel(app.currentModelDisplayName)
            if app.serverStatus.running {
                HUDDot(pulsing: true)
                HUDLabel("serving")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: PocketSpacing.s8) {
            HUDLabel("⏎ ask")
            Spacer()
            // NET-22: no "Sync now" here - this Mac is the sync server and
            // can't reach the phone; the iPhone syncs whenever PocketAI is
            // open on it. Say when it last did, and why.
            if let synced = app.lastChatSyncAt {
                HUDLabel("iPhone synced \(hudRelative(synced / 1000))")
                    .help("Your iPhone syncs chats with this Mac while PocketAI is open on it.")
            }
            if let conversationId {
                Button("Open in PocketAI") {
                    // Activating the app is not enough when another window
                    // (Settings) is frontmost: the shell itself must go key.
                    app.reveal(.chat(conversationId))
                }
                .buttonStyle(.hud)
            }
            Button("New") { reset() }
                .buttonStyle(.hud)
                .disabled(reply.isEmpty && prompt.isEmpty)
        }
    }

    private func ask() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        // Quick asks are real conversations, so anything worth keeping is
        // already in the sidebar when the window comes forward.
        let id: String
        if let existing = conversationId {
            id = existing
        } else {
            guard let created = try? app.core.createConversation(
                NewConversation(
                    title: String(text.prefix(48)), projectId: nil,
                    modelId: app.currentModelId))
            else {
                errorText = "Couldn't start a conversation."
                return
            }
            id = created.id
            conversationId = created.id
            NotificationCenter.default.post(name: .pocketConversationsChanged, object: nil)
        }

        prompt = ""
        reply = ""
        errorText = nil
        isStreaming = true
        let core = app.core
        streamTask = Task {
            do {
                for try await event in core.sendMessage(
                    conversationId: id, input: UserInput(parts: [.text(text: text)])
                ) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .delta(let delta):
                        reply += delta.text
                    case .done(let message):
                        reply = message.plainText
                    }
                }
            } catch is CancellationError {
            } catch {
                errorText = error.localizedDescription
            }
            isStreaming = false
        }
    }

    private func stop() {
        if let conversationId { app.core.cancelConversation(id: conversationId) }
        streamTask?.cancel()
        isStreaming = false
    }

    private func reset() {
        stop()
        prompt = ""
        reply = ""
        errorText = nil
        conversationId = nil
        focused = true
    }
}
