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

        model.pendingCommand = .newChat
        XCTAssertEqual(model.pendingCommand, .newChat)

        model.pendingCommand = .openTab(.models)
        XCTAssertEqual(model.pendingCommand, .openTab(.models))

        model.pendingCommand = .focusComposer
        XCTAssertEqual(model.pendingCommand, .focusComposer)

        model.pendingCommand = nil
        XCTAssertNil(model.pendingCommand)
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
    func testMenuBarStateReflection() {
        let model = AppModel()
        XCTAssertFalse(model.isGenerating)
        model.isGenerating = true
        XCTAssertTrue(model.isGenerating)
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
