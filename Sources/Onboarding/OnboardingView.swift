import PocketKit
import PocketUI
import SwiftUI

/// First launch: say what this app is, get one model onto the machine, done.
/// Three steps, skippable — nobody should have to read a tour to start typing.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var step = 0
    @State private var downloadId: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var entries: [CatalogEntry] = []

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            PocketMarkView(state: step == 1 ? .working(tokPerSec: nil) : .idle, size: 56)
            switch step {
            case 0: welcome
            case 1: pickModel
            default: ready
            }
            Spacer()
            HStack(spacing: PocketSpacing.s8) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(index == step ? PocketColor.accent : PocketColor.lineStrong)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, PocketSpacing.s16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PocketColor.bgCanvas)
        .task { reload() }
        .onDisappear { pollTask?.cancel() }
    }

    private var welcome: some View {
        VStack(spacing: PocketSpacing.s12) {
            Text("PocketAI")
                .font(.pocket(.display))
            Text("Private AI that runs on this Mac.")
                .font(.pocket(.title))
                .foregroundStyle(PocketColor.textSecondary)
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                bullet("No account, no cloud — your chats never leave this machine.")
                bullet("Models run on Apple silicon through MLX.")
                bullet("Pair your iPhone later and it can use this Mac's models.")
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.top, PocketSpacing.s8)
            Button("Continue") { step = 1 }
                .buttonStyle(.hudProminent)
                .padding(.top, PocketSpacing.s8)
        }
    }

    private var pickModel: some View {
        VStack(spacing: PocketSpacing.s12) {
            Text("Choose a model")
                .font(.pocket(.title))
            Text("One download and the app works offline for good.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
            VStack(spacing: PocketSpacing.s8) {
                ForEach(recommended, id: \.manifest.id) { entry in
                    onboardingModelRow(entry)
                }
            }
            .frame(maxWidth: 520)
            HStack(spacing: PocketSpacing.s8) {
                Button("Skip for now") { finish() }
                    .buttonStyle(.hud)
                if installedAny {
                    Button("Continue") { step = 2 }
                        .buttonStyle(.hudProminent)
                }
            }
            .padding(.top, PocketSpacing.s4)
        }
    }

    private var ready: some View {
        VStack(spacing: PocketSpacing.s12) {
            Text("You're set")
                .font(.pocket(.title))
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                bullet("⌘N starts a chat, ⌘K jumps to anything.")
                bullet("The menu bar icon asks from any app.")
                bullet("Connect LiveShortly in Settings to watch your coding agents.")
            }
            .frame(maxWidth: 440, alignment: .leading)
            VStack(spacing: PocketSpacing.s8) {
                HUDLabel("Try one")
                ForEach(Self.starters, id: \.self) { starter in
                    Button {
                        finish(starter: starter)
                    } label: {
                        Text(starter)
                            .font(.pocket(.body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, PocketSpacing.s12)
                            .padding(.vertical, PocketSpacing.s8)
                            .hudPanel()
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 440)
            .padding(.top, PocketSpacing.s8)

            Button("Start using PocketAI") { finish() }
                .buttonStyle(.hudProminent)
                .padding(.top, PocketSpacing.s4)
        }
    }

    private func onboardingModelRow(_ entry: CatalogEntry) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.manifest.displayName)
                    .font(.pocket(.headline))
                Text("\(hudBytes(entry.fit.diskBytes)) · \(entry.fit.reason)")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch entry.state {
            case .installed:
                HUDChip(text: "INSTALLED", filled: true)
            case .downloading, .queued, .verifying:
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(
                        value: entry.fit.diskBytes > 0
                            ? min(1, Double(entry.bytesDone) / Double(entry.fit.diskBytes)) : 0
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                    .tint(PocketColor.accent)
                    HUDLabel(hudBytes(entry.bytesDone))
                }
            default:
                Button("Get") {
                    try? app.core.startDownload(modelId: entry.manifest.id)
                    downloadId = entry.manifest.id
                    startPolling()
                }
                .buttonStyle(.hudProminent)
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PocketSpacing.s8) {
            Text("—").foregroundStyle(PocketColor.accent)
            Text(text)
                .font(.pocket(.body))
                .foregroundStyle(PocketColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recommended: [CatalogEntry] {
        entries
            .filter { $0.manifest.curated && $0.fit.verdict != .willNotFit
                && $0.fit.verdict != .notSupported }
            .sorted { $0.fit.diskBytes < $1.fit.diskBytes }
            .prefix(3)
            .map { $0 }
    }

    private var installedAny: Bool { entries.contains { $0.state == .installed } }

    private func reload() {
        entries = app.core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                reload()
                if let id = downloadId,
                   entries.first(where: { $0.manifest.id == id })?.state == .installed {
                    app.currentModelId = id
                    step = 2
                    return
                }
            }
        }
    }

    private static let starters = [
        "Explain what this app can do, briefly.",
        "Summarise the text I paste next.",
        "Draft a commit message from a diff I'll paste.",
    ]

    /// Finishing with a starter opens a chat already holding the question, so
    /// the first screen after onboarding is a conversation, not an empty box.
    private func finish(starter: String? = nil) {
        pollTask?.cancel()
        app.hasOnboarded = true
        if let id = app.newChat(), let starter {
            app.chatModel(for: id).send(starter)
        }
    }
}
