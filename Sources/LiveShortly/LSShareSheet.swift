import AppKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// Everything about who can see a session, in one place: how the link behaves,
/// whether it is on the public feed, and the people invited by name.
///
/// The phone has the same controls; this is the Mac's own version of them
/// rather than its sheet, so the window keeps one visual language.
struct LSShareSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    @Binding var detail: LSSessionDetail?

    @State private var shares: [LSShare] = []
    @State private var inviteEmail = ""
    @State private var inviteRole = "viewer"
    @State private var busy = false
    @State private var errorText: String?
    @State private var copied = false

    private var visibility: String { detail?.visibility ?? "private" }
    private var linkRole: String { detail?.linkRole ?? "viewer" }
    private var isPublished: Bool { detail?.publishedAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HUDRule()
            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    accessCard
                    linkCard
                    feedCard
                    peopleCard
                    if let errorText {
                        Text(errorText)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(PocketSpacing.s16)
            }
        }
        .frame(width: 560, height: 580)
        .background(PocketColor.bgCanvas)
        .task { await loadShares() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.2")
                .foregroundStyle(PocketColor.accent)
                .accessibilityHidden(true)
            Text("Share session")
                .font(.pocket(.headline))
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.hud)
                .keyboardShortcut(.cancelAction)
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgSurface)
    }

    // MARK: - Access

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Who can open it")
            ForEach(Self.visibilities, id: \.key) { option in
                Button {
                    setVisibility(visibility: option.key)
                } label: {
                    HStack(alignment: .top, spacing: PocketSpacing.s8) {
                        Image(systemName: visibility == option.key
                            ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(
                                visibility == option.key
                                    ? PocketColor.accent : PocketColor.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.title).font(.pocket(.body))
                            Text(option.blurb)
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                // The filled circle is the only thing that said "chosen"; a
                // selected trait says it to VoiceOver too.
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(option.title). \(option.blurb)")
                .accessibilityAddTraits(
                    visibility == option.key ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel()
    }

    private static let visibilities: [(key: String, title: String, blurb: String)] = [
        ("private", "Private", "Only you and people you invite below."),
        ("link", "Anyone with the link", "Not listed anywhere; the link is the key."),
        ("public", "Public", "Anyone with the link, and it can appear on the feed."),
        ("open", "Open", "Readable without signing in at all."),
    ]

    // MARK: - Link

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Link")
            HStack(spacing: PocketSpacing.s8) {
                Text(linkString)
                    .font(.pocket(.mono))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: PocketSpacing.s8)
                Button(copied ? "Copied" : "Copy") { copyLink() }
                    .buttonStyle(.hud)
            }
            .padding(PocketSpacing.s8)
            .hudPanel(PocketColor.bgSunken)

            if visibility == "link" || visibility == "public" || visibility == "open" {
                Picker("People with the link can", selection: Binding(
                    get: { linkRole },
                    set: { setVisibility(linkRole: $0) })
                ) {
                    Text("Watch").tag("viewer")
                    Text("Watch and comment").tag("commenter")
                }
                .pickerStyle(.radioGroup)
                .font(.pocket(.body))
                .disabled(busy)
            } else {
                Text("The link only works for you until access is widened above.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel()
    }

    private var linkString: String {
        app.liveShortly.client?.sessionLink(sessionID).absoluteString ?? "—"
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(linkString, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    // MARK: - Feed

    private var feedCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            HStack {
                HUDLabel("Public feed")
                Spacer()
                Button(isPublished ? "Remove" : "Publish") { toggleFeed() }
                    .buttonStyle(isPublished ? .hud : .hudProminent)
                    .disabled(busy)
            }
            Text(
                isPublished
                    ? "Listed on the LiveShortly feed where anyone can find it."
                    : "Publishing lists this session on the public feed for anyone to find."
            )
            .font(.pocket(.caption))
            .foregroundStyle(PocketColor.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel()
    }

    // MARK: - People

    private var peopleCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Invited people · \(shares.count)")
            HStack(spacing: PocketSpacing.s8) {
                TextField("name@example.com", text: $inviteEmail)
                    .textFieldStyle(.plain)
                    .font(.pocket(.body))
                    .padding(PocketSpacing.s8)
                    .hudPanel(PocketColor.bgCanvas)
                Picker("Invited role", selection: $inviteRole) {
                    Text("Watch").tag("viewer")
                    Text("Comment").tag("commenter")
                }
                .labelsHidden()
                .fixedSize()
                Button("Invite") { invite() }
                    .buttonStyle(.hudProminent)
                    .accessibilityLabel("Invite this person")
                    .disabled(busy || !inviteEmail.contains("@"))
            }
            if shares.isEmpty {
                Text("Nobody has been invited by name yet.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                        if index > 0 { HUDRule() }
                        HStack(spacing: PocketSpacing.s8) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(PocketColor.textTertiary)
                                .accessibilityHidden(true)
                            Text(share.granteeEmail ?? "unknown")
                                .font(.pocket(.body))
                                .lineLimit(1)
                            Spacer(minLength: PocketSpacing.s8)
                            HUDChip(text: share.role == "commenter" ? "COMMENT" : "WATCH")
                            Button {
                                revoke(share)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(PocketColor.textTertiary)
                            .accessibilityLabel(
                                "Remove access for \(share.granteeEmail ?? "this person")")
                            .help("Remove access")
                        }
                        .padding(.vertical, PocketSpacing.s4)
                    }
                }
            }
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel()
    }

    // MARK: - Actions

    private func loadShares() async {
        guard let client = app.liveShortly.client else { return }
        do {
            shares = try await client.shares(sessionID)
            errorText = nil
        } catch {
            // A non-owner cannot list shares; that is not worth an error.
            shares = []
        }
    }

    private func setVisibility(visibility: String? = nil, linkRole: String? = nil) {
        guard let client = app.liveShortly.client else { return }
        busy = true
        Task {
            do {
                try await client.setVisibility(
                    sessionID, visibility: visibility, linkRole: linkRole)
                if let visibility { detail?.visibility = visibility }
                if let linkRole { detail?.linkRole = linkRole }
                errorText = nil
            } catch {
                errorText = "Couldn't change access: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func toggleFeed() {
        guard let client = app.liveShortly.client else { return }
        busy = true
        let publishing = !isPublished
        Task {
            do {
                if publishing {
                    try await client.publish(sessionID)
                    detail?.publishedAt = Date()
                } else {
                    try await client.unpublish(sessionID)
                    detail?.publishedAt = nil
                }
                errorText = nil
            } catch {
                errorText = "Couldn't update the feed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func invite() {
        guard let client = app.liveShortly.client else { return }
        let email = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            do {
                let share = try await client.createShare(
                    sessionID, email: email, role: inviteRole)
                shares.append(share)
                inviteEmail = ""
                errorText = nil
            } catch {
                errorText = "Couldn't invite \(email): \(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func revoke(_ share: LSShare) {
        guard let client = app.liveShortly.client else { return }
        busy = true
        Task {
            do {
                try await client.deleteShare(sessionID, shareID: share.id)
                shares.removeAll { $0.id == share.id }
                errorText = nil
            } catch {
                errorText = "Couldn't remove access: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}
