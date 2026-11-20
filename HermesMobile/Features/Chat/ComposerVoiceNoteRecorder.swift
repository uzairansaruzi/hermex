import AVFoundation
import CoreGraphics
import Foundation
import Observation
import OSLog

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

    static let maximumDuration: TimeInterval = 5 * 60
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

    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    func begin() async {
        guard state == .idle else { return }
        errorMessage = nil
        elapsed = 0
        state = .requestingPermission

        let granted = await permissionRequester()
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

    func cancel() {
        stopRecorder()
        discardFile()
        teardownSession()
        resetState()
    }

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

    private func startTicker() {
        stopTicker()
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

enum ComposerVoiceNoteGesture {
    static let holdActivationDelay: TimeInterval = 0.5
    static let cancelTranslationThreshold: CGFloat = 80

    static func isCancelArmed(dragTranslationHeight: CGFloat) -> Bool {
        dragTranslationHeight <= -cancelTranslationThreshold
    }
}
