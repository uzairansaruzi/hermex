import Foundation
import HermexCore

public struct HermexPlatformCoordinator: Sendable {
    private let services: HermexPlatformServiceBundle

    public init(services: HermexPlatformServiceBundle) {
        self.services = services
    }

    @MainActor
    public func consumePendingShare(into store: HermexAppStore) async {
        guard let shareIngress = services.shareIngress else { return }
        do {
            guard let draft = try await shareIngress.pendingSharedDraft() else { return }
            await store.send(.applySharedDraft(draft))
            try await shareIngress.clearPendingSharedDraft()
        } catch {
            await store.send(.appendDraftText("Share import failed: \(error)"))
        }
    }

    @MainActor
    public func hydrateCachedSessions(serverID: String, into store: HermexAppStore) async {
        guard let cache = services.cache else { return }
        do {
            let sessions = try await cache.cachedSessions(for: serverID)
            guard !sessions.isEmpty else { return }
            await store.send(.hydrateCachedSessions(sessions))
        } catch {
            await store.send(.appendDraftText("Offline cache unavailable: \(error)"))
        }
    }

    @MainActor
    public func hydrateCachedMessages(sessionID: String, serverID: String, into store: HermexAppStore) async {
        guard let cache = services.cache else { return }
        do {
            let messages = try await cache.cachedMessages(sessionID: sessionID, serverID: serverID)
            guard !messages.isEmpty else { return }
            await store.send(.hydrateCachedMessages(sessionID: sessionID, messages))
        } catch {
            await store.send(.appendDraftText("Offline transcript unavailable: \(error)"))
        }
    }

    @MainActor
    public func cacheSessions(serverID: String, from store: HermexAppStore) async {
        guard let cache = services.cache else { return }
        try? await cache.replaceCachedSessions(store.sessions.sessions, for: serverID)
    }

    @MainActor
    public func cacheMessages(serverID: String, from store: HermexAppStore) async {
        guard let cache = services.cache, let sessionID = store.appState.selectedSessionID else { return }
        try? await cache.replaceCachedMessages(store.chat.messages, sessionID: sessionID, serverID: serverID)
    }

    @MainActor
    public func startVoiceRecording(in store: HermexAppStore) async {
        guard let recorder = services.voiceRecorder else { return }
        do {
            try await recorder.start()
            await store.send(.setVoiceRecording(true))
        } catch {
            await store.send(.appendDraftText("Voice recording failed: \(error)"))
        }
    }

    @MainActor
    public func stopVoiceRecordingAndTranscribe(into store: HermexAppStore) async {
        guard let recorder = services.voiceRecorder else { return }
        do {
            let url = try await recorder.stop()
            await store.send(.setVoiceRecording(false))
            guard let transcriber = services.audioTranscriber else { return }
            let response = try await transcriber.transcribeAudio(at: url)
            if let transcript = response.transcript, !transcript.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                await store.send(.appendDraftText(transcript))
            } else if let error = response.error {
                await store.send(.appendDraftText("Transcription failed: \(error)"))
            }
        } catch {
            await store.send(.setVoiceRecording(false))
            await store.send(.appendDraftText("Transcription failed: \(error)"))
        }
    }

    @MainActor
    public func cancelVoiceRecording(in store: HermexAppStore) async {
        guard let recorder = services.voiceRecorder else { return }
        await recorder.cancel()
        await store.send(.setVoiceRecording(false))
    }

    @MainActor
    public func speakLatestAssistantMessage(from store: HermexAppStore) async {
        guard let speech = services.speechSynthesizer else { return }
        guard let text = store.chat.messages.reversed().first(where: { $0.role == "assistant" })?.contentOrText else { return }
        await speech.speak(text)
    }

    @MainActor
    public func syncStatusNotification(from store: HermexAppStore) async {
        guard let notifier = services.statusNotifier, let sessionID = store.appState.selectedSessionID else { return }
        if store.chat.stream.isStreaming {
            await notifier.showRunning(
                sessionID: sessionID,
                streamID: store.chat.stream.streamID,
                preview: store.chat.messages.last?.contentOrText
            )
        } else {
            await notifier.showComplete(sessionID: sessionID)
        }
    }

    @MainActor
    public func applyStreamEvents(_ events: [HermexSSEEvent], into store: HermexAppStore) async {
        for event in events {
            await store.send(.applyStreamEvent(event))
        }
    }

    public func clearStatusNotification(sessionID: String) async {
        await services.statusNotifier?.clear(sessionID: sessionID)
    }
}

private extension HermexChatMessageDTO {
    var contentOrText: String? {
        let primary = content?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if let primary, !primary.isEmpty { return primary }
        let fallback = text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }
}
