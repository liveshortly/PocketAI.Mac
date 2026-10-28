import AppIntents
import Foundation
import PocketKit

struct PocketAIIntentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runs a one-shot prompt through the on-device model and hands the answer
/// back to Shortcuts. The conversation is archived so Shortcuts runs do not
/// clutter the sidebar.
struct AskPocketAIIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask PocketAI"
    static var description = IntentDescription("Ask PocketAI's on-device model a question.")

    @Parameter(title: "Prompt")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await PocketAIIntentRunner.run(prompt: prompt, title: "Shortcut")
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Summarises whatever text Shortcuts passes in — the most common reason to
/// reach for a local model from the menu bar.
struct SummarizeTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Summarize with PocketAI"
    static var description = IntentDescription("Summarize text on this Mac, privately.")

    @Parameter(title: "Text")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await PocketAIIntentRunner.run(
            prompt: "Summarise the following text in a few sentences:\n\n\(text)",
            title: "Summary")
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Opens a fresh chat in the app, for a Shortcut bound to a hotkey.
struct StartNewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a PocketAI chat"
    static var description = IntentDescription("Opens PocketAI with a new chat ready.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.newChat()
        return .result()
    }
}

enum PocketAIIntentRunner {
    @MainActor
    static func run(prompt: String, title: String) async throws -> String {
        guard let app = AppModel.shared else {
            throw PocketAIIntentError("PocketAI isn't running yet. Open it once and try again.")
        }
        let core = app.core
        let conversation: Conversation
        do {
            conversation = try core.createConversation(
                NewConversation(title: title, projectId: nil, modelId: app.currentModelId))
        } catch {
            throw PocketAIIntentError(
                "PocketAI couldn't start a conversation: \(error.localizedDescription)")
        }
        try? core.archiveConversation(id: conversation.id, archived: true)

        var answer = ""
        do {
            for try await event in core.sendMessage(
                conversationId: conversation.id, input: UserInput(parts: [.text(text: prompt)])
            ) {
                if case .delta(let delta) = event { answer += delta.text }
            }
        } catch {
            throw PocketAIIntentError(
                "PocketAI couldn't generate a response: \(error.localizedDescription)")
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PocketAIIntentError("PocketAI returned an empty response.")
        }
        return trimmed
    }
}

struct PocketAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPocketAIIntent(),
            phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
            shortTitle: "Ask PocketAI",
            systemImageName: "bubble.left")
        AppShortcut(
            intent: SummarizeTextIntent(),
            phrases: ["Summarize with \(.applicationName)"],
            shortTitle: "Summarize",
            systemImageName: "text.append")
        AppShortcut(
            intent: StartNewChatIntent(),
            phrases: ["New \(.applicationName) chat"],
            shortTitle: "New chat",
            systemImageName: "plus.bubble")
    }
}
