import AppKit
import PocketKit
import PocketUI
import SwiftUI

/// One persisted turn. User turns are right-aligned accent cards; assistant
/// turns are full-width prose with fenced code lifted into `CodeBlock`.
struct MessageRow: View {
    let message: Message
    /// Continues the previous turn by the same author, so the header is
    /// dropped — the same grouping the session transcript uses.
    var grouped = false

    var body: some View {
        if message.isUser {
            UserTurn(message: message, grouped: grouped)
        } else {
            AssistantTurn(
                text: message.plainText,
                reasoning: message.reasoning,
                stats: message.stats,
                status: message.status,
                messageId: message.id,
                grouped: grouped)
        }
    }
}

struct UserTurn: View {
    let message: Message
    var grouped = false

    var body: some View {
        VStack(alignment: .trailing, spacing: PocketSpacing.s4) {
            if !grouped {
                HStack(spacing: PocketSpacing.s8) {
                    HUDLabel(String(localized: "you"))
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(message.createdAt))
                            .formatted(date: .omitted, time: .shortened)
                    )
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                }
            }
            if !message.imagePaths.isEmpty {
                HStack(spacing: PocketSpacing.s4) {
                    ForEach(message.imagePaths, id: \.self) { path in
                        if let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 92, height: 92)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: HUD.radius, style: .continuous))
                                .accessibilityLabel(
                                    "Attached image \((path as NSString).lastPathComponent)")
                        }
                    }
                }
            }
            if !message.plainText.isEmpty {
                Text(message.plainText)
                    .font(.pocket(.body))
                    .textSelection(.enabled)
                    .padding(.horizontal, PocketSpacing.s12)
                    .padding(.vertical, PocketSpacing.s8)
                    .hudAccentPanel()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Three separate unlabelled texts read as a wall; one element reads as
        // one turn: "You, 10:42, <message>".
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let when = Date(timeIntervalSince1970: TimeInterval(message.createdAt))
            .formatted(date: .omitted, time: .shortened)
        var parts = [String(localized: "You"), when]
        if !message.imagePaths.isEmpty {
            parts.append(message.imagePaths.count == 1
                ? String(localized: "1 attached image")
                : String(localized: "\(message.imagePaths.count) attached images"))
        }
        if !message.plainText.isEmpty { parts.append(message.plainText) }
        return parts.joined(separator: ", ")
    }
}

struct AssistantTurn: View {
    let text: String
    var reasoning: String?
    var stats: GenerateStats?
    var status: MessageStatus = .done
    var messageId: String = ""
    var grouped = false
    @State private var showReasoning = false
    @State private var copied = false
    @State private var speech = ReadAloud.shared

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack(spacing: PocketSpacing.s8) {
                if !grouped {
                    HUDLabel(String(localized: "◆ assistant"), tint: PocketColor.accent)
                }
                if status == .cancelled {
                    HUDChip(text: String(localized: "stopped"))
                } else if status == .error {
                    HUDChip(text: String(localized: "failed"), tint: PocketColor.statusBad)
                }
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Button {
                        speech.toggle(text, id: messageId)
                    } label: {
                        HUDLabel(
                            speech.speakingId == messageId
                                ? String(localized: "stop") : String(localized: "read aloud"),
                            tint: speech.speakingId == messageId
                                ? PocketColor.statusBad : PocketColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        speech.speakingId == messageId
                            ? "Stop reading this reply" : "Read this reply aloud")
                    .help("Read this reply aloud")
                    Button {
                        copy()
                    } label: {
                        HUDLabel(copied
                            ? String(localized: "copied") : String(localized: "copy"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy this reply")
                    .help("Copy this reply")
                }
            }
            if let reasoning, !reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showReasoning) {
                    Text(reasoning)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, PocketSpacing.s4)
                } label: {
                    HUDLabel(String(localized: "reasoning"))
                }
                .padding(PocketSpacing.s8)
                .hudPanel(PocketColor.bgSunken)
            }
            MarkdownText(text)
            if let stats {
                HUDLabel(String(
                    localized: "\(Int(stats.decodeTps)) tok/s · \(stats.completionTokens) tokens · \(stats.ttftMs) ms to first token"
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// The reply currently arriving, with a live caret at the tail.
struct StreamingRow: View {
    let text: String
    let reasoning: String

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack(spacing: PocketSpacing.s8) {
                HUDLabel(String(localized: "◆ assistant"), tint: PocketColor.accent)
                PocketMarkView(state: .working(tokPerSec: nil), size: 12)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Assistant, replying")
            if text.isEmpty && reasoning.isEmpty {
                HUDLabel(String(localized: "thinking…"))
            } else {
                MarkdownText(text, caret: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A failed turn, explained in words the user can act on, with the retry that
/// matches. Raw `localizedDescription` from the engine reads like a crash log.
struct ChatErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PocketSpacing.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PocketColor.statusWarn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(friendly)
                    .font(.pocket(.body))
                    .fixedSize(horizontal: false, vertical: true)
                if friendly != message {
                    Text(message)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .buttonStyle(.hud)
                .accessibilityLabel("Retry this reply")
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(PocketColor.statusWarn.opacity(0.10))
    }

    private var friendly: String { chatFriendlyError(message) }
}

/// Maps the handful of failures users actually hit onto plain sentences.
func chatFriendlyError(_ message: String) -> String {
    let lowered = message.lowercased()
    if lowered.contains("no model") || lowered.contains("not installed") {
        return String(localized: "No model is installed yet. Open the model library and download one.")
    }
    if lowered.contains("memory") || lowered.contains("resource") {
        return String(localized: "This Mac ran out of memory for that model. Try a smaller one, or unload other models first.")
    }
    if lowered.contains("cancel") {
        return String(localized: "That reply was stopped.")
    }
    if lowered.contains("context") || lowered.contains("too long") {
        return String(localized: "The conversation is longer than this model's context. Start a new chat to continue.")
    }
    if lowered.contains("network") || lowered.contains("offline")
        || lowered.contains("connection") {
        return String(localized: "Couldn't reach the network. Local models still work offline.")
    }
    return message
}

/// Renders assistant text: fenced code becomes `CodeBlock`, the rest is
/// inline-markdown prose. Deliberately small — a full markdown engine is not
/// what makes a reply readable, correct code framing is.
struct MarkdownText: View {
    private let blocks: [Block]
    private let caret: Bool

    init(_ text: String, caret: Bool = false) {
        self.blocks = Block.parse(text)
        self.caret = caret
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .prose(let content):
                    MarkdownProse(content, font: .pocket(.reading))
                case .code(let code, let language):
                    CodeBlock(code: code, language: language)
                }
            }
            if caret {
                Rectangle()
                    .fill(PocketColor.accent)
                    .frame(width: 7, height: 14)
                    .opacity(0.85)
                    .accessibilityHidden(true)
            }
        }
    }

    enum Block {
        case prose(String)
        case code(String, String?)

        /// Splits on ``` fences. An unterminated fence (mid-stream) still
        /// renders as code, so a block does not flicker into prose and back.
        static func parse(_ text: String) -> [Block] {
            var out: [Block] = []
            var prose: [String] = []
            var code: [String] = []
            var language: String?
            var inFence = false

            func flushProse() {
                let joined = prose.joined(separator: "\n").trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !joined.isEmpty { out.append(.prose(joined)) }
                prose = []
            }

            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("```") {
                    if inFence {
                        out.append(.code(code.joined(separator: "\n"), language))
                        code = []
                        language = nil
                        inFence = false
                    } else {
                        flushProse()
                        let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                        language = tag.isEmpty ? nil : tag
                        inFence = true
                    }
                } else if inFence {
                    code.append(line)
                } else {
                    prose.append(line)
                }
            }
            if inFence, !code.isEmpty {
                out.append(.code(code.joined(separator: "\n"), language))
            }
            flushProse()
            return out
        }
    }
}
