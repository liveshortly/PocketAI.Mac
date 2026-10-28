import AVFoundation
import Observation
import Speech
import SwiftUI

/// Live dictation for the composer: system speech recognition streamed into
/// the draft as you speak.
///
/// The app already carries `AppleSpeechToTextEngine`, but that transcribes a
/// finished audio file; a composer wants partial results while talking, which
/// is what `SFSpeechAudioBufferRecognitionRequest` gives.
@MainActor
@Observable
final class Dictation {
    private(set) var isRecording = false
    private(set) var permissionDenied = false
    /// Rough input level (0...1) for the mic button's halo.
    private(set) var level: Double = 0

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    nonisolated init() {}

    func toggle(base: String, onText: @escaping @MainActor (String) -> Void) {
        if isRecording { stop() } else { start(base: base, onText: onText) }
    }

    private func start(base: String, onText: @escaping @MainActor (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            Task { @MainActor in
                guard auth == .authorized else {
                    self.permissionDenied = true
                    return
                }
                self.begin(base: base, onText: onText)
            }
        }
    }

    private func begin(base: String, onText: @escaping @MainActor (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) {
            [weak self] buffer, _ in
            request.append(buffer)
            // Cheap peak meter so the button can show that it is hearing you.
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            for index in stride(from: 0, to: frames, by: 8) {
                peak = max(peak, abs(channel[index]))
            }
            Task { @MainActor in self?.level = Double(min(1, peak * 4)) }
        }
        engine.prepare()
        guard (try? engine.start()) != nil else { return }

        self.engine = engine
        self.request = request
        isRecording = true
        permissionDenied = false

        let prefix = base.isEmpty ? "" : base + " "
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    onText(prefix + result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true { self?.stop() }
            }
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        isRecording = false
        level = 0
    }
}
