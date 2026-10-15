import PocketKit
import PocketUI
import SwiftUI

/// 02-design-system.md §6.2: `Settings` scene (⌘,) with tabs General,
/// Models, Server, Devices, Agents, Privacy, Pro (MAC-13). Models/Server/
/// Devices reuse the real tabs built for MAC-04/06/07 rather than
/// duplicating their views. Agents stays a placeholder - that card is
/// parked out of scope for this release (next-release/agents.md).
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
            MacProView().tabItem { Label("Pro", systemImage: "star") }
        }
        .frame(width: 560, height: 420)
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

/// MAC-14: Pro + license (M-PAY §7.7's Mac half). Paste + activate a
/// license key; no App Store IAP here (Mac is direct-download, not a
/// Mac App Store build per LIC-01's Keygen-based licensing).
private struct MacProView: View {
    @Environment(AppModel.self) private var model
    @State private var entitlements: Entitlements?
    @State private var keyField = ""
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Text("PocketAI Pro").font(.pocket(.headline))
                Text("One purchase. Works on your iPhone and Mac.").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
            }
            Section {
                Label("Use your Mac's models from iPhone", systemImage: "iphone")
                Label("Serve models to other apps on your network", systemImage: "network")
            }
            if let entitlements, entitlements.pro {
                Section {
                    Label("Pro active (\(entitlements.source))", systemImage: "checkmark.seal.fill")
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
/// and egress list, plus a plain-text audit trail (who/what/when) below
/// it - the Mac equivalent of the iPhone's Settings > Network Proof,
/// with the audit log appended since Mac Settings has room for it.
private struct MacPrivacyView: View {
    @Environment(AppModel.self) private var model
    @State private var offline = false
    @State private var entries: [EgressEntry] = []
    @State private var auditEntries: [AuditEntry] = []

    var body: some View {
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
                Text("\(entries.count) internet request\(entries.count == 1 ? "" : "s") today")
                    .font(.pocket(.footnote))
                ForEach(entries, id: \.ts) { entry in
                    LabeledContent(entry.purpose, value: entry.host)
                }
            }
            Section("Audit log") {
                ForEach(auditEntries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                        Text("\(entry.actor) · \(entry.action)").font(.pocket(.footnote))
                        Text(entry.target).font(.pocket(.caption)).foregroundStyle(PocketColor.textSecondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            offline = model.core.isOffline()
            entries = model.core.egressLog(limit: 0)
            auditEntries = model.core.auditLog(query: AuditQuery(limit: 50, sinceTs: nil))
        }
        .onChange(of: offline) { _, newValue in model.core.setOfflineMode(on: newValue) }
    }
}
