import AppKit
import Foundation
import Observation
import PocketLiveShortly

/// Supervises `live daemon` on this Mac (LSI-14): finds the CLI, checks the
/// sign-in, starts/stops the daemon as a child process, and owns the allowed
/// repos list (the daemon's `--dir` flags).
///
/// Every command runs through `Process` with an argv array — no shell ever
/// sees a user path. The allowlist is the only way a path becomes reachable,
/// which keeps the CONTRACT.md security model: the server/web can only pick
/// from directories this Mac registered.
///
/// ponytail: daemon is a child of the app (owner call (a) default) and dies on
/// quit; switch to an SMAppService LaunchAgent if it must outlive the app.
@MainActor
@Observable
final class LSDaemonController {
    static let shared = LSDaemonController()

    enum Status: Equatable {
        case checking
        /// Child processes inherit the App Sandbox, so `live` can't reach
        /// ~/.liveshortly, tmux or the agents. Needs a non-sandboxed build.
        case sandboxed
        case notInstalled
        case signedOut
        case stopped
        case running(pid: Int32, since: Date)
    }

    private(set) var status: Status = .checking
    /// One timestamped line of `live` output (LSI-16 Troubleshooting).
    struct LogLine: Identifiable {
        let id: Int
        let date: Date
        let text: String
        let isError: Bool
    }

    /// `live whoami` first line, e.g. "Rohit (rohit@example.com)".
    private(set) var account: String?
    private(set) var logLines: [LogLine] = []
    /// Newest line that means "working" (ready / started). Errors older than
    /// it were resolved, so the UI dims them instead of leading with them.
    private(set) var lastSuccessID = -1
    /// The running daemon can't do its job (register/stream failing, or it
    /// exited on its own) — plain words for the header. Cleared by the next
    /// "ready".
    private(set) var trouble: String?
    /// Full ids of sessions seen running in this Mac's tmux socket, so a
    /// session stays listed here (as Ended) after its pane is gone.
    private(set) var localIDs: Set<String> = []
    private(set) var signingIn = false
    /// The API origin `live` uses (host.json > env > liveshortly.com), LSI-15.
    private(set) var server = LSServer.production
    /// Why sign-in failed or can't start, in plain words; the raw line stays
    /// in `log`.
    private(set) var problem: LSLoginProblem?
    /// The reachability check failed: Sign in stays disabled until Retry.
    private(set) var serverDown = false
    /// The `live` CLI this app drives (LSI-20): installed version, newest
    /// published one, and an install/update in flight or failed.
    var cliVersion: String?
    var cliLatest: String?
    var cliBusy = false
    var cliError: String?
    /// `tmux` is on the daemon's PATH; web-started sessions need it.
    private(set) var hasTmux = true

    var dirs: [String] {
        didSet { UserDefaults.standard.set(dirs, forKey: Self.dirsKey) }
    }
    var machineName: String {
        didSet { UserDefaults.standard.set(machineName, forKey: Self.nameKey) }
    }

    /// The macOS account the daemon runs as, and its real home (inside the
    /// sandbox `NSHomeDirectory()` is the container, not the user's home).
    let userName = NSUserName()
    let realHome: String = {
        guard let pw = getpwuid(getuid()) else { return NSHomeDirectory() }
        return String(cString: pw.pointee.pw_dir)
    }()

    /// The id `live daemon` registers under (~/.liveshortly/host_id), so the
    /// app can find this Mac in `/api/hosts`.
    var hostID: String? {
        let path = realHome + "/.liveshortly/host_id"
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private static let dirsKey = "liveShortly.daemon.dirs"
    private static let nameKey = "liveShortly.daemon.name"
    var liveURL: URL?
    private var searchPath = ""
    private var process: Process?
    private var restartOnExit = false
    private var stopping = false
    private var nextLineID = 0
    /// A chunk from the pipe can end mid-line; the tail waits here.
    private var partialLine = ""
    /// `live host set|reset` exists (live PR #38). Older CLIs would treat `host`
    /// as an agent to run, so they get host.json written directly instead.
    private var hasHostCommand = false

    private init() {
        dirs = UserDefaults.standard.stringArray(forKey: Self.dirsKey) ?? []
        machineName = UserDefaults.standard.string(forKey: Self.nameKey)
            ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // A child outlives its parent unless told otherwise.
            MainActor.assumeIsolated { LSDaemonController.shared.process?.terminate() }
        }
    }

    // MARK: - Status

    func refresh() async {
        if process != nil { return } // running: nothing to re-derive
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            status = .sandboxed
            return
        }
        if liveURL == nil { await locateLive() }
        if cliLatest == nil { Task { await checkCLIUpdate() } }
        guard liveURL != nil else {
            status = .notInstalled
            return
        }
        cliVersion = Self.parseVersion(await run(["version"]).1)
        server = LSServer.resolve(home: realHome, env: ProcessInfo.processInfo.environment)
        let (code, out) = await run(["whoami"])
        account = out.split(separator: "\n").first.map(String.init)
        status = code == 0 ? .stopped : .signedOut
        if status == .signedOut {
            await preflight()
        } else {
            problem = nil
            serverDown = false
        }
    }

    /// GET <server>/health before offering Sign in. Any HTTP answer below 500
    /// counts as reachable (a self-hosted server may not serve /health).
    private func preflight() async {
        guard let url = URL(string: server + "/health") else { return }
        var kind: LSLoginProblem.Kind?
        do {
            let (_, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
            if ((resp as? HTTPURLResponse)?.statusCode ?? 0) >= 500 { kind = .serverTrouble }
        } catch let error as URLError {
            switch error.code {
            case .appTransportSecurityRequiresSecureConnection, .cancelled: kind = nil // can't tell; let `live` try
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: kind = .serverTrouble
            default: kind = .unreachable
            }
        } catch {
            kind = .unreachable
        }
        serverDown = kind != nil
        problem = kind.map { LSLoginProblem(kind: $0, server: server) }
    }

    /// GUI apps get a bare PATH; `live daemon` needs tmux and the agents on
    /// it. Take the login shell's PATH (no user input involved) plus the usual
    /// install dirs, then find `live` on it.
    private func locateLive() async {
        let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let (_, loginPath) = await Self.exec(
            URL(fileURLWithPath: shell), ["-lc", "printf %s \"$PATH\""], env: nil)
        let extra = [realHome + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let parts = loginPath.split(separator: ":").map(String.init) + extra
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let unique = parts.filter { !$0.isEmpty && seen.insert($0).inserted }
        searchPath = unique.joined(separator: ":")
        liveURL = unique.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("live") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        hasHostCommand = await run(["help"]).1.contains("live host set")
        hasTmux = unique.contains { FileManager.default.isExecutableFile(atPath: $0 + "/tmux") }
    }

    // MARK: - Actions

    func signIn() {
        guard !signingIn else { return }
        signingIn = true
        Task {
            // `live login` opens the browser itself and polls until approved.
            problem = nil
            let (_, out) = await run(["login"])
            append(out)
            signingIn = false
            await refresh()
            if status == .signedOut, problem == nil {
                problem = LSLoginProblem(loginOutput: out, server: server)
            }
        }
    }

    /// Retry from the error banner: re-check the server, then sign in again
    /// if it answers.
    func retry() {
        Task {
            problem = nil
            await refresh()
            if status == .signedOut, !serverDown { signIn() }
        }
    }

    /// Points `live` at `url` (nil = liveshortly.com) via `live host set|reset`
    /// and restarts a running daemon so it reconnects there.
    func useServer(_ url: String?) {
        Task {
            if hasHostCommand {
                let (_, out) = await run(url.map { ["host", "set", $0] } ?? ["host", "reset"])
                append(out)
            } else {
                writeHostFile(url)
            }
            problem = nil
            if isRunning { restart() }
            await refresh()
        }
    }

    /// Fallback for CLIs without `live host`: same file, same format.
    private func writeHostFile(_ url: String?) {
        let path = realHome + "/.liveshortly/host.json"
        do {
            if let url {
                let data = try JSONSerialization.data(withJSONObject: ["api_url": url, "web_url": url])
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } else if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            append("● server: \(url ?? LSServer.production) (wrote host.json)\n")
        } catch {
            append("● could not update host.json: \(error.localizedDescription)\n")
        }
    }

    func start() {
        guard process == nil, let liveURL, !dirs.isEmpty else { return }
        trouble = nil
        stopping = false
        var args = ["daemon", "--name", machineName]
        for dir in dirs { args += ["--dir", dir] }
        let p = Process()
        p.executableURL = liveURL
        p.arguments = args
        p.environment = childEnv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Empty = EOF; without clearing, the handler spins on it forever.
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in LSDaemonController.shared.append(text) }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in LSDaemonController.shared.didExit(code: code) }
        }
        do {
            try p.run()
            process = p
            status = .running(pid: p.processIdentifier, since: Date())
            append("● started: live \(args.joined(separator: " "))\n")
        } catch {
            append("● could not start live daemon: \(error.localizedDescription)\n")
        }
    }

    func stop() {
        restartOnExit = false
        stopping = true
        process?.terminate()
    }

    /// Saves the name shown in the web/phone picker. It is a launch flag, so
    /// a running daemon restarts. Returns true when that happened.
    @discardableResult
    func rename(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != machineName else { return false }
        machineName = name
        guard isRunning else { return false }
        restart()
        return true
    }

    /// `live logout`, after stopping the daemon that uses those credentials.
    func signOut() {
        stop()
        Task {
            let (_, out) = await run(["logout"])
            append(out)
            account = nil
            await refresh()
        }
    }

    func clearLog() {
        logLines = []
        lastSuccessID = -1
    }

    /// The log as plain text, oldest first, for Copy.
    var logText: String {
        logLines.map { "\($0.date.formatted(date: .omitted, time: .standard))  \($0.text)" }
            .joined(separator: "\n")
    }

    /// Remembers live sessions whose pane runs here (see `localIDs`).
    func noteLocal(_ sessions: [LSSession]) async {
        let prefixes = await localSessionPrefixes()
        for s in sessions where s.isLive && prefixes.contains(String(s.id.prefix(8))) {
            localIDs.insert(s.id)
        }
    }

    /// The allowlist is a launch flag, so changing it means a restart.
    func restart() {
        guard process != nil else { return start() }
        restartOnExit = true
        process?.terminate()
    }

    /// Directory picker (multiple) starting at the user's real home; each pick
    /// joins the allowlist and a running daemon restarts to pick it up.
    @discardableResult
    func addRepos() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: realHome)
        panel.prompt = "Allow"
        guard panel.runModal() == .OK else { return false }
        let picked = panel.urls.map { $0.standardizedFileURL.path }.filter { !dirs.contains($0) }
        guard !picked.isEmpty else { return false }
        dirs += picked
        if isRunning { restart() }
        return true
    }

    /// File picker for any agent CLI discovery misses (LSH-18): appends
    /// `{name, command}` to ~/.liveshortly/agents.json (a plain array; same
    /// name replaces) and restarts a running daemon so it advertises it.
    @discardableResult
    func addAgent() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: realHome + "/.local/bin")
        panel.prompt = "Add Agent"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let name = url.lastPathComponent
        let builtins: Set = ["claude", "codex", "gemini", "agy", "antigravity", "ollama"]
        guard name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil,
              !builtins.contains(name) else {
            append("● can't add \(name): needs a plain name (letters, digits, - _) that isn't a built-in agent\n")
            return false
        }
        let path = realHome + "/.liveshortly/agents.json"
        var entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [[String: Any]] ?? []
        entries.removeAll { $0["name"] as? String == name }
        entries.append(["name": name, "command": url.standardizedFileURL.path])
        do {
            try FileManager.default.createDirectory(atPath: realHome + "/.liveshortly", withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            append("● could not update agents.json: \(error.localizedDescription)\n")
            return false
        }
        append("● added agent \(name) (wrote agents.json)\n")
        if isRunning { restart() }
        return true
    }

    /// Git repos a folder offers: itself, or its direct children.
    /// ponytail: one level deep; nested monorepo layouts undercount.
    nonisolated static func repoCount(_ dir: String) -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/.git") { return 1 }
        let kids = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return kids.filter { fm.fileExists(atPath: dir + "/" + $0 + "/.git") }.count
    }

    func remove(_ dir: String) {
        dirs.removeAll { $0 == dir }
        if isRunning { dirs.isEmpty ? stop() : restart() }
    }

    /// Session id prefixes (8 chars) of agents running in this Mac's
    /// LiveShortly tmux socket — `live claude` and daemon-spawned alike name
    /// their pane `live-<id[:8]>` on socket `liveshortly`.
    func localSessionPrefixes() async -> Set<String> {
        guard status != .sandboxed, let tmux = searchPath.split(separator: ":")
            .lazy.map({ URL(fileURLWithPath: String($0)).appendingPathComponent("tmux") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return [] }
        let (_, out) = await Self.exec(
            tmux, ["-L", "liveshortly", "list-sessions", "-F", "#{session_name}"], env: childEnv)
        return Set(out.split(separator: "\n").compactMap { line in
            line.hasPrefix("live-") ? String(line.dropFirst(5)) : nil
        })
    }

    // MARK: - Plumbing

    var childEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["HOME"] = realHome
        env.removeValue(forKey: "TMUX")
        return env
    }

    private func didExit(code: Int32) {
        process = nil
        status = .stopped
        append("● daemon exited (\(code))\n")
        if !stopping, !restartOnExit, code != 0 {
            trouble = "LiveShortly stopped unexpectedly. Turn it back on, or see Troubleshooting."
        }
        stopping = false
        if restartOnExit {
            restartOnExit = false
            start()
        }
    }

    private func append(_ text: String) {
        // The daemon colours its lines for a terminal; drop the escapes.
        let clean = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        var parts = (partialLine + clean).components(separatedBy: "\n")
        partialLine = parts.removeLast()
        for raw in parts {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            add(line)
        }
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func add(_ line: String) {
        let lower = line.lowercased()
        let isError = lower.range(
            of: #"\b(fail(ed)?|error|refused|could not|cannot|can't)\b"#,
            options: .regularExpression) != nil
        nextLineID += 1
        logLines.append(LogLine(id: nextLineID, date: Date(), text: line, isError: isError))
        if lower.contains("daemon ready") || lower.hasPrefix("● live started") {
            lastSuccessID = nextLineID
            trouble = nil
        } else if lower.contains("register failed") || lower.contains("stream ended") {
            trouble = LSLoginProblem(kind: .unreachable, server: server).message
        }
    }

    func run(_ args: [String]) async -> (Int32, String) {
        guard let liveURL else { return (-1, "") }
        return await Self.exec(liveURL, args, env: childEnv)
    }

    nonisolated static func exec(
        _ url: URL, _ args: [String], env: [String: String]?
    ) async -> (Int32, String) {
        await Task.detached {
            let p = Process()
            p.executableURL = url
            p.arguments = args
            if let env { p.environment = env }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
