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
    @State private var formatFilter: FormatFilter = .all
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
                    if let deleteError {
                        Text(deleteError)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !downloading.isEmpty {
                        HUDLabel(String(localized: "Downloading"))
                        ForEach(downloading, id: \.manifest.id) { entry in
                            ModelCard(entry: entry, onDelete: { confirmDelete = $0 })
                        }
                    }
                    HUDLabel(
                        showInstalledOnly
                            ? String(localized: "Installed") : String(localized: "Library"))
                    ForEach(filtered, id: \.manifest.id) { entry in
                        ModelCard(entry: entry, onDelete: { confirmDelete = $0 })
                    }
                    if filtered.isEmpty {
                        Text(
                            showInstalledOnly
                                ? "No models installed yet. Turn off “installed only” to browse the catalog."
                                : "No models match “\(search)”."
                        )
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                        .padding(.vertical, PocketSpacing.s8)
                    }
                    if !hubResults.isEmpty {
                        HUDLabel(String(localized: "Hugging Face"))
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
        .confirmationDialog(
            "Delete \(confirmDelete?.manifest.displayName ?? String(localized: "model"))? The files are removed from this Mac.",
            isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete model", role: .destructive) {
                guard let target = confirmDelete else { return }
                do {
                    try app.core.deleteModel(modelId: target.manifest.id)
                    deleteError = nil
                } catch {
                    deleteError = String(
                        localized:
                            "Couldn't delete \(target.manifest.displayName): \(error.localizedDescription)")
                }
                reload()
            }
        }
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
                ProgressView()
                    .controlSize(.small)
                HUDLabel(String(localized: "searching…"))
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
            Toggle("Installed only", isOn: $showInstalledOnly)
                .toggleStyle(.switch)
                .font(.pocket(.caption))
                .tint(PocketColor.accent)
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private var diskBar: some View {
        HStack(spacing: PocketSpacing.s12) {
            HUDLabel(String(localized: "On disk"))
            Text(hudBytes(installedBytes))
                .font(.pocket(.caption))
                .monospacedDigit()
            Spacer(minLength: 0)
            HUDLabel(
                String(localized: "\(installed.count) installed · \(entries.count) in catalog"))
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    // MARK: - Data

    private var installed: [CatalogEntry] { entries.filter { $0.state == .installed } }

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
        list = list.filter { entry in
            !inFlight.contains(entry.manifest.id)
                && formatFilter.accepts(entry.manifest.format)
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.manifest.displayName.lowercased().contains(query)
                || $0.manifest.family.lowercased().contains(query)
                || $0.manifest.id.lowercased().contains(query)
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
                AccessibilityNotification.Announcement(
                    String(localized: "\(name) finished downloading")).post()
            case (.downloading, .failed), (.queued, .failed), (.verifying, .failed):
                AccessibilityNotification.Announcement(
                    String(localized: "\(name) failed to download")).post()
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
                ? nil
                : String(localized: "Type at least three characters to search Hugging Face.")
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
        case .all: return String(localized: "All")
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
        case .mlxSafetensors: return String(localized: "Runs on Apple's MLX runtime")
        case .gguf: return String(localized: "Runs on the built-in llama.cpp engine")
        case .coreMlPackage: return String(localized: "Runs on Core ML")
        case .whisperKit: return String(localized: "Speech model, runs on WhisperKit")
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
        return String(
            localized: "The downloaded file didn't match its checksum. Retry to fetch it again.")
    }
    if lowered.contains("space") || lowered.contains("disk") {
        return String(localized: "Not enough disk space for this model.")
    }
    if lowered.contains("network") || lowered.contains("connection")
        || lowered.contains("timed out") || lowered.contains("offline") {
        return String(localized: "The download lost its connection.")
    }
    return String(localized: "The download failed.")
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

    private var isDefault: Bool { app.currentModelId == entry.manifest.id }

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
            HStack(spacing: PocketSpacing.s8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: PocketSpacing.s8) {
                        Text(ModelNaming.short(entry.manifest.displayName))
                            .font(.pocket(.headline))
                        HUDChip(text: entry.manifest.format.badge)
                            .help(entry.manifest.format.engineDescription)
                        if isDefault {
                            HUDChip(text: String(localized: "DEFAULT"), filled: true)
                        }
                    }
                    Text(subtitle)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                Spacer(minLength: 0)
                actions
            }
            if case .downloading = entry.state { progress }
            if case .queued = entry.state { progress }
            if case .paused = entry.state { progress }
            if case .verifying = entry.state {
                HUDLabel(String(localized: "verifying…"))
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
                        attempt(String(localized: "Retry")) {
                            try app.core.startDownload(modelId: entry.manifest.id)
                        }
                    }
                    .buttonStyle(.hud)
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
                    ? String(localized: "license unknown") : entry.manifest.license.spdx)
                if !entry.manifest.license.commercialOk {
                    HUDChip(
                        text: String(localized: "NON-COMMERCIAL"),
                        tint: PocketColor.statusWarn)
                }
                Spacer(minLength: 0)
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
        .task(id: entry.manifest.id) {
            // A cheap local read, not a run: shows the previous result so the
            // user isn't made to re-measure to see a number they already have.
            if entry.state == .installed, benchmark == nil {
                benchmark = app.core.storedBenchmark(id: entry.manifest.id)
            }
        }
    }

    /// What this model actually did on this Mac, and the state of a run in
    /// progress. Only installed models can be measured.
    @ViewBuilder private var benchmarkLine: some View {
        if benchmarking {
            HStack(spacing: PocketSpacing.s8) {
                ProgressView()
                    .controlSize(.small)
                HUDLabel(String(localized: "benchmarking… generating tokens on this Mac"))
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
                actionError = String(localized: "Benchmark failed: \(error.localizedDescription)")
            }
            benchmarking = false
        }
    }

    /// What this card is, said once: name, state, shape and fit verdict.
    private var cardSummary: String {
        var parts = [ModelNaming.short(entry.manifest.displayName), stateWord]
        if isDefault { parts.append(String(localized: "default model")) }
        parts.append(entry.manifest.format.badge)
        parts.append(subtitle)
        parts.append(entry.fit.reason)
        return parts.joined(separator: ", ")
    }

    private var stateWord: String {
        switch entry.state {
        case .installed: return String(localized: "installed")
        case .downloading: return String(localized: "downloading")
        case .queued: return String(localized: "queued")
        case .paused: return String(localized: "paused")
        case .verifying: return String(localized: "verifying")
        case .failed: return String(localized: "download failed")
        case .available: return String(localized: "not installed")
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
            HUDDot(tint: fitTint)
            Text(entry.fit.reason)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let measured = entry.fit.measuredTokensPerSec {
                HUDLabel(String(localized: "\(Int(measured)) tok/s measured"))
            } else if let est = entry.fit.estTokensPerSec {
                HUDLabel(String(localized: "~\(Int(est)) tok/s est."))
            }
        }
    }

    private var fitTint: Color {
        switch entry.fit.verdict {
        case .runsWell: return PocketColor.statusOk
        case .runsSlow: return PocketColor.statusWarn
        case .willNotFit, .notSupported: return PocketColor.statusBad
        }
    }

    /// Icon-only and one-word controls need a label that says what they do to
    /// which model — "Get" alone tells a screen reader nothing.
    @ViewBuilder private var actions: some View {
        let name = ModelNaming.short(entry.manifest.displayName)
        switch entry.state {
        case .installed:
            HStack(spacing: PocketSpacing.s8) {
                if !isDefault {
                    Button("Use") { app.currentModelId = entry.manifest.id }
                        .buttonStyle(.hud)
                        .accessibilityLabel("Use \(name) for new chats")
                }
                Menu {
                    Button(benchmark == nil ? "Benchmark on this Mac" : "Benchmark again") {
                        runBenchmark()
                    }
                    .disabled(benchmarking)
                    Button("Unload from memory") {
                        attempt(String(localized: "Unload")) {
                            try app.core.unloadModel(id: entry.manifest.id)
                        }
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
                attempt(String(localized: "Pause")) {
                    try app.core.pauseDownload(modelId: entry.manifest.id)
                }
            }
            .buttonStyle(.hud)
            .accessibilityLabel("Pause downloading \(name)")
        case .paused:
            Button("Resume") {
                attempt(String(localized: "Resume")) {
                    try app.core.resumeDownload(modelId: entry.manifest.id)
                }
            }
            .buttonStyle(.hud)
            .accessibilityLabel("Resume downloading \(name)")
        case .verifying:
            EmptyView()
        case .available, .failed:
            Button(entry.fit.verdict == .willNotFit ? "Get anyway" : "Get") {
                attempt(String(localized: "Download")) {
                    try app.core.startDownload(modelId: entry.manifest.id)
                }
            }
            .buttonStyle(.hudProminent)
            .accessibilityLabel("Download \(name)")
            .accessibilityHint(entry.fit.verdict == .willNotFit ? entry.fit.reason : "")
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(PocketColor.accent)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(fraction * 100)) percent")
            HStack {
                HUDLabel(
                    String(
                        localized: "\(hudBytes(entry.bytesDone)) of \(hudBytes(entry.fit.diskBytes))"
                    ))
                if let detail = rateAndETA { HUDLabel(detail) }
                Spacer()
                Button("Cancel") {
                    attempt(String(localized: "Cancel")) {
                        try app.core.cancelDownload(modelId: entry.manifest.id)
                    }
                }
                .buttonStyle(.plain)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
                    .accessibilityLabel(
                        "Cancel downloading \(ModelNaming.short(entry.manifest.displayName))")
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
        var parts = [String(localized: "\(hudBytes(UInt64(rate)))/s")]
        let remaining = Double(entry.fit.diskBytes) - Double(entry.bytesDone)
        if remaining > 0 {
            let seconds = remaining / rate
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = seconds < 3600 ? [.minute, .second] : [.hour, .minute]
            formatter.unitsStyle = .abbreviated
            if let left = formatter.string(from: seconds) {
                parts.append(String(localized: "\(left) left"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private var fraction: Double {
        guard entry.fit.diskBytes > 0 else { return 0 }
        return min(1, Double(entry.bytesDone) / Double(entry.fit.diskBytes))
    }
}
