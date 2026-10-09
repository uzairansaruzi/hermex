import AVFoundation
import NaturalLanguage
import Observation

/// Reads Hermes's latest reply aloud with on-device speech. `isSpeaking` drives
/// the Read aloud / Stop icon. The audio session is held only while speaking
/// and released with `notifyOthersOnDeactivation`, so music or a podcast the
/// reply ducked comes back at full volume afterwards.
@MainActor
@Observable
final class WatchReplySpeaker: NSObject {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts reading `text`. Returns `false` when there is nothing to read or
    /// the audio session could not be activated, so the caller can play a
    /// failure haptic instead of a silent button.
    @discardableResult
    func speak(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            return false
        }
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = Self.voice(for: words)
        // VoiceOver users have already chosen a voice and rate; honour them.
        utterance.prefersAssistiveTechnologySettings = true
        currentUtterance = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
        return true
    }

    func stop() {
        guard isSpeaking || synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        currentUtterance = nil
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A reply in another language than the watch's should not be read with
    /// the system voice's accent. Short replies are too ambiguous to detect,
    /// so they keep the default voice.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        guard text.count >= 40,
              let language = NLLanguageRecognizer.dominantLanguage(for: text),
              language != .undetermined
        else { return nil }
        let code = language.rawValue
        if Locale.current.language.languageCode?.identifier == code { return nil }
        return AVSpeechSynthesisVoice(language: code)
    }

    fileprivate func utteranceEnded(_ utterance: ObjectIdentifier) {
        // A stop-then-speak can deliver the old utterance's cancel after the
        // new one started; only the current utterance ends the session.
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == utterance else { return }
        finish()
    }
}

extension WatchReplySpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
