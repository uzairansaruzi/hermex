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
    private var draftUpdateSession = ComposerVoiceDraftUpdateSession()
    private var updateDraft: ((String) -> Void)?
    /// Reads the composer's live draft. Lets a late transcript detect that the user typed
    /// (or that a send cleared the composer) and skip the write-back instead of clobbering it.
    @ObservationIgnored var readDraft: (() -> String)?
    /// The last value voice wrote into the composer. Survives across sessions so the next
    /// session can tell an untouched leftover transcript from text the user typed.
    private(set) var lastVoiceWrittenDraft: String?
    private var suppressNextRecognitionError = false
    private var activatedAudioSessionForRecording = false
    private var audioTapInstalled = false
    /// Long-lived sample-rate converter for Volcengine capture. AVAudioConverter carries
    /// internal resampling state, so it must outlive individual tap callbacks (a local
    /// variable gets deallocated the moment the setup function returns).
    private var volcengineAudioConverter: AVAudioConverter?
    /// Accumulates downsampled PCM until we have ~200ms, which is Volcengine's optimal packet size.
    private var volcenginePCMAccumulator = Data()
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var serverRecordingTimeoutTask: Task<Void, Never>?
    private var activeTranscriptionID: UUID?
    private let logger = Logger.hermesVoiceInput

    @ObservationIgnored var apiClient: APIClient?
    @ObservationIgnored var providerPreference = ComposerSTTProviderPreference.defaultValue
    @ObservationIgnored var locale = Locale.current
    /// Hot words injected into SFSpeechAudioBufferRecognitionRequest.contextualStrings (iOS 17+).
    @ObservationIgnored var contextualStrings: [String] = []
    /// Called on every partial transcript update (for voice-first silence timer).
    @ObservationIgnored var onPartialTranscript: ((String) -> Void)?
    /// Called when recognition produces a final transcript (isFinal=true). Used by voice-first mode for immediate send.
    @ObservationIgnored var onFinalTranscript: ((String) -> Void)?

    private var volcengineSTT: VolcengineStreamingSTT?

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
        switch state {
        case .serverListening:
            if volcengineSTT != nil {
                // Volcengine streaming: send end-of-audio and stop mic,
                // but keep WebSocket alive so server can return final result.
                // The onCompleted callback will handle full cleanup.
                volcengineSTT?.finishAudio()
                stopAudio(cancelTask: false)
                state = .transcribing
            } else {
                stopServerRecordingAndTranscribe()
            }
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

    func stopBeforeSubmittingDraft() {
        suppressNextRecognitionError = true
        if volcengineSTT != nil {
            stopVolcengineStreaming()
        }
        cancelServerTranscription()
        stopAcceptingDraftUpdates()
        discardServerRecording()
        stopAudio(cancelTask: true)
        state = .idle
    }

    private func start(currentDraft: String, updateDraft: @escaping (String) -> Void) async {
        guard state == .idle else { return }

        logger.info("Voice input start requested")
        errorMessage = nil
        liveTranscript = ""
        suppressNextRecognitionError = false
        cancelServerTranscription()
        discardServerRecording()
        draftUpdateSession.begin(baseDraft: currentDraft)
        self.updateDraft = updateDraft
        state = .requestingPermission

        let canUseServer = apiClient != nil
        let canUseOnDevice = onDeviceSpeechRecognizerForRecording() != nil
        let canUseVolcengine = VolcengineSTTSettings.isConfigured
        let providers = ComposerSTTProviderPolicy.orderedProviders(
            preference: providerPreference,
            serverConfigured: canUseServer,
            onDeviceSupported: canUseOnDevice,
            volcengineConfigured: canUseVolcengine
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

        await start(provider: provider)
    }

    private func start(provider: ComposerSTTProvider) async {
        logger.info("Starting voice input with provider: \(String(describing: provider))")
        switch provider {
        case .server:
            await startServerProvider()
        case .onDevice:
            await startOnDeviceProvider()
        case .volcengineStreaming:
            await startVolcengineProvider()
        }
    }

    private func startServerProvider() async {
        let isMicrophonePermissionGranted = await requestMicrophonePermission()
        logger.info("Server voice input microphone permission completed granted=\(isMicrophonePermissionGranted, privacy: .public)")
        guard state == .requestingPermission else { return }
        guard isMicrophonePermissionGranted else {
            fail(
                String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."),
                logCategory: .microphonePermission
            )
            return
        }

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
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

    // MARK: - Volcengine Streaming STT

    private func startVolcengineProvider() async {
        let isMicrophonePermissionGranted = await requestMicrophonePermission()
        logger.info("Volcengine voice input microphone permission completed granted=\(isMicrophonePermissionGranted, privacy: .public)")
        guard state == .requestingPermission else { return }
        guard isMicrophonePermissionGranted else {
            fail(
                String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."),
                logCategory: .microphonePermission
            )
            return
        }

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
            fail(
                ComposerVoiceInputError.appNotActive.localizedDescription,
                logCategory: .appNotActive
            )
            return
        }

        guard let config = VolcengineSTTSettings.configuration(hotwords: contextualStrings) else {
            await fallbackOrFail(
                from: .volcengineStreaming,
                message: VolcengineSTTError.notConfigured.localizedDescription,
                logCategory: .speechUnavailable
            )
            return
        }

        do {
            try startVolcengineStreaming(configuration: config)
            state = .serverListening
        } catch {
            await fallbackOrFail(
                from: .volcengineStreaming,
                message: error.localizedDescription,
                logCategory: Self.logCategory(for: error)
            )
        }
    }

    private func startVolcengineStreaming(configuration: VolcengineStreamingSTT.Configuration) throws {
        stopAudio(cancelTask: true)
        logger.info("Volcengine streaming STT audio startup preparing")

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            ComposerVoiceAudioSessionConfiguration.category,
            mode: ComposerVoiceAudioSessionConfiguration.mode,
            options: ComposerVoiceAudioSessionConfiguration.options
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        activatedAudioSessionForRecording = true

        try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
            isInputAvailable: audioSession.isInputAvailable,
            sampleRate: audioSession.sampleRate,
            inputNumberOfChannels: audioSession.inputNumberOfChannels
        )

        // Set up Volcengine STT client
        let stt = VolcengineStreamingSTT()
        stt.onPartialResult = { [weak self] text in
            guard let self else { return }
            self.liveTranscript = text
            self.applyTranscriptToDraft(text)
            self.onPartialTranscript?(text)
        }
        stt.onFinalResult = { [weak self] text in
            guard let self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.onFinalTranscript?(self.liveTranscript)
            }
        }
        stt.onCompleted = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let finalText):
                self.logger.info("Volcengine STT completed: \(finalText.prefix(50))")
                if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.liveTranscript = finalText
                    self.applyTranscriptToDraft(finalText)
                }
                self.stopVolcengineStreaming()
            case .failure(let error):
                self.logger.error("Volcengine STT error: \(error.localizedDescription)")
                self.stopVolcengineStreaming()
                self.errorMessage = error.localizedDescription
            }
        }

        // Start audio engine setup (but don't install tap yet — wait for WebSocket to be ready)
        let audioEngine = audioEngineFactory()
        self.audioEngine = audioEngine
        try ComposerVoiceInputStartPolicy.validateAudioEngine(isRunning: audioEngine.isRunning)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        try ComposerVoiceInputPreflight.validate(recordingFormat: recordingFormat)

        // Prepare audio engine but don't start yet
        audioEngine.prepare()

        // Store STT reference and start WebSocket connection.
        // Audio engine will be started once WebSocket is ready (state = .streaming).
        self.volcengineSTT = stt
        stt.onReady = { [weak self] in
            guard let self else { return }
            self.startVolcengineAudioCapture(audioEngine: audioEngine, inputNode: inputNode, recordingFormat: recordingFormat, stt: stt)
        }
        stt.start(configuration: configuration)
        logger.info("Volcengine STT WebSocket connecting, audio engine prepared")
    }

    private func startVolcengineAudioCapture(audioEngine: AVAudioEngine, inputNode: AVAudioInputNode, recordingFormat: AVAudioFormat, stt: VolcengineStreamingSTT) {
        // Target: 16kHz mono 16-bit PCM for Volcengine
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            logger.error("Failed to create target audio format")
            return
        }

        guard let converter = AVAudioConverter(from: recordingFormat, to: targetFormat) else {
            logger.error("Failed to create audio converter from \(recordingFormat.sampleRate)Hz to 16000Hz")
            return
        }
        volcengineAudioConverter = converter
        volcenginePCMAccumulator = Data()

        let sampleRateRatio = targetFormat.sampleRate / recordingFormat.sampleRate
        // 200ms at 16kHz mono 16-bit = 6400 bytes; Volcengine's documented optimum.
        let targetChunkBytes = 6_400

        // The tap format MUST match the input node's hardware format. Passing a different
        // sample rate here throws `IsFormatSampleRateAndChannelCountValid` and crashes the app,
        // so downsampling happens via AVAudioConverter below instead.
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: recordingFormat) { [weak self, weak stt, converter] buffer, _ in
            guard let stt else { return }

            let outputCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * sampleRateRatio)) + 64
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }

            // Each input buffer may only be handed to the converter once; returning it again
            // makes the converter spin or emit garbage.
            var didSupplyInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didSupplyInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didSupplyInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard status == .haveData || status == .inputRanDry, conversionError == nil else { return }
            guard let int16Channel = outputBuffer.int16ChannelData, outputBuffer.frameLength > 0 else { return }

            let chunk = Data(bytes: int16Channel[0], count: Int(outputBuffer.frameLength) * 2)

            Task { @MainActor in
                guard let self else { return }
                self.volcenginePCMAccumulator.append(chunk)
                while self.volcenginePCMAccumulator.count >= targetChunkBytes {
                    let packet = self.volcenginePCMAccumulator.prefix(targetChunkBytes)
                    self.volcenginePCMAccumulator.removeFirst(targetChunkBytes)
                    stt.sendAudioFrame(Data(packet))
                }
            }
        }
        audioTapInstalled = true

        do {
            try audioEngine.start()
            ComposerAudioCaptureState.shared.setCapturing(true)
            logger.info("Volcengine audio engine started — streaming audio frames")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func stopVolcengineStreaming() {
        volcengineSTT?.cancel()
        volcengineSTT = nil
        volcengineAudioConverter = nil
        volcenginePCMAccumulator = Data()
        stopAcceptingDraftUpdates()
        stopAudio(cancelTask: true)
        state = .idle
        suppressNextRecognitionError = false
    }

    private func startOnDeviceProvider() async {
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
        guard state == .requestingPermission else { return }
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
        guard state == .requestingPermission else { return }
        guard isMicrophonePermissionGranted else {
            fail(
                String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."),
                logCategory: .microphonePermission
            )
            return
        }

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
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
        let fallback = ComposerSTTProviderPolicy.fallbackProvider(
            after: failedProvider,
            preference: providerPreference,
            serverConfigured: apiClient != nil,
            onDeviceSupported: onDeviceSpeechRecognizerForRecording() != nil,
            volcengineConfigured: VolcengineSTTSettings.isConfigured
        )

        guard let fallback else {
            fail(message, logCategory: logCategory)
            return
        }

        logger.info("Voice input falling back after \(String(describing: failedProvider), privacy: .public)")
        state = .requestingPermission
        await start(provider: fallback)
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

    private static let maxServerRecordingDuration: UInt64 = 60

    private static let serverRecordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false
    ]

    private func startServerRecording() throws {
        stopAudio(cancelTask: true)
        logger.info("Server voice input audio startup preparing")

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            ComposerVoiceAudioSessionConfiguration.category,
            mode: ComposerVoiceAudioSessionConfiguration.mode,
            options: ComposerVoiceAudioSessionConfiguration.options
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        activatedAudioSessionForRecording = true

        try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
            isInputAvailable: audioSession.isInputAvailable,
            sampleRate: audioSession.sampleRate,
            inputNumberOfChannels: audioSession.inputNumberOfChannels
        )

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermex-composer-stt-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let recorder = try AVAudioRecorder(url: recordingURL, settings: Self.serverRecordingSettings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: recordingURL)
            throw ComposerVoiceInputError.audioRecorderStartFailed
        }

        self.recordingURL = recordingURL
        audioRecorder = recorder
        ComposerAudioCaptureState.shared.setCapturing(true)
        startServerRecordingTimeout()
        logger.info("Server voice input recording started")
    }

    private func startServerRecordingTimeout() {
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxServerRecordingDuration * 1_000_000_000)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.state == .serverListening else { return }
                self.stopServerRecordingAndTranscribe()
            }
        }
    }

    private func stopServerRecordingAndTranscribe() {
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = nil

        guard state == .serverListening,
              let recorder = audioRecorder,
              let recordingURL
        else {
            discardServerRecording()
            stopAudio(cancelTask: true)
            state = .idle
            return
        }

        if recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil
        ComposerAudioCaptureState.shared.setCapturing(false)

        if activatedAudioSessionForRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedAudioSessionForRecording = false
        }

        state = .transcribing
        liveTranscript = ""

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
        guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            return
        }

        guard let apiClient else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(
                String(localized: "Server speech-to-text is not configured."),
                logCategory: .speechUnavailable
            )
            return
        }

        do {
            let audioData = try Data(contentsOf: recordingURL)
            let response = try await apiClient.transcribeAudio(
                data: audioData,
                filename: recordingURL.lastPathComponent
            )

            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            if let transcript = response.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
               !transcript.isEmpty {
                liveTranscript = transcript
                applyTranscriptToDraft(transcript)
                stopAcceptingDraftUpdates()
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                state = .idle
                suppressNextRecognitionError = false
                return
            }

            let serverMessage = response.error ?? String(localized: "Transcription returned no text.")
            await fallbackFromServerFailure(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID,
                message: serverMessage
            )
        } catch {
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
            serverConfigured: apiClient != nil,
            onDeviceSupported: onDeviceSpeechRecognizerForRecording() != nil,
            volcengineConfigured: VolcengineSTTSettings.isConfigured
        ) == .onDevice,
              let speechRecognizer = onDeviceSpeechRecognizerForRecording()
        else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(message, logCategory: .speechUnavailable)
            return
        }

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
            applyTranscriptToDraft(transcript)
            stopAcceptingDraftUpdates()
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            state = .idle
            suppressNextRecognitionError = false
        } catch {
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
        speechRecognizer: SFSpeechRecognizer
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

    private func startRecognition(speechRecognizer: SFSpeechRecognizer) throws {
        stopAudio(cancelTask: true)
        logger.info("Voice input audio startup preparing")

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
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
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
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
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioTapInstalled = true
        logger.info("Voice input audio tap installed")

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
            applyTranscriptToDraft(liveTranscript)
            onPartialTranscript?(liveTranscript)
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
            // In voice-first mode, notify with final transcript before stopping.
            // This allows the caller to auto-send the completed utterance.
            let finalTranscript = liveTranscript
            stopAcceptingDraftUpdates()
            stopAudio(cancelTask: false)
            state = .idle
            suppressNextRecognitionError = false
            if !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onFinalTranscript?(finalTranscript)
            }
        }
    }

    /// Writes `transcript` into the composer unless someone else took ownership of it.
    /// Dropping the write is what keeps a late final transcript from overwriting text the
    /// user typed after releasing the mic, or from re-populating a composer that was
    /// already sent and cleared.
    private func applyTranscriptToDraft(_ transcript: String) {
        guard let composed = draftUpdateSession.composedDraft(
            for: transcript,
            currentDraft: readDraft?()
        ) else { return }

        lastVoiceWrittenDraft = composed
        updateDraft?(composed)
    }

    private func stopAcceptingDraftUpdates() {
        draftUpdateSession.stopAcceptingUpdates()
        updateDraft = nil
    }

    private func stopAudio(cancelTask: Bool) {
        ComposerAudioCaptureState.shared.setCapturing(false)
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = nil

        if let recorder = audioRecorder, recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil

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
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = nil

        if let recorder = audioRecorder, recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    private func cancelServerTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeTranscriptionID = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    private func onDeviceSpeechRecognizerForRecording() -> SFSpeechRecognizer? {
        if let speechRecognizer {
            return speechRecognizer.supportsOnDeviceRecognition ? speechRecognizer : nil
        }

        guard Self.isLocaleSupportedBySpeechRecognizer(locale) else {
            return nil
        }
        let speechRecognizer = speechRecognizerFactory()
        guard speechRecognizer?.supportsOnDeviceRecognition == true else {
            return nil
        }
        self.speechRecognizer = speechRecognizer
        return speechRecognizer
    }

    private static func isLocaleSupportedBySpeechRecognizer(_ locale: Locale) -> Bool {
        let target = normalizedLocaleIdentifier(locale.identifier)
        return SFSpeechRecognizer.supportedLocales().contains { supportedLocale in
            normalizedLocaleIdentifier(supportedLocale.identifier) == target
        }
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
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
    static let mode = AVAudioSession.Mode.videoRecording
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothHFP]
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

enum ComposerVoiceInputStartPolicy {
    static func canStart(appIsActive: Bool) -> Bool {
        appIsActive
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

enum ComposerVoiceDraftComposer {
    static func composedDraft(baseDraft: String, transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return baseDraft
        }

        let trimmedTrailingDraft = baseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrailingDraft.isEmpty else {
            return trimmedTranscript
        }

        return "\(trimmedTrailingDraft) \(trimmedTranscript)"
    }
}

struct ComposerVoiceDraftUpdateSession {
    private var baseDraft = ""
    private var acceptsUpdates = false
    /// The exact value this session last wrote into the composer, so a late result can
    /// tell whether the composer still holds voice's own text.
    private var lastWrittenDraft: String?

    mutating func begin(baseDraft: String) {
        self.baseDraft = baseDraft
        acceptsUpdates = true
        lastWrittenDraft = nil
    }

    mutating func stopAcceptingUpdates() {
        acceptsUpdates = false
    }

    /// Composes the draft to write, or nil when the update must be dropped.
    ///
    /// `currentDraft` is the composer's live value. When it no longer matches what this
    /// session last wrote, something else owns the composer — the user typed into it, or
    /// a send cleared it — and writing `baseDraft + transcript` would clobber that. This
    /// is the window between releasing the mic and the final transcript arriving, where
    /// a late write-back used to overwrite typed text and re-populate a sent composer.
    /// Passing nil skips the check for callers that cannot read the live draft.
    mutating func composedDraft(for transcript: String, currentDraft: String? = nil) -> String? {
        guard acceptsUpdates else {
            return nil
        }

        if let currentDraft, currentDraft != (lastWrittenDraft ?? baseDraft) {
            return nil
        }

        let composed = ComposerVoiceDraftComposer.composedDraft(
            baseDraft: baseDraft,
            transcript: transcript
        )
        lastWrittenDraft = composed
        return composed
    }
}

private extension Logger {
    static let hermesVoiceInput = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "VoiceInput"
    )
}
