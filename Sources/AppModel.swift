import AppKit
import Foundation
import Observation
import PocketKit
import PocketLiveShortly
import PocketMLX
import PocketUI
import SwiftUI
import UserNotifications

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
    /// The offline switch, owned once. Three screens used to keep their own
    /// copy of `core.isOffline()` and they drifted apart.
    public private(set) var offlineMode: OfflineMode!
    public let hooks: PlatformHooks
    /// LiveShortly integration (opt-in; connected from Settings → LiveShortly).
    public let liveShortly = LSAccountModel()
    /// Window-level transient message, rendered by `RootView` through
    /// PocketUI's `ToastOverlay`. Needed because a failed delete tears down
    /// the view that would otherwise report it.
    var currentToast: ToastData?

    /// Report a failure the calling view may not outlive.
    func toast(_ message: String) { currentToast = ToastData(message: message) }

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
        /// Tools → LiveShortly: daemon, allowed repos, sessions on this Mac (LSI-14).
        case liveShortly
    }

    public var selection: Destination? {
        didSet { persistSelection() }
    }

    /// The window hosting the shell, registered by `RootView`. Settings, the
    /// menu-bar panel, the app menus and App Intents all act from outside that
    /// window, so changing `selection` there moved the shell without moving
    /// keyboard focus to it — the opened surface needed a click first.
    @ObservationIgnored public weak var shellWindow: NSWindow?

    /// Brings the shell forward and gives it keyboard focus. A no-op when it
    /// is already the key window.
    public func focusShell() {
        NSApp.activate(ignoringOtherApps: true)
        shellWindow?.makeKeyAndOrderFront(nil)
    }

    /// Navigates the shell and focuses it. Everything that opens a destination
    /// from outside the shell goes through here, so the surface that just
    /// appeared is the one the keyboard talks to.
    public func reveal(_ destination: Destination) {
        selection = destination
        focusShell()
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
        /// MAC-18: Devices shows a pairing QR (posted by `pairDevice()`).
        case pairDevice
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
    private let notifier = AppNotifier()
    /// Last seen download state per model id, so a finished or failed download
    /// is reported once instead of on every poll (MAC-16).
    @ObservationIgnored private var lastDownloadStates: [String: ModelState] = [:]
    /// Device ids seen on the last poll, and the ones already reported revoked.
    @ObservationIgnored private var lastDeviceIds: Set<String> = []
    @ObservationIgnored private var reportedRevoked: Set<String> = []
    /// False until the first poll has recorded the devices that existed at
    /// launch; nothing is announced before that.
    @ObservationIgnored private var seededDevices = false
    /// Set once the licence warning for the current expiry has been sent, so
    /// the 1s poll does not notify every second for a week.
    @ObservationIgnored private var licenseNoticeSentFor: Int64?
    private let advertiser = Advertiser()
    public private(set) var activeServerActivity: NSObjectProtocol?

    /// MAC-18: who may use this Mac's models. The server is how that
    /// happens, not a step the user runs; picking a level applies it and is
    /// saved, and launch restores it.
    public enum ServerAccess: String, CaseIterable, Sendable {
        case off
        /// Loopback only, for other apps on this Mac.
        case thisMac
        /// LAN + Bonjour, so paired phones can connect.
        case pairedDevices
    }
    public private(set) var serverAccess: ServerAccess = .off
    private static let serverAccessKey = "app.getpocketai.mac.serverAccess"
    private static let serverPortKey = "app.getpocketai.mac.serverPort"

    private static let onboardedKey = "app.getpocketai.hasOnboarded"
    private static let currentModelKey = "app.getpocketai.currentModelId"
    private static let selectionKey = "app.getpocketai.mac.selection"
    private static let licenseKeychainKey = "app.getpocketai.licenseKey"
    private static let defaultModelId =
        "mlx-community/Qwen3-4B-Instruct-2507-4bit@50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"

    public init() {
        let args = ProcessInfo.processInfo.arguments
        // MAC-19: pull a formerly sandboxed install's data out of its
        // container before anything reads defaults or opens the store. Not
        // under XCTest: the test host shares the app's bundle id.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            migrateFromSandboxIfNeeded()
        }
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

        offlineMode = OfflineMode(core: core)

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
        // Licensing is parked (D129): every build is Pro until COM-02 ships.
        // Without this a release build can't serve paired devices — the LAN
        // listener is Pro-gated, so the server silently stayed on 127.0.0.1
        // and no iPhone could reach the Mac (Wi-Fi or Tailscale).
        // Restore the DEBUG / -PocketDemoPro gate when licensing returns.
        core.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "licensing-parked"))

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

        notifier.onTap = { [weak self] route in
            guard let self else { return }
            if let route { self.selection = route }
            self.focusShell()
        }
        notifier.onPairingDecision = { [weak self] pairingId, allow in
            self?.decidePairing(id: pairingId, allow: allow)
        }
        pairingPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.pendingPairingRequest == nil, self.serverStatus.running,
                   let request = self.core.pendingPairings().first {
                    self.pendingPairingRequest = request
                    // The sheet belongs to the shell window, so when Settings
                    // (its own scene) is in front it is presented behind and
                    // never seen — pairing just never completes on the phone.
                    // This arrives unasked, so it gets a notification rather
                    // than stealing focus from whatever is being typed.
                    if self.shellWindow?.isKeyWindow != true {
                        self.notifier.notify(request: request)
                    }
                }
                self.checkDownloadNotifications()
                self.checkDeviceNotifications()
                self.checkLicenseNotification()
            }
        }
        // MAC-18: start at launch with the saved Access (no debug gate), so a
        // paired phone works after a relaunch or reboot with no clicks here.
        // The debug args still force a level for UI tests, unsaved.
        if args.contains("-PocketStartServer") {
            serverAccess = args.contains("-PocketServerLAN") ? .pairedDevices : .thisMac
        } else {
            serverAccess = Self.launchAccess(
                saved: UserDefaults.standard.string(forKey: Self.serverAccessKey)
                    .flatMap(ServerAccess.init(rawValue:)),
                pairedDevices: core.devices().filter { $0.revokedAt == nil }.count)
        }
        applyServerAccess()
        AppModel.shared = self
    }

    // MARK: - Notifications (MAC-16)

    /// A download that finishes or fails while you are in another app said
    /// nothing. Only transitions notify, and only away from `downloading` /
    /// `verifying`, so a model already installed at launch is silent.
    private func checkDownloadNotifications() {
        let entries = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        var next: [String: ModelState] = [:]
        for entry in entries {
            let id = entry.manifest.id
            next[id] = entry.state
            guard let previous = lastDownloadStates[id], previous != entry.state else { continue }
            let wasInFlight = previous == .downloading || previous == .verifying
            guard wasInFlight else { continue }
            let name = ModelNaming.short(entry.manifest.displayName)
            switch entry.state {
            case .installed:
                notifier.notifyDownloadFinished(modelName: name)
            case .failed(let reason):
                notifier.notifyDownloadFailed(modelName: name, reason: reason)
            default:
                break
            }
        }
        lastDownloadStates = next
    }

    /// A phone that finishes pairing, or a device revoked from elsewhere.
    /// The first poll only seeds the baseline, so launching with devices
    /// already paired does not announce all of them.
    private func checkDeviceNotifications() {
        let devices = core.devices()
        let ids = Set(devices.map(\.id))
        defer {
            lastDeviceIds = ids
            seededDevices = true
        }
        // An explicit flag, not "the set is empty": with no devices yet, an
        // empty baseline is also the real state, and testing for emptiness
        // swallowed the notification for the very first phone to pair.
        guard seededDevices else {
            reportedRevoked = Set(devices.filter { $0.revokedAt != nil }.map(\.id))
            return
        }
        for device in devices {
            if device.revokedAt != nil {
                if !reportedRevoked.contains(device.id) {
                    reportedRevoked.insert(device.id)
                    notifier.notifyDeviceRevoked(name: device.name)
                }
                continue
            }
            if !lastDeviceIds.contains(device.id) {
                notifier.notifyDeviceConnected(name: device.name)
            }
        }
    }

    /// Warns once inside the last week of a Pro licence, and once when it has
    /// run out. Keyed on the expiry itself, so renewing re-arms it.
    private func checkLicenseNotification() {
        let ent = core.entitlements()
        guard ent.pro, let expiresAtMs = ent.expiresAtMs else { return }
        guard licenseNoticeSentFor != expiresAtMs else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let msLeft = expiresAtMs - nowMs
        let weekMs: Int64 = 7 * 24 * 60 * 60 * 1000
        guard msLeft <= weekMs else { return }
        licenseNoticeSentFor = expiresAtMs
        if msLeft <= 0 {
            notifier.notifyLicenseExpired()
        } else {
            notifier.notifyLicenseExpiring(days: Int(msLeft / (24 * 60 * 60 * 1000)))
        }
    }

    /// The single Allow/Deny path, shared by the approval sheet and the
    /// notification actions, so a request decided anywhere clears the pending
    /// sheet and withdraws its notification. A request already expired or
    /// decided elsewhere makes the core call throw; the sheet always ignored
    /// that (the request simply no longer exists), so this does too.
    public func decidePairing(id: String, allow: Bool) {
        if allow {
            try? core.approvePairing(id: id)
        } else {
            try? core.denyPairing(id: id)
        }
        if pendingPairingRequest?.id == id { pendingPairingRequest = nil }
        notifier.withdrawPairingNotification(id: id)
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
        // `reveal`, not a bare assignment: ⌘N fires from the app menu, which
        // works while Settings or the menu-bar panel holds focus.
        reveal(.chat(conversation.id))
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

    /// MAC-18 launch decision: an explicit choice wins; never chosen means
    /// "paired devices" when a phone is already paired (so it keeps working
    /// across relaunch), otherwise off.
    nonisolated static func launchAccess(saved: ServerAccess?, pairedDevices: Int) -> ServerAccess {
        saved ?? (pairedDevices > 0 ? .pairedDevices : .off)
    }

    /// Applies and saves an Access level. Rebinding stops then starts the
    /// listener, so callers ask first when a device is connected.
    public func setServerAccess(_ access: ServerAccess) {
        serverAccess = access
        UserDefaults.standard.set(access.rawValue, forKey: Self.serverAccessKey)
        applyServerAccess()
    }

    private func applyServerAccess() {
        guard serverAccess != .off else {
            if serverStatus.running { stopServer() }
            return
        }
        let lan = serverAccess == .pairedDevices
        if serverStatus.running, serverStatus.lanEnabled != lan { stopServer() }
        if !serverStatus.running { startServer(lan: lan) }
    }

    /// "Pair a device…" from anywhere: raise Access to paired devices if
    /// it's lower, then Devices shows the QR - one click.
    public func pairDevice() {
        if serverAccess != .pairedDevices { setServerAccess(.pairedDevices) }
        selection = .devices
        focusShell()
        post(.pairDevice)
    }

    /// A ProcessInfo activity keeps App Nap and sleep away while serving.
    /// Asks for the port the last run bound (MAC-18 stable port); the core
    /// falls back to a free one if it's taken.
    public func startServer(lan: Bool) {
        let savedPort = UInt16(clamping: UserDefaults.standard.integer(forKey: Self.serverPortKey))
        do {
            serverStatus = try core.serverStart(cfg: ServerConfig(lanEnabled: lan, port: savedPort))
        } catch {
            NSLog("PocketAI: server start (lan: %@) failed: %@", lan ? "yes" : "no", "\(error)")
        }
        if serverStatus.running, serverStatus.port != 0 {
            UserDefaults.standard.set(Int(serverStatus.port), forKey: Self.serverPortKey)
        }
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

/// Local notifications for the things that finish or change while you are
/// looking at another window: a phone waiting to pair, a model that finished
/// downloading, a device that joined or was revoked, a licence about to run
/// out (MAC-16). Acting on one brings the shell forward and, where there is
/// somewhere to go, opens it.
///
/// Authorization is asked for at the first notification worth sending, not at
/// launch, so the prompt always arrives with a story behind it. Refusal costs
/// nothing: every one of these is also visible in the app.
@MainActor
final class AppNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Where a tapped notification should take you. nil = just focus the shell.
    var onTap: (@MainActor (AppModel.Destination?) -> Void)?
    /// Allow/Deny pressed on a pairing notification: (pairing id, allow).
    /// The notifier stays dumb — AppModel owns what a decision means.
    var onPairingDecision: (@MainActor (String, Bool) -> Void)?

    /// Read from the nonisolated delegate callback too, so they cannot be
    /// main-actor isolated.
    private nonisolated static let routeKey = "pocket.route"
    private nonisolated static let pairingIdKey = "pocket.pairingId"
    private nonisolated static let pairingCategoryId = "PAIRING_REQUEST"
    private nonisolated static let pairingAllowActionId = "PAIRING_ALLOW"
    private nonisolated static let pairingDenyActionId = "PAIRING_DENY"

    func notify(request: PairingRequest) {
        // Mirrors the approval sheet's caution: Deny first and plain, Allow
        // never the easy press — approving needs the Mac unlocked.
        let deny = UNNotificationAction(
            identifier: Self.pairingDenyActionId, title: "Deny", options: [])
        let allow = UNNotificationAction(
            identifier: Self.pairingAllowActionId, title: "Allow",
            options: [.authenticationRequired])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.pairingCategoryId, actions: [deny, allow],
                intentIdentifiers: [])
        ])
        post(
            title: "Pair this device?",
            body: "\(request.deviceName) wants to use this Mac's models.",
            route: nil,
            // The pairing id as notification identifier, so a decision made
            // anywhere can withdraw exactly this banner.
            identifier: request.id,
            categoryId: Self.pairingCategoryId,
            userInfo: [Self.pairingIdKey: request.id])
    }

    /// Removes a pairing banner once its request is decided, from the sheet
    /// or from the notification itself.
    func withdrawPairingNotification(id: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [id])
    }

    func notifyDownloadFinished(modelName: String) {
        post(title: "Model ready", body: "\(modelName) finished downloading.", route: .models)
    }

    func notifyDownloadFailed(modelName: String, reason: String) {
        post(
            title: "Download failed",
            body: "\(modelName) couldn't finish: \(reason)",
            route: .models)
    }

    func notifyDeviceConnected(name: String) {
        post(title: "Device connected", body: "\(name) is now paired with this Mac.", route: .devices)
    }

    func notifyDeviceRevoked(name: String) {
        post(title: "Device revoked", body: "\(name) can no longer reach this Mac.", route: .devices)
    }

    func notifyLicenseExpiring(days: Int) {
        let when = days <= 0
            ? "today"
            : (days == 1 ? "tomorrow" : "in \(days) days")
        post(title: "Pro licence expiring", body: "Your licence runs out \(when).", route: nil)
    }

    func notifyLicenseExpired() {
        post(
            title: "Pro licence expired",
            body: "Pro features are off until it is renewed.",
            route: nil)
    }

    private func post(
        title: String, body: String, route: AppModel.Destination?,
        identifier: String = UUID().uuidString,
        categoryId: String? = nil,
        userInfo: [String: Any] = [:]
    ) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            // Idempotent after the first call: a denied app gets `false` back
            // without being prompted again.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo
            if let categoryId { content.categoryIdentifier = categoryId }
            if let route, let encoded = try? JSONEncoder().encode(route) {
                content.userInfo[Self.routeKey] = encoded
            }
            try? await center.add(
                UNNotificationRequest(
                    identifier: identifier, content: content, trigger: nil))
        }
    }

    /// PocketAI is normally the active app when this fires — Settings has the
    /// focus — and macOS drops notifications for the active app unless they
    /// are asked for explicitly.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let encoded = userInfo[Self.routeKey] as? Data
        let pairingId = userInfo[Self.pairingIdKey] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case Self.pairingAllowActionId:
                if let pairingId { onPairingDecision?(pairingId, true) }
            case Self.pairingDenyActionId:
                if let pairingId { onPairingDecision?(pairingId, false) }
            default:
                // A plain tap (including on a pairing banner, whose pending
                // request is still showing the approval sheet).
                let route = encoded.flatMap {
                    try? JSONDecoder().decode(AppModel.Destination.self, from: $0)
                }
                onTap?(route)
            }
            completionHandler()
        }
    }
}
