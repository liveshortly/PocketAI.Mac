import CryptoKit
import Foundation

/// LSI-20: install and update the `live` CLI from the app, so a Mac with
/// PocketAI never runs a missing or stale `live` (LSH-20 shipped in 2.3.8 and
/// this Mac kept spawning sessions on 2.3.0).
///
/// Install downloads the same release asset `live update` uses — from
/// liveshortly/live-dist, gzip'd, checked against its published SHA-256 —
/// into ~/.local/bin/live. Update runs the installed CLI's own `live update`,
/// which does the same checks and replaces the binary in place.
extension LSDaemonController {
    /// Web-started sessions need at least this: tmux for every harness (LSH-20).
    static let minCLIVersion = "2.3.8"

    private static let releases = "https://github.com/liveshortly/live-dist/releases"

    var cliNeedsUpdate: Bool {
        guard let cliVersion, let cliLatest else { return false }
        return Self.isOlder(cliVersion, than: cliLatest)
    }

    var cliTooOld: Bool {
        guard let cliVersion else { return false }
        return Self.isOlder(cliVersion, than: Self.minCLIVersion)
    }

    func checkCLIUpdate() async {
        guard let url = URL(string: Self.releases + "/latest/download/latest.txt"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return }
        cliLatest = Self.parseVersion(String(decoding: data, as: UTF8.self))
    }

    /// Installs `live` when it is missing, otherwise updates it; a running
    /// daemon restarts onto the new binary (sessions keep running — each
    /// lives in its own process group).
    func installOrUpdateCLI() {
        guard !cliBusy else { return }
        cliBusy = true
        cliError = nil
        Task {
            defer { cliBusy = false }
            do {
                if liveURL == nil {
                    try await installCLI()
                } else {
                    let (code, out) = await run(["update"])
                    if code != 0 {
                        throw CLIError(out.split(separator: "\n").last.map(String.init) ?? "live update failed")
                    }
                }
                if isRunning {
                    // refresh() skips a running daemon; re-read the version here.
                    cliVersion = Self.parseVersion(await run(["version"]).1)
                    restart()
                } else {
                    liveURL = nil // re-locate: a fresh install lands on the search path
                    await refresh()
                }
            } catch {
                cliError = (error as? CLIError)?.message ?? error.localizedDescription
            }
        }
    }

    private func installCLI() async throws {
        await checkCLIUpdate()
        guard let latest = cliLatest else {
            throw CLIError("Couldn't reach GitHub to find the latest live. Check your connection and try again.")
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let tag = "v" + latest
        let asset = "live-\(tag)-darwin-\(arch)"
        let base = "\(Self.releases)/download/\(tag)/\(asset)"

        let (sumData, _) = try await URLSession.shared.data(from: URL(string: base + ".sha256")!)
        let want = String(decoding: sumData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard want.count == 64 else { throw CLIError("The live release has no valid checksum.") }

        let (gz, resp) = try await URLSession.shared.download(from: URL(string: base + ".gz")!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CLIError(String(localized: "live \(latest) isn't published for this Mac (\(arch))."))
        }
        defer { try? FileManager.default.removeItem(at: gz) }

        let binDir = URL(fileURLWithPath: realHome + "/.local/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let staged = binDir.appendingPathComponent(".live-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }

        // gunzip -c into the staged file; argv only, no shell.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        unzip.arguments = ["-c", gz.path]
        FileManager.default.createFile(atPath: staged.path, contents: nil)
        let out = try FileHandle(forWritingTo: staged)
        unzip.standardOutput = out
        try unzip.run()
        unzip.waitUntilExit()
        try out.close()
        guard unzip.terminationStatus == 0 else { throw CLIError("The live download was damaged.") }

        let got = SHA256.hash(data: try Data(contentsOf: staged))
            .map { String(format: "%02x", $0) }.joined()
        guard got == want.lowercased() else {
            throw CLIError("The live download didn't match its checksum, so it wasn't installed.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        let (_, version) = await Self.exec(staged, ["version"], env: nil)
        guard Self.parseVersion(version) == latest else {
            throw CLIError("The downloaded live didn't run, so it wasn't installed.")
        }
        let dest = binDir.appendingPathComponent("live")
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: staged)
    }

    /// "live v2.3.8" / "v2.3.8\n" → "2.3.8".
    nonisolated static func parseVersion(_ text: String) -> String? {
        guard let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    nonisolated static func isOlder(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    private struct CLIError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
