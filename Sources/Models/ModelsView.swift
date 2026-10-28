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
    @State private var hubResults: [CatalogEntry] = []
    @State private var hubError: String?
    @State private var refreshTask: Task<Void, Never>?
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
        var list = showInstalledOnly ? installed : entries
        list = list.filter { entry in
            !downloading.contains { $0.manifest.id == entry.manifest.id }
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

    private func searchHub() {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard query.count > 2 else {
            hubResults = []
            return
        }
        hubError = nil
        do {
            hubResults = try app.core.searchHub(query: query, format: .mlxSafetensors)
        } catch {
            hubResults = []
            hubError = "Hugging Face search failed: \(error.localizedDescription)"
        }
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
                Text(reason)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
            }
            fitLine
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    private var subtitle: String {
        var bits = [entry.manifest.family, entry.manifest.quant]
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
                Spacer()
                Button("Cancel") { try? app.core.cancelDownload(modelId: entry.manifest.id) }
                    .buttonStyle(.plain)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.statusBad)
            }
        }
    }

    private var fraction: Double {
        guard entry.fit.diskBytes > 0 else { return 0 }
        return min(1, Double(entry.bytesDone) / Double(entry.fit.diskBytes))
    }
}
