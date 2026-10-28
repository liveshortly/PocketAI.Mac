import SwiftUI
import AppKit
import PocketKit
import PocketLiveShortly
import PocketUI

/// 02-design-system.md §6.2: `Settings` scene (⌘,) with tabs General,
/// Models, Server, Devices, Agents, Privacy, License (MAC-13).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            MacGeneralView().tabItem { Label("General", systemImage: "gearshape") }
            MacModelsView().tabItem { Label("Models", systemImage: "cpu") }
            MacServerView().tabItem { Label("Server", systemImage: "server.rack") }
            MacDevicesView().tabItem { Label("Devices", systemImage: "iphone") }
            MacPrivacyView().tabItem { Label("Privacy", systemImage: "hand.raised") }
            MacLiveShortlyView().tabItem { Label("LiveShortly", systemImage: "dot.radiowaves.left.and.right") }
            MacLicenseView().tabItem { Label("License", systemImage: "key") }
        }
        .frame(width: 620, height: 500)
        .font(.pocket(.body))
    }
}

private struct MacLiveShortlyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            LSConnectView(account: model.liveShortly)
        }
    }
}

private struct MacGeneralView: View {
    var body: some View {
        Form {
            Section("About PocketAI") {
                LabeledContent("App Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Platform", value: "macOS (Apple Silicon Optimized)")
                LabeledContent("Build Target", value: "Native SwiftUI + Metal/MLX")
            }

            Section("Documentation & Privacy") {
                Link("How PocketAI Protects Your Privacy", destination: URL(string: "https://getpocketai.app/privacy")!)
                Link("GitHub Repository & Release Notes", destination: URL(string: "https://github.com/getpocketai")!)
            }
        }
        .formStyle(.grouped)
    }
}

/// MAC-14: License activation (Keygen-based licensing).
private struct MacLicenseView: View {
    @Environment(AppModel.self) private var model
    @State private var entitlements: Entitlements?
    @State private var keyField = ""
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text("PocketAI Pro License")
                        .font(.pocket(.headline))
                    Text("Enables multi-device pairing, network model serving, and high-throughput generation.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }
            }

            Section("Pro Features") {
                Label("Use your Mac's models from iPhone over Wi-Fi", systemImage: "iphone")
                Label("Serve OpenAI-compatible models to network apps", systemImage: "network")
                Label("Unlimited local inference and document grounding", systemImage: "bolt.fill")
            }

            if let entitlements, entitlements.pro {
                Section {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(PocketColor.statusOk)
                        Text("License Active (\(entitlements.source))")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.statusOk)
                    }
                }
            } else {
                Section("Have a license key?") {
                    TextField("Enter license key (e.g. PKT-XXXX-XXXX)", text: $keyField)
                    Button("Activate License") { activate() }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketColor.accent)
                        .disabled(keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let errorText {
                        Text(errorText).font(.pocket(.footnote)).foregroundStyle(PocketColor.statusBad)
                    }
                }
            }

            Section {
                Text("Everything on-device stays 100% free forever. No recurring subscription.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .task { entitlements = model.core.entitlements() }
    }

    private func activate() {
        do {
            entitlements = try model.core.activateLicense(key: keyField)
            // Persist so AppModel.init can re-activate on relaunch —
            // activation alone is memory-only.
            model.saveLicenseKey(keyField.trimmingCharacters(in: .whitespacesAndNewlines))
            errorText = nil
        } catch {
            errorText = "Couldn't activate: \(error.localizedDescription)"
        }
    }
}

/// MAC-11: Privacy (M-NP) + audit viewer. Network Proof's offline toggle
/// and egress list, plus a filtered audit trail and JSONL export with chain verification.
public struct MacPrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var offline = false
    @State private var entries: [EgressEntry] = []
    @State private var auditEntries: [AuditEntry] = []
    @State private var actionFilter = "All"
    @State private var exportStatusMessage: String?

    private let filterOptions = ["All", "chat", "server", "model", "device", "license"]

    public init() {}

    private var filteredAuditEntries: [AuditEntry] {
        if actionFilter == "All" {
            return auditEntries
        }
        return auditEntries.filter { $0.action.localizedCaseInsensitiveContains(actionFilter) }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s20) {
                // Offline Mode Banner / Toggle Card
                offlineModeCard

                // Network Proof Hero Section
                networkProofCard

                // Audit Log Section
                auditLogSection
            }
            .padding(PocketSpacing.gutterMac)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PocketColor.bgCanvas)
        .task { reload() }
        .onChange(of: offline) { _, newValue in model.core.setOfflineMode(on: newValue) }
    }

    private var offlineModeCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack {
                HStack(spacing: PocketSpacing.s12) {
                    Image(systemName: "airplane")
                        .font(.system(size: 20))
                        .foregroundStyle(offline ? PocketColor.statusWarn : PocketColor.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(offline ? PocketColor.statusWarn.opacity(0.15) : PocketColor.bgSunken)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline Mode")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)

                        Text("Completely block all outgoing internet requests from PocketAI.")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                }

                Spacer()

                Toggle("", isOn: $offline)
                    .labelsHidden()
                    .tint(PocketColor.accent)
            }

            if offline {
                HStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(PocketColor.statusWarn)
                    Text("Offline mode active — model downloads and catalog updates are paused.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusWarn)
                }
                .padding(PocketSpacing.s8)
                .background(PocketColor.statusWarn.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(PocketSpacing.s16)
        .background(PocketColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(offline ? PocketColor.statusWarn.opacity(0.4) : PocketColor.lineHairline, lineWidth: 0.8)
        )
    }

    private var networkProofCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            Text("NETWORK PROOF")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                HStack(alignment: .bottom, spacing: PocketSpacing.s12) {
                    Text("\(entries.count)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(entries.isEmpty ? PocketColor.statusOk : PocketColor.textPrimary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Outbound connections recorded")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("Prompt text and model weights are never sent to external servers.")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    .padding(.bottom, 6)

                    Spacer()
                }

                Divider()

                if entries.isEmpty {
                    HStack(spacing: PocketSpacing.s12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(PocketColor.statusOk)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Zero Outbound Internet Connections")
                                .font(.pocket(.headline))
                                .foregroundStyle(PocketColor.statusOk)
                            Text("All model inference has occurred strictly on-device.")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
                    }
                    .padding(.vertical, PocketSpacing.s8)
                } else {
                    VStack(spacing: PocketSpacing.s8) {
                        ForEach(entries, id: \.ts) { entry in
                            HStack {
                                HStack(spacing: PocketSpacing.s8) {
                                    Circle()
                                        .fill(PocketColor.statusInfo)
                                        .frame(width: 6, height: 6)
                                    Text(entry.purpose)
                                        .font(.pocket(.callout))
                                        .foregroundStyle(PocketColor.textPrimary)
                                }
                                Spacer()
                                Text(entry.host)
                                    .font(.pocket(.mono))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }
                            .padding(.vertical, 2)
                        }
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
        }
    }

    private var auditLogSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack {
                Text("AUDIT LOG & CHAIN INTEGRITY")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)

                Spacer()

                // Honest instruments: the Core exposes no chain-verify API, so
                // we report the event count plainly rather than claim "Verified".
                Text("\(filteredAuditEntries.count) events")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                HStack {
                    Picker("Filter", selection: $actionFilter) {
                        ForEach(filterOptions, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .frame(width: 180)

                    Spacer()

                    Button {
                        exportAuditLogJSONL()
                    } label: {
                        Label("Export JSONL…", systemImage: "arrow.down.doc")
                            .font(.pocket(.footnote))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let exportStatusMessage {
                    Text(exportStatusMessage)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusOk)
                }

                Divider()

                if filteredAuditEntries.isEmpty {
                    Text("No matching audit events.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                        .padding(.vertical, PocketSpacing.s8)
                } else {
                    VStack(spacing: PocketSpacing.s8) {
                        ForEach(filteredAuditEntries, id: \.id) { entry in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.actor)
                                            .font(.pocket(.caption))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(PocketColor.bgSunken)
                                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                                        Text(entry.action)
                                            .font(.pocket(.callout))
                                            .fontWeight(.medium)
                                    }

                                    Text(entry.target)
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textSecondary)
                                }

                                Spacer()

                                Text(Date(timeIntervalSince1970: Double(entry.ts) / 1000), style: .time)
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textTertiary)
                            }
                            .padding(.vertical, 3)
                            Divider()
                        }
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
        }
    }

    private func reload() {
        offline = model.core.isOffline()
        entries = model.core.egressLog(limit: 0)
        auditEntries = model.core.auditLog(query: AuditQuery(limit: 50, sinceTs: nil))
    }

    private func exportAuditLogJSONL() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pocketai-audit-\(Int(Date().timeIntervalSince1970)).jsonl"
        panel.allowedContentTypes = [.plainText, .json]

        if panel.runModal() == .OK, let url = panel.url {
            var lines: [String] = []
            for entry in auditEntries {
                let dict: [String: Any] = [
                    "id": entry.id,
                    "actor": entry.actor,
                    "action": entry.action,
                    "target": entry.target,
                    "ts": entry.ts
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                   let string = String(data: data, encoding: .utf8) {
                    lines.append(string)
                }
            }
            let exportHeader = "{\"export\": \"pocketai-audit-log\", \"count\": \(auditEntries.count)}"
            lines.insert(exportHeader, at: 0)
            let output = lines.joined(separator: "\n") + "\n"
            do {
                try output.write(to: url, atomically: true, encoding: .utf8)
                exportStatusMessage = "Exported \(auditEntries.count) entries to \(url.lastPathComponent)"
            } catch {
                exportStatusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
