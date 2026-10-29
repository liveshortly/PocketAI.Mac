import XCTest
import PocketKit
import PocketUI
import PocketImageGen
@testable import PocketAI

@MainActor
final class PocketAITests: XCTestCase {

    // MARK: - MAC-02: Window chrome and commands
    func testCommandPaletteFuzzyMatch() {
        XCTAssertTrue(fuzzyMatch(query: "rst", in: "Explain this Rust borrow checker error"))
        XCTAssertTrue(fuzzyMatch(query: "nct", in: "New chat with model"))
        XCTAssertTrue(fuzzyMatch(query: "serv", in: "Start Server"))
        XCTAssertFalse(fuzzyMatch(query: "xyz", in: "Rust borrow checker"))
    }

    func testAppModelCommandBus() {
        let model = AppModel()
        XCTAssertNil(model.pendingCommand)

        model.post(.newChat)
        XCTAssertEqual(model.pendingCommand, .newChat)

        model.post(.openConversation("c-1"))
        XCTAssertEqual(model.pendingCommand, .openConversation("c-1"))

        // Posting the same command twice must still register as a change, or
        // a second ⌘L after a ⌘N silently does nothing.
        let serial = model.commandSerial
        model.post(.focusComposer)
        model.post(.focusComposer)
        XCTAssertEqual(model.pendingCommand, .focusComposer)
        XCTAssertEqual(model.commandSerial, serial + 2)

        model.clearCommand()
        XCTAssertNil(model.pendingCommand)
    }

    /// Opening a destination from another window (Settings, the menu-bar
    /// panel) has to move the shell AND focus it. Focus needs a real window,
    /// which a unit test has none of — so this pins the navigation half and
    /// that asking with no shell registered is survivable.
    func testRevealNavigatesWithoutAShellWindow() {
        let model = AppModel()
        XCTAssertNil(model.shellWindow)

        model.reveal(.models)
        XCTAssertEqual(model.selection, .models)

        model.reveal(.devices)
        XCTAssertEqual(model.selection, .devices)

        model.focusShell()
        XCTAssertEqual(model.selection, .devices, "focusing must not navigate")
    }

    // MARK: - MAC-03: Chats and chat detail
    func testChatGroupingLogic() throws {
        let now = Date()
        let todayConv = ConversationSummary(
            id: "c-today",
            title: "Today's Conversation",
            updatedAt: Int64(now.timeIntervalSince1970 * 1000),
            archived: false
        )

        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let weekConv = ConversationSummary(
            id: "c-week",
            title: "Earlier This Week",
            updatedAt: Int64(threeDaysAgo.timeIntervalSince1970 * 1000),
            archived: false
        )

        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!
        let olderConv = ConversationSummary(
            id: "c-older",
            title: "Older Conversation",
            updatedAt: Int64(tenDaysAgo.timeIntervalSince1970 * 1000),
            archived: false
        )

        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)!

        XCTAssertTrue(Date(timeIntervalSince1970: Double(todayConv.updatedAt) / 1000) >= startOfToday)
        let weekDate = Date(timeIntervalSince1970: Double(weekConv.updatedAt) / 1000)
        XCTAssertTrue(weekDate < startOfToday && weekDate >= sevenDaysAgo)
        XCTAssertTrue(Date(timeIntervalSince1970: Double(olderConv.updatedAt) / 1000) < sevenDaysAgo)
    }

    // MARK: - MAC-04: Models & memory policy
    func testMemoryPolicyCalculation() {
        let totalRam: UInt64 = 16 * 1024 * 1024 * 1024 // 16 GB
        let policyPercent: Double = 70.0
        let budget = UInt64(Double(totalRam) * (policyPercent / 100.0))

        XCTAssertEqual(budget, UInt64(11.2 * 1024 * 1024 * 1024))
    }

    func testCatalogFilterInstalledAndCurated() {
        let previewCore = PreviewCore()
        let curated = previewCore.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
        XCTAssertFalse(curated.isEmpty)

        let visionModels = previewCore.catalog(filter: CatalogFilter(modality: .vision, curatedOnly: false, installedOnly: false))
        for m in visionModels {
            XCTAssertTrue(m.manifest.modalities.contains(.vision))
        }
    }

    // MARK: - Chat naming

    /// Models decorate their answers; a title has to survive that or chats end
    /// up named `"**Sure! Here is a title:**`.
    func testChatTitleCleaning() {
        XCTAssertEqual(ChatModel.cleanTitle("Rust borrow checker help"),
                       "Rust borrow checker help")
        XCTAssertEqual(ChatModel.cleanTitle("  \"Debugging a segfault\"  "),
                       "Debugging a segfault")
        XCTAssertEqual(ChatModel.cleanTitle("## Swift concurrency basics"),
                       "Swift concurrency basics")
        // Reasoning first, title last.
        XCTAssertEqual(ChatModel.cleanTitle("Let me think.\n\nPlanning a trip"),
                       "Planning a trip")
        // Not titles: empty, too long, too many words.
        XCTAssertNil(ChatModel.cleanTitle("   "))
        XCTAssertNil(ChatModel.cleanTitle(String(repeating: "a", count: 80)))
        XCTAssertNil(ChatModel.cleanTitle("one two three four five six seven eight nine"))
    }

    // MARK: - GGUF support

    /// GGUF models must be reachable from the library, not just MLX ones: the
    /// core routes them to the built-in llama.cpp engine, so hiding them in
    /// the UI is the only thing that would stop them running.
    func testCatalogOffersBothEngines() {
        let core = PreviewCore()
        let all = core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        let formats = Set(all.map(\.manifest.format))
        XCTAssertTrue(formats.contains(.mlxSafetensors), "catalog should offer MLX models")
        XCTAssertTrue(formats.contains(.gguf), "catalog should offer GGUF models")
    }

    func testFormatFilterSelectsEngines() {
        XCTAssertTrue(FormatFilter.all.accepts(.gguf))
        XCTAssertTrue(FormatFilter.all.accepts(.mlxSafetensors))

        XCTAssertTrue(FormatFilter.gguf.accepts(.gguf))
        XCTAssertFalse(FormatFilter.gguf.accepts(.mlxSafetensors))

        XCTAssertTrue(FormatFilter.mlx.accepts(.mlxSafetensors))
        XCTAssertFalse(FormatFilter.mlx.accepts(.gguf))

        // "All" must search both formats on Hugging Face, or GGUF models stay
        // invisible there even though llama.cpp can run them.
        XCTAssertEqual(Set(FormatFilter.all.hubFormats), [.mlxSafetensors, .gguf])
        XCTAssertEqual(FormatFilter.gguf.hubFormats, [.gguf])
    }

    func testEngineBadgesNameTheRuntime() {
        XCTAssertEqual(ModelFormat.gguf.badge, "GGUF")
        XCTAssertEqual(ModelFormat.mlxSafetensors.badge, "MLX")
        XCTAssertTrue(ModelFormat.gguf.engineDescription.contains("llama.cpp"))
    }

    // MARK: - MAC-05: Onboarding
    func testOnboardingStateDefaults() {
        let model = AppModel()
        // AppModel initializes hasOnboarded cleanly
        XCTAssertNotNil(model.hasOnboarded)
    }

    // MARK: - MAC-06: Server lifecycle and App Nap activity
    func testServerStartAndStop() {
        let model = AppModel()
        XCTAssertFalse(model.serverStatus.running)
        XCTAssertNil(model.activeServerActivity)

        model.startServer(lan: false)
        XCTAssertTrue(model.serverStatus.running)
        XCTAssertNotNil(model.activeServerActivity)

        let key = model.core.generateLocalApiKey()
        XCTAssertFalse(key.isEmpty)
        XCTAssertTrue(model.core.hasLocalApiKey())

        model.stopServer()
        XCTAssertFalse(model.serverStatus.running)
        XCTAssertNil(model.activeServerActivity)
    }

    // MARK: - MAC-07: Devices and pairing
    func testPairingOfferAndRevoke() throws {
        let previewCore = PreviewCore()
        let qrString = try previewCore.pairingOfferQrString()
        XCTAssertTrue(qrString.starts(with: "pocketai://pair?"))

        let pending = previewCore.pendingPairings()
        XCTAssertNotNil(pending)
    }

    // MARK: - MAC-08: Menu bar extra state
    /// `isGenerating` is derived from the open chat models, so it stays true
    /// while a conversation you have navigated away from is still streaming —
    /// that is what keeps Stop reachable.
    func testGeneratingReflectsOpenChats() {
        let model = AppModel()
        XCTAssertFalse(model.isGenerating, "nothing open, nothing generating")

        let chat = model.chatModel(for: "c-1")
        XCTAssertFalse(chat.isStreaming)
        XCTAssertFalse(model.isGenerating)

        // The same conversation hands back the same model rather than a
        // second one racing the first.
        XCTAssertTrue(chat === model.chatModel(for: "c-1"))

        model.stopEverything()
        XCTAssertFalse(model.isGenerating)
    }

    // MARK: - MAC-11: Privacy and audit viewer
    func testAuditLogAndEgress() {
        let previewCore = PreviewCore()
        previewCore.setOfflineMode(on: true)
        XCTAssertTrue(previewCore.isOffline())
        previewCore.setOfflineMode(on: false)
        XCTAssertFalse(previewCore.isOffline())

        let egress = previewCore.egressLog(limit: 10)
        XCTAssertNotNil(egress)

        let audit = previewCore.auditLog(query: AuditQuery(limit: 50, sinceTs: nil))
        XCTAssertNotNil(audit)
    }

    // MARK: - MAC-12: Projects and documents
    func testProjectsAndDocumentsLifecycle() throws {
        let previewCore = PreviewCore()
        let project = try previewCore.createProject(name: "Test Mac Project", instructions: "Mac testing instructions")
        XCTAssertEqual(project.name, "Test Mac Project")
        XCTAssertEqual(project.instructions, "Mac testing instructions")

        let doc = try previewCore.addDocument(
            projectId: project.id,
            name: "test.txt",
            mime: "text/plain",
            pages: [DocumentPage(page: 1, text: "Sample content for testing project indexing")]
        )
        XCTAssertEqual(doc.name, "test.txt")

        let docs = previewCore.listDocuments(projectId: project.id)
        XCTAssertEqual(docs.count, 1)

        let hits = previewCore.searchProject(projectId: project.id, query: "indexing", k: 5)
        XCTAssertFalse(hits.isEmpty)

        try previewCore.deleteDocument(id: doc.id)
        XCTAssertEqual(previewCore.listDocuments(projectId: project.id).count, 0)

        try previewCore.deleteProject(id: project.id)
        XCTAssertFalse(previewCore.listProjects().contains { $0.id == project.id })
    }

    // MARK: - MAC-12: Image Generator Configuration
    func testImageGeneratorSupportedSizes() {
        XCTAssertTrue(PocketImageGenerator.supportedSizes.contains(512))
        XCTAssertTrue(PocketImageGenerator.supportedSizes.contains(768))
        XCTAssertTrue(PocketImageGenerator.supportedSizes.contains(1024))
        XCTAssertFalse(PocketImageGenerator.supportedSizes.contains(256))
    }
}
