import Foundation
import PocketKit

/// `PreviewCore` with the two things a test has to control: which models read
/// as installed, and which core calls fail. Everything else forwards, so the
/// fixtures stay the single source of truth for shapes and streaming.
///
/// PreviewCore is `final`, so this is composition rather than a subclass; the
/// forwarding block is dull on purpose.
final class TestCore: CoreClient, @unchecked Sendable {
    private let base = PreviewCore()

    /// Model ids that should report `.installed` from `catalog()`. PreviewCore
    /// only reaches that state after a 20-second fixture download, which is
    /// not a thing to wait for in a unit test.
    var installed: Set<String> = []
    /// Calls that should throw instead of succeeding, keyed by name:
    /// "startDownload", "pauseDownload", "resumeDownload", "cancelDownload",
    /// "deleteModel", "unloadModel".
    var failing: Set<String> = []
    /// Every mutating transfer call made, in order — lets a test prove a
    /// control actually reached the core rather than looking like it did.
    private(set) var calls: [String] = []
    /// UI-141: delay the send stream so the user row is persisted late.
    var persistLate = false

    struct Refused: LocalizedError {
        let what: String
        var errorDescription: String? { "the core refused \(what)" }
    }

    private func record(_ name: String) throws {
        calls.append(name)
        if failing.contains(name) { throw Refused(what: name) }
    }

    /// A chat-capable fixture id, for tests that need one installed.
    static let chatModelId =
        "mlx-community/Qwen3-1.7B-4bit@3b1b1768f8f8cf8351c712464f906e86c2b8269e"

    // MARK: - The two overridden behaviours

    func catalog(filter: CatalogFilter) -> [CatalogEntry] {
        // Ask without the installed filter, apply our own installed set, then
        // re-apply the filter — otherwise the fixture drops everything first.
        let unfiltered = base.catalog(
            filter: CatalogFilter(
                modality: filter.modality, curatedOnly: filter.curatedOnly,
                installedOnly: false))
        return unfiltered.compactMap { entry in
            var entry = entry
            if installed.contains(entry.manifest.id) {
                entry.state = .installed
                entry.bytesDone = entry.manifest.estRuntimeBytes
            }
            if filter.installedOnly, entry.state != .installed { return nil }
            return entry
        }
    }

    func startDownload(modelId: String) throws {
        try record("startDownload")
        try base.startDownload(modelId: modelId)
    }

    func pauseDownload(modelId: String) throws {
        try record("pauseDownload")
        try base.pauseDownload(modelId: modelId)
    }

    func resumeDownload(modelId: String) throws {
        try record("resumeDownload")
        try base.resumeDownload(modelId: modelId)
    }

    func cancelDownload(modelId: String) throws {
        try record("cancelDownload")
        try base.cancelDownload(modelId: modelId)
    }

    func deleteModel(modelId: String) throws {
        try record("deleteModel")
        installed.remove(modelId)
        try base.deleteModel(modelId: modelId)
    }

    func unloadModel(id: String) throws {
        try record("unloadModel")
        try base.unloadModel(id: id)
    }

    // MARK: - Forwarding

    func mockGenerate(seed: Int64, tokensPerSec: Float) -> AsyncThrowingStream<String, Error> {
        base.mockGenerate(seed: seed, tokensPerSec: tokensPerSec)
    }
    func searchHub(query: String, format: ModelFormat) throws -> [CatalogEntry] {
        try base.searchHub(query: query, format: format)
    }
    func onMemoryWarning() { base.onMemoryWarning() }
    func benchmarkModel(id: String) throws -> Benchmark { try base.benchmarkModel(id: id) }
    func storedBenchmark(id: String) -> Benchmark? { base.storedBenchmark(id: id) }
    func conversations(query: ConversationQuery) -> [ConversationSummary] {
        base.conversations(query: query)
    }
    func conversation(id: String) -> Conversation? { base.conversation(id: id) }
    func createConversation(_ input: NewConversation) throws -> Conversation {
        try base.createConversation(input)
    }
    func messages(conversationId: String) -> [Message] {
        base.messages(conversationId: conversationId)
    }
    func deleteConversation(id: String) throws { try base.deleteConversation(id: id) }
    func archiveConversation(id: String, archived: Bool) throws {
        try base.archiveConversation(id: id, archived: archived)
    }
    func renameConversation(id: String, title: String) throws {
        try base.renameConversation(id: id, title: title)
    }
    func setConversationModel(id: String, modelId: String) throws {
        try base.setConversationModel(id: id, modelId: modelId)
    }
    func sendMessage(
        conversationId: String, input: UserInput, reasoning: ReasoningMode
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        guard persistLate else {
            return base.sendMessage(conversationId: conversationId, input: input, reasoning: reasoning)
        }
        // Like LiveCore: nothing is persisted until the stream is running.
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    for try await event in base.sendMessage(
                        conversationId: conversationId, input: input, reasoning: reasoning
                    ) { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func cancelConversation(id: String) {
        calls.append("cancelConversation")
        base.cancelConversation(id: id)
    }
    func regenerate(conversationId: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        base.regenerate(conversationId: conversationId)
    }
    func registerEngine(_ engine: Engine) { base.registerEngine(engine) }
    func devices() -> [PairedDevice] { base.devices() }
    func revokeDevice(id: String) throws { try base.revokeDevice(id: id) }
    func pairingOffer() throws -> PairingOffer { try base.pairingOffer() }
    func pairingManualCode() throws -> ManualPairingCode { try base.pairingManualCode() }
    func requestFreeLicense(email: String) throws -> String { try base.requestFreeLicense(email: email) }
    func pairingIdentity() -> PairingIdentity { base.pairingIdentity() }
    func parsePairingQr(_ qr: String) throws -> PairingOffer { try base.parsePairingQr(qr) }
    func savePeer(_ approved: ApprovedPairing) throws -> Peer { try base.savePeer(approved) }
    func peers() -> [Peer] { base.peers() }
    func revokePeer(id: String) throws { try base.revokePeer(id: id) }
    func pairingOfferQrString() throws -> String { try base.pairingOfferQrString() }
    func pendingPairings() -> [PairingRequest] { base.pendingPairings() }
    func approvePairing(id: String) throws { try base.approvePairing(id: id) }
    func denyPairing(id: String) throws { try base.denyPairing(id: id) }
    func entitlements() -> Entitlements { base.entitlements() }
    func activateLicense(key: String) throws -> Entitlements { try base.activateLicense(key: key) }
    func setStoreEntitlement(_ e: StoreEntitlement) { base.setStoreEntitlement(e) }
    func serverStart(cfg: ServerConfig) throws -> ServerStatus { try base.serverStart(cfg: cfg) }
    func serverStop() throws { try base.serverStop() }
    func serverStatus() -> ServerStatus { base.serverStatus() }
    func generateLocalApiKey() -> String { base.generateLocalApiKey() }
    func hasLocalApiKey() -> Bool { base.hasLocalApiKey() }
    func hostCertPem() -> String { base.hostCertPem() }
    func stopEverything() { base.stopEverything() }
    func isOffline() -> Bool { base.isOffline() }
    func setOfflineMode(on: Bool) { base.setOfflineMode(on: on) }
    func egressLog(limit: UInt32) -> [EgressEntry] { base.egressLog(limit: limit) }
    func auditLog(query: AuditQuery) -> [AuditEntry] { base.auditLog(query: query) }
    func createProject(name: String, instructions: String?) throws -> Project {
        try base.createProject(name: name, instructions: instructions)
    }
    func listProjects() -> [Project] { base.listProjects() }
    func renameProject(id: String, name: String) throws {
        try base.renameProject(id: id, name: name)
    }
    func setProjectInstructions(id: String, instructions: String?) throws {
        try base.setProjectInstructions(id: id, instructions: instructions)
    }
    func deleteProject(id: String) throws { try base.deleteProject(id: id) }
    func addDocument(
        projectId: String, name: String, mime: String, pages: [DocumentPage]
    ) throws -> Document {
        try base.addDocument(projectId: projectId, name: name, mime: mime, pages: pages)
    }
    func listDocuments(projectId: String) -> [Document] { base.listDocuments(projectId: projectId) }
    func deleteDocument(id: String) throws { try base.deleteDocument(id: id) }
    func searchProject(projectId: String, query: String, k: UInt32) -> [ChunkHit] {
        base.searchProject(projectId: projectId, query: query, k: k)
    }
}
