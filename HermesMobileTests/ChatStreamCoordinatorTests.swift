import Observation
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
    func testSessionLoadPreparationBelongsOnlyToCapturedStreamRun() {
        let coordinator = makeCoordinator()

        coordinator.start(streamID: "stream-old")
        let preparation = coordinator.prepareForSessionLoad()

        XCTAssertTrue(coordinator.shouldPreserveLocalOptimisticMessages(
            for: preparation,
            loadedActiveStreamID: "stream-old"
        ))
        XCTAssertFalse(coordinator.shouldPreserveLocalOptimisticMessages(
            for: preparation,
            loadedActiveStreamID: nil
        ))
        XCTAssertFalse(coordinator.shouldPreserveLocalOptimisticMessages(
            for: preparation,
            loadedActiveStreamID: "stream-new"
        ))

        coordinator.start(streamID: "stream-new")

        XCTAssertFalse(coordinator.shouldPreserveLocalOptimisticMessages(
            for: preparation,
            loadedActiveStreamID: "stream-old"
        ))
    }

    @MainActor
    func testSessionLoadPreparationExpiresWhenCapturedRunFinishes() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient)

        coordinator.start(streamID: "stream-123")
        let preparation = coordinator.prepareForSessionLoad()

        streamClient.emit(.streamEnd)

        XCTAssertFalse(coordinator.shouldPreserveLocalOptimisticMessages(
            for: preparation,
            loadedActiveStreamID: "stream-123"
        ))
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
    func testConcurrentForegroundReconnectRequestsShareOneRecoveryAttempt() async {
        let firstStatusStarted = expectation(description: "first stream status request started")
        let releaseFirstStatus = DispatchSemaphore(value: 0)
        let statusRequestCount = CoordinatorLockedCounter()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            if statusRequestCount.increment() == 1 {
                firstStatusStarted.fulfill()
                releaseFirstStatus.wait()
            }
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()

        let firstReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        await fulfillment(of: [firstStatusStarted], timeout: 1)

        let secondReconnectStarted = expectation(description: "second reconnect request started")
        let secondReconnectReturned = CoordinatorLockedCounter()
        let secondReconnect = Task { @MainActor in
            secondReconnectStarted.fulfill()
            await coordinator.reconnectIfNeeded()
            _ = secondReconnectReturned.increment()
        }
        await fulfillment(of: [secondReconnectStarted], timeout: 1)

        XCTAssertEqual(statusRequestCount.value, 1)
        XCTAssertEqual(secondReconnectReturned.value, 0)

        releaseFirstStatus.signal()
        await firstReconnect.value
        await secondReconnect.value

        XCTAssertEqual(secondReconnectReturned.value, 1)
        XCTAssertEqual(delegate.loadMessagesCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testJoiningReconnectUsesNonNilModelContextBeforeTranscriptReload() async throws {
        let firstStatusStarted = expectation(description: "first stream status request started")
        let releaseFirstStatus = DispatchSemaphore(value: 0)
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            firstStatusStarted.fulfill()
            releaseFirstStatus.wait()
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        let modelContext = try makeModelContext()

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()
        let firstReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        await fulfillment(of: [firstStatusStarted], timeout: 1)

        let joiningReconnectStarted = expectation(description: "joining reconnect request started")
        let secondReconnect = Task { @MainActor in
            joiningReconnectStarted.fulfill()
            await coordinator.reconnectIfNeeded(modelContext: modelContext)
        }
        await fulfillment(of: [joiningReconnectStarted], timeout: 1)

        releaseFirstStatus.signal()
        await firstReconnect.value
        await secondReconnect.value

        XCTAssertEqual(delegate.loadMessageReceivedModelContextValues, [true])
    }

    @MainActor
    func testJoiningReconnectRepeatsInFlightNilContextLoadWithModelContext() async throws {
        let firstLoadSuspended = expectation(description: "nil-context transcript load suspended")
        let joiningReconnectStarted = expectation(description: "joining reconnect request started")
        var releaseFirstLoad: CheckedContinuation<Void, Never>?
        let statusRequestCount = CoordinatorLockedCounter()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            _ = statusRequestCount.increment()
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        delegate.onLoadMessages = {
            guard delegate.loadMessagesCount == 1 else { return }
            await withCheckedContinuation { continuation in
                releaseFirstLoad = continuation
                firstLoadSuspended.fulfill()
            }
        }
        let modelContext = try makeModelContext()

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()
        let firstReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        await fulfillment(of: [firstLoadSuspended], timeout: 1)

        let joiningReconnect = Task { @MainActor in
            joiningReconnectStarted.fulfill()
            await coordinator.reconnectIfNeeded(modelContext: modelContext)
        }
        await fulfillment(of: [joiningReconnectStarted], timeout: 1)

        let continuation = try XCTUnwrap(releaseFirstLoad)
        releaseFirstLoad = nil
        continuation.resume()
        await firstReconnect.value
        await joiningReconnect.value

        XCTAssertEqual(statusRequestCount.value, 1)
        XCTAssertEqual(delegate.loadMessageReceivedModelContextValues, [false, true])
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testForegroundReconnectStartsNewRecoveryAfterStreamReplacement() async {
        let firstStatusStarted = expectation(description: "first stream status request started")
        let secondStatusStarted = expectation(description: "second stream status request started")
        let releaseFirstStatus = DispatchSemaphore(value: 0)
        let statusRequestCount = CoordinatorLockedCounter()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            let requestNumber = statusRequestCount.increment()
            if requestNumber == 1 {
                firstStatusStarted.fulfill()
                releaseFirstStatus.wait()
            } else if requestNumber == 2 {
                secondStatusStarted.fulfill()
            }
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-new"}"#, for: request)
        }

        coordinator.start(streamID: "stream-old")
        coordinator.suspendActiveStreamConnection()
        let firstReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        await fulfillment(of: [firstStatusStarted], timeout: 1)

        coordinator.start(streamID: "stream-new")
        coordinator.suspendActiveStreamConnection()
        let secondReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        releaseFirstStatus.signal()
        await fulfillment(of: [secondStatusStarted], timeout: 1)
        await firstReconnect.value
        await secondReconnect.value

        XCTAssertEqual(statusRequestCount.value, 2)
        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
        XCTAssertEqual(streamClient.startedURLs.count, 3)
    }

    @MainActor
    func testForegroundReconnectDoesNotResumeSupersededSameStreamGeneration() async {
        let firstStatusStarted = expectation(description: "first stream status request started")
        let secondStatusStarted = expectation(description: "second stream status request started")
        let releaseFirstStatus = DispatchSemaphore(value: 0)
        let statusRequestCount = CoordinatorLockedCounter()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            let requestNumber = statusRequestCount.increment()
            if requestNumber == 1 {
                firstStatusStarted.fulfill()
                releaseFirstStatus.wait()
            } else if requestNumber == 2 {
                secondStatusStarted.fulfill()
            }
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()
        let firstReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        await fulfillment(of: [firstStatusStarted], timeout: 1)

        coordinator.start(streamID: "stream-123")
        coordinator.suspendActiveStreamConnection()
        let secondReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        releaseFirstStatus.signal()
        await fulfillment(of: [secondStatusStarted], timeout: 1)
        await firstReconnect.value
        await secondReconnect.value

        XCTAssertEqual(statusRequestCount.value, 2)
        XCTAssertEqual(streamClient.startedURLs.count, 3)
        XCTAssertFalse(coordinator.isConnectionSuspended)
    }

    @MainActor
    func testForegroundReconnectStartsNewRecoveryAfterSessionLoadReplacesStream() async {
        let firstStatusStarted = expectation(description: "first stream status request started")
        let secondStatusStarted = expectation(description: "second stream status request started")
        let releaseFirstStatus = DispatchSemaphore(value: 0)
        let statusRequestCount = CoordinatorLockedCounter()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            let requestNumber = statusRequestCount.increment()
            if requestNumber == 1 {
                firstStatusStarted.fulfill()
                releaseFirstStatus.wait()
            } else if requestNumber == 2 {
                secondStatusStarted.fulfill()
            }
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-new"}"#, for: request)
        }

        coordinator.start(streamID: "stream-old")
        coordinator.suspendActiveStreamConnection()
        let firstReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        await fulfillment(of: [firstStatusStarted], timeout: 1)

        let preparation = coordinator.prepareForSessionLoad()
        coordinator.reconcileSessionLoad(
            loadedActiveStreamID: "stream-new",
            preparation: preparation,
            usedCacheFallback: false
        )
        let secondReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        releaseFirstStatus.signal()
        await fulfillment(of: [secondStatusStarted], timeout: 1)
        await firstReconnect.value
        await secondReconnect.value

        XCTAssertEqual(statusRequestCount.value, 2)
        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
    }

    @MainActor
    func testForegroundReconnectStartsNewRecoveryAfterPriorStreamFinishesAndNewSessionLoads() async {
        let firstStatusStarted = expectation(description: "first stream status request started")
        let secondStatusStarted = expectation(description: "second stream status request started")
        let releaseFirstStatus = DispatchSemaphore(value: 0)
        let statusRequestCount = CoordinatorLockedCounter()
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            let requestNumber = statusRequestCount.increment()
            if requestNumber == 1 {
                firstStatusStarted.fulfill()
                releaseFirstStatus.wait()
            } else if requestNumber == 2 {
                secondStatusStarted.fulfill()
            }
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-new"}"#, for: request)
        }

        coordinator.start(streamID: "stream-old")
        coordinator.suspendActiveStreamConnection()
        let firstReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        await fulfillment(of: [firstStatusStarted], timeout: 1)

        streamClient.emit(.streamEnd)
        let preparation = coordinator.prepareForSessionLoad()
        coordinator.reconcileSessionLoad(
            loadedActiveStreamID: "stream-new",
            preparation: preparation,
            usedCacheFallback: false
        )
        let secondReconnect = Task { @MainActor in
            await coordinator.reconnectIfNeeded()
        }
        releaseFirstStatus.signal()
        await fulfillment(of: [secondStatusStarted], timeout: 1)
        await firstReconnect.value
        await secondReconnect.value

        XCTAssertEqual(statusRequestCount.value, 2)
        XCTAssertEqual(coordinator.activeStreamID, "stream-new")
        XCTAssertFalse(coordinator.isConnectionSuspended)
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
    func testRefreshTranscriptCompletionOwnsTeardownBeforeQueuedTerminalEventsArrive() async throws {
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

        await coordinator.refreshTranscriptIfCompleted(streamID: "stream-123")
        streamClient.emit(.streamEnd)
        streamClient.emit(.transportError("connection closed"))

        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertEqual(delegate.drainQueueCount, 1)
        XCTAssertEqual(delegate.refreshTitleCount, 1)
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
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
    func testStaleDetectionWaitsForTransportQuietThresholdThenPollsStatus() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
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

        // #227: semantically quiet past checkingInterval, but the transport was
        // active 5.1s ago — still within transportFreshInterval, so no chip and
        // no status poll yet.
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(5.1))
        XCTAssertEqual(statusRequests, 0)
        XCTAssertEqual(coordinator.recoveryState, .idle)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))
        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .checking)
    }

    @MainActor
    func testHeartbeatKeepsSemanticallyQuietStreamOnOriginalConnection() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            statusRequests += 1
            return apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-60))
        streamClient.emit(.heartbeat)

        await coordinator.recoverStaleStreamIfNeeded(now: Date().addingTimeInterval(1))

        // #227: the heartbeat 1s ago proves the transport is alive, so the
        // semantically quiet stream stays idle with zero status polls — no
        // "Checking stream" chip and no reconnect.
        XCTAssertEqual(statusRequests, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(coordinator.recoveryState, .idle)
    }

    @MainActor
    func testHeartbeatDemotesCheckingStateToIdle() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            statusRequests += 1
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-13))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())
        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .checking)

        streamClient.emit(.heartbeat)

        XCTAssertEqual(coordinator.recoveryState, .idle)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testMarkProgressDoesNotNotifyWhenRecoveryAlreadyIdle() {
        let coordinator = makeCoordinator()
        coordinator.start(streamID: "stream-123")
        XCTAssertEqual(coordinator.recoveryState, .idle)

        let probe = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            probe.increment()
        }

        coordinator.markProgress()

        XCTAssertEqual(probe.value, 0)
        XCTAssertEqual(coordinator.recoveryState, .idle)
    }

    @MainActor
    func testRecoveryIdleEarlyReturnsDoNotNotifyWhenStateIsUnchanged() async {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        let noActiveStream = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            noActiveStream.increment()
        }
        await coordinator.recoverStaleStreamIfNeeded()
        XCTAssertEqual(noActiveStream.value, 0)

        coordinator.start(streamID: "stream-123")
        delegate.streamCoordinatorHasPendingPrompt = true
        let pendingPrompt = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            pendingPrompt.increment()
        }
        await coordinator.recoverStaleStreamIfNeeded()
        XCTAssertEqual(pendingPrompt.value, 0)

        delegate.streamCoordinatorHasPendingPrompt = false
        let progressDate = Date(timeIntervalSince1970: 1_770_000_000)
        coordinator.markProgress(now: progressDate)
        let freshProgress = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            freshProgress.increment()
        }
        await coordinator.recoverStaleStreamIfNeeded(now: progressDate.addingTimeInterval(1))
        XCTAssertEqual(freshProgress.value, 0)

        coordinator.markProgress(now: Date().addingTimeInterval(-60))
        streamClient.emit(.heartbeat)
        let freshTransport = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            freshTransport.increment()
        }
        await coordinator.recoverStaleStreamIfNeeded(now: Date().addingTimeInterval(1))
        XCTAssertEqual(freshTransport.value, 0)
    }

    @MainActor
    func testRecoveryStateNotifiesOnlyForTransitionsAndSkipsCheckingCooldownWrite() async {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            statusRequests += 1
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        let enteredChecking = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            enteredChecking.increment()
        }
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))
        XCTAssertEqual(enteredChecking.value, 1)
        XCTAssertEqual(coordinator.recoveryState, .checking)
        XCTAssertEqual(statusRequests, 1)

        let cooldown = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            cooldown.increment()
        }
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(13))
        XCTAssertEqual(cooldown.value, 0)
        XCTAssertEqual(coordinator.recoveryState, .checking)
        XCTAssertEqual(statusRequests, 1)

        let returnedToIdle = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            returnedToIdle.increment()
        }
        coordinator.markProgress(now: start.addingTimeInterval(13))
        XCTAssertEqual(returnedToIdle.value, 1)
        XCTAssertEqual(coordinator.recoveryState, .idle)
    }

    @MainActor
    func testMarkProgressNotifiesWhenRecoveryLeavesChecking() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            timing: ChatStreamCoordinatorTiming(
                checkingInterval: 5,
                reconnectInterval: 18,
                runningToolReconnectInterval: 25,
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            statusRequests += 1
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))
        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .checking)

        let probe = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.recoveryState
        } onChange: {
            probe.increment()
        }

        coordinator.markProgress()

        XCTAssertEqual(probe.value, 1)
        XCTAssertEqual(coordinator.recoveryState, .idle)
    }

    // The MockURLProtocol handler runs on URLSession's protocol thread while the
    // coordinator's status-poll await has suspended the main actor, so a
    // main-queue sync hop delivers the heartbeat deterministically *mid-flight*
    // — before the poll's continuation resumes (PR #238 review).
    @MainActor
    func testHeartbeatDuringStatusPollKeepsIdleStateWithoutReassertingChecking() async throws {
        var statusRequests = 0
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            statusRequests += 1
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { streamClient.emit(.heartbeat) }
            }
            return apiTestJSONResponse(#"{"active": true, "stream_id": "stream-123"}"#, for: request)
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-13))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())

        XCTAssertEqual(statusRequests, 1)
        XCTAssertEqual(coordinator.recoveryState, .idle)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testHeartbeatDuringForceReconnectStatusPollSkipsReconnect() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { streamClient.emit(.heartbeat) }
            }
            return apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-19))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())

        XCTAssertEqual(coordinator.recoveryState, .idle)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)
    }

    @MainActor
    func testHeartbeatDoesNotDemoteReconnectingState() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: Date().addingTimeInterval(-20))

        await coordinator.recoverStaleStreamIfNeeded(now: Date())
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)

        streamClient.emit(.heartbeat)

        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
    }

    @MainActor
    func testMissingTransportActivityReconnectsStaleActiveStream() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(18.1))

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
    }

    @MainActor
    func testSilentInitialConnectionReconnectsWhenStale() async throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let coordinator = makeCoordinator(streamClient: streamClient) { request in
            apiTestJSONResponse(
                #"{"active": true, "stream_id": "stream-123", "replay_available": true}"#,
                for: request
            )
        }

        coordinator.start(streamID: "stream-123")
        XCTAssertNil(coordinator.lastProgressDate)
        let connectionStartedAt = try XCTUnwrap(coordinator.lastTransportActivityDate)

        await coordinator.recoverStaleStreamIfNeeded(
            now: connectionStartedAt.addingTimeInterval(18.1)
        )

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(coordinator.recoveryState, .reconnecting)
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
                statusPollCooldown: 4,
                transportFreshInterval: 12
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

        // 12.1s: past transportFreshInterval, so the stale-recovery status poll
        // actually fires (#227).
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))

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
                statusPollCooldown: 4,
                transportFreshInterval: 12
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

        // 12.1s: past transportFreshInterval, so the stale-recovery status poll
        // actually fires (#227).
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))

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
                statusPollCooldown: 4,
                transportFreshInterval: 12
            )
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")
            return apiTestJSONResponse(#"{"active": false, "stream_id": "stream-123"}"#, for: request)
        }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        coordinator.start(streamID: "stream-123")
        coordinator.markProgress(now: start)

        // 12.1s: past transportFreshInterval, so the stale-recovery status poll
        // actually fires (#227).
        await coordinator.recoverStaleStreamIfNeeded(now: start.addingTimeInterval(12.1))

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
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)
        streamClient.emit(.error("server failed"))
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertEqual(delegate.errorMessages, ["server failed"])
        XCTAssertEqual(liveActivityManager.ends.last?.status, .failed)

        coordinator.start(streamID: "stream-cancel")
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 24.5)
        let response = try await coordinator.cancelActiveStream()
        XCTAssertEqual(response?.ok, true)
        XCTAssertNil(coordinator.activeStreamID)
        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertEqual(liveActivityManager.ends.last?.status, .cancelled)
    }

    @MainActor
    func testLiveResponseSpeedAcceptsOnlyCurrentSessionExactReadingsAndClearsOnLifecycleChanges() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-one")
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 99,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "another-session"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: true,
            sessionId: "session-abc"
        )))
        XCTAssertNil(coordinator.liveTokensPerSecond)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        _ = coordinator.prepareForSessionLoad()
        XCTAssertNil(coordinator.liveTokensPerSecond)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        coordinator.start(streamID: "stream-two")
        XCTAssertNil(coordinator.liveTokensPerSecond)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 36.75,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        streamClient.emit(.done(DoneStreamEvent(usage: ContextWindowSnapshot(
            contextLength: nil,
            thresholdTokens: nil,
            lastPromptTokens: nil,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil,
            tokensPerSecond: 40.5
        ))))

        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertEqual(delegate.donePayloads.last?.usage?.tokensPerSecond, 40.5)
    }

    @MainActor
    func testMeteringDoesNotNotifyWhenTokensPerSecondUnchanged() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)
        coordinator.start(streamID: "stream-one")

        let first = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.liveTokensPerSecond
        } onChange: {
            first.increment()
        }
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        let duplicate = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.liveTokensPerSecond
        } onChange: {
            duplicate.increment()
        }
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(duplicate.value, 0)
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        let cleared = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.liveTokensPerSecond
        } onChange: {
            cleared.increment()
        }
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: true,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(cleared.value, 1)
        XCTAssertNil(coordinator.liveTokensPerSecond)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 24.5)
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 99,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "another-session"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 24.5)
    }

    @MainActor
    func testLifecycleTokenRateClearsNotifyOnlyWhenValueChanges() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)
        coordinator.start(streamID: "stream-one")

        let duplicateClears = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.liveTokensPerSecond
        } onChange: {
            duplicateClears.increment()
        }
        coordinator.prepareForNewResponse()
        coordinator.start(streamID: "stream-two")
        _ = coordinator.prepareForSessionLoad()
        XCTAssertEqual(duplicateClears.value, 0)

        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 24.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 24.5)

        let meaningfulClear = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.liveTokensPerSecond
        } onChange: {
            meaningfulClear.increment()
        }
        coordinator.prepareForNewResponse()
        XCTAssertEqual(meaningfulClear.value, 1)
        XCTAssertNil(coordinator.liveTokensPerSecond)
    }

    @MainActor
    func testLiveResponseSpeedClearsImmediatelyWhenTransportFails() {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-one")
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.25)

        streamClient.emit(.transportError("Connection lost"))

        XCTAssertNil(coordinator.liveTokensPerSecond)
        XCTAssertTrue(coordinator.isConnectionSuspended)
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

    // MARK: - Late events after completion (#288)

    @MainActor
    func testLateTokenAfterDoneIsDroppedAndDoesNotMutateTranscript() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertTrue(coordinator.hasCompletedCurrentResponse)
        XCTAssertEqual(delegate.tokens, [])

        // The server's background title thread can emit a stray token after
        // done — it must never reach the transcript (#288).
        streamClient.emit(.token("Casual Greeting Exchange"))

        XCTAssertEqual(delegate.tokens, [], "late token after done must be dropped")
        XCTAssertTrue(coordinator.hasCompletedCurrentResponse)
        XCTAssertNil(coordinator.activeStreamID, "completion must not be undone by the late token")
    }

    @MainActor
    func testLateTitleAfterDoneStillUpdatesSessionMetadata() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertTrue(coordinator.hasCompletedCurrentResponse)

        // The title event arrives after done via the background thread and must
        // still update session metadata even though content events are dropped.
        streamClient.emit(.title(TitleStreamEvent(sessionId: "session-abc", title: "Casual Greeting")))

        // Title routing is metadata-only; the transcript must stay untouched.
        XCTAssertNil(coordinator.activeStreamID)
    }

    @MainActor
    func testLateMeteringAndLifecycleAfterDoneContinueTeardown() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        XCTAssertTrue(coordinator.hasCompletedCurrentResponse)

        // Metering after completion is allowed to update the TPS readout. The
        // event must be production-shaped: displayableTokensPerSecond projects
        // only when isTokensPerSecondAvailable == true and isEstimated != true.
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.5)

        let duplicate = ObservationChangeProbe()
        withObservationTracking {
            _ = coordinator.liveTokensPerSecond
        } onChange: {
            duplicate.increment()
        }
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 12.5,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(duplicate.value, 0)

        // Foreign-session metering must not update the readout.
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 99,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "other-session"
        )))
        XCTAssertEqual(coordinator.liveTokensPerSecond, 12.5, "foreign session metering ignored")

        // Lifecycle must continue so the stream finishes and the Live Activity
        // is not left dangling on "running".
        streamClient.emit(.streamEnd)

        XCTAssertEqual(delegate.finishCount, 1)
        XCTAssertFalse(coordinator.hasCompletedCurrentResponse, "finishStream resets for the next run")
        XCTAssertEqual(liveActivityManager.ends.count, 1, "no duplicate end from a second finalize")
        XCTAssertTrue(coordinator.isTerminalFenceActiveForTesting(), "terminal fence survives finishStream")

        // Teardown is one-shot per run: later terminal events must not repeat
        // delegate finish/drain/title-refresh side effects (PR #295 re-gate).
        streamClient.emit(.error("late"))
        streamClient.emit(.cancelled)
        streamClient.emit(.streamEnd)

        XCTAssertEqual(delegate.finishCount, 1, "teardown exactly once")
        XCTAssertEqual(liveActivityManager.ends.count, 1)
        XCTAssertTrue(coordinator.isTransportFinishedForTesting())
    }

    @MainActor
    func testTransportErrorAfterDoneStillFinishesExactlyOnce() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        // Transport closes without delivering streamEnd.
        streamClient.emit(.transportError("connection dropped"))

        // Settled teardown still runs: finish, snapshot cleanup, drain,
        // completed-title refresh — with the completed outcome preserved.
        XCTAssertEqual(delegate.finishCount, 1, "transportError after done must not skip teardown")
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
        XCTAssertNil(coordinator.activeStreamID)

        // And it is idempotent against further terminal events.
        streamClient.emit(.streamEnd)
        streamClient.emit(.cancelled)
        XCTAssertEqual(delegate.finishCount, 1)
    }

    @MainActor
    func testNewRunResetsTeardownOwnerAndContentFence() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd)
        XCTAssertTrue(coordinator.isTerminalFenceActiveForTesting())

        // Next run disarms both the content fence and the teardown owner.
        coordinator.prepareForNewResponse()
        XCTAssertFalse(coordinator.isTerminalFenceActiveForTesting())
        XCTAssertFalse(coordinator.isTransportFinishedForTesting())

        // A token in the new run is accepted again.
        coordinator.start(streamID: "stream-456")
        streamClient.emit(.token("fresh answer"))
        XCTAssertEqual(delegate.tokens.last, "fresh answer", "content accepted after new run starts")
    }

    @MainActor
    func testTokenAfterStreamEndIsStillDroppedByTerminalFence() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd)
        XCTAssertEqual(delegate.finishCount, 1)

        // done → streamEnd → late token must still not corrupt the transcript
        // (#288 review): finishStream clears hasCompletedCurrentResponse but the
        // terminal fence stays armed until the next run starts.
        streamClient.emit(.token("Casual Greeting Exchange"))

        XCTAssertEqual(delegate.tokens, [], "token after streamEnd must be dropped")
    }

    @MainActor
    func testNewRunStartDisarmsTerminalFence() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd)
        XCTAssertTrue(coordinator.isTerminalFenceActiveForTesting())

        // The user sends a follow-up message → new response → fence disarms.
        coordinator.prepareForNewResponse()

        XCTAssertFalse(coordinator.isTerminalFenceActiveForTesting(), "next run must accept content again")
    }

    @MainActor
    func testLateTitlePayloadReachesDelegateAfterDone() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(streamClient: streamClient, delegate: delegate)

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))

        streamClient.emit(.title(TitleStreamEvent(sessionId: "session-abc", title: "Casual Greeting Exchange")))

        XCTAssertEqual(
            delegate.titles.last?.title,
            "Casual Greeting Exchange",
            "late title must actually route to streamCoordinatorUpdateTitle (not silently dropped)"
        )
    }

    @MainActor
    func testPostDoneErrorDoesNotDoubleEndLiveActivity() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.error("late failure"))

        // Exactly one end (.complete from done); the late error tears down the
        // transport without publishing a failed end over a settled completion.
        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete])
        XCTAssertEqual(delegate.errorMessages, [], "post-completion error must not surface as failure banner")
        XCTAssertEqual(delegate.finishCount, 1)
    }

    @MainActor
    func testPostDoneCancelDoesNotDoubleEndLiveActivity() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.cancelled)

        XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete], "settled complete wins; no second end")
        XCTAssertEqual(delegate.finishCount, 1)
    }

    /// Table-driven matrix: every content-family event after completion is
    /// dropped, so a future enum case cannot silently land in the wrong bucket.
    @MainActor
    func testAllContentEventsAreDroppedAfterCompletion() throws {
        let cases: [(String, SSEEvent)] = [
            ("token", .token("late")),
            ("interimAssistant", .interimAssistant(InterimAssistantStreamEvent(text: "late"))),
            ("reasoning", .reasoning("late")),
            ("toolStarted", .toolStarted(ToolStreamEvent(eventType: "tool.started", name: "bash", preview: nil, args: nil, duration: nil, isError: false))),
            ("toolCompleted", .toolCompleted(ToolStreamEvent(eventType: "tool.completed", name: "bash", preview: nil, args: nil, duration: 0.1, isError: false)))
        ]
        for (name, event) in cases {
            let streamClient = CoordinatorSpySSEStreamingClient()
            let liveActivityManager = CoordinatorSpyLiveActivityManager()
            let delegate = CoordinatorDelegateSpy()
            let coordinator = makeCoordinator(
                streamClient: streamClient,
                liveActivityManager: liveActivityManager,
                delegate: delegate
            )

            coordinator.start(streamID: "stream-123")
            streamClient.emit(.done(DoneStreamEvent()))
            streamClient.emit(event)

            XCTAssertTrue(delegate.tokens.isEmpty, "\(name) after done leaked into transcript tokens")
            XCTAssertTrue(delegate.interimPayloads.isEmpty, "\(name): interim projection must be empty")
            XCTAssertTrue(delegate.reasoningTexts.isEmpty, "\(name): reasoning projection must be empty")
            XCTAssertTrue(delegate.toolStartedPayloads.isEmpty, "\(name): tool-started projection must be empty")
            XCTAssertTrue(delegate.toolCompletedPayloads.isEmpty, "\(name): tool-completed projection must be empty")
            XCTAssertEqual(liveActivityManager.ends.map(\.status), [.complete], "\(name): exactly one complete end")
        }
    }

    @MainActor
    func testDuplicateDoneAfterCompletionIsIgnoredWithoutDoubleFinalize() throws {
        let streamClient = CoordinatorSpySSEStreamingClient()
        let liveActivityManager = CoordinatorSpyLiveActivityManager()
        let delegate = CoordinatorDelegateSpy()
        let coordinator = makeCoordinator(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager,
            delegate: delegate
        )

        coordinator.start(streamID: "stream-123")
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.done(DoneStreamEvent()))

        XCTAssertEqual(delegate.donePayloads.count, 1, "duplicate done must not re-apply")
        XCTAssertEqual(delegate.completedNeedsTranscriptRefreshValues.count, 1, "single finalize only")
        XCTAssertEqual(liveActivityManager.ends.count, 1)
        XCTAssertNil(coordinator.activeStreamID)
    }

    private func makeModelContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
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
    private(set) var loadMessageReceivedModelContextValues: [Bool] = []
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
    private(set) var donePayloads: [DoneStreamEvent] = []
    private(set) var pendingSteerLeftovers: [String] = []
    var latestAssistantMessageID: String? = "assistant-latest"
    var restoredSnapshotEventID: String?
    var appendTokenResult = true
    var doneHasCompletedTranscript = false
    var onLoadMessages: (() async -> Void)?

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async {
        loadMessagesCount += 1
        loadMessageReceivedModelContextValues.append(modelContext != nil)
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

    private(set) var interimPayloads: [InterimAssistantStreamEvent] = []
    private(set) var reasoningTexts: [String] = []
    private(set) var toolStartedPayloads: [ToolStreamEvent] = []
    private(set) var toolCompletedPayloads: [ToolStreamEvent] = []

    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool {
        interimPayloads.append(payload)
        return payload.text?.isEmpty == false
    }

    func streamCoordinatorAppendReasoning(_ text: String) -> Bool {
        reasoningTexts.append(text)
        return !text.isEmpty
    }

    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool {
        toolStartedPayloads.append(payload)
        return true
    }

    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool {
        toolCompletedPayloads.append(payload)
        return true
    }

    private(set) var titles: [TitleStreamEvent] = []

    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool {
        titles.append(payload)
        return payload.title?.isEmpty == false
    }

    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool {
        donePayloads.append(payload)
        return doneHasCompletedTranscript
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

private final class CoordinatorLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
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

private final class ObservationChangeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
