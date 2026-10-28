import SwiftUI
import AppKit
import Network
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
    /// Honest instruments: measured download throughput per model id, derived
    /// from real bytesDone deltas between polls — never a fabricated constant.
    @State private var downloadRates: [String: Int64] = [:]
    @State private var downloadSamples: [String: (bytes: UInt64, at: Date)] = [:]
    /// Real connectivity (not the user's offline *mode*): drives the
    /// "Waiting for network…" state and auto-resume on reconnect.
    @State private var net = NetworkMonitor()

    private var installedCount: Int {
        catalog.filter { $0.state == .installed || isInFlight($0) }.count
    }

    /// An interrupted or in-progress download worth surfacing on the Installed
    /// tab. A `.failed` entry only counts if it has partial bytes on disk
    /// (i.e. it was mid-download), so a never-started failure isn't shown here.
    private func isInFlight(_ entry: CatalogEntry) -> Bool {
        switch entry.state {
        case .downloading, .paused, .verifying, .queued: return true
        case .failed: return entry.bytesDone > 0
        case .installed, .available: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Controls & Filter Bar
            controlsBar

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
        .task {
            reload()
            net.start()
            // Resume-on-launch: a download interrupted by a quit/crash comes
            // back as .paused mid-file — pick it up automatically. Failed ones
            // stay a manual Retry so a genuinely broken download can't loop.
            resumeInterrupted(includingFailed: false)
        }
        .task { await pollDownloads() }
        .onChange(of: net.isOnline) { _, online in
            // Network came back: resume anything that stalled while offline.
            if online { resumeInterrupted(includingFailed: true) }
        }
        .onChange(of: searchText) { reload() }
        .onChange(of: fitsOnly) { reload() }
        .sheet(item: $detail) { entry in
            ModelDetailSheet(
                entry: entry,
                primaryActionLabel: primaryActionLabel(for: entry),
                onPrimaryAction: { performPrimaryAction(for: entry) },
                onCancel: {
                    try? model.core.cancelDownload(modelId: entry.manifest.id)
                    reload()
                    detail = nil
                },
                onDelete: entry.state == .installed ? { pendingDelete = entry; detail = nil } : nil,
                onRetry: { try? model.core.startDownload(modelId: entry.manifest.id); reload() },
                downloadBytesPerSecond: downloadRates[entry.manifest.id] ?? 0,
                isOnline: net.isOnline
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
                Text("This will free \(formatBytes(modelDiskBytes(entry))) on your Mac.")
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
            return entries.filter { $0.state == .installed || isInFlight($0) }
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
                                .font(.pocket(.caption))
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
                                .font(.pocket(.caption))
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
                PocketMarkView(state: .idle, size: 40)

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

                    Text(formatBytes(modelDiskBytes(entry)))
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
                Label(formatBytes(modelDiskBytes(entry)), systemImage: "internaldrive")
                    .font(.pocket(.metric))
                    .foregroundStyle(PocketColor.textSecondary)

                if let speed = entry.fit.estTokensPerSec {
                    Label("\(Int(speed)) tok/s", systemImage: "bolt")
                        .font(.pocket(.metric))
                        .foregroundStyle(PocketColor.accent)
                }

                Spacer()

                Text("\(entry.manifest.format)")
                    .font(.pocket(.caption))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PocketColor.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(entry.manifest.license.spdx)
                    .font(.pocket(.caption))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PocketColor.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            // Download progress / interrupted state if active
            if showsDownloadStatus(entry) {
                downloadStatus(for: entry)
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
                Text(formatBytes(modelDiskBytes(entry))).font(.pocket(.metric))
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
            entries = entries.filter { $0.state == .installed || isInFlight($0) }
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
        // '#iphone'-suffixed variants (e.g. WhisperKit CoreML for iPhone) are
        // phone-targeted duplicates — hide them on Mac.
        catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
            .filter { !$0.manifest.id.hasSuffix("#iphone") }
        hubResults = []
        hubSearchError = nil
    }

    /// While any model is downloading, refresh the catalog and derive a real
    /// throughput from consecutive bytesDone samples. Stops sampling (and clears
    /// stale rates) once nothing is in-flight.
    private func pollDownloads() async {
        while !Task.isCancelled {
            let active = catalog.filter {
                switch $0.state {
                case .downloading, .queued, .verifying, .paused: return true
                case .failed, .installed, .available: return false
                }
            }
            if active.isEmpty {
                if !downloadSamples.isEmpty { downloadSamples.removeAll() }
                if !downloadRates.isEmpty { downloadRates.removeAll() }
            } else {
                catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
                    .filter { !$0.manifest.id.hasSuffix("#iphone") }
                let now = Date()
                for entry in catalog where entry.state == .downloading {
                    let id = entry.manifest.id
                    if let prev = downloadSamples[id] {
                        let elapsed = now.timeIntervalSince(prev.at)
                        if elapsed >= 0.4, entry.bytesDone >= prev.bytes {
                            downloadRates[id] = Int64(Double(entry.bytesDone - prev.bytes) / elapsed)
                            downloadSamples[id] = (entry.bytesDone, now)
                        }
                    } else {
                        downloadSamples[id] = (entry.bytesDone, now)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
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

    /// Only text/vision models can serve a chat; image/voice/embedding models
    /// have no "Open in Chat" path.
    private func isChatCapable(_ entry: CatalogEntry) -> Bool {
        entry.manifest.modalities.contains(.text) || entry.manifest.modalities.contains(.vision)
    }

    private func primaryActionLabel(for entry: CatalogEntry) -> String {
        switch entry.state {
        case .installed: return isChatCapable(entry) ? "Open in Chat" : "Installed"
        case .downloading: return "Pause"
        case .paused: return "Resume"
        case .verifying: return "Checking…"
        case .failed: return "Retry"
        case .available, .queued:
            return entry.fit.verdict == .willNotFit ? "Won't fit" : "Download \(formatBytes(modelDiskBytes(entry)))"
        }
    }

    private func performPrimaryAction(for entry: CatalogEntry) {
        switch entry.state {
        case .downloading: try? model.core.pauseDownload(modelId: entry.manifest.id)
        case .paused: try? model.core.resumeDownload(modelId: entry.manifest.id)
        case .available, .queued, .failed: try? model.core.startDownload(modelId: entry.manifest.id)
        case .installed:
            guard isChatCapable(entry) else { break }
            model.currentModelId = entry.manifest.id
            model.selectedTab = .chats
            model.pendingCommand = .newChat
        case .verifying:
            break
        }
        reload()
    }

    /// Whether this entry should render a download-status row (active,
    /// interrupted, or a failed-mid-download worth retrying).
    private func showsDownloadStatus(_ entry: CatalogEntry) -> Bool {
        switch entry.state {
        case .downloading, .paused, .verifying: return true
        case .failed: return entry.bytesDone > 0
        case .queued, .available, .installed: return false
        }
    }

    @ViewBuilder
    private func downloadStatus(for entry: CatalogEntry) -> some View {
        let done = Int64(entry.bytesDone)
        let total = Int64(modelDiskBytes(entry))
        switch entry.state {
        case .downloading:
            if net.isOnline {
                DownloadProgress(
                    state: .downloading(bytesDone: done, bytesTotal: total, bytesPerSecond: downloadRates[entry.manifest.id] ?? 0),
                    onPauseResume: { performPrimaryAction(for: entry) },
                    onCancel: { try? model.core.cancelDownload(modelId: entry.manifest.id); reload() }
                )
            } else {
                offlineRow(message: "Waiting for network…", done: done, total: total, entry: entry)
            }
        case .paused:
            if net.isOnline {
                DownloadProgress(
                    state: .paused(bytesDone: done, bytesTotal: total),
                    onPauseResume: { performPrimaryAction(for: entry) },
                    onCancel: { try? model.core.cancelDownload(modelId: entry.manifest.id); reload() }
                )
            } else {
                offlineRow(message: "Paused — no connection", done: done, total: total, entry: entry)
            }
        case .verifying:
            DownloadProgress(state: .verifying, onPauseResume: {}, onCancel: {})
        case .failed(let reason):
            failedRow(reason: reason, done: done, total: total, entry: entry)
        case .queued, .available, .installed:
            EmptyView()
        }
    }

    /// Honest offline state: real partial bytes, no fabricated rate/ETA.
    private func offlineRow(message: String, done: Int64, total: Int64, entry: CatalogEntry) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(PocketColor.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                Text("\(formatBytes(UInt64(max(done, 0)))) of \(formatBytes(UInt64(max(total, 0))))")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer()
            Button {
                try? model.core.cancelDownload(modelId: entry.manifest.id)
                reload()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PocketColor.textTertiary)
        }
    }

    private func failedRow(reason: String, done: Int64, total: Int64, entry: CatalogEntry) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PocketColor.statusBad)
            VStack(alignment: .leading, spacing: 2) {
                Text("Download failed · \(formatBytes(UInt64(max(done, 0)))) of \(formatBytes(UInt64(max(total, 0))))")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.statusBad)
                Text(reason)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Retry") {
                try? model.core.startDownload(modelId: entry.manifest.id)
                reload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!net.isOnline)
        }
    }

    /// Resume downloads that were interrupted. `.paused` with partial bytes is
    /// resumed via `startDownload` (the Rust core resumes from the on-disk
    /// `.part` via SHA-256; in-session `resumeDownload` state is lost across a
    /// relaunch). `.failed` is only auto-resumed on reconnect, not on launch.
    private func resumeInterrupted(includingFailed: Bool) {
        guard net.isOnline else { return }
        var resumed = false
        for entry in catalog where entry.bytesDone > 0 {
            switch entry.state {
            case .paused:
                try? model.core.startDownload(modelId: entry.manifest.id)
                resumed = true
            case .failed where includingFailed:
                try? model.core.startDownload(modelId: entry.manifest.id)
                resumed = true
            default:
                break
            }
        }
        if resumed { reload() }
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
    var onCancel: () -> Void = {}
    let onDelete: (() -> Void)?
    var onRetry: () -> Void = {}
    /// Last measured throughput from the catalog screen's poller (0 = not yet measured).
    var downloadBytesPerSecond: Int64 = 0
    var isOnline: Bool = true
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
                    LabeledContent("Size on Disk", value: formatBytes(modelDiskBytes(entry)))
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

                if showsDownloadStatus {
                    Section("Download Status") {
                        downloadStatusRow
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

    private var showsDownloadStatus: Bool {
        switch entry.state {
        case .downloading, .paused, .verifying: return true
        case .failed: return entry.bytesDone > 0
        case .queued, .available, .installed: return false
        }
    }

    @ViewBuilder
    private var downloadStatusRow: some View {
        let done = Int64(entry.bytesDone)
        let total = Int64(modelDiskBytes(entry))
        switch entry.state {
        case .downloading where !isOnline:
            Label("Waiting for network… · \(formatBytes(UInt64(max(done, 0)))) of \(formatBytes(UInt64(max(total, 0))))", systemImage: "wifi.slash")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
        case .paused where !isOnline:
            Label("Paused — no connection · \(formatBytes(UInt64(max(done, 0)))) of \(formatBytes(UInt64(max(total, 0))))", systemImage: "wifi.slash")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                Label("Download failed · \(formatBytes(UInt64(max(done, 0)))) of \(formatBytes(UInt64(max(total, 0))))", systemImage: "exclamationmark.triangle.fill")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.statusBad)
                Text(reason)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                Button("Retry") { onRetry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isOnline)
            }
        default:
            DownloadProgress(
                state: entry.state == .paused
                    ? .paused(bytesDone: done, bytesTotal: total)
                    : (entry.state == .verifying
                        ? .verifying
                        : .downloading(bytesDone: done, bytesTotal: total, bytesPerSecond: downloadBytesPerSecond)),
                onPauseResume: onPrimaryAction,
                onCancel: onCancel
            )
        }
    }
}

extension CatalogEntry: @retroactive Identifiable {
    public var id: String { manifest.id }
}

/// Download/size-on-disk total for a model: the fit report's real disk bytes,
/// falling back to summed manifest file sizes, then estRuntimeBytes (RAM
/// estimate) only as a last resort. Using estRuntimeBytes directly made
/// download bars stall around 87%.
func modelDiskBytes(_ entry: CatalogEntry) -> UInt64 {
    if entry.fit.diskBytes > 0 { return entry.fit.diskBytes }
    let summed = entry.manifest.files.reduce(UInt64(0)) { $0 + $1.size }
    return summed > 0 ? summed : entry.manifest.estRuntimeBytes
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

/// Thin wrapper over `NWPathMonitor` for real connectivity. This is distinct
/// from the user's privacy *offline mode* (`CoreClient.isOffline`); it reports
/// whether a usable network path exists so downloads can show an honest
/// "Waiting for network…" state and auto-resume on reconnect. Starts optimistic
/// (online) to avoid a false-offline flash before the first path update.
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.getpocketai.netmonitor")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }
}
