import AppKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// Tools → LiveShortly (LSI-14, redesigned in LSI-16): this Mac as a
/// LiveShortly machine. State first, in plain words — is it on, what is it
/// called, what can it run, which folders, what is running — and the raw log
/// tucked under Troubleshooting.
struct LSMachineView: View {
    @Environment(AppModel.self) private var app
    @State private var daemon = LSDaemonController.shared
    @State private var hosts: [LSHost] = []
    @State private var showLog = false

    /// This Mac registered, but not by our child process: someone ran
    /// `live daemon` in a terminal.
    private var runningElsewhere: Bool {
        !daemon.isRunning && hosts.contains { $0.id == daemon.hostID }
    }

    private var thisHost: LSHost? { hosts.first { $0.id == daemon.hostID } }

    /// The account's sessions that ran in this Mac's tmux socket.
    private var localSessions: [LSSession] {
        app.liveShortly.feed.ordered.filter { daemon.localIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HUDRule()
            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    LSStatusCard(daemon: daemon, runningElsewhere: runningElsewhere, showLog: $showLog)
                    if let thisHost, daemon.isRunning || runningElsewhere {
                        LSReadyCard(host: thisHost, server: daemon.server, daemon: daemon)
                    }
                    LSFoldersCard(daemon: daemon)
                    LSLocalSessionsCard(
                        sessions: localSessions,
                        canStart: app.liveShortly.client != nil,
                        onOpen: { app.selection = .session($0) },
                        onNew: { app.selection = .newSession() })
                    LSTroubleshootingCard(daemon: daemon, expanded: $showLog)
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 760)
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
        .onChange(of: app.liveShortly.feed.sessions) { _, sessions in
            Task { await daemon.noteLocal(sessions) }
        }
    }

    private var header: some View {
        HStack(spacing: PocketSpacing.s12) {
            LSSessionMark(isLive: daemon.isRunning || runningElsewhere, size: 22)
            Text("LiveShortly").font(.pocket(.headline))
            Spacer()
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private func reload() async {
        await daemon.refresh()
        await daemon.noteLocal(app.liveShortly.feed.sessions)
        guard let client = app.liveShortly.client else { return }
        hosts = (try? await client.hosts()) ?? hosts
    }
}

private extension View {
    /// Every card on this page: same width, same padding, hairline panel.
    func lsCard() -> some View {
        padding(PocketSpacing.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hudPanel()
    }
}

// MARK: - 1. This Mac on LiveShortly

private struct LSStatusCard: View {
    @Environment(AppModel.self) private var app
    let daemon: LSDaemonController
    let runningElsewhere: Bool
    @Binding var showLog: Bool
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(spacing: PocketSpacing.s8) {
                HUDLabel("This Mac on LiveShortly")
                Spacer(minLength: 0)
                controls
                moreMenu
            }
            LSStatusLine(daemon: daemon, runningElsewhere: runningElsewhere)
            if let trouble = daemon.trouble { troubleLine(trouble) }
            if let problem = daemon.problem { LSProblemBanner(daemon: daemon, problem: problem) }
            if let account = daemon.account, daemon.status != .signedOut {
                Text(Self.accountLine(account))
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LSServerRow(daemon: daemon)
            if daemon.status != .signedOut { LSNameRow(daemon: daemon) }
        }
        .lsCard()
    }

    /// "Rohit (r@x.com)" from `live whoami` → "Rohit · r@x.com".
    static func accountLine(_ raw: String) -> String {
        guard raw.hasSuffix(")"), let open = raw.lastIndex(of: "(") else { return raw }
        let name = raw[..<open].trimmingCharacters(in: .whitespaces)
        let email = raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]
        return name.isEmpty ? String(email) : "\(name) · \(email)"
    }

    @ViewBuilder private var controls: some View {
        switch daemon.status {
        case .signedOut:
            Button(daemon.signingIn ? "Waiting for browser…" : "Sign in") { daemon.signIn() }
                .buttonStyle(.hudProminent)
                .disabled(daemon.signingIn || daemon.serverDown)
                .help(daemon.serverDown ? (daemon.problem?.message ?? "") : "")
        case .stopped where !runningElsewhere, .running:
            Toggle("LiveShortly on this Mac", isOn: Binding(
                get: { daemon.isRunning },
                set: { $0 ? daemon.start() : daemon.stop() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!daemon.isRunning && daemon.dirs.isEmpty)
                .help(daemon.dirs.isEmpty ? "Add a folder below first" : "")
        default:
            EmptyView()
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Restart daemon") { daemon.restart() }.disabled(!daemon.isRunning)
            Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
            Button("Details…") { showDetails = true }
            if daemon.status != .signedOut, daemon.account != nil {
                Divider()
                Button("Sign out") { daemon.signOut() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .popover(isPresented: $showDetails) { LSDetailsPopover(daemon: daemon) }
    }

    private func troubleLine(_ text: String) -> some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(PocketColor.statusBad)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(text))
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.statusBad)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { daemon.isRunning ? daemon.restart() : daemon.start() }
                .buttonStyle(.hud)
        }
    }
}

/// The state in words, with the green dot only when it is actually on.
private struct LSStatusLine: View {
    let daemon: LSDaemonController
    let runningElsewhere: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            HStack(alignment: .firstTextBaseline, spacing: PocketSpacing.s8) {
                HUDDot(tint: online ? PocketColor.statusOk : PocketColor.textTertiary)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(title).font(.pocket(.body)).fontWeight(.semibold)
                if case .running(_, let since) = daemon.status {
                    Text("Since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            if let detail {
                Text(LocalizedStringKey(detail))
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var online: Bool { (daemon.isRunning || runningElsewhere) && daemon.trouble == nil }

    private var title: String {
        switch daemon.status {
        case .checking: return "Checking…"
        case .sandboxed: return "Unavailable in this build"
        case .notInstalled: return "The live CLI isn't installed"
        case .signedOut: return "Sign in to connect this Mac."
        case .stopped: return runningElsewhere ? "Online" : "Off"
        case .running: return daemon.trouble == nil ? "Online" : "Can't connect"
        }
    }

    private var detail: String? {
        let web = LSServer.isProduction(daemon.server) ? "liveshortly.com" : LSServer.label(daemon.server)
        switch daemon.status {
        case .sandboxed:
            return "The app sandbox stops PocketAI from running the `live` CLI. Run `live daemon --dir <folder>` in Terminal instead."
        case .notInstalled:
            return "Install it with `brew install liveshortly/tap/live`, then come back here."
        case .signedOut:
            return "Sign in opens your browser to approve this Mac."
        case .stopped where runningElsewhere:
            return "A `live daemon` started in Terminal is serving this Mac. Stop it there to manage it here."
        case .stopped where daemon.dirs.isEmpty:
            return "This Mac won't accept sessions. Add a folder below, then turn it on."
        case .stopped:
            return "This Mac won't accept sessions."
        case .running where daemon.trouble == nil:
            return "You can start agents on this Mac from \(web) or your iPhone."
        default:
            return nil
        }
    }
}

/// LSI-15: plain-English sign-in failure plus the way out.
private struct LSProblemBanner: View {
    let daemon: LSDaemonController
    let problem: LSLoginProblem

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(PocketColor.statusBad)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(problem.message))
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.statusBad)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { daemon.retry() }.buttonStyle(.hud)
            if problem.kind == .unreachable, !LSServer.isProduction(daemon.server) {
                Button("Use liveshortly.com") { daemon.useServer(nil) }
                    .buttonStyle(.hudProminent)
            }
        }
    }
}

/// LSI-15 server switcher.
private struct LSServerRow: View {
    let daemon: LSDaemonController
    @State private var askingCustom = false
    @State private var customURL = ""

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            Text("Server").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
            Text(LSServer.label(daemon.server))
                .font(.pocket(.footnote))
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
}

/// "Name on the web: mini ✎" — inline edit; saving restarts quietly.
private struct LSNameRow: View {
    @Environment(AppModel.self) private var app
    let daemon: LSDaemonController
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: PocketSpacing.s8) {
                Text("Name on the web:").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                if editing {
                    TextField("Machine name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(save)
                        .onExitCommand { editing = false }
                        .frame(maxWidth: 240)
                    Button("Save", action: save).buttonStyle(.hudProminent)
                } else {
                    Text(daemon.machineName).font(.pocket(.footnote)).fontWeight(.semibold)
                    Button {
                        draft = daemon.machineName
                        editing = true
                        focused = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketColor.accent)
                    .accessibilityLabel("Rename this Mac")
                }
                Spacer(minLength: 0)
            }
            Text("How this Mac appears in the session picker")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
    }

    private func save() {
        editing = false
        if daemon.rename(draft) { app.toast("Renamed — restarted to apply") }
    }
}

/// `…` › Details: the technical facts kept out of the main UI.
private struct LSDetailsPopover: View {
    let daemon: LSDaemonController

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: PocketSpacing.s12, verticalSpacing: PocketSpacing.s4) {
            row("Process", pid)
            row("Name", daemon.machineName)
            row("Server", daemon.server)
            row("Host id", daemon.hostID ?? "—")
            row("Runs as", daemon.userName)
        }
        .font(.pocket(.footnote))
        .textSelection(.enabled)
        .padding(PocketSpacing.s12)
    }

    private var pid: String {
        if case .running(let pid, _) = daemon.status { return "pid \(pid)" }
        return "not running"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(PocketColor.textSecondary)
            Text(value)
        }
    }
}

// MARK: - 2. Ready to run

private struct LSReadyCard: View {
    let host: LSHost
    let server: String
    let daemon: LSDaemonController
    @State private var allModels = false

    /// Agents `live daemon` knows how to spawn, shown greyed when missing.
    private static let known = ["claude", "codex", "gemini", "agy", "ollama", "cursor-agent"]

    private var missing: [String] { Self.known.filter { !host.agents.contains($0) } }
    private var models: [String] { host.models ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HUDLabel("Ready to run")
            chips("Agents") {
                ForEach(host.agents, id: \.self) { LSChip(icon: "terminal", text: $0) }
                ForEach(missing, id: \.self) { agent in
                    Link(destination: docsURL) {
                        LSChip(icon: "arrow.down.circle", text: "\(agent) · Install", dimmed: true)
                    }
                    .help("\(agent) isn't installed on this Mac")
                }
                Button { daemon.addAgent() } label: {
                    LSChip(icon: "plus", text: "Add an agent…", dimmed: true)
                }
                .buttonStyle(.plain)
                .help("Pick any agent CLI this Mac has; it's added to ~/.liveshortly/agents.json")
            }
            if !models.isEmpty {
                chips("Local models") {
                    ForEach(allModels ? models : Array(models.prefix(3)), id: \.self) {
                        LSChip(icon: "cpu", text: $0)
                    }
                    if models.count > 3 {
                        Button(allModels ? "Show fewer" : "+\(models.count - 3) more") { allModels.toggle() }
                            .buttonStyle(.plain)
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.accent)
                    }
                }
            }
        }
        .lsCard()
    }

    private var docsURL: URL {
        URL(string: server + "/docs/agents") ?? URL(string: "https://liveshortly.com/docs/agents")!
    }

    private func chips<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            Text(title).font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                      alignment: .leading, spacing: PocketSpacing.s4, content: content)
        }
    }
}

private struct LSChip: View {
    let icon: String
    let text: String
    var dimmed = false

    var body: some View {
        Label(text, systemImage: icon)
            .font(.pocket(.caption))
            .lineLimit(1)
            .foregroundStyle(dimmed ? PocketColor.textTertiary : PocketColor.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(PocketColor.bgSunken))
            .overlay(Capsule().stroke(PocketColor.lineHairline, lineWidth: HUD.hairline))
    }
}

// MARK: - 3. Folders agents can use

/// The daemon's `--dir` allowlist — the only paths the web or phone can reach.
private struct LSFoldersCard: View {
    @Environment(AppModel.self) private var app
    let daemon: LSDaemonController

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack {
                HUDLabel("Folders agents can use")
                Spacer()
                Button("Add folder…") {
                    let wasRunning = daemon.isRunning
                    if daemon.addRepos(), wasRunning { app.toast("Restarted to apply") }
                }
                .buttonStyle(.hud)
            }
            Text("Agents started from the web or your phone can only read and write inside these folders.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if daemon.dirs.isEmpty {
                Text("No folders yet.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            ForEach(daemon.dirs, id: \.self) { dir in
                LSFolderRow(dir: dir, home: daemon.realHome) {
                    let wasRunning = daemon.isRunning
                    daemon.remove(dir)
                    if wasRunning, !daemon.dirs.isEmpty { app.toast("Restarted to apply") }
                }
            }
        }
        .lsCard()
    }
}

private struct LSFolderRow: View {
    let dir: String
    let home: String
    let onRemove: () -> Void
    @State private var hovering = false
    @State private var repos: Int?

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "folder").foregroundStyle(PocketColor.textTertiary)
                .accessibilityHidden(true)
            Text(dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir)
                .font(.pocket(.mono))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(dir)
            if let repos {
                Text(repos == 1 ? "1 repo" : "\(repos) repos")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(PocketColor.textTertiary)
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Remove \(dir)")
                .help("Remove")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: dir) {
            let dir = dir
            repos = await Task.detached { LSDaemonController.repoCount(dir) }.value
        }
    }
}

// MARK: - 4. Sessions on this Mac

private struct LSLocalSessionsCard: View {
    let sessions: [LSSession]
    let canStart: Bool
    let onOpen: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack {
                HUDLabel("Sessions on this Mac")
                Spacer()
                Button("New session…", action: onNew)
                    .buttonStyle(.hudProminent)
                    .disabled(!canStart)
            }
            if sessions.isEmpty { empty }
            ForEach(sessions) { session in
                LSLocalSessionRow(session: session) { onOpen(session.id) }
            }
        }
        .lsCard()
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            Text("No sessions yet. Run this in Terminal or start one here.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
            LSCommandChip(command: "live claude")
        }
    }
}

private struct LSCommandChip: View {
    let command: String

    var body: some View {
        HStack(spacing: PocketSpacing.s8) {
            Text(command).font(.pocket(.mono)).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PocketColor.textTertiary)
            .accessibilityLabel("Copy \(command)")
        }
        .padding(.horizontal, PocketSpacing.s8)
        .padding(.vertical, PocketSpacing.s4)
        .hudPanel(PocketColor.bgSunken)
    }
}

/// One session that ran here; the whole row opens it.
private struct LSLocalSessionRow: View {
    let session: LSSession
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: PocketSpacing.s8) {
                LSSessionMark(session: session, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title.isEmpty ? "Untitled session" : session.title)
                        .font(.pocket(.body)).lineLimit(1)
                    Text(detail)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.isLive {
                    HUDLiveBadge()
                } else {
                    Text("Ended").font(.pocket(.caption)).foregroundStyle(PocketColor.textTertiary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.title.isEmpty ? "Untitled session" : session.title), "
            + "\(session.isLive ? "live" : "ended"), \(detail)")
    }

    private var detail: String {
        let end = session.isLive ? Date() : (session.endedAt ?? Date())
        let length = Duration.seconds(max(60, end.timeIntervalSince(session.createdAt)))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return [session.agent ?? session.framework, session.repoName, length]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - 5. Troubleshooting

private struct LSTroubleshootingCard: View {
    let daemon: LSDaemonController
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(daemon.logText, forType: .string)
                    }
                    Button("Clear") { daemon.clearLog() }
                    Spacer()
                }
                .buttonStyle(.hud)
                .disabled(daemon.logLines.isEmpty)
                logList
            }
            .padding(.top, PocketSpacing.s8)
        } label: {
            HUDLabel("Troubleshooting")
        }
        .lsCard()
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if daemon.logLines.isEmpty {
                    Text("Nothing logged yet.").foregroundStyle(PocketColor.textTertiary)
                }
                ForEach(daemon.logLines.reversed()) { line in
                    LSLogLineView(line: line, resolved: line.id < daemon.lastSuccessID)
                }
            }
            .font(.pocket(.mono))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .padding(PocketSpacing.s8)
        .hudPanel(PocketColor.bgSunken)
    }
}

/// Newest first, timestamped; an error a later success fixed reads dimmed.
private struct LSLogLineView: View {
    let line: LSDaemonController.LogLine
    let resolved: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PocketSpacing.s8) {
            Text(line.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(PocketColor.textTertiary)
            Text(line.text)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(line.isError && resolved ? 0.5 : 1)
    }

    private var tint: Color {
        guard line.isError else { return PocketColor.textSecondary }
        return resolved ? PocketColor.textTertiary : PocketColor.statusBad
    }
}
