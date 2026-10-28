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
    @State private var confirmDelete: CatalogEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            HUDRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    if !downloading.isEmpty {
                        HUDLabel("Downloading")
                        ForEach(downloading, id: \.manifest.id) { entry in
                            ModelCard(entry: entry, onDelete: { confirmDelete = $0 })
                        }
                    }
                    HUDLabel(showInstalledOnly ? "Installed" : "Library")
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
        .confirmationDialog(
            "Delete \(confirmDelete?.manifest.displayName ?? "model")? The files are removed from this Mac.",
            isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete model", role: .destructive) {
                guard let target = confirmDelete else { return }
                try? app.core.deleteModel(modelId: target.manifest.id)
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
            Picker("", selection: $formatFilter) {
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
            HUDLabel("On disk")
            Text(hudBytes(installedBytes))
                .font(.pocket(.caption))
                .monospacedDigit()
            Spacer(minLength: 0)
            HUDLabel("\(installed.count) installed · \(entries.count) in catalog")
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
            ? "Hugging Face search failed: \(failures[0])" : nil
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

/// One model: name, shape, fit verdict, and the action that applies to its
/// current state.
struct ModelCard: View {
    @Environment(AppModel.self) private var app
    let entry: CatalogEntry
    let onDelete: (CatalogEntry) -> Void

    private var isDefault: Bool { app.currentModelId == entry.manifest.id }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack(spacing: PocketSpacing.s8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: PocketSpacing.s8) {
                        Text(entry.manifest.displayName)
                            .font(.pocket(.headline))
                        HUDChip(text: entry.manifest.format.badge)
                            .help(entry.manifest.format.engineDescription)
                        if isDefault { HUDChip(text: "DEFAULT", filled: true) }
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
                HUDLabel("verifying…")
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
                        try? app.core.startDownload(modelId: entry.manifest.id)
                    }
                    .buttonStyle(.hud)
                }
                .padding(PocketSpacing.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hudPanel(PocketColor.statusBad.opacity(0.08))
            }
            fitLine
            HStack(spacing: PocketSpacing.s12) {
                HUDLabel(entry.manifest.license.spdx.isEmpty
                    ? "license unknown" : entry.manifest.license.spdx)
                if !entry.manifest.license.commercialOk {
                    HUDChip(text: "NON-COMMERCIAL", tint: PocketColor.statusWarn)
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
    }

    /// Turns a raw download error into something actionable.
    private func failureSummary(_ reason: String) -> String {
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

    private var subtitle: String {
        var bits = [entry.manifest.family, entry.manifest.quant]
        // Format already shows as a badge, so the line carries the rest.
        if entry.manifest.paramsB > 0 {
            bits.append(String(format: "%.1fB", entry.manifest.paramsB))
        }
        bits.append("\(entry.manifest.contextLength) ctx")
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
                HUDLabel("\(Int(measured)) tok/s measured")
            } else if let est = entry.fit.estTokensPerSec {
                HUDLabel("~\(Int(est)) tok/s est.")
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

    @ViewBuilder private var actions: some View {
        switch entry.state {
        case .installed:
            HStack(spacing: PocketSpacing.s8) {
                if !isDefault {
                    Button("Use") { app.currentModelId = entry.manifest.id }
                        .buttonStyle(.hud)
                }
                Menu {
                    Button("Unload from memory") {
                        try? app.core.unloadModel(id: entry.manifest.id)
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { onDelete(entry) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        case .downloading, .queued:
            Button("Pause") { try? app.core.pauseDownload(modelId: entry.manifest.id) }
                .buttonStyle(.hud)
        case .paused:
            Button("Resume") { try? app.core.resumeDownload(modelId: entry.manifest.id) }
                .buttonStyle(.hud)
        case .verifying:
            EmptyView()
        case .available, .failed:
            Button(entry.fit.verdict == .willNotFit ? "Get anyway" : "Get") {
                try? app.core.startDownload(modelId: entry.manifest.id)
            }
            .buttonStyle(.hudProminent)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(PocketColor.accent)
            HStack {
                HUDLabel("\(hudBytes(entry.bytesDone)) of \(hudBytes(entry.fit.diskBytes))")
                if let detail = rateAndETA { HUDLabel(detail) }
                Spacer()
                Button("Cancel") { try? app.core.cancelDownload(modelId: entry.manifest.id) }
                    .buttonStyle(.plain)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
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
            if let left = formatter.string(from: seconds) { parts.append("\(left) left") }
        }
        return parts.joined(separator: " · ")
    }

    private var fraction: Double {
        guard entry.fit.diskBytes > 0 else { return 0 }
        return min(1, Double(entry.bytesDone) / Double(entry.fit.diskBytes))
    }
}
