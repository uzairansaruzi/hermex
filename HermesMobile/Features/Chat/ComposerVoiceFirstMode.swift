import Foundation
import Observation
import OSLog

/// Settings key for the voice-first composer toggle.
enum VoiceFirstModeSettings {
    static let isEnabledKey = "voiceFirstModeEnabled"
    static let silenceTimeoutKey = "voiceFirstSilenceTimeout"
    static let hotWordsKey = "voiceFirstHotWords"

    /// Default silence duration (seconds) before auto-send.
    static let defaultSilenceTimeout: TimeInterval = 2.0
}

/// Lightweight state machine for voice-first composer input.
/// Owns the silence timer that triggers auto-send.
@MainActor
@Observable
final class ComposerVoiceFirstMode {
    enum Phase: Equatable {
        /// Waiting to start (mode enabled but not yet listening).
        case idle
        /// Microphone active, no transcript yet.
        case listening
        /// Transcript exists; silence timer is counting down.
        case hasTranscript
        /// Auto-send triggered; waiting for send completion before returning to listening.
        case sending
    }

    private(set) var phase: Phase = .idle
    private(set) var silenceRemaining: TimeInterval = 0

    private var silenceTimer: Task<Void, Never>?
    private var silenceTimeout: TimeInterval = VoiceFirstModeSettings.defaultSilenceTimeout
    private var lastTranscriptChangeTime: Date = .now
    private var lastTranscript: String = ""
    private let logger = Logger(subsystem: "com.gyliu.hermex", category: "VoiceFirstMode")

    var onAutoSend: (() -> Void)?

    /// Call when voice-first mode becomes active (composer appears with toggle ON).
    func activate(silenceTimeout: TimeInterval = VoiceFirstModeSettings.defaultSilenceTimeout) {
        self.silenceTimeout = silenceTimeout
        transitionTo(.idle)
    }

    /// Call when recognition starts.
    func didStartListening() {
        lastTranscript = ""
        transitionTo(.listening)
    }

    /// Call on every partial transcript update from SFSpeechRecognizer.
    func didUpdateTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            // Still no meaningful content — stay in listening.
            if phase == .hasTranscript {
                // User deleted everything? Back to listening.
                cancelSilenceTimer()
                transitionTo(.listening)
            }
            return
        }

        if trimmed != lastTranscript {
            // Transcript changed — reset the silence timer.
            lastTranscript = trimmed
            lastTranscriptChangeTime = .now
            transitionTo(.hasTranscript)
            restartSilenceTimer()
        }
    }

    /// Call when recognition ends (error, user stop, etc).
    func didStopListening() {
        cancelSilenceTimer()
        if phase != .sending {
            transitionTo(.idle)
        }
    }

    /// Call after the auto-send message has been dispatched.
    func didCompleteSend() {
        lastTranscript = ""
        transitionTo(.idle)
    }

    /// Call to deactivate the mode entirely.
    func deactivate() {
        cancelSilenceTimer()
        lastTranscript = ""
        transitionTo(.idle)
        onAutoSend = nil
    }

    // MARK: - Private

    private func transitionTo(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        logger.debug("VoiceFirstMode: \(String(describing: self.phase)) → \(String(describing: newPhase))")
        phase = newPhase
    }

    private func restartSilenceTimer() {
        cancelSilenceTimer()
        silenceRemaining = silenceTimeout

        silenceTimer = Task { [weak self] in
            guard let self else { return }
            let tickInterval: TimeInterval = 0.1
            var elapsed: TimeInterval = 0

            while elapsed < self.silenceTimeout {
                try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                elapsed += tickInterval
                self.silenceRemaining = max(0, self.silenceTimeout - elapsed)

                // Check if transcript changed during our wait.
                let timeSinceLastChange = Date.now.timeIntervalSince(self.lastTranscriptChangeTime)
                if timeSinceLastChange < elapsed - tickInterval {
                    // Transcript was updated — timer will be restarted by didUpdateTranscript.
                    return
                }
            }

            guard !Task.isCancelled, self.phase == .hasTranscript else { return }

            // Silence threshold reached — auto-send.
            self.logger.info("VoiceFirstMode: silence timer fired, auto-sending")
            self.transitionTo(.sending)
            self.onAutoSend?()
        }
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
        silenceRemaining = 0
    }
}
