import Foundation
import Speech
import UIKit
import WatchShared

/// A watch voice note is transcribed on the iPhone, using the same provider
/// order as the composer. The watch never sees a server credential, and this
/// path does not ask for speech permission: a locked phone cannot show that
/// prompt, so on-device recognition runs only when it is already allowed.
enum WatchVoiceNoteTranscription {
    static func speechAlreadyAuthorized() async -> Bool {
        await MainActor.run {
            SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    /// A non-empty server transcript is the result. `error` is part of the
    /// response the caller already decoded; it does not discard text the
    /// server managed to return. Empty text fails this provider.
    static func serverTranscriptText(transcript: String?, error _: String?) -> String? {
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    static func transcript(
        preference: ComposerSTTProviderPreference,
        speechAuthorized: Bool,
        onDeviceSupported: Bool,
        server: () async throws -> String,
        onDevice: () async throws -> String
    ) async throws -> String {
        let providers = ComposerSTTProviderPolicy.orderedProviders(
            preference: preference,
            serverConfigured: true,
            onDeviceSupported: speechAuthorized && onDeviceSupported
        )
        var lastError: Error = WatchCompanionError.backend(.invalidResponse)
        guard !providers.isEmpty else { throw lastError }
        for provider in providers {
            try Task.checkCancellation()
            let text: String
            do {
                text = try await providerText(from: provider, server: server, onDevice: onDevice)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                continue
            }
            try Task.checkCancellation()
            if !text.isEmpty { return text }
            lastError = WatchCompanionError.backend(.invalidResponse)
        }
        throw lastError
    }

    @MainActor
    static func recognizeOnDevice(data: Data) async throws -> String {
        try await OnDeviceVoiceSession().recognize(data: data)
    }

    fileprivate static func recognizer() -> SFSpeechRecognizer? {
        ComposerSpeechLocalePolicy.firstAvailable(
            in: ComposerSpeechLocalePolicy.candidates(
                current: .current,
                preferredLanguages: Locale.preferredLanguages
            ),
            supportedLocales: Set(SFSpeechRecognizer.supportedLocales()),
            recognizer: { locale in
                guard let recognizer = SFSpeechRecognizer(locale: locale),
                      recognizer.supportsOnDeviceRecognition else { return nil }
                return recognizer
            }
        )
    }

    private static func providerText(
        from provider: ComposerSTTProvider,
        server: () async throws -> String,
        onDevice: () async throws -> String
    ) async throws -> String {
        let raw = switch provider {
        case .server: try await server()
        case .onDevice: try await onDevice()
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// On-device recognition for one watch clip. Speech calls stay on the main
/// actor, the continuation resumes once, and background time ending fails
/// this attempt instead of leaving the watch on Sending.
@MainActor
private final class OnDeviceVoiceSession {
    private var request: SFSpeechURLRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private var cancelRequested = false
    private var expired = false
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    func recognize(data: Data) async throws -> String {
        try Task.checkCancellation()
        guard !data.isEmpty,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = WatchVoiceNoteTranscription.recognizer()
        else {
            throw WatchCompanionError.backend(.invalidResponse)
        }

        beginBackgroundTask()
        defer { endBackgroundTask() }
        if expired { throw WatchCompanionError.backend(.timeout) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermex-watch-\(UUID().uuidString).m4a")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.start(url: url, recognizer: recognizer, continuation: continuation)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel()
            }
        }
    }

    private func start(
        url: URL,
        recognizer: SFSpeechRecognizer,
        continuation: CheckedContinuation<String, Error>
    ) {
        self.continuation = continuation
        if cancelRequested || Task.isCancelled {
            scheduleFinish(.failure(CancellationError()))
            return
        }
        if expired {
            scheduleFinish(.failure(WatchCompanionError.backend(.timeout)))
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        self.request = request
        let started = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handle(result: result, error: error)
            }
        }
        task = started
        if cancelRequested || expired {
            started.cancel()
        }
    }

    private func cancel() {
        cancelRequested = true
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    /// Background time ran out. This is not a user cancel, so the caller can
    /// still try the next provider.
    private func expire() {
        expired = true
        task?.cancel()
        if cancelRequested {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(WatchCompanionError.backend(.timeout)))
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if cancelRequested {
            finish(.failure(CancellationError()))
            return
        }
        if let result, result.isFinal {
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || error == nil {
                finish(.success(text))
                return
            }
        }
        if let error {
            finish(.failure(expired ? WatchCompanionError.backend(.timeout) : error))
        }
    }

    /// Resumes after `withCheckedThrowingContinuation` has suspended. Resuming
    /// inside `start` traps.
    private func scheduleFinish(_ result: Result<String, Error>) {
        Task { @MainActor in
            self.finish(result)
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        task?.cancel()
        task = nil
        request = nil
        self.continuation = nil
        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func beginBackgroundTask() {
        backgroundToken = UIApplication.shared.beginBackgroundTask(withName: "hermex.watch.voice") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expire()
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        let token = backgroundToken
        backgroundToken = .invalid
        guard token != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token)
    }
}
