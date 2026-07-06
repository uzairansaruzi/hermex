import SwiftData
import XCTest
@testable import HermesMobile

final class ChatStreamCoordinatorTests: APIClientTestCase {
    @MainActor
    func testStartBuildsReplayURLAndStartsLiveActivity() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123", replayAfterSeq: 4, recoveryState: .reconnecting)

        let url = try XCTUnwrap(streamClient.startedURLs.first)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.path, "/api/chat/stream")
        XCTAssertEqual(queryItems.first(where: { $0.name == "stream_id" })?.value, "stream-123")
        XCTAssertEqual(queryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(queryItems.first(where: { $0.name == "after_seq" })?.value, "4")
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
        XCTAssertTrue(coordinator.isReplayConnection)
        XCTAssertEqual(delegate.startMonitoringCount, 1)
        XCTAssertEqual(liveActivityManager.starts, [
            CoordinatorSpyLiveActivityManager.Start(
                sessionID: "session-abc",
                sessionTitle: "Planning",
                streamID: "stream-123"
            )
        ])
    }

    @MainActor
    func testSuspendSavesLastEventStopsStreamAndMarksLiveActivityStale() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.token("Partial answer."), lastEventID: "session-abc:7")
        coordinator.suspendActiveStreamConnection()

        XCTAssertEqual(coordinator.lastEventID, "session-abc:7")
        XCTAssertTrue(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(delegate.saveSnapshotCount, 1)
        XCTAssertEqual(delegate.stopMonitoringClearPromptValues, [true])
        XCTAssertEqual(liveActivityManager.markStaleCount, 1)
    }

    @MainActor
    func testForegroundReconnectActiveStreamReloadsAndRestartsWithoutReplay() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let resumedURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: resumedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(queryItems.first(where: { $0.name == "replay" }))
    }

    @MainActor
    func testForegroundReconnectActiveStreamDoesNotRestartAfterReplacementDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(delegate.loadMessagesCount, 1)
    }

    @MainActor
    func testForegroundReconnectInactiveReplayUsesRestoredEventID() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(
                #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.token("Partial answer."), lastEventID: "session-abc:9")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(queryItems.first(where: { $0.name == "after_seq" })?.value, "9")
        XCTAssertFalse(coordinator.isConnectionSuspended)
    }

    @MainActor
    func testForegroundReconnectInactiveCompletedTranscriptFinishesStream() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertEqual(delegate.completedNeedsTranscriptRefreshValues, [false])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .complete)
    }

    @MainActor
    func testForegroundReconnectInactiveWithoutAssistantFinalizesFailedAndEndsLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        // The reloaded transcript surfaced no assistant reply after the user message.
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = false
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        // #246: this path previously re-armed and returned, leaving the Live
        // Activity stuck on "running". It must now finalize as failed and end it.
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)
    }

    @MainActor
    func testRefreshTranscriptIfCompletedWithoutAssistantKeepsWaitingWithoutEndingLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = false
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")

        await coordinator.refreshTranscriptIfCompleted(streamID: "stream-123")

        // The live SSE is still connected here, so the foreground safety net must
        // keep waiting for the real completion rather than finalizing (#246). This
        // is the deliberate counterpart to the reconnect-after-suspend fix.
        XCTAssertEqual(coordinator.activeStreamID, "stream-123")
        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testRefreshTranscriptIfCompletedBailsWhenStreamReplacedDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        // A newer run starts while the transcript reload is suspended.
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }

        coordinator.start(streamID: "stream-123")

        await coordinator.refreshTranscriptIfCompleted(streamID: "stream-123")

        // PR #266: the post-load guard must bail so the newer stream is neither
        // finalized nor clobbered by the now-stale refresh.
        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testRefreshTranscriptIfCompletedSkipsFinalizeWhenRunCompletesDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        // The live SSE delivers completion while the transcript reload is suspended.
        delegate.onLoadMessages = {
            streamClient.emit(.done(DoneStreamEvent()))
        }

        coordinator.start(streamID: "stream-123")

        await coordinator.refreshTranscriptIfCompleted(streamID: "stream-123")

        // PR #266 #2: only the live-SSE completion finalizes; the now-stale refresh
        // must not finalize again (no double end / double finishStream). The run
        // generation captured before the load changed, so the refresh bails.
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
        XCTAssertNil(coordinator.activeStreamID)
    }

    @MainActor
    func testForegroundReconnectInactiveCompletedStreamDoesNotFinishReplacementAfterLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        await coordinator.reconnectIfNeeded()

        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertTrue(delegate.completedNeedsTranscriptRefreshValues.isEmpty)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testStaleDetectionWaitsForCheckingIntervalThenPollsStatus() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4
            )
        ) { request in
            statusRequests += 1
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(4.9))
        XCTAssertEqual(statusRequests, 0)
        XCTAssertEqual(coordinator.recoveryState, .idle)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(5.1))
        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .checking)
    }

    @MainActor
    func testStaleRecoveryDoesNotFinishReplacementStreamAfterTranscriptLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        delegate.onLoadMessages = {
            coordinator.start(streamID: "stream-new")
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(5.1))

        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertTrue(delegate.completedNeedsTranscriptRefreshValues.isEmpty)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
    }

    @MainActor
    func testStaleRecoverySkipsFinalizeWhenRunCompletesDuringLoad() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        // The live SSE delivers completion while the stale-recovery transcript
        // reload is suspended.
        delegate.onLoadMessages = {
            streamClient.emit(.done(DoneStreamEvent()))
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(5.1))

        // PR #266 review #3: the run generation captured before the load changed
        // when `.done` finalized the run, so the now-stale stale-recovery path
        // bails via the shared canFinalizeRunAfterLoad guard instead of finalizing
        // a second time (no double end / double finishStream).
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
        XCTAssertNil(coordinator.activeStreamID)
    }

    @MainActor
    func testStaleRecoveryFinalizesInactiveStreamAndEndsLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        // The reloaded transcript surfaced the assistant reply for the completed run.
        delegate.latestServerLoadHadAssistantResponseAfterLatestUser = true
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(5.1))

        // Happy path: server reports the stale run inactive and no concurrent run or
        // completion intervened, so canFinalizeRunAfterLoad lets the stale-recovery
        // path complete from the refreshed transcript and end the Live Activity.
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
    }

    @MainActor
    func testTransportErrorSuspendsAndReconnectsWithReplay() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(
                #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.token("Partial answer."), lastEventID: "session-abc:4")
        streamClient.emit(.transportError("lost connection"), lastEventID: "session-abc:4")

        try await waitUntil { streamClient.startedURLs.count == 2 }

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "after_seq" })?.value, "4")
        XCTAssertEqual(delegate.saveSnapshotCount, 1)
        XCTAssertEqual(liveActivityManager.markStaleCount, 1)
    }

    @MainActor
    func testCancelDoesNotFinishReplacementStreamWhenResponseReturnsLate() async throws {
        let cancelRequestStarted = expectation(description: "cancel request started")
        let releaseCancelResponse = DispatchSemaphore(value: 0)
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            cancelRequestStarted.fulfill()
            _ = releaseCancelResponse.wait(timeout: .now() + 2)
            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        coordinator.start(streamID: "stream-cancel")
        let cancelTask = Task { @MainActor in
            try await coordinator.cancelActiveStream()
        }

        await fulfillment(of: [cancelRequestStarted], timeout: 1)
        coordinator.start(streamID: "stream-new")
        releaseCancelResponse.signal()
        let response = try await cancelTask.value

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertTrue(liveActivityManager.ends.isEmpty)
        XCTAssertEqual(delegate.finishCount, 0)
    }

    @MainActor
    func testCompletionErrorAndCancelFinalizeLiveActivity() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")
            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        coordinator.start(streamID: "stream-complete")
        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.completedNeedsTranscriptRefreshValues, [true])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .complete)

        coordinator.start(streamID: "stream-error")
        streamClient.emit(.error("server failed"))
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(delegate.errorMessages, ["server failed"])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)

        coordinator.start(streamID: "stream-cancel")
        let response = try await coordinator.cancelActiveStream()
        XCTAssertEqual(response?.ok, true)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(liveActivityManager.ends.last?.status, .cancelled)
    }

    @MainActor
    func testDecodedAppErrorEventTerminatesStreamAndSurfacesMessage() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-apperror")
        streamClient.emit(SSEEventDecoder.decode(
            eventType: "apperror",
            data: #"{"message": "Auto-compression failed", "type": "compression_error"}"#
        ))

        // apperror rides the terminal `.error` path: message surfaced, run failed,
        // socket stopped, stream fully finished (issue #25).
        XCTAssertEqual(delegate.errorMessages, ["Auto-compression failed"])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(delegate.finishCount, 1)
    }

    @MainActor
    private func makeCoordinator(
        streamClient: CoordinatorSpySSEStreamingClient? = nil,
        liveActivityManager: CoordinatorSpyLiveActivityManager? = nil,
        delegate: CoordinatorDelegateSpy? = nil,
        timing: ChatStreamCoordinatorTiming = .standard,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            apiTestJSONResponse(#"{"active": true}"#, for: request)
        }
    ) -> ChatStreamCoordinator {
        let streamClient = streamClient ?? CoordinatorSpySSEStreamingClient()
        let liveActivityManager = liveActivityManager ?? CoordinatorSpyLiveActivityManager()
        let delegate = delegate ?? CoordinatorDelegateSpy()
        let coordinator = ChatStreamCoordinator(
            client: makeClient(handler: handler),
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            showsLiveActivityResponseExcerpts: false,
            timing: timing
        )
        coordinator.attach(delegate: delegate)
        return coordinator
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

@MainActor
private final class CoordinatorDelegateSpy: ChatStreamCoordinatorDelegate {
    var streamCoordinatorSessionID: String? = "session-abc"
    var streamCoordinatorDisplayTitle = "Planning"
    var streamCoordinatorHasRunningLiveToolCall = false
    var streamCoordinatorHasPendingPrompt = false
    var latestServerLoadHadAssistantResponseAfterLatestUser = false
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool {
        latestServerLoadHadAssistantResponseAfterLatestUser
    }
    var streamCoordinatorStreamingAssistantMessageID: String?

    private(set) var loadMessagesCount = 0
    private(set) var startMonitoringCount = 0
    private(set) var stopMonitoringClearPromptValues: [Bool] = []
    private(set) var saveSnapshotCount = 0
    private(set) var restoredSnapshotStreamIDs: [String] = []
    private(set) var removedSnapshotStreamIDs: [String?] = []
    private(set) var flushedNoticeCount = 0
    private(set) var drainQueueCount = 0
    private(set) var refreshTitleCount = 0
    private(set) var completedNeedsTranscriptRefreshValues: [Bool] = []
    private(set) var finishCount = 0
    private(set) var errorMessages: [String] = []
    private(set) var recoveryErrors: [String] = []
    private(set) var startConnectionReplayValues: [Bool] = []
    private(set) var resetRecoveryCount = 0
    private(set) var tokens: [String] = []
    private(set) var pendingSteerLeftovers: [String] = []
    var latestAssistantMessageID: String? = "assistant-latest"
    var restoredSnapshotEventID: String?
    var appendTokenResult = true
    var doneHasCompletedTranscript = false
    var onLoadMessages: (() async -> Void)?

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async {
        loadMessagesCount += 1
        await onLoadMessages?()
    }

    func streamCoordinatorLatestAssistantMessageID() -> String? {
        latestAssistantMessageID
    }

    func streamCoordinatorStartAuxiliaryMonitoring() {
        startMonitoringCount += 1
    }

    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool) {
        stopMonitoringClearPromptValues.append(clearPrompt)
    }

    func streamCoordinatorSaveSnapshotIfNeeded() {
        saveSnapshotCount += 1
    }

    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String? {
        restoredSnapshotStreamIDs.append(streamID)
        return restoredSnapshotEventID
    }

    func streamCoordinatorRemoveSnapshot(streamID: String?) {
        removedSnapshotStreamIDs.append(streamID)
    }

    func streamCoordinatorFlushPinnedLocalNoticesToTranscript() {
        flushedNoticeCount += 1
    }

    func streamCoordinatorDrainQueuedSlashMessageIfIdle() {
        drainQueueCount += 1
    }

    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded() {
        refreshTitleCount += 1
    }

    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool) {
        completedNeedsTranscriptRefreshValues.append(needsTranscriptRefresh)
    }

    func streamCoordinatorDidFinishStream() {
        finishCount += 1
    }

    func streamCoordinatorDidReceiveErrorMessage(_ message: String) {
        errorMessages.append(message)
    }

    func streamCoordinatorDidReceiveRecoveryError(_ error: Error) {
        recoveryErrors.append(error.localizedDescription)
    }

    func streamCoordinatorDidStartConnection(isReplay: Bool) {
        startConnectionReplayValues.append(isReplay)
    }

    func streamCoordinatorDidResetRecoveryState() {
        resetRecoveryCount += 1
    }

    func streamCoordinatorAppendToken(_ text: String) -> Bool {
        tokens.append(text)
        return appendTokenResult
    }

    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        payload.text?.isEmpty == false
    }

    func streamCoordinatorAppendReasoning(_ text: String) -> Bool {
        !text.isEmpty
    }

    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool {
        true
    }

    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool {
        true
    }

    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool {
        payload.title?.isEmpty == false
    }

    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool {
        doneHasCompletedTranscript
    }

    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse) {}

    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse) {}

    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        pendingSteerLeftovers.append(trimmed)
        return true
    }
}

@MainActor
private final class CoordinatorSpySSEStreamingClient: SSEStreamingClient {
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    private var onEvent: (@MainActor (SSEEvent) -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ event: SSEEvent, lastEventID: String? = nil) {
        self.lastEventID = lastEventID
        onEvent?(event)
    }
}

@MainActor
private final class CoordinatorSpyLiveActivityManager: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let sessionTitle: String
        let streamID: String?
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var starts: [Start] = []
    private(set) var updates: [AgentLiveActivityEvent] = []
    private(set) var markStaleCount = 0
    private(set) var ends: [End] = []

    func start(sessionID: String, sessionTitle: String, streamID: String?) {
        starts.append(Start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID))
    }

    func update(_ event: AgentLiveActivityEvent) {
        updates.append(event)
    }

    func markStale() {
        markStaleCount += 1
    }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}
