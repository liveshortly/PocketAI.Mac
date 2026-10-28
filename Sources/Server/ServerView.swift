import AppKit
import PocketKit
import PocketUI
import SwiftUI

/// The local OpenAI-compatible server: on or off, loopback or LAN, and the
/// key other apps authenticate with.
struct ServerView: View {
    @Environment(AppModel.self) private var app
    @State private var lanEnabled = false
    @State private var apiKey: String?
    @State private var copied = false
    @State private var refreshTask: Task<Void, Never>?
    /// True while the toggle is being seeded from the server's own state.
    @State private var syncingFromStatus = false

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
            syncingFromStatus = true
            lanEnabled = app.serverStatus.lanEnabled
            syncingFromStatus = false
            apiKey = app.core.hasLocalApiKey() ? "••••••••••••••••" : nil
            startRefreshing()
        }
        .onDisappear { refreshTask?.cancel() }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(spacing: PocketSpacing.s12) {
                HUDDot(
                    tint: app.serverStatus.running
                        ? PocketColor.statusOk : PocketColor.textTertiary,
                    pulsing: app.serverStatus.running)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.serverStatus.running ? "Running" : "Stopped")
                        .font(.pocket(.headline))
                    Text(
                        app.serverStatus.running
                            ? "Port \(app.serverStatus.port) · \(app.serverStatus.connectedDevices) connected"
                            : "Other apps and paired devices can't reach this Mac's models."
                    )
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                }
                Spacer(minLength: 0)
                if app.serverStatus.running {
                    Button("Stop") { app.stopServer() }
                        .buttonStyle(.hudDestructive)
                } else {
                    Button("Start") { app.startServer(lan: lanEnabled) }
                        .buttonStyle(.hudProminent)
                }
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Access")
            Toggle("Allow devices on this network", isOn: $lanEnabled)
                .toggleStyle(.switch)
                .tint(PocketColor.accent)
                .font(.pocket(.body))
                .onChange(of: lanEnabled) { _, enabled in
                    // Only a human flip rebinds. Seeding this toggle from the
                    // live status on appear used to trip this handler and
                    // bounce a running server, killing a paired device's
                    // in-flight request.
                    guard !syncingFromStatus, app.serverStatus.running,
                          enabled != app.serverStatus.lanEnabled
                    else { return }
                    app.stopServer()
                    app.startServer(lan: enabled)
                }
            Text(
                lanEnabled
                    ? "Reachable from your LAN, so a paired iPhone can use this Mac. macOS will ask for Local Network permission."
                    : "Loopback only (127.0.0.1) — nothing outside this Mac can connect."
            )
            .font(.pocket(.caption))
            .foregroundStyle(PocketColor.textTertiary)
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
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
                Button(copied ? "Copied" : "Generate & copy") { generateKey() }
                    .buttonStyle(.hud)
            }
            Text("Point any OpenAI-compatible client at that URL. Requests never leave this Mac.")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
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
    @State private var offline = false

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
                        Toggle("Offline mode", isOn: $offline)
                            .toggleStyle(.switch)
                            .tint(PocketColor.accent)
                            .font(.pocket(.body))
                            .onChange(of: offline) { _, on in app.core.setOfflineMode(on: on) }
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
        .task {
            offline = app.core.isOffline()
            reload()
        }
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
