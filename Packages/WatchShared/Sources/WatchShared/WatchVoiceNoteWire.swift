import Foundation

/// WatchConnectivity `sendMessage` can carry about 65,536 bytes of property-list
/// payload. `WatchVoiceNoteRequest.audio` is `Data`, so JSON encodes it as
/// base64: 48 KB of AAC becomes ~64 KB and already fills that budget.
/// Longer clips stay legal — they leave `sendMessage` and travel through
/// `WCSession.transferFile`. This 48 KB value is the inline hop, not the
/// recording cap.
public enum WatchVoiceNoteWire: Sendable {
    public static let maximumInlineAudioBytes = 48_000
    public static let maximumSendMessagePayloadBytes = 65_536
    /// Encoded glance or session snapshot. The reply envelope sits on top of
    /// this, and a `sendMessage` past the payload ceiling is dropped without
    /// calling either handler, so the watch waits on a spinner.
    public static let maximumSnapshotJSONBytes = 40_000
    /// Full JSON reply, leaving room for the plist dictionary around it.
    public static let maximumDeliverableReplyBytes = 60_000
    public static let fileTransferMetadataKey = "hermexVoiceTransferID"

    public static func requiresFileTransfer(_ request: WatchVoiceNoteRequest) -> Bool {
        request.audio.count > maximumInlineAudioBytes
    }
}

/// Byte and duration budget for a watch voice note, derived from the iPhone
/// encoder (`ComposerVoiceNoteRecorder`: AAC MPEG-4, 44.1 kHz, mono, medium).
/// Duration matches iOS. Size is 64 kbps (real medium-quality AAC) plus 25%
/// headroom, still far under the 20 MB `/api/transcribe` upload cap.
public enum WatchVoiceNoteAudioBudget: Sendable {
    /// Same cap as `ComposerVoiceNoteRecorder.maximumDuration`.
    public static let maximumDuration: TimeInterval = 5 * 60
    /// iOS documents AAC mono at ~32 kbps (~1.2 MB at five minutes).
    public static let documentedBitsPerSecond = 32_000
    /// Real `AVAudioQuality.medium` AAC at 44.1 kHz mono can sit near 64 kbps.
    public static let mediumQualityBitsPerSecond = 64_000
    /// Container and encoder headroom on top of the 64 kbps estimate.
    public static let headroom = 1.25
    /// Server `/api/transcribe` / attachment upload cap.
    public static let transcribeUploadCapBytes = 20 * 1_024 * 1_024

    public static func bytes(bitsPerSecond: Int, duration: TimeInterval) -> Int {
        bitsPerSecond / 8 * Int(duration)
    }

    public static var maximumAudioBytes: Int {
        Int(Double(bytes(bitsPerSecond: mediumQualityBitsPerSecond, duration: maximumDuration)) * headroom)
    }
}

/// Joins a watch→phone `transferFile` with the matching `transcribeFile` envelope.
/// File and message can arrive in either order; tests deposit/take without sleeps.
public actor WatchVoiceNoteFileInbox {
    private var files: [UUID: Data] = [:]
    private var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]

    public init() {}

    public func deposit(transferID: UUID, data: Data) {
        if let waiter = waiters.removeValue(forKey: transferID) {
            waiter.resume(returning: data)
            return
        }
        // One unmatched clip at a time — the watch only records sequentially.
        files = [transferID: data]
    }

    public func take(transferID: UUID) async throws -> Data {
        if let data = files.removeValue(forKey: transferID) {
            return data
        }
        return try await withCheckedThrowingContinuation { continuation in
            if let existing = waiters.removeValue(forKey: transferID) {
                existing.resume(throwing: WatchCompanionError.backend(.invalidResponse))
            }
            waiters[transferID] = continuation
        }
    }

    public func fail(transferID: UUID, error: Error) {
        files[transferID] = nil
        waiters.removeValue(forKey: transferID)?.resume(throwing: error)
    }
}
