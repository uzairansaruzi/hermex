import AVFoundation
import Foundation
import Observation
import os
import OSLog
import Speech
import UIKit

/// Uploads one finished dictation recording (its bytes and file name) to the server's
/// speech-to-text and returns the reply. A webui server's is `APIClient.dictationTranscriber`;
/// a Hermes chat's is `HermesTranscription.transcriber(for:)`, bound to its Profile (#1071).
typealias ComposerTranscriber = @MainActor (Data, String) async throws -> TranscribeResponse

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

    private(set) var state: State = .idle {
        didSet {
            if state == .listening || state == .serverListening {
                recordingLease.acquire()
                startMetering()
            } else {
                recordingLease.release()
                stopMetering()
            }
        }
    }
    private(set) var errorMessage: String?
    private(set) var liveTranscript = ""
    /// When the current capture began, for the dictation row's timer.
    private(set) var captureStartedAt: Date?
    /// Held apart from the controller so only the waveform redraws for each level.
    @ObservationIgnored let levelMeter = ComposerVoiceLevelMeter()

    private let speechRecognizerFactory: (Locale) -> (any ComposerSpeechRecognizing)?
    private let supportedLocales: () -> Set<Locale>
    private let audioEngineFactory: () -> AVAudioEngine
    private var speechRecognizer: (any ComposerSpeechRecognizing)?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let serverRecorder: any ComposerServerRecording
    private var recordingURL: URL?
    private var draftUpdateSession = ComposerVoiceDraftUpdateSession()
    private var draftState: (() -> ComposerVoiceDraftState)?
    private var updateDraft: ((ComposerVoiceDraftUpdate) -> Void)?
    private var suppressNextRecognitionError = false
    private var activatedAudioSessionForRecording = false
    private var audioTapInstalled = false
    private var ownsAudioCapture = false
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var toggleTask: Task<Void, Never>?
    @ObservationIgnored private var meteringTask: Task<Void, Never>?
    /// The on-device tap's latest level. The tap runs on the audio thread.
    @ObservationIgnored private let onDeviceDecibels = OSAllocatedUnfairLock<Float?>(initialState: nil)
    private var activeTranscriptionID: UUID?
    @ObservationIgnored private let recordingLease = ComposerDictationLease.live()
    private static weak var captureOwner: ComposerVoiceInputController?
    private var startID: UUID?
    private var recognitionID: UUID?
    private var isSuspended = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private let microphonePermission: () async -> Bool
    private let speechAuthorization: () async -> SFSpeechRecognizerAuthorizationStatus
    private let mayRecord: @MainActor () -> Bool
    private let logger = Logger.hermesVoiceInput

    /// The server's speech-to-text; nil when the server has none, which leaves only on-device.
    @ObservationIgnored var transcribe: ComposerTranscriber?
    @ObservationIgnored var providerPreference = ComposerSTTProviderPreference.defaultValue

    init(
        speechRecognizerFactory: @escaping (Locale) -> (any ComposerSpeechRecognizing)? = { SFSpeechRecognizer(locale: $0) },
        supportedLocales: @escaping () -> Set<Locale> = { SFSpeechRecognizer.supportedLocales() },
        audioEngineFactory: @escaping () -> AVAudioEngine = { AVAudioEngine() },
        microphonePermission: @escaping () async -> Bool = { await ComposerVoiceMicrophonePermissionRequester.request() },
        speechAuthorization: @escaping () async -> SFSpeechRecognizerAuthorizationStatus = {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        },
        serverRecorder: (any ComposerServerRecording)? = nil,
        mayRecord: @escaping @MainActor () -> Bool = {
            ComposerVoiceInputStartPolicy.canStart(
                appIsActive: UIApplication.shared.applicationState == .active,
                appIsLocked: AppLock.shared.isLocked)
        }
    ) {
        self.speechRecognizerFactory = speechRecognizerFactory
        self.supportedLocales = supportedLocales
        self.audioEngineFactory = audioEngineFactory
        self.microphonePermission = microphonePermission
        self.speechAuthorization = speechAuthorization
        self.mayRecord = mayRecord
        self.serverRecorder = serverRecorder ?? ComposerServerAudioRecorder()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began { self.suspend() }
                else if type == .ended { self.resume() }
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    var isListening: Bool {
        state == .listening || state == .serverListening || state == .transcribing
    }

    var isRequestingPermission: Bool {
        state == .requestingPermission
    }

    /// Queue UI input under the same ownership as capture, so teardown can cancel
    /// even a microphone tap whose task has not started executing yet.
    @discardableResult
    func scheduleToggle(
        draftState: @escaping () -> ComposerVoiceDraftState,
        updateDraft: @escaping (ComposerVoiceDraftUpdate) -> Void
    ) -> Task<Void, Never> {
        toggleTask?.cancel()
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.toggle(draftState: draftState, updateDraft: updateDraft)
        }
        toggleTask = task
        return task
    }

    /// `draftState` is read when capture starts and again before every write, so
    /// the closure must return the composer's live values, not a captured copy.
    func toggle(
        draftState: @escaping () -> ComposerVoiceDraftState,
        updateDraft: @escaping (ComposerVoiceDraftUpdate) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        if isListening {
            stopKeepingTranscript()
        } else {
            await start(draftState: draftState, updateDraft: updateDraft)
        }
    }

    /// Scene inactivity stops capture immediately. A server clip remains owned by this
    /// composer until it returns unlocked, or explicit teardown discards it.
    func suspend() {
        toggleTask?.cancel()
        toggleTask = nil
        guard !isSuspended else { return }
        isSuspended = true
        startID = nil
        switch state {
        case .serverListening:
            stopAudio(cancelTask: true)
            state = .transcribing
        case .listening, .requestingPermission:
            stopKeepingTranscript()
        case .idle, .transcribing:
            break
        }
    }

    func resume() {
        guard mayRecord() else { return }
        isSuspended = false
        resumeWaiter?.resume()
        resumeWaiter = nil
        if state == .transcribing, transcriptionTask == nil, let recordingURL {
            beginTranscription(recordingURL: recordingURL)
        }
    }

    private func waitUntilResumed() async {
        if !mayRecord() { isSuspended = true }
        if isSuspended, !Task.isCancelled {
            await withCheckedContinuation { resumeWaiter = $0 }
        }
    }

    func stopKeepingTranscript() {
        startID = nil
        suppressNextRecognitionError = true
        switch state {
        case .serverListening:
            stopServerRecordingAndTranscribe()
        case .transcribing:
            cancelServerTranscription()
            stopAcceptingDraftUpdates()
            stopAudio(cancelTask: true)
            state = .idle
        case .idle, .requestingPermission, .listening:
            stopAcceptingDraftUpdates()
            stopAudio(cancelTask: false)
            state = .idle
        }
    }

    /// The dictation row's cancel: drops the recording and takes back any words
    /// already written, leaving the draft as it was before the mic was tapped.
    func cancel() {
        if let draftState, let updateDraft, let restored = draftUpdateSession.restoredDraft(current: draftState()) {
            updateDraft(restored)
        }
        stopBeforeSubmittingDraft()
    }

    func dismissError() {
        errorMessage = nil
    }

    func stopBeforeSubmittingDraft() {
        toggleTask?.cancel()
        toggleTask = nil
        startID = nil
        suppressNextRecognitionError = true
        cancelServerTranscription()
        stopAcceptingDraftUpdates()
        discardServerRecording()
        stopAudio(cancelTask: true)
        state = .idle
    }

    private func start(
        draftState: @escaping () -> ComposerVoiceDraftState,
        updateDraft: @escaping (ComposerVoiceDraftUpdate) -> Void
    ) async {
        guard state == .idle, mayRecord(), !Task.isCancelled else { return }
        if let owner = Self.captureOwner, owner !== self { owner.stopBeforeSubmittingDraft() }
        Self.captureOwner = self
        isSuspended = false
        let id = UUID()
        startID = id

        logger.info("Voice input start requested")
        errorMessage = nil
        liveTranscript = ""
        suppressNextRecognitionError = false
        cancelServerTranscription()
        discardServerRecording()
        draftUpdateSession.begin(draftState())
        self.draftState = draftState
        self.updateDraft = updateDraft
        state = .requestingPermission

        let canUseServer = transcribe != nil
        let canUseOnDevice = onDeviceSpeechRecognizerForRecording() != nil
        let providers = ComposerSTTProviderPolicy.orderedProviders(
            preference: providerPreference,
            serverConfigured: canUseServer,
            onDeviceSupported: canUseOnDevice
        )

        guard let provider = providers.first else {
            fail(
                unavailableMessage(
                    serverConfigured: canUseServer,
                    onDeviceSupported: canUseOnDevice
                ),
                logCategory: .speechUnavailable
            )
            return
        }

        await start(provider: provider, startID: id)
        if Task.isCancelled, startID == id { stopBeforeSubmittingDraft() }
    }

    private func start(provider: ComposerSTTProvider, startID: UUID) async {
        switch provider {
        case .server:
            await startServerProvider(startID: startID)
        case .onDevice:
            await startOnDeviceProvider(startID: startID)
        }
    }

    private func startServerProvider(startID: UUID) async {
        let isMicrophonePermissionGranted = await requestMicrophonePermission()
        logger.info("Server voice input microphone permission completed granted=\(isMicrophonePermissionGranted, privacy: .public)")
        guard self.startID == startID, state == .requestingPermission, !Task.isCancelled else { return }
        guard isMicrophonePermissionGranted else {
            fail(
                String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."),
                logCategory: .microphonePermission
            )
            return
        }

        guard mayRecord() else {
            fail(
                ComposerVoiceInputError.appNotActive.localizedDescription,
                logCategory: .appNotActive
            )
            return
        }

        do {
            try startServerRecording()
            state = .serverListening
        } catch {
            await fallbackOrFail(
                from: .server,
                message: error.localizedDescription,
                logCategory: Self.logCategory(for: error)
            )
        }
    }

    private func startOnDeviceProvider(startID: UUID) async {
        guard let speechRecognizer = onDeviceSpeechRecognizerForRecording() else {
            await fallbackOrFail(
                from: .onDevice,
                message: String(localized: "On-device speech recognition is not available for the current locale."),
                logCategory: .speechUnavailable
            )
            return
        }

        let speechStatus = await requestSpeechAuthorization()
        logger.info("Voice input speech authorization completed status=\(Self.logDescription(for: speechStatus), privacy: .public)")
        guard self.startID == startID, state == .requestingPermission, !Task.isCancelled else { return }
        guard speechStatus == .authorized else {
            await fallbackOrFail(
                from: .onDevice,
                message: Self.speechAuthorizationMessage(for: speechStatus),
                logCategory: .speechAuthorization
            )
            return
        }

        let isMicrophonePermissionGranted = await requestMicrophonePermission()
        logger.info("Voice input microphone permission completed granted=\(isMicrophonePermissionGranted, privacy: .public)")
        guard self.startID == startID, state == .requestingPermission, !Task.isCancelled else { return }
        guard isMicrophonePermissionGranted else {
            fail(
                String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."),
                logCategory: .microphonePermission
            )
            return
        }

        guard mayRecord() else {
            fail(
                ComposerVoiceInputError.appNotActive.localizedDescription,
                logCategory: .appNotActive
            )
            return
        }

        do {
            try startRecognition(speechRecognizer: speechRecognizer)
            state = .listening
        } catch {
            await fallbackOrFail(
                from: .onDevice,
                message: error.localizedDescription,
                logCategory: Self.logCategory(for: error)
            )
        }
    }

    private func fallbackOrFail(
        from failedProvider: ComposerSTTProvider,
        message: String,
        logCategory: VoiceInputFailureLogCategory
    ) async {
        guard let id = startID, !Task.isCancelled, !isSuspended else { return }
        let fallback = ComposerSTTProviderPolicy.fallbackProvider(
            after: failedProvider,
            preference: providerPreference,
            serverConfigured: transcribe != nil,
            onDeviceSupported: onDeviceSpeechRecognizerForRecording() != nil
        )

        guard let fallback else {
            fail(message, logCategory: logCategory)
            return
        }

        logger.info("Voice input falling back after \(String(describing: failedProvider), privacy: .public)")
        state = .requestingPermission
        await start(provider: fallback, startID: id)
    }

    private func unavailableMessage(serverConfigured: Bool, onDeviceSupported: Bool) -> String {
        if providerPreference == .onDeviceOnly {
            return String(localized: "On-device speech recognition is not available for the current locale.")
        }

        if !serverConfigured && !onDeviceSupported {
            return String(localized: "Speech-to-text is not available right now.")
        }

        if !serverConfigured {
            return String(localized: "Server speech-to-text is not configured.")
        }

        return String(localized: "On-device speech recognition is not available for the current locale.")
    }

    // MARK: - Server STT

    // Mono AAC tuned for server speech-to-text (#1355). At 44.1 kHz a 32 kbps
    // encode spreads its bits over a band speech models discard, and server STT
    // dropped noticeably more words than on an Opus voice note of the same
    // speech. 24 kHz keeps the speech band and 48 kbps there matched the voice
    // note. ~22 MB/hour still lets recording run until the user stops it; past
    // the upload ceiling (~55 minutes) the byte guard below takes over.
    static let serverRecordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: serverRecordingSampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: serverRecordingBitrate
    ]

    static let serverRecordingSampleRate = 24_000.0
    static let serverRecordingBitrate = 48_000
    static let serverRecordingFileExtension = "m4a"
    // Leave 1 MiB below the server's configurable 20 MiB default for the
    // multipart envelope. A lower custom limit still uses the existing fallback.
    // A Hermes host takes up to 25 MiB of decoded audio (#1071).
    static let maximumServerRecordingUploadBytes = 19 * 1_024 * 1_024

    static func serverRecordingFileSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        return size
    }

    /// Returns `nil` before reading an oversized recording into memory.
    static func loadServerRecordingForUpload(
        fileSize: Int,
        dataLoader: () throws -> Data
    ) rethrows -> Data? {
        guard fileSize <= maximumServerRecordingUploadBytes else {
            return nil
        }
        return try dataLoader()
    }

    private func startServerRecording() throws {
        stopAudio(cancelTask: true)
        let id = startID
        serverRecorder.onFinish = { [weak self] in
            guard let self, self.startID == id, self.state == .serverListening else { return }
            if self.mayRecord() { self.stopKeepingTranscript() }
            else { self.suspend() }
        }
        recordingURL = try serverRecorder.start()
        ownsAudioCapture = true
        ComposerAudioCaptureState.shared.setCapturing(true)
        logger.info("Server voice input recording started")
    }

    private func stopServerRecordingAndTranscribe() {
        guard state == .serverListening, let recordingURL else {
            discardServerRecording()
            stopAudio(cancelTask: true)
            state = .idle
            return
        }
        stopAudio(cancelTask: true)
        state = .transcribing
        liveTranscript = ""
        beginTranscription(recordingURL: recordingURL)
    }

    private func beginTranscription(recordingURL: URL) {
        let transcriptionID = UUID()
        activeTranscriptionID = transcriptionID
        transcriptionTask = Task { [weak self] in
            await self?.finishServerRecording(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID
            )
        }
    }

    private func finishServerRecording(recordingURL: URL, transcriptionID: UUID) async {
        await waitUntilResumed()
        guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            return
        }

        guard let transcribe else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(
                String(localized: "Server speech-to-text is not configured."),
                logCategory: .speechUnavailable
            )
            return
        }

        let fileSize: Int
        do {
            fileSize = try Self.serverRecordingFileSize(at: recordingURL)
        } catch {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(error.localizedDescription, logCategory: .speechUnavailable)
            return
        }

        let audioData: Data?
        do {
            audioData = try Self.loadServerRecordingForUpload(
                fileSize: fileSize,
                dataLoader: {
                    try Data(contentsOf: recordingURL)
                }
            )
        } catch {
            await fallbackFromServerFailure(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID,
                message: error.localizedDescription
            )
            return
        }

        guard let audioData else {
            await fallbackFromServerFailure(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID,
                message: CocoaError(.fileReadTooLarge).localizedDescription
            )
            return
        }

        do {
            let response = try await transcribe(audioData, recordingURL.lastPathComponent)

            await waitUntilResumed()
            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            let transcript = response.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // An empty transcript the transcriber reports as a success is silence: a Hermes
            // host's `{ok: true, transcript: ""}` (#1071). Nothing to insert, nothing failed.
            // webui's transcriber drops `ok` from an empty reply, so webui still fails it.
            guard !transcript.isEmpty || (response.ok == true && response.error == nil) else {
                await fallbackFromServerFailure(
                    recordingURL: recordingURL,
                    transcriptionID: transcriptionID,
                    message: response.error ?? String(localized: "Transcription returned no text.")
                )
                return
            }
            if !transcript.isEmpty {
                liveTranscript = transcript
                writeTranscript(transcript)
            }
            stopAcceptingDraftUpdates()
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            state = .idle
            suppressNextRecognitionError = false
        } catch {
            await waitUntilResumed()
            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            await fallbackFromServerFailure(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID,
                message: error.localizedDescription
            )
        }
    }

    private func fallbackFromServerFailure(
        recordingURL: URL,
        transcriptionID: UUID,
        message: String
    ) async {
        guard ComposerSTTProviderPolicy.fallbackProvider(
            after: .server,
            preference: providerPreference,
            serverConfigured: transcribe != nil,
            onDeviceSupported: onDeviceSpeechRecognizerForRecording() != nil
        ) == .onDevice,
              let speechRecognizer = onDeviceSpeechRecognizerForRecording()
        else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(message, logCategory: .speechUnavailable)
            return
        }

        await waitUntilResumed()
        guard isActiveTranscription(transcriptionID), !Task.isCancelled else { return }
        let speechStatus = await requestSpeechAuthorization()
        guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            return
        }
        guard speechStatus == .authorized else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(Self.speechAuthorizationMessage(for: speechStatus), logCategory: .speechAuthorization)
            return
        }

        do {
            let transcript = try await recognizeRecordedFile(
                recordingURL,
                speechRecognizer: speechRecognizer
            )
            await waitUntilResumed()
            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            liveTranscript = transcript
            guard !transcript.isEmpty else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                fail(
                    String(localized: "Transcription returned no text."),
                    logCategory: .speechUnavailable
                )
                return
            }
            writeTranscript(transcript)
            stopAcceptingDraftUpdates()
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            state = .idle
            suppressNextRecognitionError = false
        } catch {
            await waitUntilResumed()
            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(error.localizedDescription, logCategory: .speechUnavailable)
        }
    }

    private func recognizeRecordedFile(
        _ recordingURL: URL,
        speechRecognizer: any ComposerSpeechRecognizing
    ) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = SFSpeechURLRecognitionRequest(url: recordingURL)
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = false

                let resumeBox = SpeechRecognitionContinuationBox()
                recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, !resumeBox.didResume else { return }

                        if let error {
                            resumeBox.didResume = true
                            self.recognitionTask = nil
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let result, result.isFinal else { return }
                        let transcript = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        resumeBox.didResume = true
                        self.recognitionTask = nil
                        continuation.resume(returning: transcript)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
        }
    }

    private func isActiveTranscription(_ transcriptionID: UUID) -> Bool {
        activeTranscriptionID == transcriptionID
    }

    private func cleanupRecordingFile(_ recordingURL: URL, transcriptionID: UUID) {
        try? FileManager.default.removeItem(at: recordingURL)
        if isActiveTranscription(transcriptionID) {
            self.recordingURL = nil
            activeTranscriptionID = nil
            transcriptionTask = nil
        }
    }

    private func startRecognition(speechRecognizer: any ComposerSpeechRecognizing) throws {
        stopAudio(cancelTask: true)
        logger.info("Voice input audio startup preparing")

        guard mayRecord() else {
            throw ComposerVoiceInputError.appNotActive
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            ComposerVoiceAudioSessionConfiguration.category,
            mode: ComposerVoiceAudioSessionConfiguration.mode,
            options: ComposerVoiceAudioSessionConfiguration.options
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        activatedAudioSessionForRecording = true
        logger.info(
            "Voice input audio session active inputAvailable=\(audioSession.isInputAvailable, privacy: .public) sampleRate=\(audioSession.sampleRate, privacy: .public) inputChannels=\(audioSession.inputNumberOfChannels, privacy: .public)"
        )
        try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
            isInputAvailable: audioSession.isInputAvailable,
            sampleRate: audioSession.sampleRate,
            inputNumberOfChannels: audioSession.inputNumberOfChannels
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        let audioEngine = audioEngineFactory()
        self.audioEngine = audioEngine
        try ComposerVoiceInputStartPolicy.validateAudioEngine(isRunning: audioEngine.isRunning)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        try ComposerVoiceInputPreflight.validate(recordingFormat: recordingFormat)
        logger.info(
            "Voice input installing audio tap sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
        )
        let onDeviceDecibels = onDeviceDecibels
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
            let decibels = ComposerVoiceLevelMeter.decibels(of: buffer)
            onDeviceDecibels.withLock { $0 = decibels }
        }
        audioTapInstalled = true
        logger.info("Voice input audio tap installed")

        audioEngine.prepare()

        let id = UUID()
        recognitionID = id
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.recognitionID == id else { return }
                self.handleRecognition(result: result, error: error)
            }
        }

        try audioEngine.start()
        ownsAudioCapture = true
        ComposerAudioCaptureState.shared.setCapturing(true)
        logger.info("Voice input audio engine started")
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            liveTranscript = result.bestTranscription.formattedString
            guard writeTranscript(liveTranscript) else {
                stopKeepingTranscript()
                return
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

    /// Writes one result into the span this dictation owns. Returns false when the
    /// draft changed underneath it: the draft and caret stay as they are, and no
    /// later result is written.
    @discardableResult
    private func writeTranscript(_ transcript: String) -> Bool {
        guard let draftState, let updateDraft else { return true }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let update = draftUpdateSession.update(for: transcript, current: draftState()) else {
            stopAcceptingDraftUpdates()
            errorMessage = String(localized: "Dictation stopped because the draft changed.")
            return false
        }
        updateDraft(update)
        return true
    }

    private func stopAcceptingDraftUpdates() {
        draftUpdateSession.stopAcceptingUpdates()
        draftState = nil
        updateDraft = nil
    }

    // MARK: - Metering

    /// Samples the mic for the waveform, only while a capture runs.
    private func startMetering() {
        meteringTask?.cancel()
        levelMeter.reset()
        captureStartedAt = Date()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ComposerVoiceLevelMeter.sampleInterval)
                guard let self, !Task.isCancelled else { return }
                let decibels = self.state == .serverListening
                    ? self.serverRecorder.decibels
                    : self.onDeviceDecibels.withLock { $0 }
                self.levelMeter.push(decibels: decibels)
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        captureStartedAt = nil
        onDeviceDecibels.withLock { $0 = nil }
    }

    private func stopAudio(cancelTask: Bool) {
        recognitionID = nil
        recordingLease.release()
        if ownsAudioCapture {
            ownsAudioCapture = false
            ComposerAudioCaptureState.shared.setCapturing(false)
        }

        serverRecorder.onFinish = nil
        serverRecorder.stop()

        if let audioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
                logger.info("Voice input audio engine stopped")
            }

            if audioTapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioTapInstalled = false
                logger.info("Voice input audio tap removed")
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

        if activatedAudioSessionForRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedAudioSessionForRecording = false
            logger.info("Voice input audio session deactivated")
        }
    }

    private func discardServerRecording() {
        serverRecorder.onFinish = nil
        serverRecorder.stop()

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    private func cancelServerTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeTranscriptionID = nil
        resumeWaiter?.resume()
        resumeWaiter = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    /// The on-device recognizer for the first dictation locale candidate that
    /// has a model, cached for the controller's lifetime. Live dictation and
    /// the server-failure file fallback both record through this pick.
    private func onDeviceSpeechRecognizerForRecording() -> (any ComposerSpeechRecognizing)? {
        if let speechRecognizer {
            return speechRecognizer.supportsOnDeviceRecognition ? speechRecognizer : nil
        }

        let speechRecognizer = ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: .current,
                preferredLanguages: Locale.preferredLanguages
            ),
            supportedLocales: supportedLocales()
        ) { locale -> (any ComposerSpeechRecognizing)? in
            guard let recognizer = self.speechRecognizerFactory(locale),
                  recognizer.supportsOnDeviceRecognition
            else { return nil }
            return recognizer
        }
        self.speechRecognizer = speechRecognizer
        return speechRecognizer
    }

    private func fail(_ message: String, logCategory: VoiceInputFailureLogCategory) {
        logger.error("Voice input failed category=\(logCategory.rawValue, privacy: .public)")
        suppressNextRecognitionError = false
        stopAcceptingDraftUpdates()
        cancelServerTranscription()
        discardServerRecording()
        stopAudio(cancelTask: true)
        state = .idle
        errorMessage = message
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await speechAuthorization()
    }

    private func requestMicrophonePermission() async -> Bool {
        await microphonePermission()
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
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }

    private static func logCategory(for error: Error) -> VoiceInputFailureLogCategory {
        guard let voiceError = error as? ComposerVoiceInputError else {
            return .audioStartup
        }

        switch voiceError {
        case .noAudioInput:
            return .noAudioInput
        case .invalidInputFormat:
            return .invalidInputFormat
        case .appNotActive:
            return .appNotActive
        case .audioEngineAlreadyRunning, .audioRecorderStartFailed:
            return .audioEngineAlreadyRunning
        }
    }
}

private final class SpeechRecognitionContinuationBox {
    var didResume = false
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
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetooth]
}

enum ComposerVoiceInputError: LocalizedError {
    case noAudioInput
    case invalidInputFormat
    case appNotActive
    case audioEngineAlreadyRunning
    case audioRecorderStartFailed

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            return String(localized: "No microphone input is available. Check the Simulator or device microphone settings.")
        case .invalidInputFormat:
            return String(localized: "Voice input is not available because the microphone input format is invalid.")
        case .appNotActive:
            return String(localized: "Voice input can start only while Hermex is active.")
        case .audioEngineAlreadyRunning:
            return String(localized: "Voice input is already preparing the microphone. Try again in a moment.")
        case .audioRecorderStartFailed:
            return String(localized: "Voice input could not start recording. Try again in a moment.")
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

/// Chooses the dictation language. `Locale.current` (app language plus device
/// region) stays first so users whose dictation already works keep the same
/// recognizer; the user's preferred languages and `en-US` cover regions whose
/// pairing has no on-device model, such as `en_PK`.
enum ComposerSpeechLocalePolicy {
    static let preferredLanguageLimit = 3
    static let lastResortIdentifier = "en-US"

    /// `current`, then the first few distinct preferred languages, then `en-US`,
    /// deduplicated by normalized identifier. Duplicates of `current` (usually
    /// the first preferred language) do not use up a preferred-language slot.
    static func candidates(current: Locale, preferredLanguages: [String]) -> [Locale] {
        let leading = distinct([current.identifier] + preferredLanguages).prefix(1 + preferredLanguageLimit)
        return distinct(leading + [lastResortIdentifier]).map(Locale.init(identifier:))
    }

    /// Walks `candidates` in order and returns the first `recognizer` result.
    /// `recognizer` is called only for candidates listed in `supportedLocales`,
    /// with the supported locale itself, and returns nil when that locale has
    /// no on-device model. An exact identifier match wins over a language plus
    /// region match, so `hi-IN` never resolves to `hi-IN-translit`.
    static func firstAvailable<Recognizer>(
        in candidates: [Locale],
        supportedLocales: Set<Locale>,
        recognizer: (Locale) -> Recognizer?
    ) -> Recognizer? {
        // Sorted so collisions resolve the same way on every launch.
        let supported = supportedLocales.sorted { $0.identifier < $1.identifier }
        let byExactIdentifier = Dictionary(
            supported.map { (exactIdentifier($0.identifier), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let byLanguageAndRegion = Dictionary(
            supported.map { (normalizedIdentifier($0.identifier), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for candidate in candidates {
            let match = byExactIdentifier[exactIdentifier(candidate.identifier)]
                ?? byLanguageAndRegion[normalizedIdentifier(candidate.identifier)]
            if let match, let result = recognizer(match) {
                return result
            }
        }
        return nil
    }

    /// Language plus region, lowercased: `en_US`, `en-US`, and `en_US@rg=pkzzzz`
    /// all normalize to `en-us`, and `zh-Hans-CN` to `zh-cn`, because
    /// `SFSpeechRecognizer.supportedLocales()` lists Chinese without a script.
    /// An identifier without a region (`en`) keeps its exact form.
    static func normalizedIdentifier(_ identifier: String) -> String {
        let language = Locale(identifier: identifier).language
        if let code = language.languageCode?.identifier, let region = language.region?.identifier {
            return "\(code)-\(region)".lowercased()
        }
        return exactIdentifier(identifier)
    }

    /// The identifier without any `@…` keywords, with `-` separators, lowercased.
    private static func exactIdentifier(_ identifier: String) -> String {
        let base = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? identifier
        return base.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func distinct<Identifiers: Sequence<String>>(_ identifiers: Identifiers) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert(normalizedIdentifier($0)).inserted }
    }
}

enum ComposerVoiceInputStartPolicy {
    static func canStart(appIsActive: Bool, appIsLocked: Bool = false) -> Bool {
        appIsActive && !appIsLocked
    }

    static func validateAudioSessionInput(
        isInputAvailable: Bool,
        sampleRate: Double,
        inputNumberOfChannels: Int
    ) throws {
        guard isInputAvailable else {
            throw ComposerVoiceInputError.noAudioInput
        }

        try ComposerVoiceInputPreflight.validate(
            sampleRate: sampleRate,
            channelCount: UInt32(max(inputNumberOfChannels, 0))
        )
    }

    static func validateAudioEngine(isRunning: Bool) throws {
        guard !isRunning else {
            throw ComposerVoiceInputError.audioEngineAlreadyRunning
        }
    }
}

enum ComposerVoiceInputPreflight {
    static let validSampleRateRange: ClosedRange<Double> = 8_000...192_000
    static let validChannelCountRange: ClosedRange<UInt32> = 1...16

    static func validate(sampleRate: Double, channelCount: UInt32) throws {
        guard sampleRate.isFinite,
              validSampleRateRange.contains(sampleRate),
              validChannelCountRange.contains(channelCount)
        else {
            throw ComposerVoiceInputError.invalidInputFormat
        }
    }

    static func validate(recordingFormat: AVAudioFormat) throws {
        try validate(
            sampleRate: recordingFormat.sampleRate,
            channelCount: recordingFormat.channelCount
        )
    }
}

/// The draft as the composer holds it right now.
struct ComposerVoiceDraftState {
    let text: String
    let selection: ComposerSelection
}

/// One accepted dictation write: the new draft and where the caret goes in it.
struct ComposerVoiceDraftUpdate: Equatable {
    let text: String
    let caret: NSRange
}

enum ComposerVoiceDraftComposer {
    /// Replaces `range` with the trimmed transcript, leaving everything outside it
    /// alone, and puts the caret after what it wrote. Nil when `range` is out of
    /// bounds or splits a composed character.
    static func replacing(_ range: NSRange, in text: String, with transcript: String) -> ComposerVoiceDraftUpdate? {
        let draft = text as NSString
        guard range.location >= 0, range.length >= 0, range.upperBound <= draft.length,
              isCharacterBoundary(range.location, in: draft),
              isCharacterBoundary(range.upperBound, in: draft)
        else { return nil }

        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = transcript.first, let last = transcript.last else { return nil }

        let before = range.location > 0 ? character(at: range.location - 1, in: draft) : nil
        let after = range.upperBound < draft.length ? character(at: range.upperBound, in: draft) : nil
        let leading = before.map { needsSpace(between: $0, and: first) } == true ? " " : ""
        let trailing = after.map { needsSpace(between: last, and: $0) } == true ? " " : ""

        let insertion = leading + transcript + trailing
        return ComposerVoiceDraftUpdate(
            text: draft.replacingCharacters(in: range, with: insertion),
            caret: NSRange(location: range.location + (insertion as NSString).length, length: 0)
        )
    }

    /// A bounded spacing policy, not script detection: word-like text gets a space
    /// from its neighbour, except beside Chinese or Japanese text, after opening
    /// punctuation and before closing punctuation. No transcript locale is assumed.
    private static func needsSpace(between left: Character, and right: Character) -> Bool {
        guard !isUnspacedScript(left), !isUnspacedScript(right) else { return false }
        let endsWord = left.isLetter || left.isNumber || left.isSymbol || ".,;:!?)]}\u{201D}\u{2019}\u{2026}".contains(left)
        // `/`, `@` and `#` start the chips and references a draft can hold.
        let startsWord = right.isLetter || right.isNumber || right.isSymbol || "/@#([{\u{201C}\u{2018}".contains(right)
        return endsWord && startsWord
    }

    private static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x303F, // CJK radicals, symbols and punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF00...0xFFEF, // Halfwidth and fullwidth forms
             0x20000...0x3FFFF: // CJK supplementary planes
            return true
        default:
            return false
        }
    }

    private static func isCharacterBoundary(_ index: Int, in text: NSString) -> Bool {
        index == text.length || text.rangeOfComposedCharacterSequence(at: index).location == index
    }

    private static func character(at index: Int, in text: NSString) -> Character? {
        text.substring(with: text.rangeOfComposedCharacterSequence(at: index)).first
    }
}

/// The span of the draft one dictation owns.
///
/// Every result replaces that span rather than rebuilding the draft from a base
/// string, and only while the draft is still exactly what this session last left.
/// Voice writes never publish a generation, so a user edit, including an edit
/// undone back to identical text, is what moves it. A write from anywhere else
/// shows up in the text. A caret that merely moved does not stop dictation.
struct ComposerVoiceDraftUpdateSession {
    private struct Ownership {
        let original: ComposerVoiceDraftUpdate
        let generation: Int
        var expectedText: String
        var range: NSRange
    }

    private var ownership: Ownership?

    mutating func begin(_ draft: ComposerVoiceDraftState) {
        ownership = Ownership(
            original: ComposerVoiceDraftUpdate(text: draft.text, caret: draft.selection.range),
            generation: draft.selection.publishGeneration,
            expectedText: draft.text,
            range: draft.selection.range
        )
    }

    mutating func stopAcceptingUpdates() {
        ownership = nil
    }

    /// The draft with `transcript` in the owned span, or nil when the draft is no
    /// longer this session's to write.
    mutating func update(for transcript: String, current: ComposerVoiceDraftState) -> ComposerVoiceDraftUpdate? {
        guard var ownership, Self.isUnchanged(current, since: ownership),
              let update = ComposerVoiceDraftComposer.replacing(ownership.range, in: current.text, with: transcript)
        else { return nil }

        ownership.expectedText = update.text
        ownership.range.length = update.caret.location - ownership.range.location
        self.ownership = ownership
        return update
    }

    /// The draft from before this session's first write, or nil when nothing was
    /// written or the draft has since moved on.
    func restoredDraft(current: ComposerVoiceDraftState) -> ComposerVoiceDraftUpdate? {
        guard let ownership, Self.isUnchanged(current, since: ownership),
              current.text != ownership.original.text
        else { return nil }
        return ownership.original
    }

    private static func isUnchanged(_ current: ComposerVoiceDraftState, since ownership: Ownership) -> Bool {
        current.text == ownership.expectedText
            && current.selection.publishGeneration == ownership.generation
    }
}

/// The dictation row's waveform: recent mic levels, newest last.
@MainActor
@Observable
final class ComposerVoiceLevelMeter {
    static let sampleInterval = Duration.milliseconds(80)
    private static let sampleCount = 64
    private static let noiseFloorDecibels: Float = -60

    private(set) var levels = [Float](repeating: 0, count: sampleCount)

    func reset() {
        levels = [Float](repeating: 0, count: Self.sampleCount)
    }

    func push(decibels: Float?) {
        levels.removeFirst()
        levels.append(Self.level(decibels: decibels))
    }

    /// Maps decibels to 0...1, on a square root so quiet speech still shows.
    private static func level(decibels: Float?) -> Float {
        guard let decibels, decibels.isFinite, decibels > noiseFloorDecibels else { return 0 }
        guard decibels < 0 else { return 1 }
        let floor = pow(10, noiseFloorDecibels / 20)
        return ((pow(10, decibels / 20) - floor) / (1 - floor)).squareRoot()
    }

    /// One audio buffer's level. Runs on the audio thread.
    nonisolated static func decibels(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : nil
    }
}

private extension Logger {
    static let hermesVoiceInput = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "VoiceInput"
    )
}

/// A recording-only lease. Permission prompts, deferred clips and transcription never
/// hold it. The UIKit adapter below is separate so restoration can be tested without
/// changing the test host's orientation or idle timer.
@MainActor
final class ComposerDictationLease {
    private let readIdle: () -> Bool
    private let writeIdle: (Bool) -> Void
    private let writeOrientation: (UIInterfaceOrientationMask?) -> Void
    private var previousIdle: Bool?
    private weak var scene: UIWindowScene?
    private static var lockedSceneID: String?
    private static var lockedOrientation: UIInterfaceOrientationMask?

    init(readIdle: @escaping () -> Bool, writeIdle: @escaping (Bool) -> Void,
         writeOrientation: @escaping (UIInterfaceOrientationMask?) -> Void) {
        self.readIdle = readIdle
        self.writeIdle = writeIdle
        self.writeOrientation = writeOrientation
    }

    static func live() -> ComposerDictationLease {
        ComposerDictationLease(
            readIdle: { UIApplication.shared.isIdleTimerDisabled },
            writeIdle: { UIApplication.shared.isIdleTimerDisabled = $0 },
            writeOrientation: { mask in lockedOrientation = mask }
        )
    }

    func acquire() {
        guard previousIdle == nil else { return }
        scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else { return }
        Self.lockedSceneID = scene.session.persistentIdentifier
        acquire(isPhone: scene.traitCollection.userInterfaceIdiom == .phone,
                orientation: scene.interfaceOrientation)
        invalidateOrientation()
    }

    func acquire(isPhone: Bool, orientation: UIInterfaceOrientation) {
        guard isPhone, previousIdle == nil else { return }
        previousIdle = readIdle()
        writeIdle(true)
        let mask: UIInterfaceOrientationMask
        switch orientation {
        case .landscapeLeft: mask = .landscapeLeft
        case .landscapeRight: mask = .landscapeRight
        case .portraitUpsideDown: mask = .portraitUpsideDown
        default: mask = .portrait
        }
        writeOrientation(mask)
    }

    func release() {
        guard let previousIdle else { return }
        self.previousIdle = nil
        writeIdle(previousIdle)
        writeOrientation(nil)
        invalidateOrientation()
        scene = nil
    }

    static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        if let scene = window?.windowScene,
           scene.session.persistentIdentifier == lockedSceneID, let lockedOrientation {
            return lockedOrientation
        }
        // Matches Info.plist's normal iPhone/iPad policy. UIKit still intersects
        // this with the presented controller's supported orientations.
        return window?.traitCollection.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    private func invalidateOrientation() {
        for window in scene?.windows ?? [] {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

/// The part of `SFSpeechRecognizer` dictation uses, so tests can stand in a
/// recognizer without the simulator's speech service.
protocol ComposerSpeechRecognizing: AnyObject {
    var supportsOnDeviceRecognition: Bool { get }
    func recognitionTask(
        with request: SFSpeechRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, (any Error)?) -> Void
    ) -> SFSpeechRecognitionTask
}

extension SFSpeechRecognizer: ComposerSpeechRecognizing {}

/// Owns the physical server-STT recorder and its audio session. The controller owns
/// the returned file, including retention across inactivity and eventual deletion.
@MainActor
protocol ComposerServerRecording: AnyObject {
    var onFinish: (() -> Void)? { get set }
    /// The mic's current level, or nil when the recorder has none to report.
    var decibels: Float? { get }
    func start() throws -> URL
    func stop()
}

@MainActor
private final class ComposerServerAudioRecorder: NSObject, ComposerServerRecording, AVAudioRecorderDelegate {
    var onFinish: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var ownsAudioSession = false

    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermex-composer-stt-\(UUID().uuidString)")
            .appendingPathExtension(ComposerVoiceInputController.serverRecordingFileExtension)
        do {
            try session.setCategory(ComposerVoiceAudioSessionConfiguration.category,
                                    mode: ComposerVoiceAudioSessionConfiguration.mode,
                                    options: ComposerVoiceAudioSessionConfiguration.options)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            ownsAudioSession = true
            try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
                isInputAvailable: session.isInputAvailable, sampleRate: session.sampleRate,
                inputNumberOfChannels: session.inputNumberOfChannels)
            let recorder = try AVAudioRecorder(url: url, settings: ComposerVoiceInputController.serverRecordingSettings)
            self.recorder = recorder
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else { throw ComposerVoiceInputError.audioRecorderStartFailed }
            return url
        } catch {
            stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    var decibels: Float? {
        guard let recorder else { return nil }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.onFinish?()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.onFinish?()
        }
    }

    func stop() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
}
