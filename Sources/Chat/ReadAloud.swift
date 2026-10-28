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
    private let monitor = SpeechMonitor()
    /// Id of the message currently being spoken, so only that row shows Stop.
    private(set) var speakingId: String?
    /// Voice identifier to speak with; nil uses the system default.
    var voiceIdentifier: String? {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey) }
    }

    private static let voiceKey = "app.getpocketai.mac.ttsVoice"

    private init() {
        voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey)
        // The delegate is the only reliable "finished" signal. Polling
        // `isSpeaking` raced the synthesizer's own start-up and cleared the
        // button while it was still talking.
        monitor.onFinish = { [weak self] in self?.speakingId = nil }
        synthesizer.delegate = monitor
    }

    func toggle(_ text: String, id: String) {
        if speakingId == id {
            stop()
            return
        }
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice()
        speakingId = id
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingId = nil
    }

    /// Voices available for the current language, for the settings picker.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let prefix = String(Locale.current.identifier.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices()
        let local = all.filter { $0.language.hasPrefix(prefix) }
        return (local.isEmpty ? all : local).sorted { $0.name < $1.name }
    }

    private func voice() -> AVSpeechSynthesisVoice? {
        if let voiceIdentifier,
           let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        return AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

/// Bridges the synthesizer's delegate callbacks back onto the main actor.
private final class SpeechMonitor: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (@MainActor () -> Void)?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in onFinish?() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in onFinish?() }
    }
}
