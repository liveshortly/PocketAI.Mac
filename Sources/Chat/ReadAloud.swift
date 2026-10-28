import AVFoundation
import Observation
import SwiftUI

/// Reads a reply out loud. One synthesizer for the whole app, so starting a
/// new reply stops the previous one instead of talking over it.
@MainActor
@Observable
final class ReadAloud {
    static let shared = ReadAloud()

    private let synthesizer = AVSpeechSynthesizer()
    /// Id of the message currently being spoken, so only that row shows Stop.
    private(set) var speakingId: String?

    private init() {}

    func toggle(_ text: String, id: String) {
        if speakingId == id {
            stop()
            return
        }
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        speakingId = id
        synthesizer.speak(utterance)
        // AVSpeechSynthesizer's delegate is the only "finished" signal, and a
        // delegate here would outlive the row; polling once a second is enough
        // to clear the button when speech ends on its own.
        Task { [weak self] in
            while let self, self.synthesizer.isSpeaking {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            self?.speakingId = nil
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingId = nil
    }
}
