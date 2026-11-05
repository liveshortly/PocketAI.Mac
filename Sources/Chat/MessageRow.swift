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
    /// The newest turn: its actions stay visible instead of on hover.
    var isLast = false
    /// Re-runs the reply; offered on the last assistant turn only.
    var onRetry: (() -> Void)?
    /// Puts a user turn's text back into the composer.
    var onEdit: ((String) -> Void)?
    /// UI-68: rewrite this turn in place (drops what came after it).
    var onSaveEdit: ((String) -> Void)?
    /// UI-68: carry on a stopped reply.
    var onContinue: (() -> Void)?

    var body: some View {
        if message.isUser {
            UserTurn(message: message, grouped: grouped, onEdit: onEdit, onSaveEdit: onSaveEdit)
        } else {
            AssistantTurn(
                text: message.plainText,
                reasoning: message.reasoning,
                toolSteps: message.toolSteps,
                sources: message.sources,
                stats: message.stats,
                status: message.status,
                messageId: message.id,
                grouped: grouped,
                isLast: isLast,
                thoughtSeconds: ThoughtTimes.seconds(for: message.id),
                onRetry: onRetry,
                onContinue: onContinue)
        }
    }
}

struct UserTurn: View {
    let message: Message
    var grouped = false
    var onEdit: ((String) -> Void)?
    var onSaveEdit: ((String) -> Void)?
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: PocketSpacing.s4) {
            if !grouped {
                HStack(spacing: PocketSpacing.s8) {
                    HUDLabel("you")
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
            if editing {
                editor
            } else if !message.plainText.isEmpty {
                UserMessageText(message.plainText)
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
        // A sent turn had no actions at all: no copy, no way to reuse it.
        .contextMenu {
            if !message.plainText.isEmpty {
                Button("Copy") { copyToPasteboard(message.plainText) }
                if onSaveEdit != nil {
                    Button("Edit…") { draft = message.plainText; editing = true }
                }
                if let onEdit {
                    Button("Edit as New Message") { onEdit(message.plainText) }
                }
            }
        }
    }

    /// UI-68: in-place editor; saving replaces this turn and what followed it.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: PocketSpacing.s8) {
            TextEditor(text: $draft)
                .font(.pocket(.body))
                .scrollContentBackground(.hidden)
                .frame(minWidth: 320, maxWidth: 520, minHeight: 64, maxHeight: 200)
                .padding(PocketSpacing.s8)
                .hudPanel(PocketColor.bgCanvas)
                .accessibilityLabel("Edit your message")
            Text("Saving replaces the replies after this message.")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
            HStack(spacing: PocketSpacing.s8) {
                Button("Cancel") { editing = false }
                    .buttonStyle(.hud)
                    .keyboardShortcut(.cancelAction)
                Button("Save & resend") {
                    editing = false
                    onSaveEdit?(draft)
                }
                .buttonStyle(.hudProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var accessibilityText: String {
        let when = Date(timeIntervalSince1970: TimeInterval(message.createdAt))
            .formatted(date: .omitted, time: .shortened)
        var parts = ["You", when]
        if !message.imagePaths.isEmpty {
            parts.append(String(localized: "\(message.imagePaths.count) attached images"))
        }
        if !message.plainText.isEmpty { parts.append(message.plainText) }
        return parts.joined(separator: ", ")
    }
}

struct AssistantTurn: View {
    let text: String
    var reasoning: String?
    var toolSteps: [ToolStep] = []
    var sources: [String] = []
    var stats: GenerateStats?
    var status: MessageStatus = .done
    var messageId: String = ""
    var grouped = false
    var isLast = false
    var thoughtSeconds: Int?
    var onRetry: (() -> Void)?
    var onContinue: (() -> Void)?
    @State private var showReasoning = false
    @State private var copied = false
    @State private var hovering = false
    @State private var speech = ReadAloud.shared
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// Copy / read aloud / retry on every reply was a column of noise down the
    /// transcript. They show on hover, on the newest reply, while in use, and
    /// always under VoiceOver (an invisible control is a missing one).
    private var showActions: Bool {
        hovering || isLast || voiceOver || copied || speech.speakingId == messageId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack(spacing: PocketSpacing.s8) {
                if !grouped {
                    HUDLabel("◆ assistant", tint: PocketColor.accent)
                }
                if status == .cancelled {
                    HUDChip(text: "stopped")
                } else if status == .error {
                    HUDChip(text: "failed", tint: PocketColor.statusBad)
                }
                Spacer(minLength: 0)
                if !text.isEmpty {
                    actions
                        .opacity(showActions ? 1 : 0)
                        .allowsHitTesting(showActions)
                }
            }
            ToolStepsView(steps: toolSteps)
            if let reasoning, !reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showReasoning) {
                    Text(reasoning)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, PocketSpacing.s4)
                } label: {
                    // UI-68: "Thought for 4 s" when this Mac timed it.
                    HUDLabel(thoughtSeconds.map { String(localized: "Thought for \($0) s") }
                        ?? String(localized: "reasoning"))
                }
                .padding(PocketSpacing.s8)
                .hudPanel(PocketColor.bgSunken)
            }
            MarkdownText(text)
            if status == .cancelled, isLast, let onContinue {
                Button("Continue", action: onContinue)
                    .buttonStyle(.hud)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Continue this reply")
            }
            SourcesView(urls: sources)
            if let stats {
                HUDLabel(
                    String(localized: "\(Int(stats.decodeTps)) tok/s · \(stats.completionTokens) tokens · \(stats.ttftMs) ms to first token")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        // The same actions by right-click, for anyone who never hovers.
        .contextMenu {
            if !text.isEmpty {
                Button("Copy") { copy() }
                Button(speech.speakingId == messageId ? "Stop Reading" : "Read Aloud") {
                    speech.toggle(text, id: messageId)
                }
            }
            if isLast, let onRetry {
                Button("Regenerate", action: onRetry)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: PocketSpacing.s8) {
            Button {
                speech.toggle(text, id: messageId)
            } label: {
                HUDLabel(
                    speech.speakingId == messageId ? "stop" : "read aloud",
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
                HUDLabel(copied ? "copied" : "copy")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy this reply")
            .help("Copy this reply (⇧⌘C copies the latest)")
            if isLast, let onRetry {
                Button(action: onRetry) {
                    HUDLabel("retry")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate this reply")
                .help("Regenerate this reply (⇧⌘R)")
            }
        }
    }

    private func copy() {
        copyToPasteboard(text)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// Plain-text copy used by every transcript action.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// The reply currently arriving, with a live caret at the tail.
struct StreamingRow: View {
    let text: String
    let reasoning: String
    var steps: [ToolStep] = []
    /// UI-146: shared live status row (nil keeps the row hidden, e.g. previews).
    var phase: ChatPhase?
    var modelName: String?
    var onStop: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack(spacing: PocketSpacing.s8) {
                HUDLabel("◆ assistant", tint: PocketColor.accent)
                PocketMarkView(state: .thinking(tokPerSec: nil), size: 12)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Assistant, replying")
            ToolStepsView(steps: steps)
            ReplyStatusLine(phase: phase, modelName: modelName, onStop: onStop)
            if text.isEmpty && reasoning.isEmpty {
                // Model loading/prefilling: the animated PocketAI mark,
                // centered, as on iPhone's MessageView (UI-28).
                VStack(spacing: PocketSpacing.s8) {
                    PocketMarkView(state: .loading, size: 40)
                        .accessibilityHidden(true) // the status row above carries the status
                    if phase == nil { HUDLabel("thinking…") }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PocketSpacing.s8)
            } else if text.isEmpty {
                // A reasoning model can think for a minute before its first
                // answer token. This used to show a lone caret the whole
                // time; show the reasoning as it arrives instead.
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    HUDLabel("thinking…")
                    Text(reasoningTail)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(PocketSpacing.s8)
                .hudPanel(PocketColor.bgSunken)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Thinking")
            } else {
                MarkdownText(text, caret: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // §8: announced as live content, not re-read per token.
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The last few lines of reasoning — the part being written now.
    private var reasoningTail: String {
        let lines = reasoning.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return String(lines.suffix(4).joined(separator: "\n").suffix(400))
    }
}

/// AGT-12/13: "Searched" / "Read" / "Ran code" rows for the tools a reply
/// used, each expandable to its results, page URL or code and output.
/// Nothing when no tools ran.
struct ToolStepsView: View {
    let steps: [ToolStep]

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    ToolStepRow(step: step)
                }
            }
            .padding(PocketSpacing.s8)
            .hudPanel(PocketColor.bgSunken)
        }
    }
}

private struct ToolStepRow: View {
    let step: ToolStep
    @State private var expanded = false

    var body: some View {
        if step.kind == "ran" {
            let ran = RanCodeDetail(step: step)
            RanCodeRow(language: step.codeLanguageName, code: ran.code, output: ran.output, error: ran.error,
                       durationMs: ran.durationMs, truncated: ran.truncated, denied: ran.denied)
        } else {
            searchOrReadRow
        }
    }

    private var searchOrReadRow: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(step.detail)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, PocketSpacing.s4)
        } label: {
            Label(step.title, systemImage: step.kind == "read" ? "doc.text" : "magnifyingglass")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
                .lineLimit(1)
        }
    }
}

extension ToolStep {
    var title: String { kind == "read" ? String(localized: "Read: \(label)") : String(localized: "Searched: \(label)") }
}

/// AGT-12: the pages a reply read, as links under the answer.
struct SourcesView: View {
    let urls: [String]

    var body: some View {
        let links = urls.compactMap { URL(string: $0) }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                HUDLabel("sources")
                ForEach(links, id: \.self) { url in
                    Link(url.host() ?? url.absoluteString, destination: url)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.accent)
                        .help(url.absoluteString)
                }
            }
        }
    }
}

/// A failed turn, explained in words the user can act on, with the retry that
/// matches. Raw `localizedDescription` from the engine reads like a crash log.
struct ChatErrorRow: View {
    let message: String
    let retry: () -> Void
    /// Offered instead of Retry when no model is installed — retrying that
    /// only fails the same way again.
    var openModels: (() -> Void)?

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
            if needsModel, let openModels {
                Button("Browse models", action: openModels)
                    .buttonStyle(.hudProminent)
            } else {
                Button("Retry", action: retry)
                    .buttonStyle(.hud)
                    .accessibilityLabel("Retry this reply")
            }
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(PocketColor.statusWarn.opacity(0.10))
    }

    private var friendly: String { chatFriendlyError(message) }

    private var needsModel: Bool {
        let lowered = message.lowercased()
        return lowered.contains("no model") || lowered.contains("not installed")
    }
}

/// Maps the handful of failures users actually hit onto plain sentences.
func chatFriendlyError(_ message: String) -> String {
    let lowered = message.lowercased()
    if lowered.contains("no model") || lowered.contains("not installed") {
        return "No model is installed yet. Open the model library and download one."
    }
    if lowered.contains("memory") || lowered.contains("resource") {
        return "This Mac ran out of memory for that model. Try a smaller one, "
            + "or unload other models first."
    }
    if lowered.contains("cancel") {
        return "That reply was stopped."
    }
    if lowered.contains("context") || lowered.contains("too long") {
        return "The conversation is longer than this model's context. "
            + "Start a new chat to continue."
    }
    if lowered.contains("network") || lowered.contains("offline")
        || lowered.contains("connection") {
        return "Couldn't reach the network. Local models still work offline."
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

#Preview("Streaming — thinking") {
    VStack(spacing: PocketSpacing.s24) {
        StreamingRow(text: "", reasoning: "")
        StreamingRow(text: "", reasoning: "The user wants a summary.\nFirst, find the main claim.")
        StreamingRow(text: "Here's the first part of the answer", reasoning: "")
    }
    .padding()
    .frame(width: 480)
    .background(PocketColor.bgCanvas)
}
