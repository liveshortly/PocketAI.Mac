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

    // APL-06 real-hardware proof: real MLX text generation (load + generate +
    // TokenSink) on the Mac GPU. Self-gates on the staged Qwen 0.5B 4bit weights.
    private static let chatRepo = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    private static let chatRev = "main"
    private var chatModelDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.getpocketai", isDirectory: true)
            .appendingPathComponent("Models/\(Self.chatRepo)/\(Self.chatRev)", isDirectory: true)
    }

    func testRealMLXTextGenerationOnAppleSilicon() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: chatModelDir.path),
                          "Qwen 0.5B MLX weights not staged; skipping real MLX generate")

        let manifest = ModelManifest(
            id: "\(Self.chatRepo)@\(Self.chatRev)",
            displayName: "Qwen2.5 0.5B",
            family: "qwen2",
            paramsB: 0.5,
            quant: "4bit",
            format: .mlxSafetensors,
            modalities: [.text],
            contextLength: 2048,
            files: [],
            license: LicenseInfo(spdx: "apache-2.0", commercialOk: true, url: ""),
            hfRepo: Self.chatRepo,
            hfRevision: Self.chatRev,
            minRamBytes: 0,
            estRuntimeBytes: 600_000_000,
            tags: [],
            curated: true
        )

        let engine = PocketMLXEngine()
        let loaded = try engine.load(model: manifest, opts: LoadOptions(contextLength: nil, pinnedEngine: nil))
        defer { try? engine.unload(handle: loaded.handle) }

        let req = GenerateRequest(
            requestId: UUID().uuidString,
            messages: [ChatMessage(role: "user", parts: [.text(text: "Reply with exactly: PocketAI works.")])],
            tools: [],
            params: SamplingParams(temperature: 0.0, topP: 1.0, topK: 0, minP: 0.0,
                                   maxTokens: 24, stop: [], seed: 42, repetitionPenalty: 0.0),
            reasoning: .off
        )

        final class CollectorSink: TokenSink, @unchecked Sendable {
            var text = ""; var completed = false
            func onDelta(delta: GenerateDelta) { text += delta.text }
            func onDone(stats: GenerateStats) { completed = true }
            func onError(err: PocketError) {}
        }
        let sink = CollectorSink()
        let stats = try engine.generate(handle: loaded.handle, req: req, sink: sink)

        XCTAssertTrue(sink.completed, "generation completed")
        XCTAssertGreaterThan(stats.completionTokens, 0, "produced tokens")
        XCTAssertFalse(sink.text.isEmpty, "non-empty decode")
        XCTAssertGreaterThan(stats.decodeTps, 0, "real decode tok/s measured on GPU")
    }
}
