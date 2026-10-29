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

    /// Sends a turn. Returns false when the turn was refused, so the composer
    /// can keep what was typed: it used to clear the box first and call this
    /// second, which destroyed the message whenever no model was installed.
    @discardableResult
    func send(_ text: String, attachments: [URL] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        // `run` cancels our reader but not the core's generation, so starting a
        // second turn mid-stream would leave the first decoding unattended.
        guard !isStreaming else { return false }
        guard rebindModelIfMissing() else { return false }

        var parts: [ContentPart] = attachments.map { .imageRef(path: $0.path) }
        if !trimmed.isEmpty { parts.append(.text(text: trimmed)) }
        run { [core, conversationId] in
            core.sendMessage(conversationId: conversationId, input: UserInput(parts: parts))
        }
        return true
    }

    /// A chat remembers the model it was created with, which may since have
    /// been deleted from the library. Re-point it at an installed one rather
    /// than letting the send fail somewhere inside the engine.
    /// Returns false when nothing is installed to fall back to.
    @discardableResult
    private func rebindModelIfMissing() -> Bool {
        // Apple's system model needs no download and has no catalog entry;
        // it is available whenever the engine says so.
        if conversation?.modelId == AppleFoundationModelsEngine.modelId,
           AppleFoundationModelsEngine.isAvailable {
            return true
        }
        let installed = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true)
        ).filter {
            $0.manifest.modalities.contains(.text) || $0.manifest.modalities.contains(.vision)
        }
        guard !installed.isEmpty else {
            if AppleFoundationModelsEngine.isAvailable {
                setModel(AppleFoundationModelsEngine.modelId)
                return true
            }
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
        // The core persists whatever was decoded as a cancelled message.
        // Without re-reading it, Stop wiped the partial reply off the
        // transcript and it only came back after navigating away and back.
        messages = core.messages(conversationId: conversationId)
        conversation = core.conversation(id: conversationId)
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
                        self.nameIfUntitled()
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

    /// Gives a new chat a real name, written by the model that answered it.
    ///
    /// Only after the first exchange, only when the user has not named it, and
    /// best-effort: a failure leaves the chat as it was rather than surfacing
    /// an error for something nobody asked for.
    private func nameIfUntitled() {
        guard (conversation?.title ?? "").isEmpty,
              messages.count >= 2,
              let question = messages.first(where: { $0.isUser })?.plainText,
              let answer = messages.last(where: { !$0.isUser })?.plainText
        else { return }

        let modelId = conversation?.modelId ?? ""
        let core = self.core
        let conversationId = self.conversationId
        Task { [weak self] in
            let prompt = """
                Give this conversation a title of at most six words. Reply with the \
                title alone — no quotes, no punctuation at the end, no preamble.

                Message: \(question.prefix(500))
                Reply: \(answer.prefix(500))
                """
            // A scratch conversation keeps the naming turn out of the thread
            // and out of the sidebar.
            guard let scratch = try? core.createConversation(
                NewConversation(title: "Naming", projectId: nil, modelId: modelId))
            else { return }
            try? core.archiveConversation(id: scratch.id, archived: true)
            defer { try? core.deleteConversation(id: scratch.id) }

            var titled = ""
            do {
                for try await event in core.sendMessage(
                    conversationId: scratch.id, input: UserInput(parts: [.text(text: prompt)])
                ) {
                    if case .delta(let delta) = event { titled += delta.text }
                    if titled.count > 120 { break }  // a runaway answer is not a title
                }
            } catch {
                return
            }

            guard let title = Self.cleanTitle(titled) else { return }
            await MainActor.run {
                guard let self, (self.conversation?.title ?? "").isEmpty else { return }
                try? core.renameConversation(id: conversationId, title: title)
                self.conversation = core.conversation(id: conversationId)
                NotificationCenter.default.post(
                    name: .pocketConversationsChanged, object: nil)
            }
        }
    }

    /// Takes the model's first line, strips the decoration models like to add,
    /// and rejects anything that does not look like a title.
    static func cleanTitle(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some models answer with reasoning first; the title is the last
        // non-empty line in that case, the only line otherwise.
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? text
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ .:-–—*#"))
        guard !text.isEmpty, text.count <= 60 else { return nil }
        let words = text.split(separator: " ")
        guard words.count <= 8 else { return nil }
        return text
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
