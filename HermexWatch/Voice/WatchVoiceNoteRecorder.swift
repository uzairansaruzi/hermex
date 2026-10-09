import AVFoundation
import Foundation
import Observation
import HermexWatchRoot

enum WatchSpeechError: Error {
    case denied
    case unavailable
    case empty
    case abandoned
}

@MainActor
@Observable
final class WatchVoiceNoteRecorder {
    struct Clip {
        let url: URL
        let duration: TimeInterval
    }

    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var ticker: Timer?
    private var didActivateSession = false

    /// Matches `ComposerVoiceNoteRecorder.recordingSettings` so a 5:00 watch clip
    /// is the same AAC the iPhone already transcribes through `/api/transcribe`.
    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    var hasReachedMaximumDuration: Bool {
        elapsed >= WatchVoiceCapturePolicy.maximumDuration
    }

    func begin(isStillCurrent: @MainActor () -> Bool = { true }) async throws {
        let granted = await requestMicrophone()
        guard granted else { throw WatchSpeechError.denied }
        guard isStillCurrent() else { throw WatchSpeechError.abandoned }
        try activateSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString.prefix(8)).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
        elapsed = 0
        guard isStillCurrent() else {
            teardownSession()
            throw WatchSpeechError.abandoned
        }
        guard recorder.record(forDuration: WatchVoiceCapturePolicy.maximumDuration) else {
            teardownSession()
            throw WatchSpeechError.unavailable
        }
        self.recorder = recorder
        fileURL = url
        startTicker()
    }

    func finish() -> Clip? {
        guard let recorder, let fileURL else {
            cancel()
            return nil
        }
        // Clamp so a 5:00 auto-stop that overshoots `currentTime` still sends.
        let duration = min(recorder.currentTime, WatchVoiceCapturePolicy.maximumDuration)
        stopRecorder()
        teardownSession()
        guard WatchVoiceCapturePolicy.accept(duration: duration) else {
            try? FileManager.default.removeItem(at: fileURL)
            self.fileURL = nil
            elapsed = 0
            return nil
        }
        self.fileURL = nil
        elapsed = 0
        return Clip(url: fileURL, duration: duration)
    }

    func cancel() {
        stopRecorder()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        elapsed = 0
        teardownSession()
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        didActivateSession = true
    }

    private func teardownSession() {
        guard didActivateSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        didActivateSession = false
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        if !recorder.isRecording, fileURL != nil {
            elapsed = max(elapsed, WatchVoiceCapturePolicy.maximumDuration)
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func stopRecorder() {
        if recorder?.isRecording == true {
            recorder?.stop()
        }
        recorder = nil
        stopTicker()
    }
}
