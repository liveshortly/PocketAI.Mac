import PocketKit
import PocketUI
import SwiftUI

/// Model library: what is installed, what is downloading, what fits this Mac.
/// Fit comes from the core's own report — never a guess made in the UI.
struct ModelsView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [CatalogEntry] = []
    @State private var search = ""
    @State private var showInstalledOnly = false
    /// UI-128 / §7.3: the library opens on what this Mac can run; a search
    /// still looks at everything.
    @AppStorage("models.fitsOnly") private var fitsOnly = true
    @State private var formatFilter: FormatFilter = .all
    /// UI-128: hide models whose licence forbids commercial use.
    @AppStorage("models.commercialOnly") private var commercialOnly = false
    @State private var hubResults: [CatalogEntry] = []
    @State private var hubError: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var searching = false
    @State private var autoResumed: Set<String> = []
    @State private var confirmDelete: CatalogEntry?
    /// A refused delete used to leave the row exactly where it was with no
    /// explanation; the reason belongs on screen.
    @State private var deleteError: String?
    /// Previous state per model, so a transfer finishing (which moves no
    /// focus) can be announced to VoiceOver.
    @State private var lastStates: [String: ModelState] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            HUDRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    // UI-123: offline mode used to show live Download buttons
                    // that could only fail; say why network actions are off.
                    if app.offlineMode.isOn { offlineBanner }
                    if let deleteError {
                        Text(deleteError)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !downloading.isEmpty {
                        HUDLabel("Downloading")
                        ForEach(downloading, id: \.manifest.id) { entry in
                            ModelCard(entry: entry, onDelete: { confirmDelete = $0 })
                        }
                    }
                    if showsAppleIntelligence {
                        HUDLabel(showInstalledOnly ? "Installed" : "Library")
                        appleIntelligenceRow
                    }
                    // UI-128 / §7.3: browse by what the model is for.
                    ForEach(sections, id: \.title) { section in
                        HUDLabel(section.title)
                        ForEach(section.entries, id: \.manifest.id) { entry in
                            ModelCard(entry: entry, onDelete: { confirmDelete = $0 })
                        }
                    }
                    if filtered.isEmpty {
                        Text(emptyMessage)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                        .padding(.vertical, PocketSpacing.s8)
                    }
                    if !hubResults.isEmpty {
                        HUDLabel("Hugging Face")
                        ForEach(hubResults, id: \.manifest.id) { entry in
                            ModelCard(entry: entry, onDelete: { confirmDelete = $0 })
                        }
                    }
                    if let hubError {
                        Text(hubError)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                    }
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            HUDRule()
            diskBar
        }
        .background(PocketColor.bgCanvas)
        .task { startRefreshing() }
        .onChange(of: app.commandSerial) { _, _ in
            if app.pendingCommand == .refresh { reload() }
        }
        .onDisappear { refreshTask?.cancel() }
        // UI-124: the title was a sentence with the raw display name; the
        // short name, the space it frees and the default-model consequence
        // are what the decision needs.
        .confirmationDialog(
            "Delete \(ModelNaming.short(confirmDelete?.manifest.displayName ?? "model"))?",
            isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { target in
            Button("Delete", role: .destructive) {
                do {
                    try app.core.deleteModel(modelId: target.manifest.id)
                    deleteError = nil
                } catch {
                    deleteError = String(localized: "Couldn't delete \(target.manifest.displayName): ")
                        + error.localizedDescription
                }
                reload()
            }
        } message: { target in
            Text(deleteMessage(target))
        }
    }

    private func deleteMessage(_ target: CatalogEntry) -> String {
        var text = String(localized: "Frees \(hudBytes(target.fit.diskBytes)) on this Mac. ")
            + "You can download it again later."
        if app.currentModelId == target.manifest.id {
            text += " It's your default model, so new chats will need another one."
        }
        return text
    }

    // MARK: - States

    private var offlineBanner: some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PocketColor.textSecondary)
                .accessibilityHidden(true)
            Text("Offline mode is on. Downloads and Hugging Face search wait until you turn it off in Settings.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PocketSpacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(PocketColor.bgSunken)
        .accessibilityElement(children: .combine)
    }

    /// UI-122: one sentence per real cause. "No models match “”" showed when
    /// the search was empty and only the engine filter excluded everything.
    private var emptyMessage: String {
        let query = search.trimmingCharacters(in: .whitespaces)
        let engine = formatFilter == .all ? "" : "\(formatFilter.label) "
        if entries.isEmpty {
            return "The model catalog is empty. Press ⌘R to reload it."
        }
        if !query.isEmpty {
            let hub = query.count > 2 && !app.offlineMode.isOn
                ? " Press Return to search Hugging Face." : ""
            return "No \(engine)models here match “\(query)”.\(hub)"
        }
        if showInstalledOnly {
            return installed.isEmpty
                ? "No models installed yet. Turn off “Installed only” to browse the catalog."
                : "No \(engine)models installed. Choose All to see the rest."
        }
        return "No \(engine)models in the catalog."
    }

    /// UI-126: Apple's model needs no download, so it never had a catalog
    /// entry and could only be picked in onboarding or the chat menu.
    private var showsAppleIntelligence: Bool {
        guard app.appleIntelligenceAvailable, formatFilter == .all else { return false }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || "apple intelligence".contains(query)
    }

    private var appleIntelligenceRow: some View {
        let isDefault = app.currentModelId == AppModel.appleIntelligenceId
        return HStack(spacing: PocketSpacing.s8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: PocketSpacing.s8) {
                    Text("Apple Intelligence")
                        .font(.pocket(.headline))
                    HUDChip(text: "BUILT IN")
                    if isDefault { HUDChip(text: "DEFAULT", filled: true) }
                }
                Text("Apple's on-device model, part of macOS. No download.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer(minLength: 0)
            if !isDefault {
                Button("Use") { app.currentModelId = AppModel.appleIntelligenceId }
                    .buttonStyle(.hud)
                    .accessibilityLabel("Use Apple Intelligence for new chats")
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isDefault ? "Apple Intelligence, built in, default model" : "Apple Intelligence, built in")
    }

    private var header: some View {
        HStack(spacing: PocketSpacing.s12) {
            Text("Models")
                .font(.pocket(.headline))
            Spacer(minLength: 0)
            TextField("Search models", text: $search)
                .textFieldStyle(.plain)
                .font(.pocket(.body))
                .frame(width: 220)
                .padding(.horizontal, PocketSpacing.s8)
                .padding(.vertical, 5)
                .hudPanel(PocketColor.bgCanvas)
                .onSubmit(searchHub)
            // A Hugging Face search is a network round trip per format and was
            // tracked but never shown, so ⏎ looked like it did nothing.
            if searching {
                PocketMarkView(state: .loading, size: 16)
                    .accessibilityHidden(true) // the adjacent text carries the status
                HUDLabel("searching…")
            }
            // A named picker even with labels hidden: an empty title left this
            // control anonymous to VoiceOver.
            Picker("Engine", selection: $formatFilter) {
                ForEach(FormatFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("MLX runs through Apple's MLX; GGUF runs through llama.cpp. Both run on this Mac.")
            Toggle("Fits this Mac", isOn: $fitsOnly)
                .toggleStyle(.switch)
                .font(.pocket(.caption))
                .help("Hide models too big or unsupported for this Mac. Searching always shows everything.")
            Toggle("Commercial use", isOn: $commercialOnly)
                .toggleStyle(.switch)
                .font(.pocket(.caption))
                .help("Hide models whose licence doesn't allow commercial use.")
            Toggle("Installed only", isOn: $showInstalledOnly)
                .toggleStyle(.switch)
                .font(.pocket(.caption))
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private var diskBar: some View {
        HStack(spacing: PocketSpacing.s12) {
            HUDLabel("On disk")
            Text(hudBytes(installedBytes))
                .font(.pocket(.caption))
                .monospacedDigit()
            if let free = Self.freeDiskBytes() {
                Text("· \(hudBytes(free)) free")
                    .font(.pocket(.caption))
                    .monospacedDigit()
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer(minLength: 0)
            HUDLabel("\(installed.count) installed · \(entries.count) in catalog")
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    // MARK: - Data

    private var installed: [CatalogEntry] { entries.filter { $0.state == .installed } }

    private static func fits(_ entry: CatalogEntry) -> Bool {
        switch entry.fit.verdict {
        case .runsWell, .runsSlow: return true
        case .willNotFit, .notSupported: return false
        }
    }

    /// Space the system will give a new download (purgeable caches count).
    private static func freeDiskBytes() -> UInt64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }

    private var downloading: [CatalogEntry] {
        entries.filter {
            switch $0.state {
            case .downloading, .queued, .paused, .verifying: return true
            default: return false
            }
        }
    }

    private var installedBytes: UInt64 {
        installed.reduce(0) { $0 + $1.fit.diskBytes }
    }

    private var filtered: [CatalogEntry] {
        // Build the in-flight set once; testing `downloading` per row rescanned
        // the whole catalog for every entry.
        let inFlight = Set(downloading.map(\.manifest.id))
        var list = showInstalledOnly ? installed : entries
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        list = list.filter { entry in
            !inFlight.contains(entry.manifest.id)
                && formatFilter.accepts(entry.manifest.format)
                && (!commercialOnly || entry.manifest.license.commercialOk)
                && (!fitsOnly || !query.isEmpty || entry.state == .installed || Self.fits(entry))
        }
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.manifest.displayName.lowercased().contains(query)
                || $0.manifest.family.lowercased().contains(query)
                || $0.manifest.id.lowercased().contains(query)
        }
    }

    /// The filtered library split by purpose, in a fixed order, empty groups dropped.
    private var sections: [(title: String, entries: [CatalogEntry])] {
        func kind(_ e: CatalogEntry) -> String {
            let m = e.manifest.modalities
            if m.contains(.text) || m.contains(.vision) {
                return m.contains(.vision) ? "Vision" : "Chat"
            }
            if m.contains(.image) { return "Images" }
            if m.contains(.speechToText) || m.contains(.textToSpeech) { return "Voice" }
            return "Other"
        }
        let list = filtered
        return ["Chat", "Vision", "Images", "Voice", "Other"].compactMap { title in
            let group = list.filter { kind($0) == title }
            return group.isEmpty ? nil : (String(localized: String.LocalizationValue(title)), group)
        }
    }

    private func reload() {
        entries = app.core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        announceFinishedTransfers()
        resumeInterrupted()
    }

    /// A download reaching `installed` or `failed` changes the screen without
    /// moving focus, which is silent to a screen reader.
    private func announceFinishedTransfers() {
        for entry in entries {
            let id = entry.manifest.id
            let previous = lastStates[id]
            lastStates[id] = entry.state
            guard let previous, previous != entry.state else { continue }
            let name = ModelNaming.short(entry.manifest.displayName)
            switch (previous, entry.state) {
            case (.downloading, .installed), (.verifying, .installed), (.queued, .installed):
                AccessibilityNotification.Announcement(String(localized: "\(name) finished downloading")).post()
            case (.downloading, .failed), (.queued, .failed), (.verifying, .failed):
                AccessibilityNotification.Announcement(String(localized: "\(name) failed to download")).post()
            default:
                break
            }
        }
    }

    /// Resumes transfers that stopped on their own. A download the user paused
    /// is left alone — only failures that look transient are retried, and each
    /// is retried once per visit so a genuinely broken download cannot loop.
    private func resumeInterrupted() {
        guard !app.core.isOffline() else { return }
        for entry in entries {
            guard case .failed(let reason) = entry.state else { continue }
            let lowered = reason.lowercased()
            let transient = lowered.contains("network") || lowered.contains("connection")
                || lowered.contains("timed out") || lowered.contains("interrupted")
            guard transient, !autoResumed.contains(entry.manifest.id) else { continue }
            autoResumed.insert(entry.manifest.id)
            try? app.core.resumeDownload(modelId: entry.manifest.id)
        }
    }

    /// Download progress only shows up on subsequent `catalog()` calls, so the
    /// view polls while it is on screen — 1s is enough for a progress bar and
    /// cheap (a local read, no network).
    private func startRefreshing() {
        reload()
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                reload()
            }
        }
    }

    /// Hugging Face search takes one format per call, so a search covering
    /// both engines is two calls merged — otherwise GGUF models are invisible
    /// here even though llama.cpp can run them.
    private func searchHub() {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard query.count > 2 else {
            hubResults = []
            // Say why nothing happened; ⏎ on "qw" used to be a silent no-op.
            hubError = query.isEmpty
                ? nil : "Type at least three characters to search Hugging Face."
            return
        }
        guard !app.offlineMode.isOn else {
            hubResults = []
            hubError = "Offline mode is on, so Hugging Face isn't searched."
            return
        }
        hubError = nil
        searching = true
        let core = app.core
        let formats = formatFilter.hubFormats
        Task {
            // Hugging Face search is a blocking network call at the FFI
            // boundary; running it inline from onSubmit froze the window.
            let (found, failures) = await Task.detached {
                var found: [CatalogEntry] = []
                var failures: [String] = []
                for format in formats {
                    do {
                        found += try core.searchHub(query: query, format: format)
                    } catch {
                        failures.append(error.localizedDescription)
                    }
                }
                return (found, failures)
            }.value
            apply(found: found, failures: failures)
            searching = false
        }
    }

    private func apply(found: [CatalogEntry], failures: [String]) {
        // Drop anything already in the local catalog so the Hugging Face
        // section only shows what is genuinely new.
        let known = Set(entries.map(\.manifest.id))
        hubResults = found.filter { !known.contains($0.manifest.id) }
        hubError = found.isEmpty && !failures.isEmpty
            ? String(localized: "Hugging Face search failed: \(failures[0])") : nil
    }
}

/// Which engine's models to show. Both run locally; MLX is Apple's runtime,
/// GGUF goes through the built-in llama.cpp engine.
enum FormatFilter: CaseIterable, Hashable {
    case all, mlx, gguf

    var label: String {
        switch self {
        case .all: return "All"
        case .mlx: return "MLX"
        case .gguf: return "GGUF"
        }
    }

    /// Formats to query Hugging Face with for this filter.
    var hubFormats: [ModelFormat] {
        switch self {
        case .all: return [.mlxSafetensors, .gguf]
        case .mlx: return [.mlxSafetensors]
        case .gguf: return [.gguf]
        }
    }

    func accepts(_ format: ModelFormat) -> Bool {
        switch self {
        case .all: return true
        case .mlx: return format == .mlxSafetensors
        case .gguf: return format == .gguf
        }
    }
}

extension ModelFormat {
    /// Short badge text for a model card.
    var badge: String {
        switch self {
        case .mlxSafetensors: return "MLX"
        case .gguf: return "GGUF"
        case .coreMlPackage: return "Core ML"
        case .whisperKit: return "WhisperKit"
        }
    }

    /// What actually runs this model, said plainly for a tooltip.
    var engineDescription: String {
        switch self {
        case .mlxSafetensors: return "Runs on Apple's MLX runtime"
        case .gguf: return "Runs on the built-in llama.cpp engine"
        case .coreMlPackage: return "Runs on Core ML"
        case .whisperKit: return "Speech model, runs on WhisperKit"
        }
    }
}

/// Tracks transfer rate per model from successive catalog reads, so a
/// multi-gigabyte download can say how long it has left.
@MainActor
final class DownloadRates {
    static let shared = DownloadRates()
    private var samples: [String: (bytes: UInt64, at: Date)] = [:]
    private var rates: [String: Double] = [:]

    /// Bytes per second, smoothed, or nil until two samples exist.
    func observe(id: String, bytes: UInt64) -> Double? {
        let now = Date()
        defer { samples[id] = (bytes, now) }
        guard let previous = samples[id] else { return rates[id] }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0.5, bytes >= previous.bytes else { return rates[id] }
        let instant = Double(bytes - previous.bytes) / elapsed
        // Exponential smoothing: raw per-second deltas swing too much to read.
        let smoothed = rates[id].map { $0 * 0.7 + instant * 0.3 } ?? instant
        rates[id] = smoothed
        return smoothed
    }

    func forget(_ id: String) {
        samples[id] = nil
        rates[id] = nil
    }
}

/// Turns a raw download error into something actionable.
func failureSummary(_ reason: String) -> String {
    let lowered = reason.lowercased()
    if lowered.contains("checksum") || lowered.contains("sha") {
        return "The downloaded file didn't match its checksum. Retry to fetch it again."
    }
    if lowered.contains("space") || lowered.contains("disk") {
        return "Not enough disk space for this model."
    }
    if lowered.contains("network") || lowered.contains("connection")
        || lowered.contains("timed out") || lowered.contains("offline") {
        return "The download lost its connection."
    }
    return "The download failed."
}

/// One model: name, shape, fit verdict, and the action that applies to its
/// current state.
struct ModelCard: View {
    @Environment(AppModel.self) private var app
    let entry: CatalogEntry
    let onDelete: (CatalogEntry) -> Void
    /// What went wrong with the last action on this card. Every transfer
    /// control used to discard its error with `try?`, so a refused download,
    /// pause or cancel left a button that looked dead.
    @State private var actionError: String?
    /// The model's last benchmark (read from the store on appear, replaced by a
    /// fresh run) and whether one is running right now. A run generates real
    /// tokens for a few seconds, so it has to be visible while it happens.
    @State private var benchmark: Benchmark?
    @State private var benchmarking = false
    /// UI-121 / UI-125: a won't-fit download and a cancel each need a yes.
    @State private var confirmUnfit = false
    @State private var confirmCancel = false
    @State private var showDetail = false

    private var isDefault: Bool { app.currentModelId == entry.manifest.id }
    private var name: String { ModelNaming.short(entry.manifest.displayName) }
    private var offline: Bool { app.offlineMode.isOn }

    /// UI-127: only text and vision models can be the chat default; "Use" on
    /// an image or speech model set a default no chat could load.
    private var isChatModel: Bool {
        entry.manifest.modalities.contains(.text) || entry.manifest.modalities.contains(.vision)
    }

    /// Says what a non-chat model is for, in place of the "Use" button.
    private var purposeChip: String? {
        let m = entry.manifest.modalities
        if isChatModel { return nil }
        if m.contains(.image) { return "IMAGES" }
        if m.contains(.speechToText) || m.contains(.textToSpeech) { return "VOICE" }
        if m.contains(.embedding) { return "EMBEDDINGS" }
        return nil
    }

    private var fitKind: FitBadgeKind {
        switch entry.fit.verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }

    private func startDownload() {
        DownloadRates.shared.forget(entry.manifest.id)
        attempt("Download") { try app.core.startDownload(modelId: entry.manifest.id) }
    }

    /// Runs a core call and keeps its failure on the card instead of dropping
    /// it. `what` names the action in the user's words ("Pause").
    private func attempt(_ what: String, _ work: () throws -> Void) {
        do {
            try work()
            actionError = nil
        } catch {
            actionError = String(localized: "\(what) failed: \(error.localizedDescription)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            // UI-128: at the largest text sizes the controls drop under the name.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PocketSpacing.s8) {
                    titleBlock
                    Spacer(minLength: 0)
                    actions
                }
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    titleBlock
                    actions
                }
            }
            if case .downloading = entry.state { progress }
            if case .queued = entry.state { progress }
            if case .paused = entry.state { progress }
            if case .verifying = entry.state {
                // Spec C10 wording; "verifying" is the engineer's word.
                HUDLabel("Checking file…")
            }
            if case .failed(let reason) = entry.state {
                HStack(alignment: .top, spacing: PocketSpacing.s8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failureSummary(reason))
                            .font(.pocket(.body))
                        Text(reason)
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button("Retry") {
                        DownloadRates.shared.forget(entry.manifest.id)
                        attempt("Retry") {
                            try app.core.startDownload(modelId: entry.manifest.id)
                        }
                    }
                    .buttonStyle(.hud)
                    .frame(minHeight: 44)
                    .disabled(offline)
                    .help(offline ? "Turn off offline mode to retry." : "")
                    .accessibilityLabel(
                        "Retry downloading \(ModelNaming.short(entry.manifest.displayName))")
                }
                .padding(PocketSpacing.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hudPanel(PocketColor.statusBad.opacity(0.08))
            }
            fitLine
            benchmarkLine
            if let actionError {
                HStack(alignment: .top, spacing: PocketSpacing.s8) {
                    Text(actionError)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") { self.actionError = nil }
                        .buttonStyle(.plain)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            HStack(spacing: PocketSpacing.s12) {
                HUDLabel(entry.manifest.license.spdx.isEmpty
                    ? "license unknown" : entry.manifest.license.spdx)
                if !entry.manifest.license.commercialOk {
                    HUDChip(text: "NON-COMMERCIAL", tint: PocketColor.statusWarn)
                }
                Spacer(minLength: 0)
                Button("Details") { showDetail = true }
                    .buttonStyle(.plain)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.accent)
                    .accessibilityLabel("Details for \(name)")
                if let url = URL(string: entry.manifest.license.url),
                   !entry.manifest.license.url.isEmpty {
                    Link("License", destination: url)
                        .font(.pocket(.caption))
                }
                if !entry.manifest.hfRepo.isEmpty,
                   let repo = URL(string: "https://huggingface.co/\(entry.manifest.hfRepo)") {
                    Link("Source", destination: repo)
                        .font(.pocket(.caption))
                }
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
        // A card is a name, a shape, a verdict and a row of controls. As a
        // container with its own label it reads as one model instead of a
        // dozen loose strings.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardSummary)
        .confirmationDialog(
            "Download \(name) anyway?", isPresented: $confirmUnfit, titleVisibility: .visible
        ) {
            Button("Download anyway") { startDownload() }
        } message: {
            Text("\(entry.fit.reason) It may not load, or may slow this Mac down.")
        }
        .confirmationDialog(
            "Cancel downloading \(name)?", isPresented: $confirmCancel, titleVisibility: .visible
        ) {
            Button("Cancel download", role: .destructive) {
                attempt("Cancel") { try app.core.cancelDownload(modelId: entry.manifest.id) }
            }
            Button("Keep downloading", role: .cancel) {}
        } message: {
            Text("\(hudBytes(entry.bytesDone)) of \(hudBytes(entry.fit.diskBytes)) is downloaded. "
                + "Pause instead if you want to pick it up later.")
        }
        .sheet(isPresented: $showDetail) { ModelDetailView(entry: entry) }
        .task(id: entry.manifest.id) {
            // A cheap local read, not a run: shows the previous result so the
            // user isn't made to re-measure to see a number they already have.
            if entry.state == .installed, benchmark == nil {
                benchmark = app.core.storedBenchmark(id: entry.manifest.id)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: PocketSpacing.s8) {
                Text(ModelNaming.short(entry.manifest.displayName))
                    .font(.pocket(.headline))
                HUDChip(text: entry.manifest.format.badge)
                    .help(entry.manifest.format.engineDescription)
                if let purposeChip { HUDChip(text: purposeChip) }
                if isDefault { HUDChip(text: "DEFAULT", filled: true) }
            }
            Text(subtitle)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
    }

    /// What this model actually did on this Mac, and the state of a run in
    /// progress. Only installed models can be measured.
    @ViewBuilder private var benchmarkLine: some View {
        if benchmarking {
            HStack(spacing: PocketSpacing.s8) {
                PocketMarkView(state: .loading, size: 16)
                    .accessibilityHidden(true) // the adjacent text carries the status
                HUDLabel("benchmarking… generating tokens on this Mac")
            }
        } else if let benchmark {
            HStack(spacing: PocketSpacing.s12) {
                HUDLabel(String(localized: "\(Int(benchmark.tps)) tok/s"))
                HUDLabel(String(localized: "\(benchmark.ttftMs) ms to first token"))
                if benchmark.peakBytes > 0 {
                    HUDLabel(String(localized: "\(hudBytes(benchmark.peakBytes)) peak"))
                }
                Spacer(minLength: 0)
                Button("Re-run") { runBenchmark() }
                    .buttonStyle(.plain)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.accent)
                    .accessibilityLabel(
                        "Benchmark \(ModelNaming.short(entry.manifest.displayName)) again")
            }
        }
    }

    /// Measures the model for real: seconds of inference behind a blocking FFI
    /// call, so it runs off the main actor — inline it would freeze the window.
    private func runBenchmark() {
        guard !benchmarking else { return }
        benchmarking = true
        actionError = nil
        let core = app.core
        let id = entry.manifest.id
        Task {
            let outcome = await Task.detached { () -> Result<Benchmark, Error> in
                do { return .success(try core.benchmarkModel(id: id)) } catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let measured): benchmark = measured
            case .failure(let error):
                actionError = "Benchmark failed: " + error.localizedDescription
            }
            benchmarking = false
        }
    }

    /// What this card is, said once: name, state, shape and fit verdict.
    private var cardSummary: String {
        var parts = [name, stateWord]
        if isDefault { parts.append("default model") }
        if let purposeChip { parts.append("for \(purposeChip.lowercased())") }
        parts.append(entry.manifest.format.badge)
        parts.append(subtitle)
        parts.append(entry.fit.reason)
        return parts.joined(separator: ", ")
    }

    private var stateWord: String {
        switch entry.state {
        case .installed: return "installed"
        case .downloading: return "downloading"
        case .queued: return "queued"
        case .paused: return "paused"
        case .verifying: return "verifying"
        case .failed: return "download failed"
        case .available: return "not installed"
        }
    }

    private var subtitle: String {
        var bits = [entry.manifest.family, entry.manifest.quant]
        // Format already shows as a badge, so the line carries the rest.
        if entry.manifest.paramsB > 0 {
            bits.append(String(format: "%.1fB", entry.manifest.paramsB))
        }
        bits.append(String(localized: "\(entry.manifest.contextLength) ctx"))
        bits.append(hudBytes(entry.fit.diskBytes))
        return bits.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var fitLine: some View {
        HStack(spacing: PocketSpacing.s8) {
            // UI-120: the verdict was a colored dot only; the shared badge
            // names it ("Won't fit") so color isn't the sole signal.
            FitBadge(kind: fitKind, reason: entry.fit.reason)
            Text(entry.fit.reason)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
                .lineLimit(2)
                .accessibilityHidden(true) // the badge's label carries the reason
            Spacer(minLength: 0)
            if let measured = entry.fit.measuredTokensPerSec {
                HUDLabel(String(localized: "\(Int(measured)) tok/s measured"))
            } else if let est = entry.fit.estTokensPerSec {
                HUDLabel(String(localized: "~\(Int(est)) tok/s est."))
            }
        }
    }

    /// Icon-only and one-word controls need a label that says what they do to
    /// which model — "Download" alone tells a screen reader nothing.
    @ViewBuilder private var actions: some View {
        switch entry.state {
        case .installed:
            HStack(spacing: PocketSpacing.s8) {
                if !isDefault && isChatModel {
                    Button("Use") { app.currentModelId = entry.manifest.id }
                        .buttonStyle(.hud)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Use \(name) for new chats")
                }
                Menu {
                    Button(benchmark == nil ? "Benchmark on this Mac" : "Benchmark again") {
                        runBenchmark()
                    }
                    .disabled(benchmarking)
                    Button("Unload from memory") {
                        attempt("Unload") { try app.core.unloadModel(id: entry.manifest.id) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { onDelete(entry) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More actions for \(name)")
            }
        case .downloading, .queued:
            Button("Pause") {
                attempt("Pause") { try app.core.pauseDownload(modelId: entry.manifest.id) }
            }
            .buttonStyle(.hud)
            .frame(minHeight: 44)
            .accessibilityLabel("Pause downloading \(name)")
        case .paused:
            Button("Resume") {
                attempt("Resume") { try app.core.resumeDownload(modelId: entry.manifest.id) }
            }
            .buttonStyle(.hud)
            .frame(minHeight: 44)
            .disabled(offline)
            .help(offline ? "Turn off offline mode to resume." : "")
            .accessibilityLabel("Resume downloading \(name)")
        case .verifying:
            EmptyView()
        case .available:
            downloadButton
        case .failed:
            // UI-128: the failure panel already has Retry; a second
            // Download beside it did the same thing.
            EmptyView()
        }
    }

    /// UI-119: "Download", matching onboarding (was "Get"). UI-121: a model
    /// the core says this Mac can't run is not offered at all; one that won't
    /// fit is a secondary button behind a confirmation that gives the reason.
    @ViewBuilder private var downloadButton: some View {
        let size = hudBytes(entry.fit.diskBytes)
        switch entry.fit.verdict {
        case .notSupported:
            Button("Download") {}
                .buttonStyle(.hud)
                .disabled(true)
                .help(entry.fit.reason)
                .accessibilityLabel("Download \(name), unavailable")
                .accessibilityHint(entry.fit.reason)
        case .willNotFit:
            Button("Download anyway…") { confirmUnfit = true }
                .buttonStyle(.hud)
                .frame(minHeight: 44)
                .disabled(offline)
                .help(offline ? "Turn off offline mode to download." : entry.fit.reason)
                .accessibilityLabel("Download \(name) anyway, \(size)")
                .accessibilityHint(entry.fit.reason)
        case .runsWell, .runsSlow:
            Button("Download") { startDownload() }
                .buttonStyle(.hudProminent)
                .frame(minHeight: 44)
                .disabled(offline)
                .help(offline ? String(localized: "Turn off offline mode to download.") : String(localized: "Download \(size)"))
                .accessibilityLabel("Download \(name), \(size)")
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressRing(fraction: fraction)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
                HUDLabel(String(localized: "\(hudBytes(entry.bytesDone)) of \(hudBytes(entry.fit.diskBytes))"))
                if let detail = rateAndETA { HUDLabel(detail) }
                Spacer()
                Button("Cancel…") { confirmCancel = true }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
                    .accessibilityLabel("Cancel downloading \(name)")
            }
        }
    }

    /// "12.4 MB/s · about 3 min left", once a rate can be measured.
    private var rateAndETA: String? {
        guard case .downloading = entry.state,
              let rate = DownloadRates.shared.observe(
                id: entry.manifest.id, bytes: entry.bytesDone),
              rate > 0
        else { return nil }
        var parts = ["\(hudBytes(UInt64(rate)))/s"]
        let remaining = Double(entry.fit.diskBytes) - Double(entry.bytesDone)
        if remaining > 0 {
            let seconds = remaining / rate
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = seconds < 3600 ? [.minute, .second] : [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            if let left = formatter.string(from: seconds) { parts.append(String(localized: "\(left) left")) }
        }
        return parts.joined(separator: " · ")
    }

    private var fraction: Double {
        guard entry.fit.diskBytes > 0 else { return 0 }
        return min(1, Double(entry.bytesDone) / Double(entry.fit.diskBytes))
    }
}

/// UI-128 / spec C10: a determinate ring that ends in a check.
struct ProgressRing: View {
    let fraction: Double
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(PocketColor.lineStrong, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(PocketColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if fraction >= 1 {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(PocketColor.statusOk)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
    }
}

/// UI-128: everything the manifest knows about one model.
struct ModelDetailView: View {
    let entry: CatalogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = entry.manifest
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            Text(ModelNaming.short(m.displayName)).font(.pocket(.headline))
            Form {
                LabeledContent("Family", value: m.family)
                LabeledContent("Format", value: m.format.badge)
                LabeledContent("Size", value: hudBytes(entry.fit.diskBytes))
                if m.paramsB > 0 { LabeledContent("Parameters", value: String(format: "%.1fB", m.paramsB)) }
                if !m.quant.isEmpty { LabeledContent("Quantisation", value: m.quant) }
                LabeledContent("Context", value: String(localized: "\(m.contextLength) tokens"))
                LabeledContent("Memory needed", value: hudBytes(m.minRamBytes))
                LabeledContent("Licence", value: m.license.spdx.isEmpty ? String(localized: "unknown") : m.license.spdx)
                LabeledContent("Commercial use", value: m.license.commercialOk ? String(localized: "Allowed") : String(localized: "Not allowed"))
                LabeledContent("Fit on this Mac", value: entry.fit.reason)
                if !m.tags.isEmpty { LabeledContent("Tags", value: m.tags.joined(separator: ", ")) }
                if !m.hfRepo.isEmpty { LabeledContent("Source", value: m.hfRepo) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.hudProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PocketSpacing.s16)
        .frame(width: 480, height: 460)
        .background(PocketColor.bgSurface)
    }
}
