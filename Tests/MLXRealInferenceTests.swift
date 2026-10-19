import XCTest
import PocketMLX
@testable import PocketKit

/// APL-07 real-hardware proof: runs the real MLX bge-small embedder on the Mac GPU.
/// Hosted by the PocketAI app target so MLX's bundled Metal shader library
/// (default.metallib) loads — bare `swift test` cannot (D106).
///
/// Self-gating: runs only when the bge-small weights are already in the local
/// Hugging Face cache (warm on this Mac). CI has a cold cache, so it skips there
/// instead of downloading ~130MB over the network.
final class MLXRealInferenceTests: XCTestCase {
    private var bgeCached: Bool {
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--BAAI--bge-small-en-v1.5")
        return FileManager.default.fileExists(atPath: hub.path)
    }

    func testRealMLXEmbeddingOnAppleSilicon() throws {
        try XCTSkipUnless(bgeCached, "bge-small not in local HF cache; skipping real MLX run")

        let engine = PocketMLXEngine()
        let inputs = [
            "The quick brown fox jumps over the lazy dog.",
            "A fast brown fox leaps over a sleepy canine.",
            "Quantum computing uses superposition and entanglement."
        ]
        let vecs = try engine.embed(handle: "", inputs: inputs)

        XCTAssertEqual(vecs.count, 3)
        XCTAssertGreaterThan(vecs[0].count, 0, "non-empty embedding dim")
        for v in vecs {
            let len = sqrt(v.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(len, 1.0, accuracy: 1e-3, "embeddings are L2-normalised")
        }
        // Real semantics: paraphrase pair must be closer than the unrelated pair.
        func cos(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        XCTAssertGreaterThan(cos(vecs[0], vecs[1]), cos(vecs[0], vecs[2]),
                             "paraphrase similarity should exceed unrelated similarity")
    }
}
