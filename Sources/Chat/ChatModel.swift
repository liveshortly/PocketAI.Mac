import Foundation
import Observation
import PocketKit
import SwiftUI

/// Streaming state for one conversation. Kept separate from `AppModel` so a
/// token arriving every few milliseconds invalidates this view and nothing
/// else in the window.
@Observable
@MainActor
final class ChatModel {
    let conversationId: String
    private let core: CoreClient

    private(set) var messages: [Message] = []
    private(set) var conversation: Conversation?
    /// Text accumulated for the reply currently streaming in; empty when idle.
    private(set) var streamingText = ""
    private(set) var streamingReasoning = ""
    private(set) var isStreaming = false
    private(set) var tokensPerSecond: Int = 0
    private(set) var lastStats: GenerateStats?
    private(set) var errorText: String?

    private var streamTask: Task<Void, Never>?
    private var streamStart: Date?
    private var tokenCount = 0

    init(conversationId: String, core: CoreClient) {
        self.conversationId = conversationId
        self.core = core
        load()
    }

    func load() {
        conversation = core.conversation(id: conversationId)
        messages = core.messages(conversationId: conversationId)
    }

    var title: String {
        let stored = conversation?.title ?? ""
        if !stored.isEmpty { return stored }
        // Untitled chats read by their first user message, like the iPhone app.
        if let first = messages.first(where: { $0.role == "user" }) {
            let text = first.plainText
            if !text.isEmpty { return String(text.prefix(48)) }
        }
        return "New chat"
    }

    var isEmpty: Bool { messages.isEmpty && !isStreaming }

    // MARK: - Sending

    func send(_ text: String, attachments: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard rebindModelIfMissing() else { return }

        var parts: [ContentPart] = attachments.map { .imageRef(path: $0.path) }
        if !trimmed.isEmpty { parts.append(.text(text: trimmed)) }
        run { [core, conversationId] in
            core.sendMessage(conversationId: conversationId, input: UserInput(parts: parts))
        }
    }

    /// A chat remembers the model it was created with, which may since have
    /// been deleted from the library. Re-point it at an installed one rather
    /// than letting the send fail somewhere inside the engine.
    /// Returns false when nothing is installed to fall back to.
    @discardableResult
    private func rebindModelIfMissing() -> Bool {
        let installed = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true)
        ).filter {
            $0.manifest.modalities.contains(.text) || $0.manifest.modalities.contains(.vision)
        }
        guard !installed.isEmpty else {
            errorText = "No model is installed yet — open the model library and download one."
            return false
        }
        let current = conversation?.modelId
        if let current, installed.contains(where: { $0.manifest.id == current }) { return true }
        guard let replacement = installed.first else { return false }
        setModel(replacement.manifest.id)
        return true
    }

    /// True when this chat's model can take images.
    var modelSupportsVision: Bool {
        let id = conversation?.modelId
        return core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true)
        ).first { $0.manifest.id == id }?.manifest.modalities.contains(.vision) ?? false
    }

    /// An installed vision model to point the user at, if there is one.
    var suggestedVisionModel: String? {
        core.catalog(
            filter: CatalogFilter(modality: .vision, curatedOnly: false, installedOnly: true)
        ).first?.manifest.displayName
    }

    /// Drops the trailing assistant reply and re-runs from existing history.
    func regenerate() {
        guard !isStreaming else { return }
        run { [core, conversationId] in core.regenerate(conversationId: conversationId) }
    }

    func stop() {
        core.cancelConversation(id: conversationId)
        streamTask?.cancel()
        finishStream()
    }

    func setModel(_ modelId: String) {
        try? core.setConversationModel(id: conversationId, modelId: modelId)
        conversation = core.conversation(id: conversationId)
    }

    func rename(_ title: String) {
        try? core.renameConversation(id: conversationId, title: title)
        conversation = core.conversation(id: conversationId)
        NotificationCenter.default.post(name: .pocketConversationsChanged, object: nil)
    }

    private func run(
        _ makeStream: @escaping () -> AsyncThrowingStream<ChatStreamEvent, Error>
    ) {
        streamTask?.cancel()
        errorText = nil
        streamingText = ""
        streamingReasoning = ""
        tokenCount = 0
        tokensPerSecond = 0
        streamStart = Date()
        isStreaming = true
        // The user's own message is persisted by the core; reload so it shows
        // immediately rather than only when the reply lands.
        messages = core.messages(conversationId: conversationId)

        streamTask = Task { [weak self] in
            do {
                for try await event in makeStream() {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .delta(let delta):
                        self.apply(delta)
                    case .done(let message):
                        self.lastStats = message.stats
                        self.finishStream()
                        self.messages = self.core.messages(conversationId: self.conversationId)
                        self.conversation = self.core.conversation(id: self.conversationId)
                        NotificationCenter.default.post(
                            name: .pocketConversationsChanged, object: nil)
                    }
                }
                self?.finishStream()
            } catch is CancellationError {
                self?.finishStream()
            } catch {
                guard let self else { return }
                self.errorText = error.localizedDescription
                self.finishStream()
            }
        }
    }

    private func apply(_ delta: GenerateDelta) {
        if messages.isEmpty || messages.last?.role != "user" {
            // First delta of a turn: make sure the user's message is on screen.
            messages = core.messages(conversationId: conversationId)
        }
        streamingText += delta.text
        streamingReasoning += delta.reasoning
        tokenCount += 1
        if let start = streamStart {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0.4 { tokensPerSecond = Int(Double(tokenCount) / elapsed) }
        }
    }

    private func finishStream() {
        isStreaming = false
        streamingText = ""
        streamingReasoning = ""
        streamStart = nil
        // Keep the last measured rate visible in the inspector after the turn.
    }

}

extension Message {
    /// Flattens the message's parts into displayable text.
    var plainText: String {
        parts.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }
        .joined(separator: "\n")
    }

    /// Image attachments carried by this message, as file paths.
    var imagePaths: [String] {
        parts.compactMap {
            if case .imageRef(let path) = $0 { return path }
            return nil
        }
    }

    var isUser: Bool { role == "user" }
}

extension Message: @retroactive Identifiable {}
