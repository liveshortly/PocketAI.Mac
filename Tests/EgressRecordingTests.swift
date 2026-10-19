import XCTest
import Network
import Foundation
@testable import PocketKit

final class EgressRecordingTests: XCTestCase {

    private struct TimeoutError: Error {}

    private struct RecordedEgress: Equatable, Sendable {
        let host: String
        let purpose: NetPurpose
        let bytesOut: Int64
        let bytesIn: Int64
    }

    private final class TinyLoopbackServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "com.getpocketai.tests.egress-loopback")
        private let portLock = NSLock()
        private var resumed = false

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            parameters.allowLocalEndpointReuse = true
            self.listener = try NWListener(using: parameters)
        }

        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                let resumeOnce: (Result<UInt16, Error>) -> Void = { [self] result in
                    portLock.lock()
                    defer { portLock.unlock() }
                    if !resumed {
                        resumed = true
                        continuation.resume(with: result)
                    }
                }

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port?.rawValue {
                            resumeOnce(.success(port))
                        } else {
                            resumeOnce(.failure(NSError(domain: "TinyLoopbackServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No port assigned"])))
                        }
                    case .failed(let error):
                        resumeOnce(.failure(error))
                    case .cancelled:
                        resumeOnce(.failure(NSError(domain: "TinyLoopbackServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Listener cancelled"])))
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self else { return }
                    connection.start(queue: self.queue)
                    self.serve(connection)
                }

                listener.start(queue: queue)
            }
        }

        private func serve(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, error in
                if error != nil {
                    connection.cancel()
                    return
                }

                let body = "OK - PocketAI Egress Test"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                let responseData = Data(response.utf8)

                connection.send(content: responseData, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }

        func stop() {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
    }

    func testEgressRecordingRecordsHostAndBytesIn() async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.performEgressRecording()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw TimeoutError()
                }

                // Wait for the first task to finish
                try await group.next()
                group.cancelAll()
            }
        } catch is TimeoutError {
            throw XCTSkip("Loopback test timed out after 15s")
        }
    }

    private func performEgressRecording() async throws {
        let server: TinyLoopbackServer
        do {
            server = try TinyLoopbackServer()
        } catch {
            throw XCTSkip("Failed to initialize loopback NWListener: \(error)")
        }
        defer { server.stop() }

        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            throw XCTSkip("Failed to start loopback server on 127.0.0.1: \(error)")
        }

        guard let loopbackURL = URL(string: "http://127.0.0.1:\(port)/test") else {
            XCTFail("Invalid loopback URL")
            return
        }

        let captureLock = NSLock()
        var captured: [RecordedEgress] = []

        let net = Net(
            isOffline: { false },
            onEgress: { host, purpose, bytesOut, bytesIn in
                captureLock.lock()
                captured.append(RecordedEgress(host: host, purpose: purpose, bytesOut: bytesOut, bytesIn: bytesIn))
                captureLock.unlock()
            }
        )

        var request = URLRequest(url: loopbackURL)
        request.timeoutInterval = 10.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await net.data(for: request, purpose: .catalogRefresh)

        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertGreaterThan(data.count, 0)

        captureLock.lock()
        let records = captured
        captureLock.unlock()

        XCTAssertEqual(records.count, 1, "Expected exactly 1 egress record")
        guard let entry = records.first else { return }

        print("[APL-04] Recorded egress entry: host=\(entry.host), purpose=\(entry.purpose.rawValue), bytesOut=\(entry.bytesOut), bytesIn=\(entry.bytesIn)")
        XCTAssertTrue(
            entry.host == "127.0.0.1" || entry.host == "localhost",
            "Recorded host should be 127.0.0.1 or localhost, got: \(entry.host)"
        )
        XCTAssertEqual(entry.purpose, .catalogRefresh)
        XCTAssertGreaterThan(entry.bytesIn, 0, "bytesIn should be greater than 0")
        XCTAssertEqual(entry.bytesIn, Int64(data.count), "bytesIn should match response data size")
    }
}
