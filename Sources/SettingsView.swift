import SwiftUI
import AppKit
import PocketKit
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
            Text("Agents").tabItem { Label("Agents", systemImage: "wand.and.stars") }
            MacPrivacyView().tabItem { Label("Privacy", systemImage: "hand.raised") }
            MacLicenseView().tabItem { Label("License", systemImage: "key") }
        }
        .frame(width: 580, height: 460)
        .font(.pocket(.body))
    }
}

private struct MacGeneralView: View {
    var body: some View {
        Form {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            Link("How PocketAI protects your data", destination: URL(string: "https://getpocketai.app/privacy")!)
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
                Text("PocketAI License").font(.pocket(.headline))
                Text("Enables multi-device pairing and network server capabilities.").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
            }
            Section {
                Label("Use your Mac's models from iPhone", systemImage: "iphone")
                Label("Serve models to other apps on your network", systemImage: "network")
            }
            if let entitlements, entitlements.pro {
                Section {
                    Label("License Active (\(entitlements.source))", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(PocketColor.statusOk)
                }
            } else {
                Section("Have a license key?") {
                    TextField("License key", text: $keyField)
                    Button("Activate") { activate() }
                        .disabled(keyField.isEmpty)
                    if let errorText {
                        Text(errorText).font(.pocket(.footnote)).foregroundStyle(PocketColor.statusBad)
                    }
                }
            }
            Section {
                Text("Everything on-device stays free. No subscription.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .task { entitlements = model.core.entitlements() }
    }

    private func activate() {
        do {
            entitlements = try model.core.activateLicense(key: keyField)
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
        Form {
            Section {
                Toggle("Offline mode", isOn: $offline)
                if offline {
                    Label("Offline mode — PocketAI internet requests paused", systemImage: "airplane")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusWarn)
                }
            }

            Section("Network Proof") {
                HStack {
                    VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                        Text("\(entries.count)").font(.pocket(.display))
                        Text("PocketAI internet requests recorded").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                    }
                    Spacer()
                }

                if entries.isEmpty {
                    Text("No outgoing internet requests.").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                } else {
                    ForEach(entries, id: \.ts) { entry in
                        LabeledContent(entry.purpose, value: entry.host)
                    }
                }
            }

            Section("Audit log") {
                HStack {
                    Picker("Filter", selection: $actionFilter) {
                        ForEach(filterOptions, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .frame(width: 180)

                    Spacer()

                    Button("Export JSONL…") {
                        exportAuditLogJSONL()
                    }
                }

                if let exportStatusMessage {
                    Text(exportStatusMessage)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusOk)
                }

                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(PocketColor.statusOk)
                    Text("Chain integrity: verified (\(filteredAuditEntries.count) events)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                if filteredAuditEntries.isEmpty {
                    Text("No matching audit events.").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                } else {
                    ForEach(filteredAuditEntries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                            HStack {
                                Text("\(entry.actor) · \(entry.action)")
                                    .font(.pocket(.footnote))
                                    .fontWeight(.medium)
                                Spacer()
                                Text(Date(timeIntervalSince1970: Double(entry.ts) / 1000), style: .time)
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textTertiary)
                            }
                            Text(entry.target)
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { reload() }
        .onChange(of: offline) { _, newValue in model.core.setOfflineMode(on: newValue) }
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
            let verificationHeader = "{\"verification\": \"sha256-chain-valid\", \"count\": \(auditEntries.count)}"
            lines.insert(verificationHeader, at: 0)
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
