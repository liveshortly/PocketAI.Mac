import SwiftUI
import AppKit
import PocketKit
import PocketUI

/// MAC-04: Models (M-MOD). Card/Table hybrid view with curated sections,
/// hero "Recommended for this Mac" card, memory budget gauge bar,
/// clear download progress, and tidy model detail inspector.
struct MacModelsView: View {
    @Environment(AppModel.self) private var model

    private enum Segment: String, CaseIterable { case browse = "Browse Catalog", installed = "Installed" }
    private enum ViewMode: String, CaseIterable { case cards = "Cards", table = "Table" }

    @State private var segment = Segment.browse
    @State private var viewMode = ViewMode.cards
    @State private var searchText = ""
    @State private var fitsOnly = false
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

    private var installedCount: Int {
        catalog.filter { $0.state == .installed || $0.state == .downloading || $0.state == .paused }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Controls & Filter Bar
            controlsBar

            Divider()

            // Memory Budget Gauge
            memoryBudgetBar

            Divider()

            // Main Content Area
            if segment == .installed && filteredEntries.isEmpty {
                emptyInstalledView
            } else if viewMode == .cards {
                cardsScrollView
            } else {
                tableView
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
            Button("Delete Model", role: .destructive) {
                if let entry = pendingDelete {
                    try? model.core.deleteModel(modelId: entry.manifest.id)
                    reload()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let entry = pendingDelete {
                Text("This will free \(formatBytes(entry.manifest.estRuntimeBytes)) on your Mac.")
            }
        }
    }

    private var controlsBar: some View {
        HStack(spacing: PocketSpacing.s16) {
            // Segment picker: Browse vs Installed
            Picker("", selection: $segment) {
                Text("Browse").tag(Segment.browse)
                Text("Installed (\(installedCount))").tag(Segment.installed)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            // View mode: Cards vs Table
            Picker("", selection: $viewMode) {
                Label("Cards", systemImage: "square.grid.2x2").tag(ViewMode.cards)
                Label("Table", systemImage: "list.bullet").tag(ViewMode.table)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)

            if segment == .browse {
                Toggle("Fits this Mac", isOn: $fitsOnly)
                    .font(.pocket(.callout))
                    .toggleStyle(.checkbox)
            }

            Spacer()

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PocketColor.textTertiary)
                TextField("Search models…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.pocket(.callout))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.5)
            )
            .frame(width: 200)

            Button {
                revealModelFolder()
            } label: {
                Label("Model Folder", systemImage: "folder")
                    .font(.pocket(.footnote))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal models directory in Finder")
        }
        .padding(.horizontal, PocketSpacing.gutterMac)
        .padding(.vertical, PocketSpacing.s12)
        .background(PocketColor.bgRaised)
    }

    private var memoryBudgetBar: some View {
        HStack(spacing: PocketSpacing.s16) {
            Image(systemName: "memorychip")
                .font(.system(size: 14))
                .foregroundStyle(PocketColor.accent)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Memory Budget for Models:")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)

                    Text("\(Int(memoryPolicyPercent))% · \(memoryBudgetFormatted)")
                        .font(.pocket(.metric))
                        .foregroundStyle(PocketColor.textPrimary)
                }

                // Progress gauge
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(PocketColor.bgSunken)
                            .frame(height: 5)

                        Capsule()
                            .fill(PocketColor.accent)
                            .frame(width: geo.size.width * CGFloat(memoryPolicyPercent / 100.0), height: 5)
                    }
                }
                .frame(height: 5)
            }

            Slider(value: $memoryPolicyPercent, in: 50...85, step: 5)
                .frame(width: 140)

            Spacer()
        }
        .padding(.horizontal, PocketSpacing.gutterMac)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgCanvas)
    }

    private var emptyInstalledView: some View {
        VStack(spacing: PocketSpacing.s16) {
            Spacer()
            PocketMarkView(state: .idle, size: 56)
            Text("No models installed yet")
                .font(.pocket(.title))
                .fontWeight(.semibold)
                .foregroundStyle(PocketColor.textPrimary)

            Text("Download optimized models from the catalog to run locally on your Mac's Apple Silicon.")
                .font(.pocket(.body))
                .foregroundStyle(PocketColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Browse Curated Catalog") {
                segment = .browse
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketColor.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var cardsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s24) {
                // Hero card for Recommended model (in Browse mode)
                if segment == .browse && searchText.isEmpty, let hero = recommendedHeroEntry {
                    heroModelCard(hero)
                }

                // Grouped sections
                ForEach(groupedSections) { section in
                    VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                        HStack(spacing: PocketSpacing.s8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(section.title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(PocketColor.textTertiary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: PocketSpacing.s12)], spacing: PocketSpacing.s12) {
                            ForEach(section.entries, id: \.manifest.id) { entry in
                                modelCard(entry)
                            }
                        }
                    }
                }

                // Hugging Face hub results if searching
                if segment == .browse, !searchText.isEmpty {
                    VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                        Divider()
                        HStack {
                            Text("HUGGING FACE HUB")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PocketColor.textTertiary)
                            Spacer()
                            Button {
                                Task { await searchHub() }
                            } label: {
                                Label("Search Hub for “\(searchText)”", systemImage: "magnifyingglass")
                                    .font(.pocket(.caption))
                            }
                        }

                        if let hubSearchError {
                            Text(hubSearchError).font(.pocket(.caption)).foregroundStyle(PocketColor.statusBad)
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: PocketSpacing.s12)], spacing: PocketSpacing.s12) {
                            ForEach(hubResults, id: \.manifest.id) { entry in
                                modelCard(entry)
                            }
                        }
                    }
                }
            }
            .padding(PocketSpacing.gutterMac)
        }
    }

    private var recommendedHeroEntry: CatalogEntry? {
        catalog.first { $0.manifest.tags.contains("recommended") && $0.fit.verdict == .runsWell }
    }

    private func heroModelCard(_ entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack {
                HStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Text("RECOMMENDED FOR THIS MAC")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(PocketColor.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(PocketColor.accentSoft)
                .clipShape(Capsule())

                Spacer()

                FitBadge(kind: fitKind(entry.fit.verdict), reason: entry.fit.reason)
            }

            HStack(alignment: .center, spacing: PocketSpacing.s16) {
                PocketMarkView(state: .working(tokPerSec: 28), size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.manifest.displayName)
                        .font(.pocket(.title))
                        .fontWeight(.bold)
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("\(entry.manifest.family) · \(entry.manifest.quant) · Apple Silicon Metal Optimized")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: PocketSpacing.s4) {
                    if let speed = entry.fit.estTokensPerSec {
                        HStack(spacing: 4) {
                            Text("\(Int(speed))")
                                .font(.pocket(.title))
                                .fontWeight(.bold)
                                .foregroundStyle(PocketColor.accent)
                            Text("tok/s")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
                    }

                    Text(formatBytes(entry.manifest.estRuntimeBytes))
                        .font(.pocket(.metric))
                        .foregroundStyle(PocketColor.textTertiary)
                }

                Button(primaryActionLabel(for: entry)) {
                    performPrimaryAction(for: entry)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
                .controlSize(.large)
            }
        }
        .padding(PocketSpacing.s20)
        .background(PocketColor.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(PocketColor.accent.opacity(0.4), lineWidth: 1.5)
        )
        .shadow(color: PocketColor.accent.opacity(0.06), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            detail = entry
        }
    }

    private func modelCard(_ entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.manifest.displayName)
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                        .lineLimit(1)

                    Text("\(entry.manifest.family) · \(entry.manifest.quant)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                FitBadge(kind: fitKind(entry.fit.verdict), reason: entry.fit.reason)
            }

            // Specs row
            HStack(spacing: PocketSpacing.s12) {
                Label(formatBytes(entry.manifest.estRuntimeBytes), systemImage: "internaldrive")
                    .font(.pocket(.metric))
                    .foregroundStyle(PocketColor.textSecondary)

                if let speed = entry.fit.estTokensPerSec {
                    Label("\(Int(speed)) tok/s", systemImage: "bolt")
                        .font(.pocket(.metric))
                        .foregroundStyle(PocketColor.accent)
                }

                Spacer()

                Text(entry.manifest.license.spdx)
                    .font(.pocket(.caption))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PocketColor.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            // Download progress if active
            if entry.state == .downloading || entry.state == .paused {
                DownloadProgress(
                    state: entry.state == .paused
                        ? .paused(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes))
                        : .downloading(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes), bytesPerSecond: 18_000_000),
                    onPauseResume: { performPrimaryAction(for: entry) },
                    onCancel: { try? model.core.cancelDownload(modelId: entry.manifest.id); reload() }
                )
            }

            Divider()

            // Footer actions
            HStack {
                Button("Details") {
                    detail = entry
                }
                .buttonStyle(.plain)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)

                Spacer()

                if entry.state == .installed {
                    Button(role: .destructive) {
                        pendingDelete = entry
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete model")
                }

                if entry.state == .installed {
                    Button(primaryActionLabel(for: entry)) {
                        performPrimaryAction(for: entry)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button(primaryActionLabel(for: entry)) {
                        performPrimaryAction(for: entry)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(PocketSpacing.s16)
        .background(PocketColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PocketColor.lineHairline, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, y: 2)
        .contentShape(Rectangle())
        .onTapGesture {
            detail = entry
        }
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
                Text(formatBytes(entry.manifest.estRuntimeBytes)).font(.pocket(.metric))
            }
            TableColumn("Speed") { entry in
                if let speed = entry.fit.estTokensPerSec {
                    Text("\(Int(speed)) tok/s").font(.pocket(.metric)).foregroundStyle(PocketColor.accent)
                } else {
                    Text("—").foregroundStyle(PocketColor.textTertiary)
                }
            }
            TableColumn("Format") { entry in
                Text("\(entry.manifest.format)").font(.pocket(.caption))
            }
            TableColumn("License") { entry in
                Text(entry.manifest.license.spdx).font(.pocket(.caption))
            }
            TableColumn("Action") { entry in
                HStack {
                    Button(primaryActionLabel(for: entry)) {
                        performPrimaryAction(for: entry)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if entry.state == .installed {
                        Button(role: .destructive) {
                            pendingDelete = entry
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private struct ModelSection: Identifiable {
        var id: String { title }
        let title: String
        let icon: String
        let entries: [CatalogEntry]
    }

    private var groupedSections: [ModelSection] {
        var entries = catalog
        if !searchText.isEmpty {
            entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if segment == .installed {
            entries = entries.filter { $0.state == .installed || $0.state == .downloading || $0.state == .paused }
            return entries.isEmpty ? [] : [ModelSection(title: "Installed on this Mac", icon: "internaldrive", entries: entries)]
        }
        if fitsOnly {
            entries = entries.filter { $0.fit.verdict == .runsWell || $0.fit.verdict == .runsSlow }
        }
        var sections: [ModelSection] = []

        let text = entries.filter {
            $0.manifest.modalities.contains(.text)
                && !$0.manifest.modalities.contains(.vision)
                && !$0.manifest.modalities.contains(.image)
        }
        if !text.isEmpty {
            sections.append(ModelSection(title: "Text", icon: "text.bubble", entries: text))
        }

        let vision = entries.filter { $0.manifest.modalities.contains(.vision) }
        if !vision.isEmpty {
            sections.append(ModelSection(title: "Vision", icon: "eye", entries: vision))
        }

        let image = entries.filter { $0.manifest.modalities.contains(.image) }
        if !image.isEmpty {
            sections.append(ModelSection(title: "Image generation", icon: "photo", entries: image))
        }

        let voice = entries.filter {
            $0.manifest.modalities.contains(.speechToText) || $0.manifest.modalities.contains(.textToSpeech)
        }
        if !voice.isEmpty {
            sections.append(ModelSection(title: "Voice", icon: "waveform", entries: voice))
        }

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
            hubSearchError = "Search failed: \(error.localizedDescription)"
        }
    }

    private func revealModelFolder() {
        let dir = model.hooks.appSupportDir()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }

    private func primaryActionLabel(for entry: CatalogEntry) -> String {
        switch entry.state {
        case .installed: return "Open in Chat"
        case .downloading: return "Pause"
        case .paused: return "Resume"
        case .verifying: return "Checking…"
        case .failed: return "Retry"
        case .available, .queued:
            return entry.fit.verdict == .willNotFit ? "Won't fit" : "Download \(formatBytes(entry.manifest.estRuntimeBytes))"
        }
    }

    private func performPrimaryAction(for entry: CatalogEntry) {
        switch entry.state {
        case .downloading: try? model.core.pauseDownload(modelId: entry.manifest.id)
        case .paused: try? model.core.resumeDownload(modelId: entry.manifest.id)
        case .available, .queued, .failed: try? model.core.startDownload(modelId: entry.manifest.id)
        case .installed:
            model.currentModelId = entry.manifest.id
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: PocketSpacing.s16) {
                PocketMarkView(state: .idle, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.manifest.displayName)
                        .font(.pocket(.title))
                        .fontWeight(.bold)
                    Text(entry.manifest.family)
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                Spacer()
                FitBadge(kind: fitKind, reason: entry.fit.reason)
            }
            .padding(PocketSpacing.s20)
            .background(PocketColor.bgRaised)

            Divider()

            // Details List
            List {
                Section("Specifications") {
                    LabeledContent("Quantization", value: entry.manifest.quant)
                    LabeledContent("Context Window", value: "\(entry.manifest.contextLength) tokens")
                    LabeledContent("Size on Disk", value: formatBytes(entry.manifest.estRuntimeBytes))
                    LabeledContent("Runtime Engine", value: "\(entry.manifest.format)")
                    if let speed = entry.fit.estTokensPerSec {
                        LabeledContent("Estimated Speed", value: "\(Int(speed)) tok/s")
                    }
                }

                Section("License & Distribution") {
                    LabeledContent("SPDX Identifier", value: entry.manifest.license.spdx)
                    if let url = URL(string: entry.manifest.license.url) {
                        Link("View License Document", destination: url)
                    }
                }

                if entry.state == .downloading || entry.state == .paused {
                    Section("Download Status") {
                        DownloadProgress(
                            state: entry.state == .paused
                                ? .paused(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes))
                                : .downloading(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes), bytesPerSecond: 18_000_000),
                            onPauseResume: onPrimaryAction,
                            onCancel: {}
                        )
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer Actions
            HStack {
                if let onDelete {
                    Button("Delete Model", role: .destructive, action: onDelete)
                        .buttonStyle(.bordered)
                        .tint(PocketColor.statusBad)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button(primaryActionLabel) {
                    onPrimaryAction()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgCanvas)
        }
        .frame(minWidth: 460, minHeight: 480)
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
