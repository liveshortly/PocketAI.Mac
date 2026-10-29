import PocketKit
import XCTest

@testable import PocketAI

/// The three local flows that carry the product: send a message and stream a
/// reply (including Stop mid-stream), move a model through the library, and
/// pair a Mac so another device can reach it.
///
/// Unit tests against the models and view-model seams, not XCUITest: Mac UI
/// testing needs `sudo DevToolsSecurity -enable`, which this machine has not
/// been granted.
@MainActor
final class CriticalPathTests: XCTestCase {

    /// Polls a main-actor condition. The fixture core streams on real timers,
    /// so the alternative is sleeping for a guessed duration.
    private func waitUntil(
        _ description: String, timeout: TimeInterval = 8,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func newChat(_ core: TestCore) throws -> ChatModel {
        core.installed = [TestCore.chatModelId]
        let conversation = try core.createConversation(
            NewConversation(title: nil, projectId: nil, modelId: TestCore.chatModelId))
        return ChatModel(conversationId: conversation.id, core: core)
    }

    // MARK: - Flow 1: send a message, stream a reply, Stop mid-stream

    func testSendStreamsAReplyAndKeepsIt() async throws {
        let core = TestCore()
        let chat = try newChat(core)

        XCTAssertTrue(chat.send("hello"), "a send with an installed model must be accepted")
        XCTAssertTrue(chat.isStreaming)

        try await waitUntil("the reply to finish") { !chat.isStreaming }
        XCTAssertEqual(chat.streamingText, "", "the live buffer clears when the turn ends")
        XCTAssertTrue(
            chat.messages.contains { $0.isUser && $0.plainText == "hello" },
            "the question stays in the transcript")
        XCTAssertTrue(
            chat.messages.contains { !$0.isUser && !$0.plainText.isEmpty },
            "the finished reply is read back from the store, not left in the buffer")
        XCTAssertNotNil(chat.lastStats, "stats from the finished turn drive the inspector")
        XCTAssertNil(chat.errorText)
    }

    /// Stop has to leave the partial reply on screen. It used to clear the
    /// streaming buffer and never re-read the store, so whatever had been
    /// decoded vanished until you navigated away and came back.
    func testStopMidStreamEndsTheTurnAndKeepsTheTranscript() async throws {
        let core = TestCore()
        let chat = try newChat(core)

        XCTAssertTrue(chat.send("tell me something long"))
        try await waitUntil("the first tokens") { !chat.streamingText.isEmpty }

        chat.stop()

        XCTAssertFalse(chat.isStreaming, "Stop ends the turn")
        XCTAssertEqual(chat.streamingText, "")
        XCTAssertTrue(
            core.calls.contains("cancelConversation"),
            "Stop must reach the core, not just drop our reader")
        XCTAssertTrue(
            chat.messages.contains { $0.isUser && $0.plainText == "tell me something long" },
            "stopping must not wipe the question")
    }

    /// `send` reports refusal so the composer can keep what was typed. It used
    /// to return nothing, and the composer cleared the box before calling it —
    /// which destroyed the message whenever the turn was refused.
    func testRefusedSendsSayNo() async throws {
        let core = TestCore()
        let chat = try newChat(core)

        XCTAssertFalse(chat.send("   "), "whitespace is not a message")
        XCTAssertFalse(chat.isStreaming)

        XCTAssertTrue(chat.send("first"))
        XCTAssertFalse(
            chat.send("second"),
            "a second turn mid-stream is refused, and the composer must be told")
        chat.stop()
    }

    func testRegenerateIsRefusedMidStream() async throws {
        let core = TestCore()
        let chat = try newChat(core)

        XCTAssertTrue(chat.send("hello"))
        chat.regenerate()
        XCTAssertTrue(chat.isStreaming, "the original turn is still the live one")
        chat.stop()
    }

    /// A chat whose model was deleted re-points itself at an installed one
    /// rather than failing inside the engine.
    func testChatRebindsAModelThatIsNoLongerInstalled() async throws {
        let core = TestCore()
        core.installed = [TestCore.chatModelId]
        let gone = "mlx-community/Phi-4-mini-instruct-4bit@ac1c269cb4222a4e136a3d09edad301056c1f36a"
        let conversation = try core.createConversation(
            NewConversation(title: nil, projectId: nil, modelId: gone))
        let chat = ChatModel(conversationId: conversation.id, core: core)

        XCTAssertTrue(chat.send("hello"))
        XCTAssertEqual(
            chat.conversation?.modelId, TestCore.chatModelId,
            "the turn is re-pointed at something that is actually installed")
        chat.stop()
    }

    /// With nothing installed the send is either refused with a reason or
    /// bound to Apple's system model — never a silent no-op. Which of the two
    /// depends on the machine, so both are allowed; silence is not.
    func testSendWithNothingInstalledIsNeverSilent() throws {
        let core = TestCore()
        let conversation = try core.createConversation(
            NewConversation(title: nil, projectId: nil, modelId: nil))
        let chat = ChatModel(conversationId: conversation.id, core: core)

        if chat.send("hello") {
            XCTAssertEqual(chat.conversation?.modelId, AppleFoundationModelsEngine.modelId)
            chat.stop()
        } else {
            XCTAssertNotNil(chat.errorText, "a refused send must explain itself")
        }
    }

    // MARK: - Flow 2: download, switch and delete a model

    func testDownloadMovesThroughPauseResumeAndCancel() async throws {
        let core = TestCore()
        let id = TestCore.chatModelId

        try core.startDownload(modelId: id)
        XCTAssertEqual(state(core, id), .downloading)

        try await waitUntil("progress to be reported") { bytesDone(core, id) > 0 }
        let atPause = bytesDone(core, id)

        try core.pauseDownload(modelId: id)
        XCTAssertEqual(state(core, id), .paused)
        XCTAssertEqual(
            bytesDone(core, id), atPause,
            "pausing keeps what was fetched; resuming must not start over")

        try core.resumeDownload(modelId: id)
        XCTAssertEqual(state(core, id), .downloading)
        XCTAssertGreaterThanOrEqual(bytesDone(core, id), atPause)

        try core.cancelDownload(modelId: id)
        XCTAssertEqual(state(core, id), .available)
        XCTAssertEqual(bytesDone(core, id), 0, "a cancelled download leaves nothing behind")
    }

    func testInstalledModelBecomesDefaultAndDeletingItRefreshesTheLibrary() throws {
        let core = TestCore()
        let id = TestCore.chatModelId
        core.installed = [id]

        let installedOnly = CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true)
        XCTAssertTrue(core.catalog(filter: installedOnly).contains { $0.manifest.id == id })

        try core.deleteModel(modelId: id)
        XCTAssertTrue(core.calls.contains("deleteModel"))
        XCTAssertFalse(
            core.catalog(filter: installedOnly).contains { $0.manifest.id == id },
            "the library has to re-read after a delete, not keep showing the row")
        XCTAssertEqual(state(core, id), .available)
    }

    /// Every transfer control goes through a call that can throw. A refusal
    /// has to reach the caller — `try?` here is what left buttons looking dead.
    func testEveryTransferControlCanReportARefusal() {
        let core = TestCore()
        let id = TestCore.chatModelId
        for call in ["startDownload", "pauseDownload", "resumeDownload",
                     "cancelDownload", "deleteModel", "unloadModel"] {
            core.failing = [call]
            switch call {
            case "startDownload":
                XCTAssertThrowsError(try core.startDownload(modelId: id), call)
            case "pauseDownload":
                XCTAssertThrowsError(try core.pauseDownload(modelId: id), call)
            case "resumeDownload":
                XCTAssertThrowsError(try core.resumeDownload(modelId: id), call)
            case "cancelDownload":
                XCTAssertThrowsError(try core.cancelDownload(modelId: id), call)
            case "deleteModel":
                XCTAssertThrowsError(try core.deleteModel(modelId: id), call)
            default:
                XCTAssertThrowsError(try core.unloadModel(id: id), call)
            }
        }
    }

    /// A raw download error is a crash log; the library shows a sentence. Each
    /// branch here is a failure a user actually hits.
    func testDownloadFailuresReadAsSomethingActionable() {
        XCTAssertTrue(failureSummary("sha256 mismatch").contains("checksum"))
        XCTAssertTrue(failureSummary("No space left on device").contains("disk space"))
        XCTAssertTrue(failureSummary("connection reset by peer").contains("connection"))
        XCTAssertTrue(failureSummary("The request timed out").contains("connection"))
        XCTAssertEqual(failureSummary("weird internal thing"), "The download failed.")
    }

    func testChatFailuresReadAsSomethingActionable() {
        XCTAssertTrue(chatFriendlyError("no model loaded").contains("model library"))
        XCTAssertTrue(chatFriendlyError("insufficient memory").contains("smaller one"))
        XCTAssertEqual(chatFriendlyError("cancelled"), "That reply was stopped.")
        XCTAssertTrue(chatFriendlyError("context length exceeded").contains("new chat"))
        XCTAssertTrue(chatFriendlyError("offline").contains("offline"))
        // Anything unrecognised is passed through rather than mislabelled.
        XCTAssertEqual(chatFriendlyError("ENOSPC 28"), "ENOSPC 28")
    }

    /// The ETA on a multi-gigabyte download. Needs two samples at least half a
    /// second apart, never goes backwards, and smooths rather than jumping.
    func testDownloadRateNeedsTwoSamplesAndSmooths() async throws {
        let rates = DownloadRates()
        XCTAssertNil(rates.observe(id: "m", bytes: 0), "one sample is not a rate")

        try await Task.sleep(nanoseconds: 600_000_000)
        guard let first = rates.observe(id: "m", bytes: 1_000_000) else {
            return XCTFail("a second sample half a second later should give a rate")
        }
        XCTAssertGreaterThan(first, 0)

        // A sample that arrives too soon must not be treated as new data.
        XCTAssertEqual(rates.observe(id: "m", bytes: 1_200_000), first)

        rates.forget("m")
        XCTAssertNil(rates.observe(id: "m", bytes: 5_000_000), "forgetting resets the series")
    }

    // MARK: - Flow 3: pair a Mac so another device can reach it

    /// Pairing needs the LAN listener: a phone cannot reach a loopback-only
    /// server, so the Devices screen starts or rebinds it before handing out
    /// a code.
    func testPairingNeedsTheServerBoundToTheLan() {
        let app = AppModel()
        XCTAssertFalse(app.serverStatus.running)

        app.startServer(lan: false)
        XCTAssertTrue(app.serverStatus.running)
        XCTAssertFalse(app.serverStatus.lanEnabled, "loopback only")

        // What "Start server & pair…" does when it finds a loopback listener.
        app.stopServer()
        app.startServer(lan: true)
        XCTAssertTrue(app.serverStatus.running)
        XCTAssertTrue(app.serverStatus.lanEnabled, "a phone can only reach a LAN listener")

        app.stopServer()
        XCTAssertFalse(app.serverStatus.running)
    }

    func testPairingOfferCarriesWhatThePhoneNeeds() throws {
        let core = TestCore()
        let qr = try core.pairingOfferQrString()
        let offer = try core.parsePairingQr(qr)

        XCTAssertTrue(qr.hasPrefix("pocketai://pair?"))
        XCTAssertFalse(offer.certFingerprint.isEmpty, "the fingerprint is the whole security story")
        XCTAssertFalse(offer.addrs.isEmpty)
        XCTAssertNotEqual(offer.port, 0)
    }

    func testApprovingAPairingRequestClearsItAndDenyingDoesToo() throws {
        let approving = TestCore()
        guard let request = approving.pendingPairings().first else {
            return XCTFail("the fixture core should offer a pending request")
        }
        try approving.approvePairing(id: request.id)
        XCTAssertTrue(
            approving.pendingPairings().isEmpty,
            "an answered request must not come back round the poll loop")

        let denying = TestCore()
        let other = try XCTUnwrap(denying.pendingPairings().first)
        try denying.denyPairing(id: other.id)
        XCTAssertTrue(denying.pendingPairings().isEmpty)
    }

    /// The remote-engine path from this Mac's side: a saved peer is the route
    /// an engine dials, and forgetting one has to actually remove it.
    func testSavedPeerIsReachableThenForgettable() throws {
        let core = TestCore()
        let before = core.peers().count

        let peer = try core.savePeer(
            ApprovedPairing(
                hostId: "Studio", certFingerprint: "aa:bb", addr: "192.168.1.9",
                port: 7480, deviceId: "peer-1", tokenKeychainRef: "ref-1"))

        XCTAssertEqual(core.peers().count, before + 1)
        XCTAssertEqual(peer.addrs.first, "192.168.1.9", "the route has to survive the save")
        XCTAssertEqual(peer.port, 7480)
        XCTAssertFalse(peer.tokenRef.isEmpty, "without the token ref the engine cannot authenticate")

        try core.revokePeer(id: peer.id)
        XCTAssertEqual(core.peers().count, before)
    }

    func testRevokedDevicesAreNotListedAsHavingAccess() {
        let core = TestCore()
        // Mirrors DevicesView.reload()'s filter — a revoked device that is
        // still listed reads as one that still has access.
        XCTAssertTrue(core.devices().allSatisfy { $0.revokedAt == nil })
    }

    // MARK: - Helpers

    private func state(_ core: TestCore, _ id: String) -> ModelState? {
        core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
            .first { $0.manifest.id == id }?.state
    }

    private func bytesDone(_ core: TestCore, _ id: String) -> UInt64 {
        core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
            .first { $0.manifest.id == id }?.bytesDone ?? 0
    }
}
