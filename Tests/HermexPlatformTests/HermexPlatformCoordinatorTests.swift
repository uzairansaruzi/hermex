import XCTest
@testable import HermexCore
@testable import HermexPlatform

@MainActor
final class HermexPlatformCoordinatorTests: XCTestCase {
    func testConsumePendingShareAppliesDraftAndClearsIngress() async throws {
        let sharedURL = URL(fileURLWithPath: "/tmp/shared-note.txt")
        let shareIngress = ShareIngressProbe(draft: HermexSharedDraft(text: "Imported text", attachmentURLs: [sharedURL]))
        let store = HermexAppStore(environment: .testValue)
        let coordinator = HermexPlatformCoordinator(services: HermexPlatformServiceBundle(shareIngress: shareIngress))

        await coordinator.consumePendingShare(into: store)

        XCTAssertEqual(store.appState.route, .chat)
        XCTAssertEqual(store.appState.pendingSharedDraft, HermexSharedDraft(text: "Imported text", attachmentURLs: [sharedURL]))
        XCTAssertEqual(store.chat.composer.draft, "Imported text")
        XCTAssertEqual(store.chat.composer.attachments.first?.name, "shared-note.txt")
        let didClear = await shareIngress.didClear
        XCTAssertTrue(didClear)
    }

    func testCacheHydrationAndPersistenceRoutesThroughSharedStore() async throws {
        let cache = CacheStoreProbe(
            sessions: [HermexSessionDTO(sessionId: "cached", title: "Cached session", messageCount: 2)],
            messages: [
                HermexChatMessageDTO(role: "user", content: "Hi"),
                HermexChatMessageDTO(role: "assistant", content: "Cached answer")
            ]
        )
        let store = HermexAppStore(environment: .testValue)
        let coordinator = HermexPlatformCoordinator(services: HermexPlatformServiceBundle(cache: cache))

        await coordinator.hydrateCachedSessions(serverID: "server-a", into: store)
        await coordinator.hydrateCachedMessages(sessionID: "cached", serverID: "server-a", into: store)
        await coordinator.cacheSessions(serverID: "server-a", from: store)
        await coordinator.cacheMessages(serverID: "server-a", from: store)
        let replacedSessions = await cache.replacedSessions
        let replacedMessages = await cache.replacedMessages

        XCTAssertEqual(store.sessions.sessions.map(\.id), ["cached"])
        XCTAssertTrue(store.sessions.isViewingCachedData)
        XCTAssertEqual(store.appState.route, .chat)
        XCTAssertEqual(store.appState.selectedSessionID, "cached")
        XCTAssertEqual(store.chat.messages.last?.content, "Cached answer")
        XCTAssertTrue(store.chat.isViewingCachedData)
        XCTAssertEqual(replacedSessions.map(\.id), ["cached"])
        XCTAssertEqual(replacedMessages.last?.content, "Cached answer")
    }

    func testVoiceRecordingTranscribesIntoComposerDraft() async throws {
        let recorder = VoiceRecorderProbe(recordedURL: URL(fileURLWithPath: "/tmp/voice.m4a"))
        let transcriber = AudioTranscriberProbe(response: HermexTranscribeResponse(ok: true, transcript: "voice transcript"))
        let store = HermexAppStore(environment: .testValue)
        let coordinator = HermexPlatformCoordinator(services: HermexPlatformServiceBundle(
            voiceRecorder: recorder,
            audioTranscriber: transcriber
        ))

        await coordinator.startVoiceRecording(in: store)
        XCTAssertTrue(store.chat.composer.isRecordingVoice)
        let didStart = await recorder.didStart
        XCTAssertTrue(didStart)

        await coordinator.stopVoiceRecordingAndTranscribe(into: store)
        let transcribedURL = await transcriber.transcribedURL

        XCTAssertFalse(store.chat.composer.isRecordingVoice)
        XCTAssertEqual(store.chat.composer.draft, "voice transcript")
        XCTAssertEqual(transcribedURL?.lastPathComponent, "voice.m4a")
    }

    func testSpeechAndStatusNotificationsUseLatestChatState() async throws {
        let speech = SpeechSynthesizerProbe()
        let notifier = StatusNotifierProbe()
        let store = HermexAppStore(
            appState: HermexAppState(selectedSessionID: "s1", route: .chat),
            chat: HermexChatState(
                messages: [
                    HermexChatMessageDTO(role: "assistant", content: "Earlier"),
                    HermexChatMessageDTO(role: "assistant", content: "Latest")
                ],
                stream: HermexStreamState(streamID: "stream-1", isStreaming: true)
            ),
            environment: .testValue
        )
        let coordinator = HermexPlatformCoordinator(services: HermexPlatformServiceBundle(
            speechSynthesizer: speech,
            statusNotifier: notifier
        ))

        await coordinator.speakLatestAssistantMessage(from: store)
        await coordinator.syncStatusNotification(from: store)
        await coordinator.clearStatusNotification(sessionID: "s1")
        let running = await notifier.running
        let spokenText = await speech.spokenText
        let clearedSessionID = await notifier.clearedSessionID

        XCTAssertEqual(spokenText, "Latest")
        XCTAssertEqual(running?.sessionID, "s1")
        XCTAssertEqual(running?.streamID, "stream-1")
        XCTAssertEqual(running?.preview, "Latest")
        XCTAssertEqual(clearedSessionID, "s1")
    }

    func testCompletedStatusNotificationWhenStreamIsIdle() async throws {
        let notifier = StatusNotifierProbe()
        let store = HermexAppStore(
            appState: HermexAppState(selectedSessionID: "s1", route: .chat),
            chat: HermexChatState(stream: HermexStreamState(streamID: "stream-1", isStreaming: false)),
            environment: .testValue
        )
        let coordinator = HermexPlatformCoordinator(services: HermexPlatformServiceBundle(statusNotifier: notifier))

        await coordinator.syncStatusNotification(from: store)
        let completedSessionID = await notifier.completedSessionID

        XCTAssertEqual(completedSessionID, "s1")
    }

    func testStreamEventsBridgeIntoSharedStore() async throws {
        let store = HermexAppStore(
            chat: HermexChatState(stream: HermexStreamState(streamID: "stream-1", isStreaming: true)),
            environment: .testValue
        )
        let coordinator = HermexPlatformCoordinator(services: HermexPlatformServiceBundle())

        await coordinator.applyStreamEvents([.token("Hi"), .done(nil)], into: store)

        XCTAssertEqual(store.chat.messages.last?.content, "Hi")
        XCTAssertFalse(store.chat.stream.isStreaming)
    }
}

private extension HermexAppEnvironment {
    static var testValue: HermexAppEnvironment {
        HermexAppEnvironment(
            testServerConnection: { _ in .object(["ok": .bool(true)]) },
            loginToServer: { _, _ in .object(["ok": .bool(true)]) },
            loadSessions: { _, _ in HermexSessionsResponse() },
            loadSession: { _ in HermexSessionResponse() },
            startChat: { sessionID, _, _, _, _, _, _ in
                .object([
                    "session_id": .string(sessionID ?? "s1"),
                    "stream_id": .string("stream-1")
                ])
            },
            cancelStream: { _ in .object(["ok": .bool(true)]) },
            respondApproval: { _, _, _ in .object(["ok": .bool(true)]) },
            respondClarification: { _, _, _ in .object(["ok": .bool(true)]) },
            undoSession: { _ in .object(["ok": .bool(true)]) },
            retrySession: { _ in .object(["ok": .bool(true)]) },
            compressSession: { _, _ in .object(["ok": .bool(true)]) },
            loadModels: { HermexModelsResponse() },
            loadProfiles: { HermexProfilesResponse() },
            loadWorkspaces: { HermexWorkspacesResponse() },
            loadReasoning: { _, _ in HermexReasoningResponse() },
            saveReasoningEffort: { _, _, _ in .object(["ok": .bool(true)]) },
            loadDirectory: { _, _ in .object([:]) },
            loadFile: { _, _ in .object([:]) },
            loadGitStatus: { _ in .object([:]) },
            performGitAction: { _, _ in .object(["ok": .bool(true)]) },
            performGitCommand: { _, _ in .object(["ok": .bool(true)]) },
            loadTasks: { .object([:]) },
            loadSkills: { .object([:]) },
            loadMemory: { .object([:]) },
            loadInsights: { _ in .object([:]) },
            logout: { .object(["ok": .bool(true)]) }
        )
    }
}

private actor ShareIngressProbe: HermexShareIngress {
    private var draft: HermexSharedDraft?
    private(set) var didClear = false

    init(draft: HermexSharedDraft?) {
        self.draft = draft
    }

    func pendingSharedDraft() async throws -> HermexSharedDraft? {
        draft
    }

    func clearPendingSharedDraft() async throws {
        didClear = true
        draft = nil
    }
}

private actor CacheStoreProbe: HermexCacheStore {
    private let sessions: [HermexSessionDTO]
    private let messages: [HermexChatMessageDTO]
    private(set) var replacedSessions: [HermexSessionDTO] = []
    private(set) var replacedMessages: [HermexChatMessageDTO] = []

    init(sessions: [HermexSessionDTO], messages: [HermexChatMessageDTO]) {
        self.sessions = sessions
        self.messages = messages
    }

    func cachedSessions(for serverID: String) async throws -> [HermexSessionDTO] {
        sessions
    }

    func replaceCachedSessions(_ sessions: [HermexSessionDTO], for serverID: String) async throws {
        replacedSessions = sessions
    }

    func cachedMessages(sessionID: String, serverID: String) async throws -> [HermexChatMessageDTO] {
        messages
    }

    func replaceCachedMessages(_ messages: [HermexChatMessageDTO], sessionID: String, serverID: String) async throws {
        replacedMessages = messages
    }
}

private actor VoiceRecorderProbe: HermexVoiceRecorder {
    private let recordedURL: URL
    private(set) var didStart = false

    init(recordedURL: URL) {
        self.recordedURL = recordedURL
    }

    func start() async throws {
        didStart = true
    }

    func stop() async throws -> URL {
        recordedURL
    }

    func cancel() async {}
}

private actor AudioTranscriberProbe: HermexAudioTranscriber {
    private let response: HermexTranscribeResponse
    private(set) var transcribedURL: URL?

    init(response: HermexTranscribeResponse) {
        self.response = response
    }

    func transcribeAudio(at url: URL) async throws -> HermexTranscribeResponse {
        transcribedURL = url
        return response
    }
}

private actor SpeechSynthesizerProbe: HermexSpeechSynthesizer {
    private(set) var spokenText: String?
    private(set) var didStop = false

    func speak(_ text: String) async {
        spokenText = text
    }

    func stop() async {
        didStop = true
    }
}

private actor StatusNotifierProbe: HermexStatusNotifier {
    struct Running: Equatable {
        var sessionID: String
        var streamID: String?
        var preview: String?
    }

    private(set) var running: Running?
    private(set) var completedSessionID: String?
    private(set) var clearedSessionID: String?

    func showRunning(sessionID: String, streamID: String?, preview: String?) async {
        running = Running(sessionID: sessionID, streamID: streamID, preview: preview)
    }

    func showComplete(sessionID: String) async {
        completedSessionID = sessionID
    }

    func clear(sessionID: String) async {
        clearedSessionID = sessionID
    }
}
