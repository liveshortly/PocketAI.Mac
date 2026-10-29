import PocketKit
import PocketUI
import SwiftUI

/// Rename form shared by chats and projects — a proper sheet, because the
/// stock alert text field is cramped and unstyled.
struct RenameSheet: View {
    @State var title: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HUDLabel("Title")
            TextField("Untitled", text: $title)
                .textFieldStyle(.plain)
                .font(.pocket(.body))
                .focused($focused)
                .onSubmit(commit)
                .padding(PocketSpacing.s8)
                .hudPanel(PocketColor.bgCanvas)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.hud)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .buttonStyle(.hudProminent)
                    .disabled(trimmed.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PocketSpacing.s16)
        .frame(width: 420)
        .background(PocketColor.bgSurface)
        .onAppear { focused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        save(trimmed)
        dismiss()
    }
}

/// New project: name plus the instructions every chat in it will carry.
struct NewProjectSheet: View {
    @State private var name = ""
    @State private var instructions = ""
    let create: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            Text("New project")
                .font(.pocket(.title))
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                HUDLabel("Name")
                TextField("Client work", text: $name)
                    .textFieldStyle(.plain)
                    .font(.pocket(.body))
                    .focused($focused)
                    .padding(PocketSpacing.s8)
                    .hudPanel(PocketColor.bgCanvas)
            }
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                HUDLabel("Instructions · optional")
                TextEditor(text: $instructions)
                    .font(.pocket(.body))
                    .scrollContentBackground(.hidden)
                    .frame(height: 90)
                    .padding(PocketSpacing.s8)
                    .hudPanel(PocketColor.bgCanvas)
                Text("Every chat in this project starts with these instructions.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.hud)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let notes = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    create(trimmed, notes.isEmpty ? nil : notes)
                    dismiss()
                }
                .buttonStyle(.hudProminent)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(PocketSpacing.s16)
        .frame(width: 460)
        .background(PocketColor.bgSurface)
        .onAppear { focused = true }
    }
}

/// Incoming pairing request. Shows the fingerprint, because approving a device
/// without comparing it is the whole attack.
struct PairingApprovalSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: PairingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .foregroundStyle(PocketColor.accent)
                    .accessibilityHidden(true)
                Text("Pair this device?")
                    .font(.pocket(.title))
            }
            Text("\(request.deviceName) wants to use this Mac's models.")
                .font(.pocket(.body))
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                HUDLabel("Device")
                HStack {
                    Text(request.deviceName)
                        .font(.pocket(.mono))
                    Spacer()
                    HUDChip(text: request.platform)
                }
                .padding(PocketSpacing.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hudPanel(PocketColor.bgSunken)
                Text("Approve only if you are holding that device and started pairing on it.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            HStack {
                Spacer()
                // Escape denies. Approving a device is never the safe
                // default, so Allow gets no keyboard shortcut.
                Button("Deny") {
                    try? app.core.denyPairing(id: request.id)
                    app.pendingPairingRequest = nil
                    dismiss()
                }
                .buttonStyle(.hudDestructive)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Deny \(request.deviceName)")
                Button("Allow") {
                    try? app.core.approvePairing(id: request.id)
                    app.pendingPairingRequest = nil
                    dismiss()
                }
                .buttonStyle(.hudProminent)
                .accessibilityLabel("Allow \(request.deviceName) to use this Mac")
            }
        }
        .padding(PocketSpacing.s16)
        .frame(width: 480)
        .background(PocketColor.bgSurface)
    }
}
