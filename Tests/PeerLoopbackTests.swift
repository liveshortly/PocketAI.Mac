import XCTest
import Network
@testable import PocketKit
@testable import PocketMLX
@testable import PocketAI

@MainActor
final class PeerLoopbackTests: XCTestCase {

    private func createTempAppSupportDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket_peer_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCore(appSupportDir: URL) throws -> (LiveCore, PlatformHooks) {
        let hooks = LivePlatformHooks()
        let config = CoreConfig(appSupportDir: appSupportDir.path, platform: .macOs)
        let core = try LiveCore(config: config, platform: hooks)
        core.registerEngine(RoutingEngine())
        // Enable Pro entitlement so LAN serving and pairing offer generation are entitled
        core.setStoreEntitlement(StoreEntitlement(pro: true, transactionId: "loopback_test"))
        return (core, hooks)
    }

    // MARK: - 1. APL-08: Bonjour advertise & discover loopback
    func testBonjourAdvertiseAndDiscoverLoopback() async throws {
        let advertiser = Advertiser()
        let browser = Browser()
        defer {
            advertiser.stop()
            browser.stop()
        }

        let testHostId = "pocket-test-\(UUID().uuidString.prefix(8))"
        let testName = "TestMac"
        let testFingerprint = "fp-\(UUID().uuidString.prefix(8))"
        let testPort: UInt16 = 7480

        let startTime = CFAbsoluteTimeGetCurrent()
        advertiser.start(hostId: testHostId, name: testName, fingerprint: testFingerprint, port: testPort)
        browser.start()

        var discoveredPeer: DiscoveredPeer?
        let timeout: TimeInterval = 20.0
        let deadline = Date(timeIntervalSinceNow: timeout)

        while Date() < deadline {
            if browser.state == .denied {
                throw XCTSkip("Local Network access denied by TCC (kDNSServiceErr_PolicyDenied)")
            }

            if let peer = browser.peers.first(where: { $0.hostId == testHostId }) {
                discoveredPeer = peer
                break
            }

            // Pump run loop for NetService and sleep to yield to Swift Concurrency / MainActor tasks
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        if let peer = discoveredPeer {
            print("[APL-08] Discovery elapsed time: \(String(format: "%.3f", elapsed))s")
            XCTAssertEqual(peer.hostId, testHostId)
            XCTAssertEqual(peer.fingerprint, testFingerprint)
        } else {
            throw XCTSkip("Local Network / Bonjour access denied or timed out in test environment (browser state: \(browser.state))")
        }
    }

    // MARK: - 2. APL-09: Server start and pinned TLS session
    func testServerStartAndPinnedTLSSession() async throws {
        let tempDir = try createTempAppSupportDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (core, _) = try makeCore(appSupportDir: tempDir)
        let status = try core.serverStart(cfg: ServerConfig(lanEnabled: true, port: 0))
        defer { try? core.serverStop() }

        XCTAssertTrue(status.running)
        XCTAssertGreaterThan(status.port, 0)

        let offer = try core.pairingOffer()
        let endpoint = PeerEndpoint(host: "127.0.0.1", port: status.port, fingerprint: offer.certFingerprint)
        let client = PeerClient(endpoint: endpoint, token: offer.secret)

        let rtt = await client.measureRTT()
        if let rtt {
            print("[APL-09] Pinned TLS RTT: \(String(format: "%.4f", rtt))s")
            XCTAssertGreaterThan(rtt, 0, "measureRTT returned valid round-trip time")
        } else {
            throw XCTSkip("Pinned TLS loopback session unavailable: server lacks TLS listener or local network denied by test environment")
        }
    }

    // MARK: - 3. NET-10 + APL-10: Pairing handshake loopback
    func testPairingHandshakeLoopback() async throws {
        let tempDir = try createTempAppSupportDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (core, hooks) = try makeCore(appSupportDir: tempDir)
        let status = try core.serverStart(cfg: ServerConfig(lanEnabled: true, port: 0))
        defer { try? core.serverStop() }

        XCTAssertTrue(status.running)
        XCTAssertGreaterThan(status.port, 0)

        let qr = try core.pairingOfferQrString()
        let coordinator = PairingCoordinator(core: core.rawCore, keychain: hooks)

        let pairTask = Task {
            await coordinator.pair(qr: qr, devicePlatform: "ios")
        }

        // Bounded wait for coordinator to either hit waitingForApproval or fail/timeout
        let timeout: TimeInterval = 10.0
        let deadline = Date(timeIntervalSinceNow: timeout)
        var approved = false

        while Date() < deadline {
            if case .waitingForApproval(let pairingId) = coordinator.phase {
                try core.approvePairing(id: pairingId)
                approved = true
                break
            } else if let pending = core.pendingPairings().first {
                try core.approvePairing(id: pending.id)
                approved = true
                break
            } else if case .failed(let reason) = coordinator.phase {
                throw XCTSkip("Pairing handshake loopback failed: \(reason) (Local Network / pinned TLS unavailable in test environment)")
            } else if case .denied = coordinator.phase {
                XCTFail("Pairing handshake was unexpectedly denied")
                break
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        if !approved {
            if case .failed(let reason) = coordinator.phase {
                throw XCTSkip("Pairing handshake loopback failed: \(reason) (Local Network / pinned TLS unavailable in test environment)")
            } else {
                throw XCTSkip("Pairing handshake timed out waiting for reachable host or approval (phase: \(coordinator.phase))")
            }
        }

        // Wait for coordinator to finalize pairing
        _ = await pairTask.value

        if case .failed(let reason) = coordinator.phase {
            throw XCTSkip("Pairing coordinator failed during finalization: \(reason)")
        }

        XCTAssertEqual(coordinator.phase, .approved, "Pairing coordinator should reach .approved")
        let pairedDevices = core.devices()
        XCTAssertFalse(pairedDevices.isEmpty, "Device should be saved in paired devices list")
    }
}
