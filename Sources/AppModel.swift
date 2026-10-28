import Foundation
import Observation
import PocketKit
import PocketLiveShortly
import PocketMLX
import SwiftUI

/// Root application state: the Rust core handle, what the sidebar has
/// selected, and the command bus the menus and keyboard shortcuts fire into.
///
/// Per-conversation streaming state lives in `ChatModel`, not here, so a
/// streamed token never invalidates the whole window.
@Observable
@MainActor
public final class AppModel {
    public let core: CoreClient
    public let hooks: PlatformHooks
    /// LiveShortly integration (opt-in; connected from Settings → LiveShortly).
    public let liveShortly = LSAccountModel()

    /// Non-nil when the Rust core failed to open at launch. The app stays
    /// navigable and surfaces this instead of crashing with `fatalError`.
    public private(set) var coreOpenError: String?
    public private(set) var serverStatus = ServerStatus(
        running: false, lanEnabled: false, port: 0, connectedDevices: 0)

    // MARK: - Navigation

    /// What the detail pane is showing. Conversations, projects and
    /// LiveShortly sessions are addressed by id so the sidebar can restore a
    /// selection across launches.
    public enum Destination: Hashable, Codable, Sendable {
        case chat(String)
        case project(String)
        case session(String)
        case models
        case devices
        case server
        case images
        case privacy
    }

    public var selection: Destination? {
        didSet { persistSelection() }
    }

    /// Right inspector visibility, remembered across launches.
    public var showInspector: Bool {
        didSet { UserDefaults.standard.set(showInspector, forKey: Self.inspectorKey) }
    }

    public var showCommandPalette = false
    public var sidebarSearch = ""

    // MARK: - Chat state shared with the chrome

    /// True while any conversation is streaming — drives the toolbar mark and
    /// enables Stop in the menu.
    public var isGenerating = false
    /// Measured decode rate of the live stream. Zero until a real rate is
    /// observed; never seed a fabricated throughput.
    public var activeTokPerSec: Int = 0

    public var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    /// Globally selected default model, persisted and restored on launch.
    public var currentModelId: String = AppModel.defaultModelId {
        didSet {
            UserDefaults.standard.set(currentModelId, forKey: Self.currentModelKey)
            refreshCurrentModelDisplayName()
        }
    }
    /// Cached so a streamed token redraw never re-reads the catalog.
    public private(set) var currentModelDisplayName: String = "Qwen3 4B"

    // MARK: - Command bus

    /// Menu items and keyboard shortcuts post commands here; the focused view
    /// consumes them. Keeps `.commands` free of view-layer plumbing.
    public enum Command: Equatable {
        case newChat
        case focusComposer
        case stopGeneration
        case regenerate
        case openConversation(String)
        case newLiveSession
    }
    public var pendingCommand: Command?

    /// Incoming pairing request awaiting Allow/Deny, polled app-wide so the
    /// approval sheet can present from any screen.
    public var pendingPairingRequest: PairingRequest?
    private var pairingPollTask: Task<Void, Never>?
    private let advertiser = Advertiser()
    public private(set) var activeServerActivity: NSObjectProtocol?

    private static let onboardedKey = "app.getpocketai.hasOnboarded"
    private static let currentModelKey = "app.getpocketai.currentModelId"
    private static let inspectorKey = "app.getpocketai.mac.showInspector"
    private static let selectionKey = "app.getpocketai.mac.selection"
    private static let licenseKeychainKey = "app.getpocketai.licenseKey"
    private static let defaultModelId =
        "mlx-community/Qwen3-4B-Instruct-2507-4bit@50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"

    public init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-PocketResetOnboarding") {
            hasOnboarded = false
        } else if args.contains("-PocketSkipOnboarding") {
            hasOnboarded = true
        } else {
            hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        }
        showInspector = UserDefaults.standard.bool(forKey: Self.inspectorKey)

        let hooks = LivePlatformHooks()
        self.hooks = hooks
        if args.contains("-PocketPreviewCore") {
            core = PreviewCore()
        } else {
            let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .macOs)
            do {
                let live = try LiveCore(config: config, platform: hooks)
                // On-device chat engines (MLX safetensors + Apple Intelligence)
                // so send() can actually run inference.
                live.registerEngine(RoutingEngine())
                core = live
            } catch {
                coreOpenError = """
                    PocketAI's on-device engine couldn't start. Please restart the app; \
                    if it keeps happening, reinstall. (\(error.localizedDescription))
                    """
                core = PreviewCore()
            }
        }

        // Re-activate a saved license so Pro survives a relaunch. Offline or
        // transient failure is non-fatal — it retries next launch.
        if let data = hooks.keychainGet(key: Self.licenseKeychainKey),
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            do {
                _ = try core.activateLicense(key: key)
            } catch {
                NSLog(
                    "PocketAI: saved license re-activation failed (retrying next launch): %@",
                    error.localizedDescription)
            }
        }
        #if DEBUG
        core.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "debug-local"))
        #else
        if args.contains("-PocketDemoPro") {
            core.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "demo"))
        }
        #endif

        serverStatus = core.serverStatus()
        if let saved = UserDefaults.standard.string(forKey: Self.currentModelKey), !saved.isEmpty {
            currentModelId = saved
        } else if let chat = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true)
        ).first(where: {
            $0.manifest.modalities.contains(.text) || $0.manifest.modalities.contains(.vision)
        }) {
            currentModelId = chat.manifest.id
        }
        refreshCurrentModelDisplayName()
        restoreSelection()

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
        if args.contains("-PocketStartServer") {
            startServer(lan: args.contains("-PocketServerLAN"))
        }
    }

    // MARK: - Model

    private func refreshCurrentModelDisplayName() {
        let catalog = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        currentModelDisplayName =
            catalog.first(where: { $0.manifest.id == currentModelId })?.manifest.displayName
            ?? "Qwen3 4B"
    }

    /// Installed chat-capable models, for the composer's model picker.
    public func installedChatModels() -> [CatalogEntry] {
        core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
            .filter {
                $0.manifest.modalities.contains(.text) || $0.manifest.modalities.contains(.vision)
            }
    }

    // MARK: - Navigation helpers

    /// Creates a conversation and selects it. Returns nil when the core
    /// refuses (a degraded core after an open failure).
    @discardableResult
    public func newChat(projectId: String? = nil) -> String? {
        let input = NewConversation(title: nil, projectId: projectId, modelId: currentModelId)
        guard let conversation = try? core.createConversation(input) else { return nil }
        selection = .chat(conversation.id)
        pendingCommand = .focusComposer
        return conversation.id
    }

    private func persistSelection() {
        guard let selection, let data = try? JSONEncoder().encode(selection) else { return }
        UserDefaults.standard.set(data, forKey: Self.selectionKey)
    }

    private func restoreSelection() {
        guard let data = UserDefaults.standard.data(forKey: Self.selectionKey),
              let saved = try? JSONDecoder().decode(Destination.self, from: data)
        else {
            selection = firstAvailableChat()
            return
        }
        // A restored chat may have been deleted in another window or launch.
        if case .chat(let id) = saved, core.conversation(id: id) == nil {
            selection = firstAvailableChat()
        } else {
            selection = saved
        }
    }

    private func firstAvailableChat() -> Destination? {
        let recents = core.conversations(
            query: ConversationQuery(search: nil, archived: false, limit: 1, offset: 0))
        return recents.first.map { .chat($0.id) }
    }

    // MARK: - Server

    public func refreshServerStatus() {
        serverStatus = core.serverStatus()
    }

    /// A ProcessInfo activity keeps App Nap and sleep away while serving.
    public func startServer(lan: Bool) {
        serverStatus = (try? core.serverStart(cfg: ServerConfig(lanEnabled: lan, port: 0)))
            ?? serverStatus
        if serverStatus.running, activeServerActivity == nil {
            activeServerActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Serving models")
        }
        // Bonjour so a paired iPhone can rediscover this Mac after an IP
        // change. `pairingIdentity()` never rotates the single-use pairing
        // secret, unlike `pairingOffer()`.
        if lan, serverStatus.running, serverStatus.port != 0 {
            let identity = core.pairingIdentity()
            advertiser.start(
                hostId: identity.hostId,
                name: identity.hostName,
                fingerprint: identity.certFingerprint,
                port: serverStatus.port)
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
        pendingCommand = .stopGeneration
        isGenerating = false
        if let activity = activeServerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            activeServerActivity = nil
        }
        refreshServerStatus()
    }

    public func saveLicenseKey(_ key: String) {
        _ = hooks.keychainSet(key: Self.licenseKeychainKey, value: Data(key.utf8))
    }
}
