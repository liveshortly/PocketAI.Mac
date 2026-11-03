import PocketLiveShortly
import PocketUI
import SwiftUI

/// Tools → LiveShortly (LSI-14): the machine side of LiveShortly on this Mac —
/// the daemon, the repos it may serve, and the sessions running here.
struct LSMachineView: View {
    @Environment(AppModel.self) private var app
    @State private var daemon = LSDaemonController.shared
    @State private var hosts: [LSHost] = []
    @State private var localSessions: [LSSession] = []
    @State private var loading = false

    /// This Mac registered, but not by our child process: someone ran
    /// `live daemon` in a terminal.
    private var runningElsewhere: Bool {
        !daemon.isRunning && hosts.contains { $0.id == daemon.hostID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HUDRule()
            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    LSDaemonCard(daemon: daemon, runningElsewhere: runningElsewhere)
                    LSReposCard(daemon: daemon)
                    sessionsCard
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task { await reload() }
        .onChange(of: daemon.isRunning) { _, _ in
            // The host shows up in /api/hosts a beat after the daemon registers.
            Task {
                try? await Task.sleep(for: .seconds(3))
                await reload()
            }
        }
    }

    private var header: some View {
        HStack(spacing: PocketSpacing.s12) {
            LSSessionMark(isLive: daemon.isRunning, size: 22)
            Text("LiveShortly").font(.pocket(.headline))
            Spacer()
            if daemon.isRunning || runningElsewhere { HUDLiveBadge() }
            Button("Refresh") { Task { await reload() } }
                .buttonStyle(.hud)
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Sessions on this Mac")
            if loading {
                PocketMarkView(state: .loading, size: 28)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading sessions")
            } else if localSessions.isEmpty {
                Text("Nothing running here. `live claude` in Terminal, or a session started below, shows up on refresh.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            ForEach(localSessions) { session in
                LSLocalSessionRow(session: session) { app.selection = .session(session.id) }
            }
            Button("New session on this Mac…") { app.selection = .newSession() }
                .buttonStyle(.hudProminent)
                .disabled(app.liveShortly.client == nil)
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    private func reload() async {
        await daemon.refresh()
        guard let client = app.liveShortly.client else { return }
        loading = true
        hosts = (try? await client.hosts()) ?? []
        // Live sessions whose tmux pane runs on this Mac (CLI or daemon).
        let local = await daemon.localSessionPrefixes()
        let live = ((try? await client.sessions(limit: 100)) ?? []).filter(\.isLive)
        localSessions = live.filter { local.contains(String($0.id.prefix(8))) }
        loading = false
    }
}

/// Block 1: is the daemon installed, signed in, running — and the buttons.
private struct LSDaemonCard: View {
    let daemon: LSDaemonController
    let runningElsewhere: Bool
    @State private var showLog = false
    @State private var askingCustom = false
    @State private var customURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HUDLabel("Daemon on this Mac")
            HStack(spacing: PocketSpacing.s8) {
                HUDDot(tint: tint, pulsing: daemon.isRunning)
                Text(statusText).font(.pocket(.body))
                Spacer(minLength: 0)
                controls
            }
            if let hint {
                Text(LocalizedStringKey(hint))
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = daemon.problem { problemBanner(problem) }
            serverRow
            nameField
            if !daemon.log.isEmpty {
                DisclosureGroup("Log", isExpanded: $showLog) { logView }
                    .font(.pocket(.footnote))
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    @ViewBuilder private var controls: some View {
        switch daemon.status {
        case .signedOut:
            Button(daemon.signingIn ? "Waiting for browser…" : "Sign in") { daemon.signIn() }
                .buttonStyle(.hudProminent)
                .disabled(daemon.signingIn || daemon.serverDown)
                .help(daemon.serverDown ? (daemon.problem?.message ?? "") : "")
        case .stopped where !runningElsewhere:
            Button("Start") { daemon.start() }
                .buttonStyle(.hudProminent)
                .disabled(daemon.dirs.isEmpty)
        case .running:
            Button("Restart") { daemon.restart() }.buttonStyle(.hud)
            Button("Stop") { daemon.stop() }.buttonStyle(.hudDestructive)
        default:
            EmptyView()
        }
    }

    /// LSI-15: plain-English failure plus the way out. The raw Go error is
    /// still in the Log below.
    private func problemBanner(_ problem: LSLoginProblem) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            Label {
                Text(LocalizedStringKey(problem.message))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketColor.statusWarn)
            }
            .font(.pocket(.footnote))
            HStack(spacing: PocketSpacing.s8) {
                Button("Retry") { daemon.retry() }.buttonStyle(.hud)
                if problem.kind == .unreachable, !LSServer.isProduction(daemon.server) {
                    Button("Use liveshortly.com") { daemon.useServer(nil) }
                        .buttonStyle(.hudProminent)
                }
            }
        }
        .padding(PocketSpacing.s8)
        .hudPanel(PocketColor.bgSunken)
    }

    private var serverRow: some View {
        HStack(spacing: PocketSpacing.s8) {
            Text("Server").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
            Text(LSServer.label(daemon.server))
                .font(.pocket(.mono))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(daemon.server)
            Spacer(minLength: 0)
            Menu("Change") {
                Button("liveshortly.com") { daemon.useServer(nil) }
                    .disabled(LSServer.isProduction(daemon.server))
                Button("Custom…") {
                    customURL = LSServer.isProduction(daemon.server) ? "" : daemon.server
                    askingCustom = true
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(daemon.signingIn)
        }
        .alert("Custom server", isPresented: $askingCustom) {
            TextField("https://live.example.com", text: $customURL)
            Button("Use") { daemon.useServer(customOrigin) }
                .disabled(customOrigin == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A self-hosted LiveShortly server. A running daemon restarts to connect there.")
        }
    }

    /// The typed URL as an http(s) origin, or nil if it isn't one.
    private var customOrigin: String? {
        let raw = customURL.trimmingCharacters(in: .whitespaces)
        guard let c = URLComponents(string: raw), c.scheme == "http" || c.scheme == "https",
              c.host?.isEmpty == false else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private var nameField: some View {
        HStack(spacing: PocketSpacing.s8) {
            Text("Shown as").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
            TextField("Machine name", text: Bindable(daemon).machineName)
                .textFieldStyle(.roundedBorder)
                .disabled(daemon.isRunning)
        }
    }

    private var logView: some View {
        ScrollView {
            Text(daemon.log)
                .font(.pocket(.mono))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .padding(PocketSpacing.s8)
        .hudPanel(PocketColor.bgSunken)
    }

    private var tint: Color {
        daemon.isRunning || runningElsewhere ? PocketColor.statusOk : PocketColor.textTertiary
    }

    private var statusText: String {
        switch daemon.status {
        case .checking: return "Checking…"
        case .sandboxed: return "Unavailable in this build"
        case .notInstalled: return "live CLI not installed"
        case .signedOut: return "Signed out"
        case .stopped: return runningElsewhere ? "Running outside PocketAI" : "Stopped"
        case .running(let pid, let since):
            return "Running · pid \(pid) · \(daemon.machineName) · up "
                + since.formatted(.relative(presentation: .named))
        }
    }

    private var hint: String? {
        switch daemon.status {
        case .sandboxed:
            return "The app sandbox stops PocketAI from running the `live` CLI. Run `live daemon --dir <repo>` in Terminal instead."
        case .notInstalled:
            return "Install it with `brew install liveshortly/tap/live`, then Refresh."
        case .signedOut:
            return "Sign in opens your browser to approve this Mac (`live login`)."
        case .stopped where runningElsewhere:
            return "A `live daemon` started in Terminal is serving this Mac. Stop it there to manage it here."
        case .stopped where daemon.dirs.isEmpty:
            return "Add at least one repo below to start."
        default:
            return daemon.account.map { "Signed in as \($0)" }
        }
    }
}

/// Block 2: the daemon's `--dir` allowlist. The only way a path becomes
/// reachable from the web or the phone.
private struct LSReposCard: View {
    let daemon: LSDaemonController

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack {
                HUDLabel("Allowed repos")
                Spacer()
                Button("Add repo…") { daemon.addRepos() }.buttonStyle(.hud)
            }
            if daemon.dirs.isEmpty {
                Text("No repos yet. Agents started from the web or your phone can only run in these.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            ForEach(daemon.dirs, id: \.self) { dir in
                LSRepoRow(dir: dir, home: daemon.realHome) { daemon.remove(dir) }
            }
            if daemon.isRunning {
                Text("Changing this list restarts the daemon.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }
}

private struct LSRepoRow: View {
    let dir: String
    let home: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "folder").foregroundStyle(PocketColor.textTertiary)
                .accessibilityHidden(true)
            Text(dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir)
                .font(.pocket(.mono))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(dir)
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(PocketColor.textTertiary)
                .accessibilityLabel("Remove \(dir)")
        }
        .padding(.vertical, 2)
    }
}

/// A live session running on this Mac, opened in the regular viewer
/// (watch + comment + allow/deny — the same as `live join`).
private struct LSLocalSessionRow: View {
    let session: LSSession
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            LSSessionMark(isLive: true, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title.isEmpty ? "Untitled session" : session.title)
                    .font(.pocket(.body)).lineLimit(1)
                Text([session.framework, "\(session.eventCount) events"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Open", action: onOpen).buttonStyle(.hud)
        }
        .padding(.vertical, 2)
    }
}
