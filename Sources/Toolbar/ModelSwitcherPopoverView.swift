import SwiftUI
import PocketKit
import PocketUI

/// Unified toolbar model switcher popover per 02-design-system.md §6.2.
/// Shows current model, allows fast switching among installed/curated models,
/// and links to the full Models tab.
struct ModelSwitcherPopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var availableModels: [CatalogEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Select Model")
                    .font(.pocket(.headline))
                Spacer()
                Text("\(availableModels.count) available")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.top, PocketSpacing.s16)
            .padding(.bottom, PocketSpacing.s12)

            Divider()

            // List of models
            ScrollView {
                VStack(spacing: PocketSpacing.s4) {
                    ForEach(availableModels, id: \.manifest.id) { entry in
                        let isSelected = entry.manifest.id == model.currentModelId
                        Button {
                            model.currentModelId = entry.manifest.id
                            dismiss()
                        } label: {
                            HStack(spacing: PocketSpacing.s12) {
                                PocketMarkView(
                                    state: isSelected && model.isGenerating ? .working(tokPerSec: Double(model.activeTokPerSec)) : .idle,
                                    size: 20
                                )

                                VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                                    HStack(spacing: PocketSpacing.s8) {
                                        Text(entry.manifest.displayName)
                                            .font(.pocket(.body))
                                            .fontWeight(isSelected ? .semibold : .regular)
                                            .foregroundStyle(isSelected ? PocketColor.accent : PocketColor.textPrimary)

                                        if isSelected {
                                            Text("Active")
                                                .font(.pocket(.caption))
                                                .foregroundStyle(PocketColor.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(PocketColor.accentSoft)
                                                .clipShape(Capsule())
                                        }
                                    }

                                    HStack(spacing: PocketSpacing.s8) {
                                        Text("\(entry.manifest.family) · \(entry.manifest.quant)")
                                            .font(.pocket(.caption))
                                            .foregroundStyle(PocketColor.textSecondary)

                                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.manifest.estRuntimeBytes), countStyle: .memory))
                                            .font(.pocket(.metric))
                                            .foregroundStyle(PocketColor.textTertiary)
                                    }
                                }

                                Spacer()

                                FitBadge(kind: fitKind(entry.fit.verdict), reason: entry.fit.reason)

                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(PocketColor.accent)
                                }
                            }
                            .padding(.horizontal, PocketSpacing.s12)
                            .padding(.vertical, PocketSpacing.s8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? PocketColor.accentSoft.opacity(0.5) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(PocketSpacing.s8)
            }
            .frame(maxHeight: 280)

            Divider()

            // Footer
            HStack {
                Button {
                    model.selectedTab = .models
                    dismiss()
                } label: {
                    Label("Manage All Models…", systemImage: "cpu")
                        .font(.pocket(.callout))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketColor.accent)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgCanvas)
        }
        .frame(width: 380)
        .task {
            loadModels()
        }
    }

    private func loadModels() {
        let installed = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
        if !installed.isEmpty {
            availableModels = installed
        } else {
            availableModels = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
        }
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
