import Foundation
import Observation
import PocketKit

@Observable
@MainActor
public final class AppModel {
    public let core: CoreClient
    public private(set) var serverStatus = ServerStatus(running: false, lanEnabled: false, port: 0, connectedDevices: 0)

    /// MAC-02: a tiny command bus so `.commands`/keyboard shortcuts at the
    /// `App` scene level can reach into whatever's showing in the
    /// `NavigationSplitView` detail pane without each view needing its own
    /// notification wiring. Views observe this via `onChange` and reset it
    /// to `nil` once handled, so the same shortcut can fire again.
    public enum Command: Equatable {
        case newChat
        case focusComposer
        case stopGeneration
        case openConversation(String)
    }
    public var pendingCommand: Command?

    public init() {
        if ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore") {
            core = PreviewCore()
        } else {
            let hooks = LivePlatformHooks()
            let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .macOs)
            do {
                core = try LiveCore(config: config, platform: hooks)
            } catch {
                fatalError("PocketCore.open failed: \(error)")
            }
        }
        serverStatus = core.serverStatus()
    }

    public func refreshServerStatus() {
        serverStatus = core.serverStatus()
    }

    public func startServer(lan: Bool) {
        serverStatus = (try? core.serverStart(cfg: ServerConfig(lanEnabled: lan, port: 0))) ?? serverStatus
    }

    public func stopServer() {
        try? core.serverStop()
        refreshServerStatus()
    }

    public func stopEverything() {
        core.stopEverything()
        refreshServerStatus()
    }
}
