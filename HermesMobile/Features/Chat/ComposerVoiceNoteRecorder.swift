import AVFoundation
import CoreGraphics
import Foundation
import Observation
import OSLog

/// Records a short voice note to a temporary `.m4a`/AAC file with `AVAudioRecorder`,
/// distinct from `ComposerVoiceInputController` (on-device dictation). The composer
/// holds one of these as `@State`: hold the mic to `begin()`, release to `finish()`,
/// slide up to `cancel()`. Drives an elapsed-time ticker and flips the shared
/// `ComposerAudioCaptureState` so the inline audio player won't fight for the session.
@MainActor
@Observable
final class ComposerVoiceNoteRecorder {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
    }

    struct RecordedVoiceNote {
        let data: Data
        let filename: String
        let duration: TimeInterval
    }

    /// Hard cap on a single clip. AAC mono at ~32 kbps stays far under the 20 MB
    /// upload limit even at five minutes (~1.2 MB), so this bounds UX, not size.
    static let maximumDuration: TimeInterval = 5 * 60
    /// Clips shorter than this are treated as accidental taps and discarded.
    static let minimumDuration: TimeInterval = 0.5

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var didActivateSession = false
    @ObservationIgnored private let recorderFactory: (URL) throws -> AVAudioRecorder
    @ObservationIgnored private let permissionRequester: () async -> Bool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "VoiceNote"
    )

    init(
        recorderFactory: @escaping (URL) throws -> AVAudioRecorder = { try AVAudioRecorder(url: $0, settings: ComposerVoiceNoteRecorder.recordingSettings) },
        permissionRequester: @escaping () async -> Bool = { await ComposerVoiceMicrophonePermissionRequester.request() }
    ) {
        self.recorderFactory = recorderFactory
        self.permissionRequester = permissionRequester
    }

    var isRecording: Bool { state == .recording }
    var isRequestingPermission: Bool { state == .requestingPermission }
    var hasReachedMaximumDuration: Bool { elapsed >= Self.maximumDuration }

    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    // MARK: - Lifecycle

    /// Requests mic permission (if needed), configures the audio session, and
    /// starts recording to a temporary `.m4a` file. No-op if already active.
    func begin() async {
        guard state == .idle else { return }
        errorMessage = nil
        elapsed = 0
        state = .requestingPermission

        let granted = await permissionRequester()
        // The state can change while we await the system prompt (e.g. the view
        // disappeared and called `cancel()`); bail rather than starting late.
        guard state == .requestingPermission else { return }
        guard granted else {
            fail(String(localized: "Microphone access is disabled. Enable it in Settings to record a voice note."))
            return
        }

        do {
            try startRecording()
            state = .recording
            startTicker()
            logger.info("Voice note recording started")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Stops recording and returns the finished clip, or nil if it was too short,
    /// failed to read, or wasn't recording. Always restores the audio session.
    func finish() -> RecordedVoiceNote? {
        guard state == .recording, let recorder, let fileURL else {
            cancel()
            return nil
        }

        let duration = recorder.currentTime
        stopRecorder()

        guard duration >= Self.minimumDuration else {
            discardFile()
            teardownSession()
            resetState()
            return nil
        }

        let data = try? Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        discardFile()
        teardownSession()
        resetState()

        guard let data, !data.isEmpty else {
            errorMessage = String(localized: "Couldn't read the recorded voice note. Try again.")
            return nil
        }
        return RecordedVoiceNote(data: data, filename: filename, duration: duration)
    }

    /// Stops and discards the recording without producing a clip.
    func cancel() {
        stopRecorder()
        discardFile()
        teardownSession()
        resetState()
    }

    // MARK: - Recording internals

    private func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        didActivateSession = true

        let url = Self.makeTemporaryFileURL()
        let recorder = try recorderFactory(url)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw ComposerVoiceNoteRecorderError.couldNotStart
        }
        self.recorder = recorder
        self.fileURL = url
        ComposerAudioCaptureState.shared.setCapturing(true)
    }

    private func stopRecorder() {
        if recorder?.isRecording == true {
            recorder?.stop()
        }
        recorder = nil
        ComposerAudioCaptureState.shared.setCapturing(false)
        stopTicker()
    }

    private func discardFile() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }

    private func teardownSession() {
        guard didActivateSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        didActivateSession = false
    }

    private func resetState() {
        state = .idle
        elapsed = 0
    }

    private func fail(_ message: String) {
        cancel()
        errorMessage = message
        logger.error("Voice note recording failed")
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        // `.common` so the timer keeps firing while the transcript scrolls.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        elapsed = recorder.currentTime
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    static func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(VoiceNoteFilename.generate())
    }

    deinit {
        ticker?.invalidate()
    }
}

enum ComposerVoiceNoteRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return String(localized: "Couldn't start recording. Try again.")
        }
    }
}

/// Generates collision-resistant `.m4a` names for recorded voice notes. The
/// 8-char suffix mirrors the attachment coordinator's uniquing so two quick notes
/// don't clash on upload, and the `.m4a` extension makes the inline player treat
/// the clip as audio even when the server reports a generic MIME type.
enum VoiceNoteFilename {
    static func generate(uuid: UUID = UUID()) -> String {
        let suffix = uuid.uuidString.prefix(8).lowercased()
        return "voice-note-\(suffix).m4a"
    }

    static func isVoiceNote(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasPrefix("voice-note-") && lower.hasSuffix(".m4a")
    }
}

/// Pure decision helpers for the hold-to-talk mic gesture, kept out of the view
/// so the thresholds and the cancel logic are unit-testable.
enum ComposerVoiceNoteGesture {
    /// A press must be held at least this long before it records, so a quick tap
    /// still routes to dictation. Matches `LongPressGesture(minimumDuration:)`.
    /// Set to the system long-press feel (0.5s) so a deliberate tap — which can
    /// linger ~0.3s on screen — isn't mistaken for a hold.
    static let holdActivationDelay: TimeInterval = 0.5
    /// Sliding the finger up past this many points arms cancel-on-release.
    static let cancelTranslationThreshold: CGFloat = 80

    /// Dragging up yields a negative height; cancel once it passes the threshold.
    /// Sliding down (positive height) never cancels.
    static func isCancelArmed(dragTranslationHeight: CGFloat) -> Bool {
        dragTranslationHeight <= -cancelTranslationThreshold
    }
}
