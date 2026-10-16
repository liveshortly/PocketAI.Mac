import Foundation
import Observation
import PocketKit
import PocketMLX

@Observable
@MainActor
public final class AppModel {
    public let core: CoreClient
    public let hooks: PlatformHooks
    public private(set) var serverStatus = ServerStatus(running: false, lanEnabled: false, port: 0, connectedDevices: 0)
    public var isGenerating: Bool = false
    public var selectedTab: SidebarItem
    public private(set) var activeServerActivity: NSObjectProtocol?

    public enum SidebarItem: String, Identifiable, CaseIterable, Sendable {
        case chats = "Chats"
        case projects = "Projects"
        case models = "Models"
        case server = "Server"
        case devices = "Devices"
        case privacy = "Privacy"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .chats: return "bubble.left.and.bubble.right"
            case .projects: return "folder"
            case .models: return "cpu"
            case .server: return "server.rack"
            case .devices: return "iphone"
            case .privacy: return "hand.raised"
            }
        }
    }

    private static var initialTabSelection: SidebarItem {
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-PocketInitialTab"),
           ProcessInfo.processInfo.arguments.count > index + 1 {
            return SidebarItem(rawValue: ProcessInfo.processInfo.arguments[index + 1]) ?? .chats
        }
        return .chats
    }

    /// MAC-05: onboarding gate, same `UserDefaults` pattern as the iPhone app.
    public var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }
    private static let onboardedKey = "app.getpocketai.hasOnboarded"

    /// MAC-02: command bus so `.commands`/keyboard shortcuts reach across
    /// the app cleanly.
    public enum Command: Equatable {
        case newChat
        case focusComposer
        case stopGeneration
        case openConversation(String)
        case openTab(SidebarItem)
    }
    public var pendingCommand: Command?

    public init() {
        selectedTab = Self.initialTabSelection
        if ProcessInfo.processInfo.arguments.contains("-PocketResetOnboarding") {
            hasOnboarded = false
        } else if ProcessInfo.processInfo.arguments.contains("-PocketSkipOnboarding") {
            hasOnboarded = true
        } else {
            hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        }

        let hooks = LivePlatformHooks()
        self.hooks = hooks
        if ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore") {
            core = PreviewCore()
        } else {
            let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .macOs)
            do {
                let live = try LiveCore(config: config, platform: hooks)
                // Register the on-device chat engines (MLX .safetensors +
                // Apple Intelligence) so send() can actually run inference.
                live.registerEngine(RoutingEngine())
                core = live
            } catch {
                fatalError("PocketCore.open failed: \(error)")
            }
        }
        serverStatus = core.serverStatus()
    }

    public func refreshServerStatus() {
        serverStatus = core.serverStatus()
    }

    /// MAC-06: ProcessInfo activity prevents App Nap/sleep during model serving.
    public func startServer(lan: Bool) {
        serverStatus = (try? core.serverStart(cfg: ServerConfig(lanEnabled: lan, port: 0))) ?? serverStatus
        if serverStatus.running && activeServerActivity == nil {
            activeServerActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Serving models"
            )
        }
    }

    public func stopServer() {
        try? core.serverStop()
        if let activity = activeServerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            activeServerActivity = nil
        }
        refreshServerStatus()
    }

    public func stopEverything() {
        core.stopEverything()
        isGenerating = false
        if let activity = activeServerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            activeServerActivity = nil
        }
        refreshServerStatus()
    }
}
