import PocketKit
import PocketUI
import SwiftUI

/// Right pane: what the model is doing and what this machine is doing. The
/// numbers here are measured, never estimated — an empty value means nothing
/// has been measured yet.
struct InspectorView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HUDLabel("Inspector")
                Spacer()
                Button {
                    app.showInspector = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, PocketSpacing.s8)
            HUDRule()

            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    group("Model") {
                        field("Name", app.currentModelDisplayName)
                        if let entry = currentEntry {
                            field("Quant", entry.manifest.quant)
                            field("Context", "\(entry.manifest.contextLength) tokens")
                            field("Disk", hudBytes(entry.fit.diskBytes))
                            field("Est. memory", hudBytes(entry.fit.estRuntimeBytes))
                            if let measured = entry.fit.measuredTokensPerSec {
                                field("Measured", "\(Int(measured)) tok/s")
                            }
                        }
                    }
                    group("Now") {
                        field("State", app.isGenerating ? "generating" : "idle")
                        if app.activeTokPerSec > 0 {
                            field("Rate", "\(app.activeTokPerSec) tok/s")
                        }
                    }
                    group("Machine") {
                        field("Server", app.serverStatus.running
                            ? "running · port \(app.serverStatus.port)" : "stopped")
                        field("Paired devices", "\(app.serverStatus.connectedDevices)")
                        field("Offline mode", app.core.isOffline() ? "on" : "off")
                    }
                }
                .padding(PocketSpacing.s12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PocketColor.bgSurface)
    }

    private var currentEntry: CatalogEntry? {
        app.core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false)
        ).first { $0.manifest.id == app.currentModelId }
    }

    @ViewBuilder private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            HUDLabel(title)
            VStack(spacing: 0) { content() }
                .padding(PocketSpacing.s8)
                .hudPanel()
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
            Spacer(minLength: PocketSpacing.s8)
            Text(value)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}
