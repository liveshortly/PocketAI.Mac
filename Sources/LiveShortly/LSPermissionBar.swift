import PocketLiveShortly
import PocketUI
import SwiftUI

/// The agent is waiting on a verdict. Compact by design: the message, a
/// one-line summary of the tool call, and the two answers. "Review" opens the
/// full command or diff for anything that deserves a second look.
struct LSPermissionBar: View {
    let probe: LSEvent
    var toolCall: LSEvent?
    let onReview: () -> Void
    let onDecide: (String) async -> Bool
    @State private var answering = false

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketColor.statusWarn)
                    .accessibilityHidden(true)
                HUDLabel("permission requested", tint: PocketColor.statusWarn)
            }
            if let message = probe.payload["message"]?.stringValue {
                Text(message)
                    .font(.pocket(.body))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let toolCall {
                Button(action: onReview) {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "terminal")
                            .font(.pocket(.caption))
                            .accessibilityHidden(true)
                        Text(lsToolSummaryText(toolCall))
                            .font(.pocket(.mono))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: PocketSpacing.s8)
                        HUDLabel("review")
                        Image(systemName: "chevron.right")
                            .font(.pocket(.caption))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(PocketColor.textSecondary)
                    .padding(PocketSpacing.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPanel(PocketColor.bgSunken)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review \(lsToolSummaryText(toolCall))")
                .accessibilityHint("Shows the exact command or change before you answer")
            }
            HStack(spacing: PocketSpacing.s8) {
                Button("Allow") { answer("allow") }
                    .buttonStyle(.hudProminent)
                    .accessibilityLabel("Allow this request")
                Button("Deny") { answer("deny") }
                    .buttonStyle(.hudDestructive)
                    .accessibilityLabel("Deny this request")
                Spacer(minLength: 0)
            }
            .disabled(answering)
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                .fill(PocketColor.statusWarn.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                .stroke(PocketColor.statusWarn.opacity(0.4), lineWidth: HUD.hairline))
    }

    private func answer(_ decision: String) {
        answering = true
        Task {
            // Re-enable on failure: a dropped verdict must not leave the only
            // way to unblock the agent permanently greyed out.
            if await onDecide(decision) == false { answering = false }
        }
    }
}

/// The full request: the exact command, diff or file the agent wants to run,
/// so a verdict is informed rather than a guess.
struct LSProbeDetailView: View {
    let probe: LSEvent
    var toolCall: LSEvent?
    let onDecide: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    private var kind: String? { probe.payload["kind"]?.stringValue }

    /// UI-87: ⌘⏎ Allow / ⌘⌫ Deny, here and nowhere else — never on the inline
    /// bar or a menu, where a stray Return from the composer could approve a
    /// tool call. Only for a permission request: an input request may grow a
    /// text field, where ⌘⌫ means "delete line".
    static func shortcut(for verdict: String, kind: String?) -> KeyboardShortcut? {
        guard kind == "permission" else { return nil }
        switch verdict {
        case "allow": return KeyboardShortcut(.return, modifiers: .command)
        case "deny": return KeyboardShortcut(.delete, modifiers: .command)
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(
                    kind == "permission"
                        ? "Permission request" : "Input request"
                )
                .font(.pocket(.headline))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.hud)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(PocketSpacing.s12)
            HUDRule()

            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                    if let message = probe.payload["message"]?.stringValue {
                        Text(message)
                            .font(.pocket(.body))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let toolCall {
                        toolSection(toolCall)
                    } else {
                        Text("No tool details were captured for this request.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                }
                .padding(PocketSpacing.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HUDRule()
            HStack(spacing: PocketSpacing.s12) {
                Button("Deny") {
                    Task { _ = await onDecide("deny") }
                    dismiss()
                }
                .buttonStyle(.hudDestructive)
                .keyboardShortcut(Self.shortcut(for: "deny", kind: kind))
                .help(kind == "permission" ? "Deny (⌘⌫)" : "Deny")
                Button("Allow") {
                    Task { _ = await onDecide("allow") }
                    dismiss()
                }
                .buttonStyle(.hudProminent)
                .keyboardShortcut(Self.shortcut(for: "allow", kind: kind))
                .help(kind == "permission" ? "Allow (⌘⏎)" : "Allow")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(PocketSpacing.s12)
        }
        .frame(width: 640, height: 520)
        .background(PocketColor.bgSurface)
    }

    @ViewBuilder private func toolSection(_ call: LSEvent) -> some View {
        let tool = call.payload["tool"]?.stringValue ?? "tool"
        let input = call.payload["input"]
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel(tool)
            switch tool {
            case "Bash":
                if let description = input?["description"]?.stringValue {
                    Text(description)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                CodeBlock(
                    code: input?["command"]?.stringValue
                        ?? call.payload["command"]?.stringValue ?? "",
                    language: "bash")
            case "Edit":
                if let path = input?["file_path"]?.stringValue {
                    Text(path)
                        .font(.pocket(.mono))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                diff(
                    old: input?["old_string"]?.stringValue ?? "",
                    new: input?["new_string"]?.stringValue ?? "")
            case "Write", "NotebookEdit":
                if let path = input?["file_path"]?.stringValue {
                    Text(path)
                        .font(.pocket(.mono))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                CodeBlock(code: input?["content"]?.stringValue ?? "", language: nil)
            default:
                CodeBlock(code: lsBodyText(call), language: nil)
            }
        }
    }

    /// Minimal unified diff — removed lines red, added green.
    private func diff(old: String, new: String) -> some View {
        let removed = old.split(separator: "\n", omittingEmptySubsequences: false)
        let added = new.split(separator: "\n", omittingEmptySubsequences: false)
        let cap = 80
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(removed.prefix(cap).enumerated()), id: \.offset) { _, line in
                    Text("- \(line)").foregroundStyle(PocketColor.statusBad)
                }
                if removed.count > cap {
                    HUDLabel(String(localized: "… \(removed.count - cap) more removed"))
                }
                ForEach(Array(added.prefix(cap).enumerated()), id: \.offset) { _, line in
                    Text("+ \(line)").foregroundStyle(PocketColor.statusOk)
                }
                if added.count > cap {
                    HUDLabel(String(localized: "… \(added.count - cap) more added"))
                }
            }
            .font(.pocket(.mono))
            .textSelection(.enabled)
            .padding(PocketSpacing.s8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(PocketColor.bgSunken)
    }
}

/// "Tool · gist" for the one-line summary on the permission bar.
func lsToolSummaryText(_ call: LSEvent) -> String {
    let tool = call.payload["tool"]?.stringValue ?? "tool"
    let input = call.payload["input"]
    let gist: String? = switch tool {
    case "Bash":
        (input?["command"]?.stringValue ?? call.payload["command"]?.stringValue)?
            .split(separator: "\n", maxSplits: 1).first.map(String.init)
    case "Edit", "Write", "MultiEdit", "Read", "NotebookEdit":
        (input?["file_path"]?.stringValue as NSString?)?.lastPathComponent
    default:
        nil
    }
    return gist.map { "\(tool) · \($0)" } ?? tool
}
