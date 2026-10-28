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
    /// Set once the window's model exists, so App Intents (Shortcuts) can
    /// reach the same core instead of opening a second handle to the store.
    public private(set) static var shared: AppModel?

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
        /// Starting an agent session is a destination like any other, so it
        /// opens in the detail pane instead of a modal over the app.
        /// Carries the project a session is being started for, so the
        /// finished session can be filed under it.
        case newSession(projectId: String? = nil)
        /// The sidebar keeps only the most recent few; these are the full,
        /// searchable lists behind them.
        case allChats
        case allSessions
        case models
        case devices
        case server
        case images
        case privacy
    }

    public var selection: Destination? {
        didSet { persistSelection() }
    }

    public var showCommandPalette = false
    public var sidebarSearch = ""

    // MARK: - Chat state shared with the chrome

    /// Live chat models, keyed by conversation. Held here rather than in the
    /// view so switching away from a generating chat does not orphan its
    /// stream: the reply keeps arriving, Stop still reaches it, and coming
    /// back shows the text that landed while you were gone.
    private var chatModels: [String: ChatModel] = [:]

    /// True while any conversation is streaming — drives the working mark and
    /// enables Stop in the menu.
    public var isGenerating: Bool {
        chatModels.values.contains { $0.isStreaming }
    }
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
        case refresh
        case newChat
        case focusComposer
        case stopGeneration
        case regenerate
        case openConversation(String)
        case newLiveSession
    }
    /// Commands are consumed by the focused view and cleared. Each post also
    /// carries a serial so sending the SAME command twice still registers as a
    /// change — otherwise a latched value made the next ⌘L do nothing.
    public private(set) var pendingCommand: Command?
    public private(set) var commandSerial = 0

    public func post(_ command: Command) {
        pendingCommand = command
        commandSerial += 1
    }

    public func clearCommand() {
        pendingCommand = nil
    }

    /// Incoming pairing request awaiting Allow/Deny, polled app-wide so the
    /// approval sheet can present from any screen.
    public var pendingPairingRequest: PairingRequest?
    private var pairingPollTask: Task<Void, Never>?
    private let advertiser = Advertiser()
    public private(set) var activeServerActivity: NSObjectProtocol?

    private static let onboardedKey = "app.getpocketai.hasOnboarded"
    private static let currentModelKey = "app.getpocketai.currentModelId"
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
        AppModel.shared = self
    }

    // MARK: - Model

    private func refreshCurrentModelDisplayName() {
        let catalog = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        if currentModelId == Self.appleIntelligenceId {
            currentModelDisplayName = "Apple Intelligence"
            return
        }
        let name = catalog.first { $0.manifest.id == currentModelId }?.manifest.displayName
        currentModelDisplayName = ModelNaming.short(name ?? currentModelId)
    }

    /// True when this Mac can run Apple's on-device system model.
    public var appleIntelligenceAvailable: Bool { AppleFoundationModelsEngine.isAvailable }
    public static let appleIntelligenceId = AppleFoundationModelsEngine.modelId

    /// A display name for any model id, including the ones that have no
    /// catalog entry because they need no download.
    public func displayName(forModelId id: String) -> String {
        if id == Self.appleIntelligenceId { return "Apple Intelligence" }
        let catalogName = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false)
        ).first { $0.manifest.id == id }?.manifest.displayName
        // Even a catalog display name carries packaging noise
        // ("Qwen3-4B-Instruct-2507-GGUF"); short() is what belongs on screen.
        return ModelNaming.short(catalogName ?? id)
    }

    /// Installed chat-capable models, for the composer's model picker.
    public func installedChatModels() -> [CatalogEntry] {
        core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
            .filter {
                $0.manifest.modalities.contains(.text) || $0.manifest.modalities.contains(.vision)
            }
    }

    // MARK: - Chat models

    /// The model for a conversation, reused if it is already open.
    func chatModel(for conversationId: String) -> ChatModel {
        if let existing = chatModels[conversationId] { return existing }
        let model = ChatModel(conversationId: conversationId, core: core)
        chatModels[conversationId] = model
        evictIdleModels()
        return model
    }

    /// Stops generation everywhere — what ⌘. and Stop everything mean.
    public func stopAllGeneration() {
        for model in chatModels.values where model.isStreaming { model.stop() }
    }

    public func forgetChatModel(_ conversationId: String) {
        chatModels[conversationId]?.stop()
        chatModels[conversationId] = nil
    }

    /// Keeps a handful of recent conversations warm; anything idle beyond that
    /// is dropped so a long session does not accumulate transcripts in memory.
    private func evictIdleModels() {
        guard chatModels.count > 8 else { return }
        // Dictionary order is arbitrary, so sort by when each conversation was
        // last touched and drop the stalest. Taking a slice of `keys` evicted
        // whichever chats happened to hash first, including recent ones.
        let idle = chatModels
            .filter { !$0.value.isStreaming && $0.key != currentChatId }
            .sorted { lhs, rhs in
                (lhs.value.conversation?.updatedAt ?? 0)
                    < (rhs.value.conversation?.updatedAt ?? 0)
            }
        for (key, _) in idle.dropLast(4) { chatModels[key] = nil }
    }

    private var currentChatId: String? {
        if case .chat(let id) = selection { return id }
        return nil
    }

    // MARK: - Navigation helpers

    /// Creates a conversation and selects it. Returns nil when the core
    /// refuses (a degraded core after an open failure).
    @discardableResult
    public func newChat(projectId: String? = nil, modelId: String? = nil) -> String? {
        let chosen = modelId ?? currentModelId
        let input = NewConversation(title: nil, projectId: projectId, modelId: chosen)
        guard let conversation = try? core.createConversation(input) else { return nil }
        // Picking a model for a new chat makes it the default for the next one.
        if let modelId, modelId != currentModelId { currentModelId = modelId }
        selection = .chat(conversation.id)
        post(.focusComposer)
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
        stopAllGeneration()
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
