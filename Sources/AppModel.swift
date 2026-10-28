import Foundation
import Observation
import PocketKit
import PocketLiveShortly
import PocketMLX

@Observable
@MainActor
public final class AppModel {
    public let core: CoreClient
    public let hooks: PlatformHooks
    /// LiveShortly integration (opt-in; connected from Settings → LiveShortly).
    public let liveShortly = LSAccountModel()
    /// Non-nil when the Rust core failed to open at launch; app degrades
    /// gracefully and surfaces this instead of crashing with `fatalError`.
    public private(set) var coreOpenError: String?
    public private(set) var serverStatus = ServerStatus(running: false, lanEnabled: false, port: 0, connectedDevices: 0)
    public var isGenerating: Bool = false
    public var selectedTab: SidebarItem
    public private(set) var activeServerActivity: NSObjectProtocol?
    /// APL-08: advertises this Mac over Bonjour (`_pocketai._tcp`) while the
    /// LAN server runs, so a paired iPhone can rediscover it after an IP change.
    private let advertiser = Advertiser()

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

    /// Globally selected default model. Persisted; restored on launch with a
    /// fallback to the first installed chat-capable model.
    public var currentModelId: String = AppModel.defaultModelId {
        didSet {
            UserDefaults.standard.set(currentModelId, forKey: Self.currentModelKey)
            refreshCurrentModelDisplayName()
        }
    }
    private static let currentModelKey = "app.getpocketai.currentModelId"
    private static let defaultModelId = "mlx-community/Qwen3-4B-Instruct-2507-4bit@50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
    /// Cached — recomputed only when `currentModelId` changes. The old computed
    /// property ran `core.catalog()` on every read, i.e. on every streamed
    /// token redraw.
    public private(set) var currentModelDisplayName: String = "Qwen3 4B"

    private func refreshCurrentModelDisplayName() {
        let catalog = core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        currentModelDisplayName = catalog.first(where: { $0.manifest.id == currentModelId })?.manifest.displayName ?? "Qwen3 4B"
    }
    public var showChatInspector: Bool = false
    /// Honest instruments: 0 until a real token rate is measured from a live
    /// stream. Never seed a fabricated throughput.
    public var activeTokPerSec: Int = 0

    /// MAC-02: command bus so `.commands`/keyboard shortcuts reach across
    /// the app cleanly.
    public enum Command: Equatable {
        case newChat
        case focusComposer
        case stopGeneration
        case openConversation(String)
        case openTab(SidebarItem)
        case toggleInspector
    }
    public var pendingCommand: Command?

    /// Incoming pairing request awaiting Allow/Deny — polled app-wide (not just
    /// on the Devices tab) so the approval sheet can present from any screen,
    /// including over the QR sheet.
    public var pendingPairingRequest: PairingRequest?
    private var pairingPollTask: Task<Void, Never>?

    private static let licenseKeychainKey = "app.getpocketai.licenseKey"

    public init() {
        selectedTab = Self.initialTabSelection
        if ProcessInfo.processInfo.arguments.contains("-PocketResetOnboarding") {
            hasOnboarded = false
        } else if ProcessInfo.processInfo.arguments.contains("-PocketSkipOnboarding") {
            hasOnboarded = true
        } else {
            hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        }

        if ProcessInfo.processInfo.arguments.contains("-PocketShowInspector") {
            showChatInspector = true
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
                // Graceful degradation instead of a hard crash.
                coreOpenError = "PocketAI's on-device engine couldn't start. Please restart the app; if it keeps happening, reinstall. (\(error.localizedDescription))"
                core = PreviewCore()
            }
        }
        // MAC-14: re-activate a previously saved license key so Pro survives a
        // relaunch. Offline/transient failure is non-fatal — just log it.
        if let data = hooks.keychainGet(key: Self.licenseKeychainKey),
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            do {
                _ = try core.activateLicense(key: key)
            } catch {
                NSLog("PocketAI: saved license re-activation failed (will retry next launch): %@", error.localizedDescription)
            }
        }
        // Local testing: DEBUG builds are always Pro, so pairing + LAN serving
        // (both Pro-gated) work without an activated Keygen license. Release
        // keeps the real licensing path (-PocketDemoPro still overrides).
        #if DEBUG
        core.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "debug-local"))
        #else
        if ProcessInfo.processInfo.arguments.contains("-PocketDemoPro") {
            core.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "demo"))
        }
        #endif
        serverStatus = core.serverStatus()
        // Restore the persisted model choice; fall back to the first installed
        // chat-capable model, else keep the curated default.
        if let saved = UserDefaults.standard.string(forKey: Self.currentModelKey), !saved.isEmpty {
            currentModelId = saved
        } else {
            let installed = core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
            if let chat = installed.first(where: {
                $0.manifest.modalities.contains(.text) || $0.manifest.modalities.contains(.vision)
            }) {
                currentModelId = chat.manifest.id
            }
        }
        refreshCurrentModelDisplayName()
        // Poll for incoming pairing requests on every tab, not just Devices.
        pairingPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.pendingPairingRequest == nil, self.serverStatus.running,
                   let request = self.core.pendingPairings().first {
                    self.pendingPairingRequest = request
                }
            }
        }
        // Demo/testing: auto-start the LAN server so a paired iPhone can reach
        // this Mac without a manual toggle.
        if ProcessInfo.processInfo.arguments.contains("-PocketStartServer") {
            // Loopback (127.0.0.1) needs no Local Network permission; LAN does.
            let lan = ProcessInfo.processInfo.arguments.contains("-PocketServerLAN")
            startServer(lan: lan)
        }
    }

    /// Persists an activated license key so `init` can re-activate on relaunch.
    public func saveLicenseKey(_ key: String) {
        _ = hooks.keychainSet(key: Self.licenseKeychainKey, value: Data(key.utf8))
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
        // Advertise over Bonjour on LAN so a paired iPhone can rediscover this
        // Mac after an IP change. Identity comes from the read-only
        // `pairingIdentity()` getter — unlike `pairingOffer()` it never rotates
        // the single-use pairing secret (which would invalidate a shown QR)
        // and isn't Pro-gated.
        if lan, serverStatus.running, serverStatus.port != 0 {
            let identity = core.pairingIdentity()
            advertiser.start(
                hostId: identity.hostId,
                name: identity.hostName,
                fingerprint: identity.certFingerprint,
                port: serverStatus.port
            )
        }
    }

    public func stopServer() {
        try? core.serverStop()
        advertiser.stop()
        if let activity = activeServerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            activeServerActivity = nil
        }
        refreshServerStatus()
    }

    public func stopEverything() {
        core.stopEverything()
        advertiser.stop()
        // Let the active chat view cancel its stream task too.
        pendingCommand = .stopGeneration
        isGenerating = false
        if let activity = activeServerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            activeServerActivity = nil
        }
        refreshServerStatus()
    }
}
