import SwiftUI
import AppKit
import PocketKit
import PocketMLX
import Speech
import SQLite3

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-PocketAudioSelfTest") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AudioSelfTestRunner.shared.runIfNeeded()
            }
        } else if args.contains("-PocketSpeechSelfTest") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                SpeechSelfTestRunner.shared.runIfNeeded()
            }
        } else if args.contains("-PocketNetSelfTest") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NetSelfTestRunner.shared.runIfNeeded()
            }
        } else if args.contains("-PocketRemoteGenSelfTest") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                RemoteGenSelfTestRunner.shared.runIfNeeded()
            }
        } else if args.contains("-PocketSendSelfTest") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                SendSelfTestRunner.shared.runIfNeeded()
            }
        }
    }
}

@main
struct PocketAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environment(model)
                .task {
                    AudioSelfTestRunner.shared.runIfNeeded()
                    SpeechSelfTestRunner.shared.runIfNeeded()
                    NetSelfTestRunner.shared.runIfNeeded(core: model.core)
                    RemoteGenSelfTestRunner.shared.runIfNeeded(core: model.core)
                    SendSelfTestRunner.shared.runIfNeeded(core: model.core)
                }
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    model.selectedTab = .chats
                    model.pendingCommand = .newChat
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Project") {
                    model.selectedTab = .projects
                    model.pendingCommand = .openTab(.projects)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Generate Image") {
                    openWindow(id: "image-generation")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { openWindow(id: "command-palette") }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Focus Composer") { model.pendingCommand = .focusComposer }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Toggle Inspector") {
                    model.showChatInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Stop Generation") { model.pendingCommand = .stopGeneration }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Stop Everything") { model.stopEverything() }
                    .keyboardShortcut(".", modifiers: [.command, .option])
            }
        }

        MenuBarExtra(
            "PocketAI",
            systemImage: model.isGenerating
                ? "bolt.horizontal.circle.fill"
                : (model.serverStatus.running ? "bolt.horizontal.fill" : "bolt.horizontal")
        ) {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Command Palette", id: "command-palette") {
            CommandPaletteView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Image Generation", id: "image-generation") {
            MacImageGenView()
                .environment(model)
        }
        // Resizable: a full feature window, not a fixed palette — users expand it.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 620)
        .defaultPosition(.center)
    }
}

private final class AudioSelfTestRunner: @unchecked Sendable {
    static let shared = AudioSelfTestRunner()
    private let lock = NSLock()
    private var hasRun = false

    func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-PocketAudioSelfTest"),
              args.indices.contains(index + 1) else {
            return
        }
        lock.lock()
        if hasRun {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        let outPath = args[index + 1]
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try? FileManager.default.removeItem(atPath: outPath)
                let parentDir = URL(fileURLWithPath: outPath).deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                try PocketKit.AppleTextToSpeechEngine().synthesize(
                    text: "Pocket AI speaks on device.",
                    voice: "en-US",
                    outPath: outPath
                )
                let size = ((try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
                FileHandle.standardError.write(Data("AUDIO_SELFTEST_BYTES=\(size)\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("AUDIO_SELFTEST_ERROR=\(error)\n".utf8))
                exit(1)
            }
        }
    }
}

private final class SpeechSelfTestRunner: @unchecked Sendable {
    static let shared = SpeechSelfTestRunner()
    private let lock = NSLock()
    private var hasRun = false

    func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-PocketSpeechSelfTest"),
              args.indices.contains(index + 1) else {
            return
        }
        lock.lock()
        if hasRun {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        let outPath = args[index + 1]

        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            SFSpeechRecognizer.requestAuthorization { _ in }
            let statusStr: String
            switch status {
            case .notDetermined: statusStr = "undetermined"
            case .denied: statusStr = "denied"
            case .restricted: statusStr = "restricted"
            default: statusStr = "\(status)"
            }
            FileHandle.standardError.write(Data("STT_SELFTEST_AUTH=\(statusStr)\n".utf8))
            exit(2)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try? FileManager.default.removeItem(atPath: outPath)
                let parentDir = URL(fileURLWithPath: outPath).deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                try PocketKit.AppleTextToSpeechEngine().synthesize(
                    text: "the quick brown fox jumps over the lazy dog",
                    voice: "en-US",
                    outPath: outPath
                )

                    final class STTTokenSink: TokenSink, @unchecked Sendable {
                        private let lock = NSLock()
                        var text = ""
                        var error: PocketError?

                        func onDelta(delta: GenerateDelta) {
                            lock.lock()
                            text += delta.text
                            lock.unlock()
                        }

                        func onDone(stats: GenerateStats) {}

                        func onError(err: PocketError) {
                            lock.lock()
                            error = err
                            lock.unlock()
                        }
                    }

                    let sink = STTTokenSink()
                    let stt = PocketKit.AppleSpeechToTextEngine()
                    try stt.transcribe(audioPath: outPath, lang: "en-US", sink: sink)

                    if let err = sink.error {
                        FileHandle.standardError.write(Data("STT_SELFTEST_ERROR=\(err)\n".utf8))
                        exit(1)
                    }

                    let recognised = sink.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    FileHandle.standardError.write(Data("STT_SELFTEST_TEXT=\(recognised)\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("STT_SELFTEST_ERROR=\(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }

private final class NetSelfTestRunner: @unchecked Sendable {
    static let shared = NetSelfTestRunner()
    private let lock = NSLock()
    private var hasRun = false

    func runIfNeeded(core: CoreClient? = nil) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-PocketNetSelfTest") else {
            return
        }
        lock.lock()
        if hasRun {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                // Watchdog to enforce ~40s overall bound
                Task {
                    try? await Task.sleep(nanoseconds: 40_000_000_000)
                    FileHandle.standardError.write(Data("NET_SELFTEST_ERROR=timed out after 40s\n".utf8))
                    exit(1)
                }

                do {
                    let liveCore: LiveCore
                    if let c = core as? LiveCore {
                        liveCore = c
                    } else {
                        let hooks = LivePlatformHooks()
                        let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .macOs)
                        liveCore = try LiveCore(config: config, platform: hooks)
                        liveCore.registerEngine(RoutingEngine())
                    }

                    // Enable Pro entitlement for pairing and LAN server features
                    liveCore.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "net_selftest"))

                    // (a) Advertiser.start(...) + Browser.start() and wait <= 10s for peer (APL-08)
                    let testHostId = "pocket-selftest-\(ProcessInfo.processInfo.processIdentifier)"
                    let advertiser = Advertiser()
                    let browser = await MainActor.run { Browser() }

                    advertiser.start(hostId: testHostId, name: "Pocket SelfTest", fingerprint: "fp-selftest", port: 52000)
                    await MainActor.run { browser.start() }

                    var discovered = false
                    let discoStart = Date()
                    while Date().timeIntervalSince(discoStart) <= 10.0 {
                        let found = await MainActor.run {
                            browser.peers.contains { $0.hostId == testHostId }
                        }
                        if found {
                            discovered = true
                            break
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    advertiser.stop()
                    await MainActor.run { browser.stop() }

                    if discovered {
                        FileHandle.standardError.write(Data("NET_DISCOVER=ok\n".utf8))
                    } else {
                        FileHandle.standardError.write(Data("NET_DISCOVER=timeout\n".utf8))
                    }

                    // (b) Server start + PeerClient measureRTT() (APL-09)
                    let serverStatus = try liveCore.serverStart(cfg: ServerConfig(lanEnabled: true, port: 0))
                    guard serverStatus.running && serverStatus.port > 0 else {
                        throw PocketError.Internal(message: "Server failed to start or port is 0")
                    }
                    let offer = try liveCore.pairingOffer()
                    let endpoint = PeerEndpoint(host: "127.0.0.1", port: serverStatus.port, fingerprint: offer.certFingerprint)
                    let client = PeerClient(endpoint: endpoint, token: offer.secret)
                    let rtt = await client.measureRTT()
                    if let rtt {
                        FileHandle.standardError.write(Data("NET_RTT=\(String(format: "%.4f", rtt))\n".utf8))
                    } else {
                        FileHandle.standardError.write(Data("NET_RTT=nil\n".utf8))
                    }

                    // (c) Pairing handshake via PairingCoordinator (NET-10 / APL-10)
                    var qr = try liveCore.pairingOfferQrString()
                    if !qr.contains("127.0.0.1") {
                        if let hRange = qr.range(of: "&h=") {
                            qr.insert(contentsOf: "127.0.0.1,", at: hRange.upperBound)
                        }
                    }

                    let hooks = LivePlatformHooks()
                    let coordinator = await MainActor.run {
                        PairingCoordinator(core: liveCore.rawCore, keychain: hooks)
                    }

                    let pairTask = Task {
                        await coordinator.pair(qr: qr, devicePlatform: "ios")
                    }

                    let approveDeadline = Date().addingTimeInterval(15.0)
                    var approved = false
                    while Date() < approveDeadline {
                        let phase = await MainActor.run { coordinator.phase }
                        if case .waitingForApproval(let pairingId) = phase {
                            try liveCore.approvePairing(id: pairingId)
                            approved = true
                            break
                        } else if let pending = liveCore.pendingPairings().first {
                            try liveCore.approvePairing(id: pending.id)
                            approved = true
                            break
                        } else if case .failed = phase {
                            break
                        } else if case .denied = phase {
                            break
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }

                    _ = await pairTask.value

                    let count = liveCore.devices().count
                    FileHandle.standardError.write(Data("NET_PAIRED=\(count)\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("NET_SELFTEST_ERROR=\(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }
}

private final class RemoteGenSelfTestRunner: @unchecked Sendable {
    static let shared = RemoteGenSelfTestRunner()
    private let lock = NSLock()
    private var hasRun = false

    func runIfNeeded(core: CoreClient? = nil) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-PocketRemoteGenSelfTest") else {
            return
        }
        lock.lock()
        if hasRun {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                // Watchdog to enforce ~90s overall bound
                Task {
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    FileHandle.standardError.write(Data("REMOTE_GEN_ERROR=timed out after 90s\n".utf8))
                    exit(1)
                }

                do {
                    let liveCore: LiveCore
                    if let c = core as? LiveCore {
                        liveCore = c
                    } else {
                        let hooks = LivePlatformHooks()
                        let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .macOs)
                        liveCore = try LiveCore(config: config, platform: hooks)
                        liveCore.registerEngine(RoutingEngine())
                    }

                    // Enable Pro entitlement for pairing and LAN server features
                    liveCore.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "remote_gen_selftest"))

                    // Ensure staged model is registered in sqlite models table
                    let hooks = LivePlatformHooks()
                    let dbPath = (hooks.appSupportDir() as NSString).appendingPathComponent("pocket.sqlite")
                    var db: OpaquePointer?
                    if sqlite3_open(dbPath, &db) == SQLITE_OK, let db {
                        let sql = """
                        INSERT OR IGNORE INTO models (id, repo, revision, format, parameter_size, quantization, context_length, input_modalities, state, installed_at)
                        VALUES ('mlx-community/Qwen2.5-0.5B-Instruct-4bit@main', 'mlx-community/Qwen2.5-0.5B-Instruct-4bit', 'main', 'mlx_safetensors', '0.5B', '4bit', 32768, 'text', 'installed', 0);
                        """
                        sqlite3_exec(db, sql, nil, nil, nil)
                        sqlite3_close(db)
                    }

                    // 2. serverStart(ServerConfig(lanEnabled:false, port:0))
                    let serverStatus = try liveCore.serverStart(cfg: ServerConfig(lanEnabled: false, port: 0))
                    guard serverStatus.running && serverStatus.port > 0 else {
                        throw PocketError.Internal(message: "Server failed to start or port is 0")
                    }

                    // 3. Build PeerClient
                    let offer = try liveCore.pairingOffer()
                    let endpoint = PeerEndpoint(host: "127.0.0.1", port: serverStatus.port, fingerprint: offer.certFingerprint)
                    let client = PeerClient(endpoint: endpoint, token: offer.secret)
                    _ = await client.measureRTT()

                    // 4. RemoteEngine generate
                    let engine = RemoteEngine(client: client)
                    let req = GenerateRequest(
                        requestId: UUID().uuidString,
                        messages: [ChatMessage(role: "user", parts: [.text(text: "Reply with: PocketAI remote works.")])],
                        tools: [],
                        params: SamplingParams(
                            temperature: 0.0,
                            topP: 1.0,
                            topK: 0,
                            minP: 0.0,
                            maxTokens: 24,
                            stop: [],
                            seed: 42,
                            repetitionPenalty: 0.0
                        ),
                        reasoning: .off
                    )

                    final class RemoteCollectorSink: TokenSink, @unchecked Sendable {
                        private let lock = NSLock()
                        var text = ""
                        var completed = false
                        var stats: GenerateStats?
                        var error: PocketError?

                        func onDelta(delta: GenerateDelta) {
                            lock.lock()
                            text += delta.text
                            lock.unlock()
                        }

                        func onDone(stats: GenerateStats) {
                            lock.lock()
                            completed = true
                            self.stats = stats
                            lock.unlock()
                        }

                        func onError(err: PocketError) {
                            lock.lock()
                            error = err
                            lock.unlock()
                        }
                    }

                    let sink = RemoteCollectorSink()
                    let stats = try engine.generate(
                        handle: "mlx-community/Qwen2.5-0.5B-Instruct-4bit@main",
                        req: req,
                        sink: sink
                    )

                    if let err = sink.error {
                        FileHandle.standardError.write(Data("REMOTE_GEN_ERROR=\(err)\n".utf8))
                        exit(1)
                    }

                    let tokens = stats.completionTokens
                    let text = sink.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    FileHandle.standardError.write(Data("REMOTE_GEN_TOKENS=\(tokens)\n".utf8))
                    FileHandle.standardError.write(Data("REMOTE_GEN_TEXT=\(text)\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("REMOTE_GEN_ERROR=\(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }
}

extension LiveCore {
    func send(conversationId: String, input: UserInput, sink: ChatSink) throws -> Message {
        try rawCore.send(conversationId: conversationId, input: input, sink: sink)
    }
}

private final class SendSelfTestSink: ChatSink, @unchecked Sendable {
    private let lock = NSLock()
    var text = ""
    var completed = false
    var error: PocketError?
    var savedMessage: Message?

    func onDelta(delta: GenerateDelta) {
        lock.lock()
        text += delta.text
        lock.unlock()
    }

    func onDone(stats: GenerateStats) {
        lock.lock()
        completed = true
        lock.unlock()
    }

    func onError(err: PocketError) {
        lock.lock()
        error = err
        lock.unlock()
    }

    func onMessageSaved(message: Message) {
        lock.lock()
        savedMessage = message
        lock.unlock()
    }

    func accumulatedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

private final class SendSelfTestRunner: @unchecked Sendable {
    static let shared = SendSelfTestRunner()
    private let lock = NSLock()
    private var hasRun = false

    func runIfNeeded(core: CoreClient? = nil) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-PocketSendSelfTest") else {
            return
        }
        lock.lock()
        if hasRun {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                // Watchdog to enforce ~120s overall bound
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    FileHandle.standardError.write(Data("SEND_ERROR=timed out after 120s\n".utf8))
                    exit(1)
                }

                do {
                    let hooks = LivePlatformHooks()
                    let defaultAppSupport = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                        .appendingPathComponent("com.getpocketai.app").path) ?? hooks.appSupportDir()
                    let appSupportDir = defaultAppSupport

                    // Ensure Models directory exists and symlink if needed
                    let modelsDir = URL(fileURLWithPath: appSupportDir).appendingPathComponent("Models")
                    try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
                    if hooks.appSupportDir() != appSupportDir {
                        let hooksModels = URL(fileURLWithPath: hooks.appSupportDir()).appendingPathComponent("Models")
                        if FileManager.default.fileExists(atPath: modelsDir.path) && !FileManager.default.fileExists(atPath: hooksModels.path) {
                            try? FileManager.default.createSymbolicLink(at: hooksModels, withDestinationURL: modelsDir)
                        }
                    }

                    // Ensure staged model is registered in sqlite models table
                    let dbPath = (appSupportDir as NSString).appendingPathComponent("pocket.sqlite")
                    var db: OpaquePointer?
                    if sqlite3_open(dbPath, &db) == SQLITE_OK, let db {
                        let manifestJson = """
                        {"id":"mlx-community/Qwen2.5-0.5B-Instruct-4bit@main","display_name":"Qwen2.5 0.5B","family":"qwen2","params_b":0.5,"quant":"4bit","format":"mlx","modalities":["text"],"context_length":2048,"files":[],"license":{"spdx":"apache-2.0","commercial_ok":true,"url":""},"hf_repo":"mlx-community/Qwen2.5-0.5B-Instruct-4bit","hf_revision":"main","min_ram_bytes":0,"est_runtime_bytes":600000000,"tags":[],"curated":true}
                        """.replacingOccurrences(of: "'", with: "''")
                        let sql = """
                        INSERT OR REPLACE INTO models (id, manifest_json, state, bytes_done, installed_at, pinned_engine)
                        VALUES ('mlx-community/Qwen2.5-0.5B-Instruct-4bit@main', '\(manifestJson)', 'installed', 278064920, 0, 'mlx');
                        """
                        sqlite3_exec(db, sql, nil, nil, nil)
                        let legacySql = """
                        INSERT OR IGNORE INTO models (id, repo, revision, format, parameter_size, quantization, context_length, input_modalities, state, installed_at)
                        VALUES ('mlx-community/Qwen2.5-0.5B-Instruct-4bit@main', 'mlx-community/Qwen2.5-0.5B-Instruct-4bit', 'main', 'mlx_safetensors', '0.5B', '4bit', 32768, 'text', 'installed', 0);
                        """
                        sqlite3_exec(db, legacySql, nil, nil, nil)
                        sqlite3_close(db)
                    }

                    // 1. Build a LiveCore that can see the staged model, register RoutingEngine(), set Pro entitlement
                    let liveCore: LiveCore
                    if let c = core as? LiveCore {
                        liveCore = c
                    } else {
                        let config = CoreConfig(appSupportDir: appSupportDir, platform: .macOs)
                        liveCore = try LiveCore(config: config, platform: hooks)
                        liveCore.registerEngine(RoutingEngine())
                    }
                    liveCore.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "send_selftest"))

                    // 2. Create a conversation; select the staged Qwen as the model
                    let modelId = "mlx-community/Qwen2.5-0.5B-Instruct-4bit@main"
                    let conversation = try liveCore.createConversation(
                        NewConversation(
                            title: "ENG-08 Multi-Turn Test",
                            projectId: nil,
                            modelId: modelId
                        )
                    )

                    // 3. TURN 1: send(conversationId:, input: <user text "My name is Rohit. Remember it.">, sink:)
                    let sink1 = SendSelfTestSink()
                    let input1 = UserInput(parts: [.text(text: "My name is Rohit. Remember it.")])
                    let msg1 = try liveCore.send(conversationId: conversation.id, input: input1, sink: sink1)
                    if let err = sink1.error {
                        throw err
                    }
                    var turn1Text = sink1.accumulatedText().trimmingCharacters(in: .whitespacesAndNewlines)
                    if turn1Text.isEmpty {
                        turn1Text = msg1.parts.compactMap { part -> String? in
                            if case .text(let t) = part { return t }
                            return nil
                        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    // 4. TURN 2: send(conversationId:, input: <user text "What is my name? Answer with just the name.">, sink:)
                    let sink2 = SendSelfTestSink()
                    let input2 = UserInput(parts: [.text(text: "What is my name? Answer with just the name.")])
                    let msg2 = try liveCore.send(conversationId: conversation.id, input: input2, sink: sink2)
                    if let err = sink2.error {
                        throw err
                    }
                    var turn2Text = sink2.accumulatedText().trimmingCharacters(in: .whitespacesAndNewlines)
                    if turn2Text.isEmpty {
                        turn2Text = msg2.parts.compactMap { part -> String? in
                            if case .text(let t) = part { return t }
                            return nil
                        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    // 5. Print SEND_TURN1=<assistant text>, SEND_TURN2=<assistant text> then exit(0); on error SEND_ERROR=<err> + exit(1)
                    let cleanTurn1 = turn1Text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                    let cleanTurn2 = turn2Text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")

                    FileHandle.standardError.write(Data("SEND_TURN1=\(cleanTurn1)\n".utf8))
                    FileHandle.standardError.write(Data("SEND_TURN2=\(cleanTurn2)\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("SEND_ERROR=\(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }
}



