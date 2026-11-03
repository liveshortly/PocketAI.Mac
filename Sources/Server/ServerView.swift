import AppKit
import PocketKit
import PocketUI
import SwiftUI

/// The local OpenAI-compatible server: who may use it (MAC-18 Access) and
/// the key other apps authenticate with. There is no Start button - picking
/// an Access level is what runs the server.
struct ServerView: View {
    @Environment(AppModel.self) private var app
    @State private var apiKey: String?
    @State private var copied = false
    @State private var refreshTask: Task<Void, Never>?
    /// A switch that would rebind under a connected device, awaiting an
    /// inline "switch anyway?".
    @State private var pendingAccess: AppModel.ServerAccess?
    /// Generating replaces the key, so a second one waits for a yes.
    @State private var confirmRegenerate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Local server")
                    .font(.pocket(.headline))
                Spacer()
                if app.serverStatus.running {
                    HUDLiveBadge()
                }
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    statusCard
                    accessCard
                    endpointCard
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task {
            apiKey = app.core.hasLocalApiKey() ? "••••••••••••••••" : nil
            startRefreshing()
        }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: app.commandSerial) { _, _ in
            if app.pendingCommand == .refresh { app.refreshServerStatus() }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(spacing: PocketSpacing.s12) {
                HUDDot(
                    tint: app.serverStatus.running
                        ? PocketColor.statusOk : PocketColor.textTertiary,
                    pulsing: app.serverStatus.running)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.serverStatus.running ? "Running" : "Stopped")
                        .font(.pocket(.headline))
                    Text(statusDetail)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    private var statusDetail: String {
        let s = app.serverStatus
        guard s.running else {
            return app.serverAccess == .off
                ? "Other apps and paired devices can't reach this Mac's models."
                : "Couldn't start the server. Pick Access again, or relaunch PocketAI if the port is busy."
        }
        let reach = s.lanEnabled ? "this Mac and your network" : "this Mac only"
        let devices = s.connectedDevices == 1 ? "1 device" : "\(s.connectedDevices) devices"
        return "Port \(s.port) · \(reach) · \(devices) connected"
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Access")
            Picker("Access", selection: accessBinding) {
                Text("Off").tag(AppModel.ServerAccess.off)
                Text("This Mac only").tag(AppModel.ServerAccess.thisMac)
                Text("This Mac + paired devices").tag(AppModel.ServerAccess.pairedDevices)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Server access")
            if let pendingAccess { switchAnywayRow(pendingAccess) }
            Text(accessCaption)
                .font(.pocket(.caption))
                .foregroundStyle(app.serverAccess == .pairedDevices && app.serverNeedsLicense
                    ? PocketColor.statusWarn : PocketColor.textTertiary)
            if app.serverAccess == .pairedDevices, app.serverNeedsLicense {
                EnterLicenseButton()
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    /// Switching rebinds the listener, which would cut off a device mid-reply,
    /// so with one connected the switch waits for an inline yes.
    private var accessBinding: Binding<AppModel.ServerAccess> {
        Binding(
            get: { pendingAccess ?? app.serverAccess },
            set: { access in
                guard access != app.serverAccess else { pendingAccess = nil; return }
                if app.serverStatus.connectedDevices > 0 {
                    pendingAccess = access
                } else {
                    app.setServerAccess(access)
                }
            })
    }

    private func switchAnywayRow(_ access: AppModel.ServerAccess) -> some View {
        let count = app.serverStatus.connectedDevices
        return HStack(spacing: PocketSpacing.s8) {
            Text("\(count) device\(count == 1 ? " is" : "s are") using this Mac. Switch anyway?")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.statusWarn)
            Spacer(minLength: 0)
            Button("Cancel") { pendingAccess = nil }
                .buttonStyle(.hud)
            Button("Switch") {
                pendingAccess = nil
                app.setServerAccess(access)
            }
            .buttonStyle(.hudDestructive)
        }
    }

    private var accessCaption: String {
        switch app.serverAccess {
        case .off: return "Nothing can use this Mac's models from outside the app."
        case .thisMac: return "Loopback only (127.0.0.1), for other apps on this Mac."
        case .pairedDevices where app.serverNeedsLicense:
            return "Paired devices need PocketAI Pro. Until a license key is entered, this Mac serves only itself."
        case .pairedDevices:
            return "Reachable from your LAN, so a paired iPhone can use this Mac. macOS will ask for Local Network permission."
        }
    }

    private var endpointCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("For other apps")
            row("Base URL", app.serverStatus.running
                ? "http://127.0.0.1:\(app.serverStatus.port)/v1" : "—")
            row("Model", app.currentModelId)
            HStack {
                Text("API key")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                Spacer(minLength: PocketSpacing.s8)
                Text(apiKey ?? "not generated")
                    .font(.pocket(.mono))
                    .textSelection(.enabled)
                    .accessibilityLabel(apiKeyAccessibility)
                Button(copied ? "Copied" : apiKey == nil ? "Generate & copy" : "Regenerate & copy…") {
                    if apiKey == nil { generateKey() } else { confirmRegenerate = true }
                }
                .buttonStyle(.hud)
                .confirmationDialog("Replace the API key?", isPresented: $confirmRegenerate) {
                    Button("Replace Key") { generateKey() }
                } message: {
                    Text("Apps using the current key stop working until you give them the new one. The new key is copied to the clipboard.")
                }
            }
            Text("Point any OpenAI-compatible client at that URL. Requests never leave this Mac.")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    /// The masked key is bullets; VoiceOver should say what state it is in.
    private var apiKeyAccessibility: String {
        guard let apiKey else { return "API key not generated" }
        return apiKey.hasPrefix("•") ? "API key set, hidden" : "API key \(apiKey)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
            Spacer(minLength: PocketSpacing.s8)
            Text(value)
                .font(.pocket(.mono))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    private func generateKey() {
        let key = app.core.generateLocalApiKey()
        apiKey = key
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                app.refreshServerStatus()
            }
        }
    }
}

/// Offline mode, what left this Mac, and what the app did.
struct PrivacyView: View {
    @Environment(AppModel.self) private var app
    @State private var egress: [EgressEntry] = []
    @State private var audit: [AuditEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy")
                    .font(.pocket(.headline))
                Spacer()
                Button("Refresh") { reload() }
                    .buttonStyle(.hud)
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Toggle("Offline mode", isOn: Binding(
                            get: { app.offlineMode.isOn },
                            set: { app.offlineMode.set($0) }))
                            .toggleStyle(.switch)
                            .font(.pocket(.body))
                        Text("Blocks every outbound request, model downloads included.")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                    .padding(PocketSpacing.s12)
                    .hudPanel()

                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        HUDLabel("Network activity · \(egress.count)")
                        if egress.isEmpty {
                            emptyNote("Nothing has left this Mac.")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(egress.enumerated()), id: \.offset) { index, entry in
                                    if index > 0 { HUDRule() }
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.host).font(.pocket(.body))
                                            Text("\(entry.purpose) · \(entry.initiatedBy)")
                                                .font(.pocket(.caption))
                                                .foregroundStyle(PocketColor.textTertiary)
                                        }
                                        Spacer(minLength: 0)
                                        Text("↑\(hudBytes(entry.bytesOut)) ↓\(hudBytes(entry.bytesIn))")
                                            .font(.pocket(.caption))
                                            .foregroundStyle(PocketColor.textTertiary)
                                            .monospacedDigit()
                                    }
                                    .padding(PocketSpacing.s8)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(
                                        "\(entry.host), \(entry.purpose), started by "
                                        + "\(entry.initiatedBy), "
                                        + "\(hudBytes(entry.bytesOut)) sent, "
                                        + "\(hudBytes(entry.bytesIn)) received")
                                }
                            }
                            .hudPanel()
                        }
                    }

                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        HUDLabel("Audit log · \(audit.count)")
                        if audit.isEmpty {
                            emptyNote("No recorded actions yet.")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(audit, id: \.id) { entry in
                                    HStack {
                                        Text(entry.action)
                                            .font(.pocket(.body))
                                        Text(entry.target)
                                            .font(.pocket(.caption))
                                            .foregroundStyle(PocketColor.textTertiary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(hudRelative(entry.ts))
                                            .font(.pocket(.caption))
                                            .foregroundStyle(PocketColor.textTertiary)
                                    }
                                    .padding(PocketSpacing.s8)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(
                                        "\(entry.action), \(entry.target), "
                                        + hudRelative(entry.ts))
                                    HUDRule()
                                }
                            }
                            .hudPanel()
                        }
                    }
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task { reload() }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.pocket(.footnote))
            .foregroundStyle(PocketColor.textTertiary)
            .padding(PocketSpacing.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hudPanel()
    }

    private func reload() {
        egress = app.core.egressLog(limit: 50)
        audit = app.core.auditLog(query: AuditQuery(limit: 50, sinceTs: nil))
    }
}

extension AuditEntry: @retroactive Identifiable {}
