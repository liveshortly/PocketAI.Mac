import PocketKit
import PocketUI
import SwiftUI

/// 02-design-system.md §6.2: `Settings` scene (⌘,) with tabs General,
/// Models, Server, Devices, Agents, Privacy. Tab bodies are placeholders
/// until their owning L6 cards land - this proves the scene itself and
/// its keyboard shortcut exist.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Text("General").tabItem { Label("General", systemImage: "gearshape") }
            Text("Models").tabItem { Label("Models", systemImage: "cpu") }
            Text("Server").tabItem { Label("Server", systemImage: "server.rack") }
            Text("Devices").tabItem { Label("Devices", systemImage: "iphone") }
            Text("Agents").tabItem { Label("Agents", systemImage: "wand.and.stars") }
            MacPrivacyView().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480, height: 320)
        .font(.pocket(.body))
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
