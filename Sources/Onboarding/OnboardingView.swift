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
    /// Why the download didn't start. Discarding this with `try?` left "Download"
    /// looking broken on the very first screen of the app.
    @State private var downloadError: String?

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            PocketMarkView(state: step == 1 ? .thinking(tokPerSec: nil) : .idle, size: 56)
                .accessibilityHidden(true)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of 3")
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
                .accessibilityAddTraits(.isHeader)
            Text("Private AI that runs on this Mac.")
                .font(.pocket(.title))
                .foregroundStyle(PocketColor.textSecondary)
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                bullet("Runs on this Mac, even offline. No account needed.")
                bullet("Your chats stay here. Nothing is sent to a cloud.")
                bullet("Pair your iPhone later to use this Mac's models from it.")
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.top, PocketSpacing.s8)
            Button("Get started") { step = 1 }
                .buttonStyle(.hudProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, PocketSpacing.s8)
        }
    }

    private var pickModel: some View {
        VStack(spacing: PocketSpacing.s12) {
            Text("Pick your first model")
                .font(.pocket(.title))
                .accessibilityAddTraits(.isHeader)
            Text("Download one and PocketAI works offline from then on.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
            VStack(spacing: PocketSpacing.s8) {
                if app.appleIntelligenceAvailable {
                    appleIntelligenceRow
                }
                ForEach(recommended, id: \.manifest.id) { entry in
                    onboardingModelRow(entry)
                }
                if recommended.isEmpty {
                    // An empty list read as a broken screen with only "Skip".
                    Text("No models to suggest right now. You can pick one later in Models.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if downloadId != nil {
                    Text("The download keeps going if you skip ahead.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let downloadError {
                    Text(downloadError)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 520)
            HStack(spacing: PocketSpacing.s8) {
                Button("Back") { step = 0 }
                    .buttonStyle(.hud)
                    .keyboardShortcut(.cancelAction)
                Button("Skip for now") { finish() }
                    .buttonStyle(.hud)
                if installedAny {
                    Button("Continue") {
                        useInstalledModelIfNeeded()
                        step = 2
                    }
                    .buttonStyle(.hudProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, PocketSpacing.s4)
        }
    }

    private var ready: some View {
        VStack(spacing: PocketSpacing.s12) {
            Text("You're set")
                .font(.pocket(.title))
                .accessibilityAddTraits(.isHeader)
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
                .keyboardShortcut(.defaultAction)
                .padding(.top, PocketSpacing.s4)
        }
    }

    private func onboardingModelRow(_ entry: CatalogEntry) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ModelNaming.short(entry.manifest.displayName))
                    .font(.pocket(.headline))
                // The fit reason is why to pick this one; two lines, secondary
                // contrast, rather than truncated tertiary text.
                Text("\(hudBytes(entry.fit.diskBytes)) · \(entry.fit.reason)")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityLabel(
                        "Downloading \(ModelNaming.short(entry.manifest.displayName))")
                    .accessibilityValue(progressText(entry))
                    HUDLabel(progressText(entry))
                }
            default:
                Button("Download") {
                    do {
                        try app.core.startDownload(modelId: entry.manifest.id)
                        downloadError = nil
                        downloadId = entry.manifest.id
                        startPolling()
                    } catch {
                        downloadError =
                            "Couldn't start that download: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.hudProminent)
                .accessibilityLabel(
                    "Download \(ModelNaming.short(entry.manifest.displayName)), \(hudBytes(entry.fit.diskBytes))")
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    /// Spec 7.1 step 3: Apple's on-device model needs no download, so it is
    /// the fastest way to a first answer when the Mac has it.
    private var appleIntelligenceRow: some View {
        HStack(spacing: PocketSpacing.s12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence")
                    .font(.pocket(.headline))
                Text("Start now with Apple's on-device model. No download.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Use") {
                app.currentModelId = AppModel.appleIntelligenceId
                step = 2
            }
            .buttonStyle(.hud)
            .accessibilityLabel("Use Apple Intelligence, no download")
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    private func progressText(_ entry: CatalogEntry) -> String {
        "\(hudBytes(entry.bytesDone)) of \(hudBytes(entry.fit.diskBytes))"
    }

    /// "Continue" with a model already on disk (a reinstall) must not open a
    /// chat bound to the default model id when that one isn't installed.
    private func useInstalledModelIfNeeded() {
        let installed = app.installedChatModels()
        guard app.currentModelId != AppModel.appleIntelligenceId,
              !installed.contains(where: { $0.manifest.id == app.currentModelId }),
              let first = installed.first
        else { return }
        app.currentModelId = first.manifest.id
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PocketSpacing.s8) {
            Text("—").foregroundStyle(PocketColor.accent)
                .accessibilityHidden(true)
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
                guard let id = downloadId,
                      let state = entries.first(where: { $0.manifest.id == id })?.state
                else { continue }
                if state == .installed {
                    app.currentModelId = id
                    step = 2
                    return
                }
                // A download that died leaves the row offering "Download" again;
                // without this the screen polls forever saying nothing.
                if case .failed(let reason) = state {
                    downloadError = "That download failed: \(reason)"
                    downloadId = nil
                    return
                }
            }
        }
    }

    /// These are sent as-is, so each must stand on its own — a "paste next"
    /// prompt got a reply to nothing.
    private static let starters = [
        "Explain how a hash map works, in two short paragraphs.",
        "Write a polite note declining a meeting.",
        "Give me five names for a weekend side project.",
    ]

    /// Finishing with a starter opens a chat already holding the question, so
    /// the first screen after onboarding is a conversation, not an empty box.
    private func finish(starter: String? = nil) {
        pollTask?.cancel()
        // Skipping mid-download: the chat should use the model being fetched,
        // not a default that may never be installed.
        if let downloadId { app.currentModelId = downloadId }
        app.hasOnboarded = true
        if let id = app.newChat(), let starter {
            app.chatModel(for: id).send(starter)
        }
    }
}
