import Foundation
import Observation
import WatchShared

public enum WatchVoiceCapturePhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case sending
    case failed(code: String)
}

public enum WatchVoiceCapturePolicy {
    public static let minimumDuration: TimeInterval = 0.5
    /// Same 5-minute cap as the iPhone composer. Longer clips leave
    /// `sendMessage` and travel through `WCSession.transferFile`.
    public static let maximumDuration: TimeInterval = WatchVoiceNoteAudioBudget.maximumDuration

    public static var maximumDurationPhrase: String {
        let seconds = Int(maximumDuration.rounded())
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }

    public static func accept(duration: TimeInterval) -> Bool {
        duration >= minimumDuration && duration <= maximumDuration + 0.5
    }
}

/// A microphone prompt can outlive the screen that asked for it. Recording
/// starts only for the attempt that is still current.
public enum WatchVoiceStartGate {
    public static func shouldBeginRecording(attempt: UUID, currentAttempt: UUID?) -> Bool {
        currentAttempt == attempt
    }

    /// Permission is still in flight. A second tap must not start another
    /// recorder that the first attempt can then cancel.
    public static func shouldAcceptNewAttempt(startInFlight: Bool) -> Bool {
        !startInFlight
    }
}

@MainActor
@Observable
public final class WatchVoiceCapture {
    public private(set) var phase: WatchVoiceCapturePhase = .idle

    public init() {}

    public func beginRecording() {
        phase = .recording
    }

    public func cancel() {
        phase = .idle
    }

    public func finishRecording(duration: TimeInterval) -> Bool {
        guard phase == .recording else { return false }
        guard WatchVoiceCapturePolicy.accept(duration: duration) else {
            phase = .failed(code: duration < WatchVoiceCapturePolicy.minimumDuration ? "tooShort" : "tooLong")
            return false
        }
        phase = .transcribing
        return true
    }

    public func markSending() {
        phase = .sending
    }

    public func markIdle() {
        phase = .idle
    }

    public func fail(code: String) {
        phase = .failed(code: code)
    }
}
