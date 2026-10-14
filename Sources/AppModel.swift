import Foundation
import Observation
import PocketKit

@Observable
@MainActor
public final class AppModel {
    public let core: CoreClient
    public private(set) var serverStatus = ServerStatus(running: false, lanEnabled: false, port: 0, connectedDevices: 0)

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
