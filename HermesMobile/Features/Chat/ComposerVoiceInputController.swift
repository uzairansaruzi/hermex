import AVFoundation
import Foundation
import Observation
import OSLog
import Speech
import UIKit

@MainActor
@Observable
final class ComposerVoiceInputController {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case serverListening
        case transcribing
    }

    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private(set) var liveTranscript = ""

    private let speechRecognizerFactory: () -> SFSpeechRecognizer?
    private let audioEngineFactory: () -> AVAudioEngine
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var draftUpdateSession = ComposerVoiceDraftUpdateSession()
    private var updateDraft: ((String) -> Void)?
    private var suppressNextRecognitionError = false
    private var activatedAudioSessionForRecording = false
    private var audioTapInstalled = false
    private let logger = Logger.hermesVoiceInput

    var apiClient: APIClient?
    var locale: Locale = .current

    init(
        speechRecognizerFactory: @escaping () -> SFSpeechRecognizer? = { SFSpeechRecognizer(locale: Locale.current) },
        audioEngineFactory: @escaping () -> AVAudioEngine = { AVAudioEngine() }
    ) {
        self.speechRecognizerFactory = speechRecognizerFactory
        self.audioEngineFactory = audioEngineFactory
    }

    var isListening: Bool {
        state == .listening || state == .serverListening || state == .transcribing
    }

    var isRequestingPermission: Bool {
        state == .requestingPermission
    }

    func toggle(currentDraft: String, updateDraft: @escaping (String) -> Void) async {
        if isListening {
            stopKeepingTranscript()
        } else {
            await start(currentDraft: currentDraft, updateDraft: updateDraft)
        }
    }

    func stopKeepingTranscript() {
        suppressNextRecognitionError = true
        if state != .serverListening && state != .transcribing {
            stopAcceptingDraftUpdates()
        }
        stopAudio(cancelTask: false)
        state = .idle
    }

    func stopBeforeSubmittingDraft() {
        suppressNextRecognitionError = true
        stopAcceptingDraftUpdates()
        stopAudio(cancelTask: true)
        state = .idle
    }

    private func start(currentDraft: String, updateDraft: @escaping (String) -> Void) async {
        guard state == .idle else { return }

        logger.info("Voice input start requested")
        errorMessage = nil
        liveTranscript = ""
        suppressNextRecognitionError = false
        draftUpdateSession.begin(baseDraft: currentDraft)
        self.updateDraft = updateDraft
        state = .requestingPermission

        transcriptionTask?.cancel()
        transcriptionTask = nil

        let appleSupportsLocale = SFSpeechRecognizer.supportedLocales().contains(locale)
        let useServerSTT = !appleSupportsLocale && apiClient != nil

        if useServerSTT {
            logger.info("Locale \(self.locale.identifier) not supported by Apple — using server STT")
            let isMicrophonePermissionGranted = await requestMicrophonePermission()
            guard state == .requestingPermission else { return }
            guard isMicrophonePermissionGranted else {
                fail(String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."), logCategory: .microphonePermission)
                return
            }
            guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
                fail(ComposerVoiceInputError.appNotActive.localizedDescription, logCategory: .appNotActive)
                return
            }
            do {
                try startServerRecording()
                state = .serverListening
            } catch {
                fail(error.localizedDescription, logCategory: .audioStartup)
            }
            return
        }

        guard let speechRecognizer = speechRecognizerForRecording() else {
            fail(String(localized: "Speech recognition is not available for the current locale."), logCategory: .speechUnavailable)
            return
        }

        let speechStatus = await requestSpeechAuthorization()
        logger.info("Voice input speech authorization completed status=\(Self.logDescription(for: speechStatus), privacy: .public)")
        guard state == .requestingPermission else { return }
        guard speechStatus == .authorized else {
            fail(Self.speechAuthorizationMessage(for: speechStatus), logCategory: .speechAuthorization)
            return
        }

        let isMicrophonePermissionGranted = await requestMicrophonePermission()
        logger.info("Voice input microphone permission completed granted=\(isMicrophonePermissionGranted, privacy: .public)")
        guard state == .requestingPermission else { return }
        guard isMicrophonePermissionGranted else {
            fail(String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."), logCategory: .microphonePermission)
            return
        }

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
            fail(ComposerVoiceInputError.appNotActive.localizedDescription, logCategory: .appNotActive)
            return
        }

        do {
            try startRecognition(speechRecognizer: speechRecognizer)
            state = .listening
        } catch {
            fail(error.localizedDescription, logCategory: Self.logCategory(for: error))
        }
    }

    // MARK: - Server STT

    private static let maxServerRecordingDuration: TimeInterval = 60

    private func startServerRecording() throws {
        stopAudio(cancelTask: true)
        logger.info("Server STT: preparing audio recording")

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        activatedAudioSessionForRecording = true

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermex-stt-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        self.recordingURL = recordingURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]

        let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        recorder.prepareToRecord()
        recorder.isMeteringEnabled = true
        recorder.record(forDuration: Self.maxServerRecordingDuration)
        self.audioRecorder = recorder

        ComposerAudioCaptureState.shared.setCapturing(true)
        logger.info("Server STT: recording started to \(recordingURL.path)")
    }

    private func finishServerRecording() async {
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: recordingURL ?? URL(fileURLWithPath: "/dev/null"))
            recordingURL = nil
            audioRecorder = nil
            return
        }
        guard let recorder = audioRecorder, let recordingURL = self.recordingURL else {
            return
        }

        if recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil
        ComposerAudioCaptureState.shared.setCapturing(false)
        logger.info("Server STT: recording finished, duration=\(recorder.currentTime)s")

        guard let apiClient else {
            audioRecorder = nil
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
            fail("Speech-to-text is not configured on this server.", logCategory: .speechUnavailable)
            return
        }

        state = .transcribing
        liveTranscript = String(localized: "Transcribing...")

        do {
            let audioData = try Data(contentsOf: recordingURL)
            let languageCode = locale.language.languageCode?.identifier
            let response = try await apiClient.transcribeAudio(
                data: audioData,
                filename: "recording.wav",
                language: languageCode
            )

            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: recordingURL)
                self.recordingURL = nil
                audioRecorder = nil
                stopAcceptingDraftUpdates()
                return
            }

            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil

            if let transcript = response.transcript, !transcript.isEmpty {
                liveTranscript = transcript
                if let composedDraft = draftUpdateSession.composedDraft(for: transcript) {
                    updateDraft?(composedDraft)
                }
                state = .idle
            } else if let errorMsg = response.error {
                fail(errorMsg, logCategory: .speechUnavailable)
            } else {
                fail("Transcription returned no text.", logCategory: .speechUnavailable)
            }
        } catch {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
            fail(error.localizedDescription, logCategory: .speechUnavailable)
        }
    }

    // MARK: - Apple Native STT

    private func startRecognition(speechRecognizer: SFSpeechRecognizer) throws {
        stopAudio(cancelTask: true)
        logger.info("Voice input audio startup preparing")

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
            throw ComposerVoiceInputError.appNotActive
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(ComposerVoiceAudioSessionConfiguration.category, mode: ComposerVoiceAudioSessionConfiguration.mode, options: ComposerVoiceAudioSessionConfiguration.options)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        activatedAudioSessionForRecording = true
        logger.info("Voice input audio session active inputAvailable=\(audioSession.isInputAvailable, privacy: .public) sampleRate=\(audioSession.sampleRate, privacy: .public) inputChannels=\(audioSession.inputNumberOfChannels, privacy: .public)")
        try ComposerVoiceInputStartPolicy.validateAudioSessionInput(isInputAvailable: audioSession.isInputAvailable, sampleRate: audioSession.sampleRate, inputNumberOfChannels: audioSession.inputNumberOfChannels)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let audioEngine = audioEngineFactory()
        self.audioEngine = audioEngine
        try ComposerVoiceInputStartPolicy.validateAudioEngine(isRunning: audioEngine.isRunning)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        try ComposerVoiceInputPreflight.validate(recordingFormat: recordingFormat)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioTapInstalled = true

        audioEngine.prepare()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error)
            }
        }

        try audioEngine.start()
        ComposerAudioCaptureState.shared.setCapturing(true)
        logger.info("Voice input audio engine started")
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            liveTranscript = result.bestTranscription.formattedString
            if let composedDraft = draftUpdateSession.composedDraft(for: liveTranscript) {
                updateDraft?(composedDraft)
            }
        }

        if let error {
            stopAcceptingDraftUpdates()
            stopAudio(cancelTask: false)
            state = .idle
            if suppressNextRecognitionError {
                suppressNextRecognitionError = false
                return
            }
            errorMessage = error.localizedDescription
        } else if result?.isFinal == true {
            stopAcceptingDraftUpdates()
            stopAudio(cancelTask: false)
            state = .idle
            suppressNextRecognitionError = false
        }
    }

    // MARK: - Shared

    private func stopAcceptingDraftUpdates() {
        draftUpdateSession.stopAcceptingUpdates()
        updateDraft = nil
    }

    private func stopAudio(cancelTask: Bool) {
        ComposerAudioCaptureState.shared.setCapturing(false)

        transcriptionTask?.cancel()
        transcriptionTask = nil

        let hadServerRecording = audioRecorder != nil && recordingURL != nil

        if let recorder = audioRecorder, recorder.isRecording {
            recorder.stop()
            // Keep audioRecorder non-nil so finishServerRecording can read it.
            // It will be cleared inside finishServerRecording when done.
        }

        if let audioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            if audioTapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioTapInstalled = false
            }
            audioEngine.reset()
        }
        audioEngine = nil

        recognitionRequest?.endAudio()

        if cancelTask {
            recognitionTask?.cancel()
        }

        recognitionTask = nil
        recognitionRequest = nil

        if hadServerRecording, let recorder = audioRecorder, let url = recordingURL {
            let task = Task { [weak self] in
                await self?.finishServerRecording(recorder: recorder, recordingURL: url)
            }
            transcriptionTask = task
        }

        if activatedAudioSessionForRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedAudioSessionForRecording = false
        }
    }

    private func speechRecognizerForRecording() -> SFSpeechRecognizer? {
        if let speechRecognizer {
            return speechRecognizer
        }
        let speechRecognizer = speechRecognizerFactory()
        self.speechRecognizer = speechRecognizer
        return speechRecognizer
    }

    private func fail(_ message: String, logCategory: VoiceInputFailureLogCategory) {
        logger.error("Voice input failed category=\(logCategory.rawValue, privacy: .public)")
        suppressNextRecognitionError = false
        stopAcceptingDraftUpdates()
        stopAudio(cancelTask: true)
        state = .idle
        errorMessage = message
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await ComposerVoiceMicrophonePermissionRequester.request()
    }

    private static func speechAuthorizationMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return String(localized: "Speech recognition is disabled. Enable it in Settings to use voice input.")
        case .restricted:
            return String(localized: "Speech recognition is restricted on this device.")
        case .notDetermined:
            return String(localized: "Speech recognition permission was not granted.")
        case .authorized:
            return ""
        @unknown default:
            return String(localized: "Speech recognition is not available right now.")
        }
    }

    private static func logDescription(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    private static func logCategory(for error: Error) -> VoiceInputFailureLogCategory {
        guard let voiceError = error as? ComposerVoiceInputError else { return .audioStartup }
        switch voiceError {
        case .noAudioInput: return .noAudioInput
        case .invalidInputFormat: return .invalidInputFormat
        case .appNotActive: return .appNotActive
        case .audioEngineAlreadyRunning: return .audioEngineAlreadyRunning
        }
    }
}

enum ComposerVoiceMicrophonePermissionRequester {
    static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { isGranted in
                continuation.resume(returning: isGranted)
            }
        }
    }
}

enum ComposerVoiceAudioSessionConfiguration {
    static let category = AVAudioSession.Category.playAndRecord
    static let mode = AVAudioSession.Mode.measurement
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothHFP]
}

enum ComposerVoiceInputError: LocalizedError {
    case noAudioInput
    case invalidInputFormat
    case appNotActive
    case audioEngineAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            return String(localized: "No microphone input is available.")
        case .invalidInputFormat:
            return String(localized: "Voice input is not available because the microphone input format is invalid.")
        case .appNotActive:
            return String(localized: "Voice input can start only while Hermex is active.")
        case .audioEngineAlreadyRunning:
            return String(localized: "Voice input is already preparing the microphone. Try again in a moment.")
        }
    }
}

enum VoiceInputFailureLogCategory: String {
    case speechUnavailable
    case speechAuthorization
    case microphonePermission
    case appNotActive
    case noAudioInput
    case invalidInputFormat
    case audioEngineAlreadyRunning
    case audioStartup
}

enum ComposerVoiceInputStartPolicy {
    static func canStart(appIsActive: Bool) -> Bool { appIsActive }
    static func validateAudioSessionInput(isInputAvailable: Bool, sampleRate: Double, inputNumberOfChannels: Int) throws {
        guard isInputAvailable else { throw ComposerVoiceInputError.noAudioInput }
        try ComposerVoiceInputPreflight.validate(sampleRate: sampleRate, channelCount: UInt32(max(inputNumberOfChannels, 0)))
    }
    static func validateAudioEngine(isRunning: Bool) throws {
        guard !isRunning else { throw ComposerVoiceInputError.audioEngineAlreadyRunning }
    }
}

enum ComposerVoiceInputPreflight {
    static let validSampleRateRange: ClosedRange<Double> = 8_000...192_000
    static let validChannelCountRange: ClosedRange<UInt32> = 1...16
    static func validate(sampleRate: Double, channelCount: UInt32) throws {
        guard sampleRate.isFinite, validSampleRateRange.contains(sampleRate), validChannelCountRange.contains(channelCount) else {
            throw ComposerVoiceInputError.invalidInputFormat
        }
    }
    static func validate(recordingFormat: AVAudioFormat) throws {
        try validate(sampleRate: recordingFormat.sampleRate, channelCount: recordingFormat.channelCount)
    }
}

enum ComposerVoiceDraftComposer {
    static func composedDraft(baseDraft: String, transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return baseDraft }
        let trimmedTrailingDraft = baseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrailingDraft.isEmpty else { return trimmedTranscript }
        return "\(trimmedTrailingDraft) \(trimmedTranscript)"
    }
}

struct ComposerVoiceDraftUpdateSession {
    private var baseDraft = ""
    private var acceptsUpdates = false
    mutating func begin(baseDraft: String) { self.baseDraft = baseDraft; acceptsUpdates = true }
    mutating func stopAcceptingUpdates() { acceptsUpdates = false }
    func composedDraft(for transcript: String) -> String? {
        guard acceptsUpdates else { return nil }
        return ComposerVoiceDraftComposer.composedDraft(baseDraft: baseDraft, transcript: transcript)
    }
}

private extension Logger {
    static let hermesVoiceInput = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile", category: "VoiceInput")
}
