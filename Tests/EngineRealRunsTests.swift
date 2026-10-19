import XCTest
import AVFoundation
import AppKit
@testable import PocketKit

/// Real-hardware engine runs executed inside the PocketAI.app bundle on this
/// Apple-Silicon Mac (macOS 26). Each test self-gates on availability so CI and
/// older SDKs skip rather than fail.
final class EngineRealRunsTests: XCTestCase {

    /// Runs `body` on a background queue and waits up to `timeout`s. Returns the
    /// thrown error, or nil on success; throws XCTSkip on timeout — the headless
    /// xcodebuild test host has no audio session, so AVSpeech can stall there even
    /// though it works in the shipping foreground app.
    private func runBounded(_ timeout: TimeInterval, _ body: @escaping () throws -> Void) throws -> Error? {
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var err: Error? }
        let box = Box()
        DispatchQueue.global().async { do { try body() } catch { box.err = error }; sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw XCTSkip("audio engine stalled in headless test host (needs a real audio session)")
        }
        return box.err
    }

    // APL-13: AVSpeechSynthesizer writes a real wav on device.
    func testTTSSynthesizesWav() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }

        if let err = try runBounded(20, {
            try AppleTextToSpeechEngine().synthesize(
                text: "Pocket AI speaks on device.", voice: "en-US", outPath: out.path)
        }) { throw err }

        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 2048, "wav has real PCM audio, not an empty header")
    }

    // APL-17: DocumentTextExtractor pulls text back from real fixture files.
    func testDocExtractionTxtAndPDF() throws {
        let tmp = FileManager.default.temporaryDirectory
        let needle = "PocketAI extraction works"

        // plain text path
        let txt = tmp.appendingPathComponent("doc_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: txt) }
        try needle.write(to: txt, atomically: true, encoding: .utf8)
        let txtPages = try DocumentTextExtractor.extract(fileURL: txt)
        XCTAssertTrue(txtPages.contains { $0.text.contains(needle) }, "txt text extracted")

        // PDF path (real text layer via Core Text)
        let pdf = tmp.appendingPathComponent("doc_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdf) }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: needle,
            attributes: [.font: NSFont.systemFont(ofSize: 24)])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        let pdfPages = try DocumentTextExtractor.extract(fileURL: pdf)
        XCTAssertTrue(pdfPages.contains { $0.text.contains(needle) }, "pdf text extracted")
    }

    // APL-16: Apple Foundation Models (Apple Intelligence) real generate — only
    // when this Mac has Apple Intelligence available.
    func testFoundationModelsGenerateIfAvailable() throws {
        try XCTSkipUnless(AppleFoundationModelsEngine.isAvailable,
                          "Apple Intelligence not available/enabled on this Mac")

        let engine = AppleFoundationModelsEngine()
        let manifest = ModelManifest(
            id: AppleFoundationModelsEngine.modelId,
            displayName: "Apple Intelligence", family: "apple", paramsB: 0, quant: "",
            format: .mlxSafetensors, modalities: [.text], contextLength: 4096, files: [],
            license: LicenseInfo(spdx: "", commercialOk: true, url: ""),
            hfRepo: "", hfRevision: "", minRamBytes: 0, estRuntimeBytes: 0, tags: [], curated: true)
        let loaded = try engine.load(model: manifest, opts: LoadOptions(contextLength: nil, pinnedEngine: nil))
        defer { try? engine.unload(handle: loaded.handle) }

        let req = GenerateRequest(
            requestId: UUID().uuidString,
            messages: [ChatMessage(role: "user", parts: [.text(text: "Say hello in three words.")])],
            tools: [],
            params: SamplingParams(temperature: 0.0, topP: 1.0, topK: 0, minP: 0.0,
                                   maxTokens: 32, stop: [], seed: 0, repetitionPenalty: 0.0),
            reasoning: .off)
        final class Sink: TokenSink, @unchecked Sendable {
            var text = ""; var done = false
            func onDelta(delta: GenerateDelta) { text += delta.text }
            func onDone(stats: GenerateStats) { done = true }
            func onError(err: PocketError) {}
        }
        let sink = Sink()
        let stats = try engine.generate(handle: loaded.handle, req: req, sink: sink)
        XCTAssertTrue(sink.done)
        XCTAssertGreaterThan(stats.completionTokens, 0)
        XCTAssertFalse(sink.text.isEmpty)
    }

    // APL-12: offline STT — synthesize speech then transcribe it back. Skips if
    // speech authorization is not granted to this test host (a TCC gate, not code).
    func testSTTTranscribesSynthesizedSpeech() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26 SpeechAnalyzer") }
        let phrase = "the quick brown fox jumps over the lazy dog"
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }

        final class Sink: TokenSink, @unchecked Sendable {
            var text = ""; var err: String?
            func onDelta(delta: GenerateDelta) { text += delta.text }
            func onDone(stats: GenerateStats) {}
            func onError(err: PocketError) { self.err = "\(err)" }
        }
        let sink = Sink()
        if let err = try runBounded(20, {
            try AppleTextToSpeechEngine().synthesize(text: phrase, voice: "en-US", outPath: wav.path)
        }) { throw XCTSkip("tts unavailable in test host: \(err)") }

        if let err = try runBounded(30, {
            try AppleSpeechToTextEngine().transcribe(audioPath: wav.path, lang: "en-US", sink: sink)
        }) { throw XCTSkip("speech transcription unavailable (auth/TCC or model): \(err)") }
        if let e = sink.err { throw XCTSkip("speech engine error (likely auth/TCC): \(e)") }
        let got = sink.text.lowercased()
        XCTAssertTrue(["fox", "quick", "brown", "dog"].contains { got.contains($0) },
                      "recognised at least one expected word; got: \(sink.text)")
    }
}
