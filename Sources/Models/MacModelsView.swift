import SwiftUI
import AppKit
import PocketKit
import PocketUI

/// MAC-04: Models (M-MOD). Table-style list + detail inspector,
/// memory policy slider (50–85 %) with live budget readout, and "Reveal in Finder" for model folder.
struct MacModelsView: View {
    @Environment(AppModel.self) private var model

    private enum Segment: String, CaseIterable { case installed = "Installed", browse = "Browse" }
    private enum ViewMode: String, CaseIterable { case table = "Table", cards = "Cards" }

    @State private var segment = Segment.browse
    @State private var viewMode = ViewMode.table
    @State private var searchText = ""
    @State private var fitsOnly = true
    @State private var catalog: [CatalogEntry] = []
    @State private var detail: CatalogEntry?
    @State private var pendingDelete: CatalogEntry?
    @State private var hubResults: [CatalogEntry] = []
    @State private var hubSearchError: String?

    @AppStorage("app.getpocketai.memoryPolicy") private var memoryPolicyPercent: Double = 70.0

    private var profile: DeviceProfile {
        model.hooks.deviceProfile()
    }

    private var memoryBudgetFormatted: String {
        let total = profile.totalRamBytes
        let budget = UInt64(Double(total) * (memoryPolicyPercent / 100.0))
        return "\(formatBytes(budget)) of \(formatBytes(total))"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Controls bar
            HStack(spacing: PocketSpacing.s16) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                if segment == .browse {
                    Toggle("Fits only", isOn: $fitsOnly)
                        .font(.pocket(.footnote))
                }

                Spacer()

                Button("Reveal in Finder") {
                    revealModelFolder()
                }
                .font(.pocket(.footnote))
            }
            .padding(.horizontal, PocketSpacing.gutterMac)
            .padding(.vertical, PocketSpacing.s8)

            // Memory policy slider (50–85 %) per MAC-04
            HStack(spacing: PocketSpacing.s12) {
                Text("Memory Budget (\(Int(memoryPolicyPercent))% · \(memoryBudgetFormatted))")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)

                Slider(value: $memoryPolicyPercent, in: 50...85, step: 5)
                    .frame(width: 160)

                Spacer()
            }
            .padding(.horizontal, PocketSpacing.gutterMac)
            .padding(.bottom, PocketSpacing.s8)

            Divider()

            // Main display: Table or Cards
            if viewMode == .table {
                tableView
            } else {
                cardsView
            }
        }
        .background(PocketColor.bgCanvas)
        .task { reload() }
        .onChange(of: searchText) { reload() }
        .onChange(of: fitsOnly) { reload() }
        .sheet(item: $detail) { entry in
            ModelDetailSheet(
                entry: entry,
                primaryActionLabel: primaryActionLabel(for: entry),
                onPrimaryAction: { performPrimaryAction(for: entry) },
                onDelete: entry.state == .installed ? { pendingDelete = entry; detail = nil } : nil
            )
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.manifest.displayName ?? "model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    try? model.core.deleteModel(modelId: entry.manifest.id)
                    reload()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let entry = pendingDelete {
                Text("Frees \(formatBytes(entry.manifest.estRuntimeBytes)).")
            }
        }
    }

    private var filteredEntries: [CatalogEntry] {
        var entries = catalog
        if !searchText.isEmpty {
            entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if segment == .installed {
            return entries.filter { $0.state == .installed || $0.state == .downloading || $0.state == .paused }
        }
        if fitsOnly {
            entries = entries.filter { $0.fit.verdict == .runsWell || $0.fit.verdict == .runsSlow }
        }
        return entries
    }

    private var tableView: some View {
        Table(filteredEntries) {
            TableColumn("Name") { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.manifest.displayName).font(.pocket(.headline))
                    Text(entry.manifest.family).font(.pocket(.caption)).foregroundStyle(PocketColor.textSecondary)
                }
            }
            TableColumn("Fit") { entry in
                FitBadge(kind: fitKind(entry.fit.verdict), reason: entry.fit.reason)
            }
            TableColumn("Size") { entry in
                Text(formatBytes(entry.manifest.estRuntimeBytes)).font(.pocket(.mono))
            }
            TableColumn("Speed") { entry in
                if let speed = entry.fit.estTokensPerSec {
                    Text("\(Int(speed)) tok/s").font(.pocket(.mono))
                } else {
                    Text("—").foregroundStyle(PocketColor.textTertiary)
                }
            }
            TableColumn("Engine") { entry in
                Text("\(entry.manifest.format)").font(.pocket(.caption))
            }
            TableColumn("License") { entry in
                Text(entry.manifest.license.spdx).font(.pocket(.caption))
            }
            TableColumn("Status") { entry in
                HStack {
                    Text("\(entry.state)").font(.pocket(.caption))
                    Spacer()
                    Button(primaryActionLabel(for: entry)) {
                        performPrimaryAction(for: entry)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search models")
    }

    private var cardsView: some View {
        List {
            ForEach(groupedSections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.entries, id: \.manifest.id) { entry in
                        ModelRow(
                            data: rowData(for: entry),
                            primaryActionLabel: primaryActionLabel(for: entry),
                            onPrimaryAction: { performPrimaryAction(for: entry) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { detail = entry }
                    }
                }
            }
            if segment == .browse, !searchText.isEmpty {
                Section {
                    if model.core.isOffline() {
                        Label("Offline mode is on — turn it off in Settings to search Hugging Face.", systemImage: "airplane")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    } else {
                        Button {
                            Task { await searchHub() }
                        } label: {
                            Label("Search Hugging Face for \"\(searchText)\"", systemImage: "magnifyingglass")
                        }
                    }
                    if let hubSearchError {
                        Text(hubSearchError).font(.pocket(.caption)).foregroundStyle(PocketColor.statusBad)
                    }
                    ForEach(hubResults, id: \.manifest.id) { entry in
                        ModelRow(
                            data: rowData(for: entry),
                            primaryActionLabel: primaryActionLabel(for: entry),
                            onPrimaryAction: { performPrimaryAction(for: entry) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { detail = entry }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search models")
    }

    private struct ModelSection {
        let title: String
        let entries: [CatalogEntry]
    }

    private var groupedSections: [ModelSection] {
        var entries = catalog
        if !searchText.isEmpty {
            entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if segment == .installed {
            entries = entries.filter { $0.state == .installed || $0.state == .downloading || $0.state == .paused }
            return entries.isEmpty ? [] : [ModelSection(title: "Installed", entries: entries)]
        }
        if fitsOnly {
            entries = entries.filter { $0.fit.verdict == .runsWell || $0.fit.verdict == .runsSlow }
        }
        var sections: [ModelSection] = []
        let recommended = entries.filter { $0.manifest.tags.contains("recommended") }
        if !recommended.isEmpty { sections.append(ModelSection(title: "Recommended for this Mac", entries: recommended)) }
        let vision = entries.filter { $0.manifest.modalities.contains(.vision) }
        if !vision.isEmpty { sections.append(ModelSection(title: "Vision", entries: vision)) }
        let voice = entries.filter { $0.manifest.modalities.contains(.speechToText) || $0.manifest.modalities.contains(.textToSpeech) }
        if !voice.isEmpty { sections.append(ModelSection(title: "Voice", entries: voice)) }
        let images = entries.filter { $0.manifest.modalities.contains(.image) }
        if !images.isEmpty { sections.append(ModelSection(title: "Images", entries: images)) }
        let rest = entries.filter {
            !$0.manifest.tags.contains("recommended")
                && !$0.manifest.modalities.contains(.vision)
                && !$0.manifest.modalities.contains(.speechToText)
                && !$0.manifest.modalities.contains(.textToSpeech)
                && !$0.manifest.modalities.contains(.image)
        }
        if !rest.isEmpty { sections.append(ModelSection(title: "Fast & small", entries: rest)) }
        return sections
    }

    private func reload() {
        catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
        hubResults = []
        hubSearchError = nil
    }

    private func searchHub() async {
        hubSearchError = nil
        do {
            hubResults = try model.core.searchHub(query: searchText, format: .mlxSafetensors)
        } catch {
            hubResults = []
            hubSearchError = "Search failed: \(error)"
        }
    }

    private func revealModelFolder() {
        let dir = model.hooks.appSupportDir()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }

    private func rowData(for entry: CatalogEntry) -> ModelRowData {
        ModelRowData(
            name: entry.manifest.displayName,
            familyParamsQuant: "\(entry.manifest.family) · \(entry.manifest.quant)",
            fitKind: fitKind(entry.fit.verdict),
            fitReason: entry.fit.reason,
            sizeOnDisk: formatBytes(entry.manifest.estRuntimeBytes),
            speedText: entry.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
            speedIsMeasured: entry.fit.measuredTokensPerSec != nil,
            licenseLabel: entry.manifest.license.spdx
        )
    }

    private func primaryActionLabel(for entry: CatalogEntry) -> String {
        switch entry.state {
        case .installed: return "Open"
        case .downloading: return "Pause"
        case .paused: return "Resume"
        case .verifying: return "Checking…"
        case .failed: return "Retry"
        case .available, .queued: return entry.fit.verdict == .willNotFit ? "Won't fit" : "Download \(formatBytes(entry.manifest.estRuntimeBytes))"
        }
    }

    private func performPrimaryAction(for entry: CatalogEntry) {
        switch entry.state {
        case .downloading: try? model.core.pauseDownload(modelId: entry.manifest.id)
        case .paused: try? model.core.resumeDownload(modelId: entry.manifest.id)
        case .available, .queued, .failed: try? model.core.startDownload(modelId: entry.manifest.id)
        case .installed:
            model.selectedTab = .chats
            model.pendingCommand = .newChat
        case .verifying:
            break
        }
        reload()
    }

    private func fitKind(_ verdict: FitVerdict) -> FitBadgeKind {
        switch verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }
}

private struct ModelDetailSheet: View {
    let entry: CatalogEntry
    let primaryActionLabel: String
    let onPrimaryAction: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section {
                    Text(entry.manifest.displayName).font(.pocket(.title))
                    Text(entry.manifest.family).font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                    FitBadge(kind: fitKind, reason: entry.fit.reason)
                }
                Section("Specs") {
                    LabeledContent("Quant", value: entry.manifest.quant)
                    LabeledContent("Context", value: "\(entry.manifest.contextLength)")
                    LabeledContent("Size", value: formatBytes(entry.manifest.estRuntimeBytes))
                    LabeledContent("Format", value: "\(entry.manifest.format)")
                }
                Section("License") {
                    Text(entry.manifest.license.spdx)
                    Link(entry.manifest.license.url, destination: URL(string: entry.manifest.license.url) ?? URL(string: "https://huggingface.co")!)
                }
                if entry.state == .downloading || entry.state == .paused {
                    Section {
                        DownloadProgress(
                            state: entry.state == .paused
                                ? .paused(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes))
                                : .downloading(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes), bytesPerSecond: 18_000_000),
                            onPauseResume: onPrimaryAction,
                            onCancel: {}
                        )
                    }
                }
                Section {
                    Button(primaryActionLabel, action: onPrimaryAction)
                    if let onDelete {
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private var fitKind: FitBadgeKind {
        switch entry.fit.verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }
}

extension CatalogEntry: @retroactive Identifiable {
    public var id: String { manifest.id }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
