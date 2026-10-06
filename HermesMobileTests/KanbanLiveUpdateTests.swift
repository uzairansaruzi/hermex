import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor
final class KanbanLiveUpdateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearSavedKanbanBoards()
    }

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testVisibleBoardStartsAtSnapshotCursorAndCoalescesEventBurst() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)

        XCTAssertEqual(stream.starts.first?.board, "main")
        XCTAssertEqual(stream.starts.first?.since, 11)
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        stream.emit(Self.eventsFrame(cursor: 13, kind: "future.unknown.kind"))

        try await waitUntil { await client.boardCallCount == 2 }
        XCTAssertEqual(state.liveCursor, 13)
        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        let lastRequest = await client.boardRequests.last
        XCTAssertNil(lastRequest?.since)
        let statsCallCount = await client.statsCallCount
        let assigneeCallCount = await client.assigneeCallCount
        // Only the initial load reads stats and assignees; the live burst fetches the Board alone.
        XCTAssertEqual(statsCallCount, 1)
        XCTAssertEqual(assigneeCallCount, 1)
        state.setVisible(false)
    }

    func testLiveRefreshOfBoardOnScreenHidesTheLoadingRow() async throws {
        let client = GatedLiveKanbanClient()
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        try await waitUntil { await client.boardCallCount == 2 }

        // Writes stay gated while the refresh runs, but the Card list keeps its shape.
        XCTAssertTrue(state.isRefreshing)
        XCTAssertNotNil(state.snapshot)
        XCTAssertFalse(state.showsBoardLoadingRow)

        await client.release(.cursor12)
        try await waitUntil { state.snapshot?.latestEventID == 12 && !state.isRefreshing }
        state.setVisible(false)
    }

    func testBurstDuringLiveRefreshQueuesOneFollowUpInsteadOfCancelling() async throws {
        let client = GatedLiveKanbanClient()
        let stream = KanbanStreamSpy()
        let probe = RefreshingProbe()
        let state = makeState(client: client, stream: stream, sleep: { duration in
            probe.recordSleep()
            try await Task.sleep(for: duration)
        })
        probe.state = state

        await state.load()
        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        try await waitUntil { await client.boardCallCount == 2 }

        // Two more bursts land while the live refresh is still downloading.
        stream.emit(Self.eventsFrame(cursor: 13, kind: "task.updated"))
        stream.emit(Self.eventsFrame(cursor: 14, kind: "task.updated"))
        await client.release(.cursor12)

        // The in-flight refresh was applied, then exactly one follow-up started.
        try await waitUntil { await client.boardCallCount == 3 }
        XCTAssertEqual(state.snapshot?.latestEventID, 12)
        await client.release(.cursor14)
        try await waitUntil { state.snapshot?.latestEventID == 14 && !state.isRefreshing }

        let boardCallCount = await client.boardCallCount
        let statsCallCount = await client.statsCallCount
        let assigneeCallCount = await client.assigneeCallCount
        XCTAssertEqual(boardCallCount, 3)
        XCTAssertEqual(statsCallCount, 1)
        XCTAssertEqual(assigneeCallCount, 1)
        // The follow-up waited out its own debounce with the refresh flag down, so
        // writes unlock between passes.
        XCTAssertEqual(probe.refreshingAtEachSleep, [false, false])
        state.setVisible(false)
    }

    func testLiveRefreshThatSupersedesAPullFinishesItsStatsAndAssigneeReads() async throws {
        let client = GatedLiveKanbanClient()
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))

        // A pull is still downloading the Board when a burst's live refresh takes over.
        let pull = Task { await state.refresh() }
        try await waitUntil { await client.boardCallCount == 2 }
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        try await waitUntil { await client.boardCallCount == 3 }
        await client.release(.cursor12)
        await pull.value
        await client.release(.cursor12)

        // The live refresh reads the stats and assignees the superseded pull never did.
        try await waitUntil { await client.assigneeCallCount == 2 && !state.isRefreshing }
        let statsCallCount = await client.statsCallCount
        XCTAssertEqual(statsCallCount, 2)
        state.setVisible(false)
    }

    func testSuspendDuringLiveRefreshDoesNotSwallowTheNextBurst() async throws {
        let client = GatedLiveKanbanClient()
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        try await waitUntil { await client.boardCallCount == 2 }

        // Push a Card mid-refresh, pop back, and receive a new burst.
        state.setVisible(false)
        state.setVisible(true)
        stream.emit(.hello(cursor: 12, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 13, kind: "task.updated"))

        try await waitUntil { await client.boardCallCount == 3 }
        await client.release(.cursor12)
        // Once the client has returned the stale result, the stale refresh finishes on
        // the main actor before this test resumes there.
        try await waitUntil { await client.resumedFetchCount == 1 }

        // The stale refresh must not clear the new refresh's in-flight flag: this burst
        // queues a follow-up instead of cancelling the fetch holding cursor 14.
        stream.emit(Self.eventsFrame(cursor: 15, kind: "task.updated"))
        await client.release(.cursor14)
        try await waitUntil { await client.boardCallCount == 4 }
        XCTAssertEqual(state.snapshot?.latestEventID, 14)
        await client.release(.cursor15)
        try await waitUntil { state.snapshot?.latestEventID == 15 && !state.isRefreshing }
        state.setVisible(false)
    }

    func testLiveRefreshThatSupersedesUnsettledReadsFinishesThem() async throws {
        let client = GatedLiveKanbanClient(cancelsFirstStatsRead: true)
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        // A pop cancelled the first load after its Board arrived.
        await Task { await state.load() }.value
        XCTAssertNotNil(state.snapshot)
        XCTAssertNil(state.stats)

        // Returning resumes the stream while `loadIfNeeded` refetches to finish the reads.
        state.setVisible(true)
        let reappear = Task { await state.loadIfNeeded() }
        try await waitUntil { await client.boardCallCount == 2 }

        // A backlog burst supersedes that refresh before its Board returns.
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        try await waitUntil { await client.boardCallCount == 3 }
        await client.release(.cursor12)
        await reappear.value
        await client.release(.cursor12)

        try await waitUntil { state.stats != nil && state.assigneeHistory != nil }
        let statsCallCount = await client.statsCallCount
        XCTAssertEqual(statsCallCount, 2)
        state.setVisible(false)
    }

    func testReturningFromCardResumesStreamFromAdvancedCursorWithoutReload() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        stream.emit(Self.eventsFrame(cursor: 13, kind: "task.updated"))
        try await waitUntil { state.snapshot?.latestEventID == 13 }
        XCTAssertEqual(state.liveCursor, 13)

        // Push a Card, then pop back to the Board.
        state.setVisible(false)
        await state.loadIfNeeded()
        state.setVisible(true)

        XCTAssertEqual(stream.starts.count, 2)
        XCTAssertEqual(stream.starts.last?.since, 13)
        let boardCallCount = await client.boardCallCount
        XCTAssertEqual(boardCallCount, 2)
        state.setVisible(false)
    }

    func testReturningFromCardRefreshesBoardWhenPopCancelledLiveRefresh() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(
            client: client,
            stream: stream,
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .seconds(60),
                reconnectDelays: [.milliseconds(5)],
                pollingInterval: .seconds(60),
                failuresBeforePolling: 3
            )
        )

        await state.load()
        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 13, kind: "task.updated"))
        XCTAssertEqual(state.liveCursor, 13)

        // The pop lands inside the coalescing window, so the burst's refresh never runs.
        state.setVisible(false)
        await state.loadIfNeeded()
        state.setVisible(true)

        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        let requests = await client.boardRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests.last?.since)
        XCTAssertEqual(stream.starts.last?.since, 13)
        state.setVisible(false)
    }

    func testLiveEventReconciliationMarksAdvisoryDispatchPreviewStale() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        await state.previewDispatch()
        XCTAssertEqual(state.dispatchState?.phase, .succeeded)
        XCTAssertFalse(state.isPreviewStale)

        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))

        try await waitUntil { await client.boardCallCount == 2 }
        XCTAssertTrue(state.isPreviewStale)
        state.setVisible(false)
    }

    func testRepeatedFailuresFallBackToPollingWithoutRequestStorm() async throws {
        let client = LiveKanbanClient(
            boardResults: [.success(.rich), .success(.newer)],
            eventsResult: .success(.events(cursor: 13))
        )
        let stream = KanbanStreamSpy()
        let polling = PollingProbe()
        let state = makeState(
            client: client,
            stream: stream,
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(5),
                reconnectDelays: [.zero, .zero],
                pollingInterval: PollingProbe.interval,
                failuresBeforePolling: 3
            ),
            sleep: { duration in try await polling.sleep(duration) }
        )

        await state.load()
        state.setVisible(true)
        stream.failCurrent()
        try await waitUntil { stream.starts.count == 2 }
        stream.failCurrent()
        try await waitUntil { stream.starts.count == 3 }
        stream.failCurrent()

        try await waitUntil { state.liveUpdatesDelayed }
        try await waitUntil { await client.boardCallCount == 2 }
        // The loop is parked on its second interval, so no further poll can land.
        try await waitUntil { polling.intervalsStarted == 2 }
        let eventCallCount = await client.eventCallCount
        XCTAssertEqual(eventCallCount, 1)
        XCTAssertEqual(state.liveCursor, 13)
        XCTAssertEqual(stream.starts.count, 3)
        state.setVisible(false)
    }

    func testDisconnectPreservesSnapshotAndFullRefreshRecoversBeforeActionSeam() async {
        let client = LiveKanbanClient(boardResults: [
            .success(.rich),
            .failure(APIError.network(underlying: URLError(.notConnectedToInternet))),
            .success(.newer)
        ])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        stream.emit(.hello(cursor: 11, board: "main"))
        let loadedCards = state.allCards

        await state.refresh()

        XCTAssertTrue(state.isOffline)
        XCTAssertTrue(state.loadedDetailIsStale)
        XCTAssertEqual(state.allCards, loadedCards)
        XCTAssertFalse(state.canUseServerAuthoritativeActions)

        await state.refresh()

        XCTAssertFalse(state.isOffline)
        XCTAssertFalse(state.loadedDetailIsStale)
        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        XCTAssertTrue(state.canUseServerAuthoritativeActions)
        XCTAssertEqual(stream.starts.count, 2)
        state.setVisible(false)
    }

    func testBackgroundSuspendsAndForegroundReconcilesBeforeRestartingStream() async {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        XCTAssertEqual(stream.starts.count, 1)

        await state.setScenePhase(.background)
        XCTAssertGreaterThanOrEqual(stream.stopCount, 1)
        stream.emit(.events(events: [], cursor: 99, frameID: 99), startIndex: 0)
        XCTAssertEqual(state.liveCursor, 11)

        await state.setScenePhase(.active)

        let boardRequests = await client.boardRequests
        let boardsCallCount = await client.boardsCallCount
        let statsCallCount = await client.statsCallCount
        let assigneeCallCount = await client.assigneeCallCount
        XCTAssertEqual(boardRequests.count, 2)
        XCTAssertEqual(boardRequests.last?.since, 11)
        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        // A changed Board also reconciles the Board list, stats, and assignee history.
        XCTAssertEqual(boardsCallCount, 2)
        XCTAssertEqual(statsCallCount, 2)
        XCTAssertEqual(assigneeCallCount, 2)
        XCTAssertEqual(stream.starts.count, 2)
        state.setVisible(false)
    }

    func testInactiveOverlayKeepsStreamAndBoardWithoutRequests() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        let stopCount = stream.stopCount
        let revision = state.detailRefreshRevision

        await state.setScenePhase(.inactive)
        await state.setScenePhase(.active)

        let boardCallCount = await client.boardCallCount
        let boardsCallCount = await client.boardsCallCount
        let statsCallCount = await client.statsCallCount
        XCTAssertEqual(boardCallCount, 1)
        XCTAssertEqual(boardsCallCount, 1)
        XCTAssertEqual(statsCallCount, 1)
        XCTAssertEqual(stream.stopCount, stopCount)
        XCTAssertEqual(stream.starts.count, 1)
        XCTAssertEqual(state.detailRefreshRevision, revision)

        // The stream stayed current through the overlay, so its events still land.
        stream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"))
        try await waitUntil { await client.boardCallCount == 2 }
        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        state.setVisible(false)
    }

    func testForegroundWithoutNewEventsKeepsBoardAndResumesFromCursor() async {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.unchanged(latest: 11))])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        let snapshot = state.snapshot
        let revision = state.detailRefreshRevision

        await state.setScenePhase(.background)
        await state.setScenePhase(.active)

        let boardRequests = await client.boardRequests
        let boardsCallCount = await client.boardsCallCount
        let statsCallCount = await client.statsCallCount
        let assigneeCallCount = await client.assigneeCallCount
        XCTAssertEqual(boardRequests.count, 2)
        XCTAssertEqual(boardRequests.last?.since, 11)
        // Only the initial load read the Board list, stats, and assignee history.
        XCTAssertEqual(boardsCallCount, 1)
        XCTAssertEqual(statsCallCount, 1)
        XCTAssertEqual(assigneeCallCount, 1)
        XCTAssertEqual(state.snapshot, snapshot)
        XCTAssertEqual(state.detailRefreshRevision, revision)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertEqual(stream.starts.count, 2)
        XCTAssertEqual(stream.starts.last?.since, 11)
        state.setVisible(false)
    }

    func testUnchangedForegroundRetriesStatsThatFailedEarlier() async {
        let client = LiveKanbanClient(
            boardResults: [.success(.rich), .success(.unchanged(latest: 11))],
            statsFailures: 1
        )
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        XCTAssertNil(state.stats)

        await state.setScenePhase(.background)
        await state.setScenePhase(.active)

        let boardRequests = await client.boardRequests
        let statsCallCount = await client.statsCallCount
        XCTAssertEqual(boardRequests.last?.since, 11)
        XCTAssertEqual(statsCallCount, 2)
        XCTAssertNotNil(state.stats)
        XCTAssertFalse(state.capabilityWarnings.contains(.statsUnavailable))
        state.setVisible(false)
    }

    func testForegroundAfterFailedFilterRefreshReloadsWithoutCursor() async {
        let client = LiveKanbanClient(boardResults: [
            .success(.rich),
            .failure(APIError.http(statusCode: 500, body: nil)),
            .success(.newer)
        ])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        await state.setTenantFilter("acme")
        XCTAssertTrue(state.refreshFailed)
        XCTAssertEqual(state.snapshot?.latestEventID, 11)

        await state.setScenePhase(.background)
        await state.setScenePhase(.active)

        // The snapshot still holds the unfiltered Board, and upstream's cursor ignores
        // filters, so the foreground must fetch the filtered Board in full.
        let boardRequests = await client.boardRequests
        XCTAssertEqual(boardRequests.count, 3)
        XCTAssertEqual(boardRequests.last?.tenant, "acme")
        XCTAssertNil(boardRequests.last?.since)
        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        XCTAssertFalse(state.refreshFailed)
        state.setVisible(false)
    }

    func testForegroundBoardCollectionFailureStillRefreshesAndRestartsStream() async {
        let client = LiveKanbanClient(
            boardResults: [.success(.rich), .success(.newer)],
            boardsResults: [.success(.single), .success(.incomplete)]
        )
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        await state.setScenePhase(.background)

        await state.setScenePhase(.active)

        let boardCallCount = await client.boardCallCount
        XCTAssertEqual(boardCallCount, 2)
        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        XCTAssertEqual(stream.starts.count, 2)
        XCTAssertTrue(state.refreshFailed)
        XCTAssertFalse(state.canUseServerAuthoritativeActions)
        state.setVisible(false)
    }

    func testForegroundRefreshCannotStopNewBoardStreamAfterBoardSwitch() async throws {
        let client = ForegroundBoardSwitchClient()
        let stream = KanbanStreamSpy()
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client,
            streamClient: stream,
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(5),
                reconnectDelays: [.milliseconds(5)],
                pollingInterval: .seconds(60),
                failuresBeforePolling: 3
            )
        )

        await state.load()
        state.setVisible(true)
        await state.setScenePhase(.background)

        let foreground = Task { await state.setScenePhase(.active) }
        try await waitUntil { await client.foregroundRequestStarted }
        await state.selectBoard("release")
        let stopCountAfterSwitch = stream.stopCount

        await client.finishForegroundRequest()
        await foreground.value

        XCTAssertEqual(state.selectedBoardSlug, "release")
        XCTAssertEqual(stream.starts.last?.board, "release")
        XCTAssertEqual(stream.stopCount, stopCountAfterSwitch)
        state.setVisible(false)
    }

    func testBoardSwitchTearsDownOldGenerationAndReconnectsPinnedToNewBoard() async throws {
        let client = LiveKanbanClient(
            boards: .multiple,
            boardResults: [.success(.rich), .success(.release), .success(.releaseUpdated)]
        )
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        await state.selectBoard("release")

        XCTAssertEqual(stream.starts.count, 2)
        XCTAssertEqual(stream.starts.last?.board, "release")
        XCTAssertEqual(stream.starts.last?.since, 20)
        stream.emit(.events(events: [], cursor: 99, frameID: 99), startIndex: 0)
        XCTAssertEqual(state.liveCursor, 20)
        stream.emit(Self.eventsFrame(cursor: 21, kind: "task.created"))

        try await waitUntil { await client.boardCallCount == 3 }
        XCTAssertEqual(state.snapshot?.latestEventID, 21)
        state.setVisible(false)
    }

    func testRestoredBoardIsReconciledAndRestreamedAfterForeground() async {
        let server = URL(string: "https://example.test")!
        let suiteName = "KanbanLiveUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        KanbanBoardPreference.save("release", for: server, in: defaults)
        let client = LiveKanbanClient(
            boards: .multiple,
            boardResults: [.success(.release), .success(.releaseUpdated)]
        )
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream, defaults: defaults)

        await state.load()
        state.setVisible(true)
        XCTAssertEqual(state.selectedBoardSlug, "release")
        XCTAssertEqual(stream.starts.first?.board, "release")
        XCTAssertEqual(stream.starts.first?.since, 20)

        await state.setScenePhase(.background)
        await state.setScenePhase(.active)

        let boardRequests = await client.boardRequests
        XCTAssertEqual(boardRequests.map(\.board), ["release", "release"])
        XCTAssertEqual(boardRequests.last?.since, 20)
        XCTAssertEqual(state.snapshot?.latestEventID, 21)
        XCTAssertEqual(stream.starts.count, 2)
        XCTAssertEqual(stream.starts.last?.board, "release")
        state.setVisible(false)
    }

    func testPullToRefreshRetriesDelayedStreamAndNoticeClearsOnlyAfterHello() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(
            client: client,
            stream: stream,
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(5),
                reconnectDelays: [.zero, .zero],
                pollingInterval: .seconds(60),
                failuresBeforePolling: 3
            )
        )

        await state.load()
        state.setVisible(true)
        for expectedStarts in 2...3 {
            stream.failCurrent()
            try await waitUntil { stream.starts.count == expectedStarts }
        }
        stream.failCurrent()
        try await waitUntil { state.liveUpdatesDelayed }

        await state.refresh()

        XCTAssertTrue(state.liveUpdatesDelayed)
        XCTAssertEqual(stream.starts.count, 4)
        stream.emit(.hello(cursor: 13, board: "main"))
        XCTAssertFalse(state.liveUpdatesDelayed)
        state.setVisible(false)
    }

    func testPollingDelayDoesNotRetainFeatureState() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich)])
        let stream = KanbanStreamSpy()
        var state: KanbanFeatureState? = makeState(
            client: client,
            stream: stream,
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(5),
                reconnectDelays: [.zero, .zero],
                pollingInterval: .seconds(60),
                failuresBeforePolling: 3
            )
        )
        weak let releasedState = state

        await state?.load()
        state?.setVisible(true)
        for expectedStarts in 2...3 {
            stream.failCurrent()
            try await waitUntil { stream.starts.count == expectedStarts }
        }
        stream.failCurrent()
        try await waitUntil { state?.liveUpdatesDelayed == true }

        state = nil
        try await waitUntil { releasedState == nil }
    }

    func testServerVisibilityHandoffMakesOutgoingCallbacksInert() async throws {
        let firstClient = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let secondClient = LiveKanbanClient(boardResults: [.success(.rich)])
        let firstStream = KanbanStreamSpy()
        let secondStream = KanbanStreamSpy()
        let first = makeState(client: firstClient, stream: firstStream)
        let second = KanbanFeatureState(
            server: URL(string: "https://second.example.test")!,
            client: secondClient,
            streamClient: secondStream,
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(5),
                reconnectDelays: [.milliseconds(5)],
                pollingInterval: .seconds(60),
                failuresBeforePolling: 3
            )
        )

        await first.load()
        await second.load()
        first.setVisible(true)
        firstStream.emit(.hello(cursor: 11, board: "main"))

        first.setVisible(false)
        second.setVisible(true)
        firstStream.emit(Self.eventsFrame(cursor: 12, kind: "task.updated"), startIndex: 0)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertGreaterThanOrEqual(firstStream.stopCount, 1)
        let firstBoardCallCount = await firstClient.boardCallCount
        XCTAssertEqual(firstBoardCallCount, 1)
        XCTAssertEqual(first.liveCursor, 11)
        XCTAssertEqual(secondStream.starts.count, 1)
        second.setVisible(false)
    }

    // MARK: - Hermes socket (#1045)

    func testAHermesBoardStreamsFromItsCursorAndAFrameBurstReloadsItOnce() async {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)], backend: .hermes)
        let stream = KanbanStreamSpy()
        let clock = ScriptedClock()
        let state = makeState(client: client, stream: stream, sleep: clock.sleep)

        await state.load()
        state.setVisible(true)
        XCTAssertEqual(stream.starts, [.init(board: "main", since: 11)])
        stream.emit(.opened)
        stream.emit(Self.socketFrame(cursor: 12))
        stream.emit(Self.socketFrame(cursor: 13))

        await until("the burst's reload") { state.snapshot?.latestEventID == 13 }
        XCTAssertEqual(state.liveCursor, 13)
        let boardCallCount = await client.boardCallCount
        XCTAssertEqual(boardCallCount, 2, "one load and one coalesced reload")
        XCTAssertEqual(stream.starts.count, 1)
        state.setVisible(false)
    }

    func testAFailingHermesSocketBacksOffOneTwoFiveTenThenHoldsThirty() async {
        let client = LiveKanbanClient(boardResults: [.success(.rich)], backend: .hermes)
        let stream = KanbanStreamSpy()
        let clock = ScriptedClock(parking: [Self.pollingInterval])
        let state = makeState(client: client, stream: stream, timing: Self.hermesTiming, sleep: clock.sleep)

        await state.load()
        state.setVisible(true)
        for failure in 1...6 {
            stream.failCurrent()
            await until("reconnect \(failure)") { stream.starts.count == failure + 1 }
            XCTAssertEqual(state.liveUpdatesDelayed, failure >= 3, "failure \(failure)")
        }

        XCTAssertEqual(clock.durations.filter { $0 != Self.pollingInterval },
                       [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30), .seconds(30)])
        XCTAssertEqual(stream.starts.map(\.since), Array(repeating: 11, count: 7))
        state.setVisible(false)
    }

    func testThreeHermesFailuresPollTheBoardUntilTheSocketOpensAgain() async {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.unchanged(latest: 11))], backend: .hermes)
        let stream = KanbanStreamSpy()
        let clock = ScriptedClock(parking: [Self.pollingInterval])
        let state = makeState(client: client, stream: stream, timing: Self.hermesTiming, sleep: clock.sleep)

        await state.load()
        state.setVisible(true)
        for failure in 1...3 {
            stream.failCurrent()
            await until("reconnect \(failure)") { stream.starts.count == failure + 1 }
        }
        XCTAssertTrue(state.liveUpdatesDelayed)
        await until("the first poll waits") { clock.parkedCount(Self.pollingInterval) == 1 }

        clock.resume(Self.pollingInterval)
        await until("the poll's reload, then the next wait") { clock.durations.filter { $0 == Self.pollingInterval }.count == 2 }
        let boardRequests = await client.boardRequests
        XCTAssertEqual(boardRequests.map(\.since), [nil, 11], "the poll asks whether the Board moved past the one on screen")
        XCTAssertEqual(state.allCards.map(\.cardID), ["CARD-1"], "an unmoved Board stays as it is")
        XCTAssertTrue(state.liveUpdatesDelayed)

        stream.emit(.opened)
        XCTAssertFalse(state.liveUpdatesDelayed)
        await until("polling stops") { clock.parkedCount(Self.pollingInterval) == 0 }
        XCTAssertEqual(clock.cancelledCount, 1)
        state.setVisible(false)
    }

    /// A foreground check the host refuses (a tunnel's 502 while it restarts) is not
    /// offline and opens no socket, so the first poll that reaches the Board reopens it.
    func testAHermesPollAfterARefusedForegroundCheckReopensTheSocket() async {
        let client = LiveKanbanClient(boardResults: [
            .success(.rich),
            .failure(BotFailure.rejected(502)),
            .success(.unchanged(latest: 11))
        ], backend: .hermes)
        let stream = KanbanStreamSpy()
        let clock = ScriptedClock(parking: [Self.pollingInterval])
        let state = makeState(client: client, stream: stream, timing: Self.hermesTiming, sleep: clock.sleep)

        await state.load()
        state.setVisible(true)
        stream.emit(.opened)
        await state.setScenePhase(.background)
        await state.setScenePhase(.active)
        XCTAssertTrue(state.refreshFailed)
        XCTAssertFalse(state.isOffline)
        XCTAssertEqual(stream.starts.count, 1, "the refused check opens no socket")
        await until("the poll waits") { clock.parkedCount(Self.pollingInterval) == 1 }

        clock.resume(Self.pollingInterval)
        await until("the poll reopens the socket") { stream.starts.count == 2 }
        XCTAssertEqual(stream.starts.last, .init(board: "main", since: 11))
        XCTAssertFalse(state.refreshFailed)
        state.setVisible(false)
    }

    func testAHermesBoardReloadBelowTheCursorResetsItAndReconnects() async {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.recreated)], backend: .hermes)
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream, sleep: ScriptedClock().sleep)

        await state.load()
        state.setVisible(true)
        stream.emit(.opened)
        stream.emit(Self.socketFrame(cursor: 14))

        await until("the socket reopens at the lower cursor") { stream.starts.count == 2 }
        XCTAssertEqual(state.liveCursor, 3)
        XCTAssertEqual(stream.starts.last, .init(board: "main", since: 3))
        XCTAssertEqual(state.snapshot?.latestEventID, 3)
        state.setVisible(false)
    }

    /// The real socket client under the feature state: a socket that answers no ping is
    /// dead, and the next one opens on a fresh ticket at the cursor its frames reached.
    func testADeadHermesSocketReconnectsOnAFreshTicketAtTheCurrentCursor() async throws {
        let host = KanbanSocketHost()
        let socketClock = ScriptedClock(parking: [.seconds(25)])
        let stateClock = ScriptedClock()
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.cursor12)], backend: .hermes)
        let state = KanbanFeatureState(
            server: URL(string: "https://hermes-home.example")!,
            client: client,
            streamClient: KanbanWebSocketEventClient(http: host.connection(), options: .init(
                sleep: socketClock.sleep, socketFactory: host.script.makeSocket)),
            sleep: stateClock.sleep
        )

        await state.load()
        state.setVisible(true)
        await until("the first ping") { host.script.pingCount(0) == 1 }
        host.script.pong(0)
        host.script.deliver(Self.socketText(cursor: 12), on: 0)
        await until("the frame's reload") { state.snapshot?.latestEventID == 12 }

        // A ping goes out every 25 s; one still unanswered at the next ends the socket.
        socketClock.resume(.seconds(25))
        await until("the second ping") { host.script.pingCount(0) == 2 }
        socketClock.resume(.seconds(25))
        await until("the reconnect") { host.script.upgrades.count == 2 }

        XCTAssertTrue(host.script.isClosed(0))
        XCTAssertEqual(stateClock.durations, [.milliseconds(300), .seconds(1)], "the frame's debounce, then the first reconnect's 1 s")
        let upgrade = try XCTUnwrap(host.script.upgrades.last)
        XCTAssertEqual(upgrade.url?.queryValue("since"), "12")
        XCTAssertEqual(upgrade.url?.queryValue("ticket"), "ticket-2")
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 2)
        state.setVisible(false)
        await until("leaving closes the socket") { host.script.isClosed(1) }
    }

    func testEachHermesConnectMintsATicketForTheBoardsSocketWithTheSavedHeadersAndNoSubprotocol() async throws {
        let host = KanbanSocketHost()
        let events = KanbanSocketEvents()
        let client = KanbanWebSocketEventClient(http: host.connection(headers: [CustomHeader(name: "X-Access", value: "token")]),
                                                options: .init(sleep: ScriptedClock(parking: [.seconds(25)]).sleep,
                                                               socketFactory: host.script.makeSocket))

        client.start(board: "release board", since: 11, onFrame: events.frame, onFailure: events.failure)
        await until("the first upgrade") { host.script.upgrades.count == 1 }
        client.stop()
        client.start(board: "main", since: 12, onFrame: events.frame, onFailure: events.failure)
        await until("the second upgrade") { host.script.upgrades.count == 2 }

        let upgrades = host.script.upgrades
        XCTAssertEqual(upgrades.map { $0.url?.absoluteString }, [
            "wss://hermes.example/api/plugins/kanban/events?board=release%20board&since=11&ticket=ticket-1",
            "wss://hermes.example/api/plugins/kanban/events?board=main&since=12&ticket=ticket-2"
        ])
        for upgrade in upgrades {
            XCTAssertNil(upgrade.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "the host echoes no subprotocol")
            XCTAssertEqual(upgrade.value(forHTTPHeaderField: "X-Access"), "token")
        }
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 2)
        XCTAssertTrue(events.frames.isEmpty)
        XCTAssertEqual(events.failures, 0)
        client.stop()
    }

    func testA403OnTheHermesUpgradeTriesOneFreshTicketBeforeFailing() async {
        let host = KanbanSocketHost()
        host.script.refusals = [0: BotFailure.upgradeRefused(403), 1: BotFailure.upgradeRefused(403)]
        let events = KanbanSocketEvents()
        let client = KanbanWebSocketEventClient(http: host.connection(),
                                                options: .init(sleep: ScriptedClock(parking: [.seconds(25)]).sleep,
                                                               socketFactory: host.script.makeSocket))

        client.start(board: "main", since: 11, onFrame: events.frame, onFailure: events.failure)
        await until("the failure") { events.failures == 1 }

        XCTAssertEqual(host.script.upgrades.compactMap { $0.url?.queryValue("ticket") }, ["ticket-1", "ticket-2"])
        XCTAssertTrue(events.frames.isEmpty)
        client.start(board: "main", since: 11, onFrame: events.frame, onFailure: events.failure)
        await until("a later start's upgrade") { host.script.upgrades.count == 3 }
        await until("the later start opens") { host.script.pingCount(2) == 1 }
        host.script.pong(2)
        await until("open") { events.frames == [.opened] }
        XCTAssertEqual(events.failures, 1, "a 403 retry belongs to one start")
        client.stop()
    }

    func testAHermesSocketPingsEveryTwentyFiveSecondsAndAFrameCountsAsAPong() async {
        let host = KanbanSocketHost()
        let clock = ScriptedClock(parking: [.seconds(25)])
        let events = KanbanSocketEvents()
        let client = KanbanWebSocketEventClient(http: host.connection(),
                                                options: .init(sleep: clock.sleep, socketFactory: host.script.makeSocket))

        client.start(board: "main", since: 11, onFrame: events.frame, onFailure: events.failure)
        await until("the first ping") { host.script.pingCount(0) == 1 }
        XCTAssertTrue(events.frames.isEmpty, "the upgrade is not open until its first pong")
        host.script.pong(0)
        await until("open") { events.frames == [.opened] }

        clock.resume(.seconds(25))
        await until("the second ping") { host.script.pingCount(0) == 2 }
        host.script.deliver(#"{"events":[{"id":12,"task_id":"t_1","kind":"status","future":1}],"cursor":12,"future":true}"#, on: 0)
        await until("the frame") { events.frames.count == 2 }
        clock.resume(.seconds(25))
        await until("the third ping") { host.script.pingCount(0) == 3 }
        XCTAssertEqual(events.failures, 0, "a frame since the last ping keeps the socket")
        clock.resume(.seconds(25))
        await until("the failure") { events.failures == 1 }

        XCTAssertTrue(host.script.isClosed(0))
        guard case let .events(frameEvents, cursor, _) = events.frames[1] else {
            return XCTFail("Expected an events frame, got \(events.frames[1])")
        }
        XCTAssertEqual(cursor, 12)
        XCTAssertEqual(frameEvents.map(\.eventID), [12], "unknown keys are ignored")
        XCTAssertEqual(clock.durations, Array(repeating: .seconds(25), count: 3))
        client.stop()
    }

    func testAStoppedHermesSocketReportsNothingMore() async {
        let host = KanbanSocketHost()
        let events = KanbanSocketEvents()
        let client = KanbanWebSocketEventClient(http: host.connection(),
                                                options: .init(sleep: ScriptedClock(parking: [.seconds(25)]).sleep,
                                                               socketFactory: host.script.makeSocket))
        client.start(board: "main", since: 11, onFrame: events.frame, onFailure: events.failure)
        await until("the first ping") { host.script.pingCount(0) == 1 }
        host.script.pong(0)
        await until("open") { events.frames == [.opened] }

        client.stop()
        await until("the socket closes") { host.script.isClosed(0) }
        // Its read now fails, as a cancelled socket's does; the next start shows that went unreported.
        client.start(board: "main", since: 11, onFrame: events.frame, onFailure: events.failure)
        await until("the next socket's ping") { host.script.pingCount(1) == 1 }
        host.script.pong(1)
        await until("the next socket opens") { events.frames.count == 2 }

        XCTAssertEqual(events.frames, [.opened, .opened])
        XCTAssertEqual(events.failures, 0)
        client.stop()
    }

    private func makeState(
        client: any KanbanDataClient,
        stream: KanbanStreamSpy,
        timing: KanbanLiveUpdateTiming = KanbanLiveUpdateTiming(
            coalescingDelay: .milliseconds(5),
            reconnectDelays: [.milliseconds(5), .milliseconds(5)],
            pollingInterval: .seconds(60),
            failuresBeforePolling: 3
        ),
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        defaults: UserDefaults = .standard
    ) -> KanbanFeatureState {
        KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client,
            streamClient: stream,
            timing: timing,
            sleep: sleep,
            defaults: defaults
        )
    }

    /// Apart from the 30 s reconnect hold, so a test can tell the two waits apart.
    private static let pollingInterval = Duration.seconds(60)
    private static let hermesTiming = KanbanLiveUpdateTiming(
        coalescingDelay: .milliseconds(300),
        reconnectDelays: KanbanLiveUpdateTiming.production.reconnectDelays,
        pollingInterval: pollingInterval,
        failuresBeforePolling: 3
    )

    /// A Hermes socket frame, as `scripts/local-hermes` sends one.
    private static func socketText(cursor: Int) -> String {
        #"{"events":[{"id":\#(cursor),"task_id":"t_9b1c2d3e","run_id":null,"kind":"status","payload":{"status":"ready"},"created_at":1791251517}],"cursor":\#(cursor)}"#
    }

    private static func socketFrame(cursor: Int) -> KanbanStreamFrame {
        KanbanStreamFrameDecoder.decodeSocketFrame(Data(socketText(cursor: cursor).utf8))
    }

    /// Waits, without polling, for `condition`: it is checked again whenever an observable
    /// value it read changes.
    private func until(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            let changed = XCTestExpectation(description: description)
            withObservationTracking { _ = condition() } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 2) == .completed else {
                return XCTFail("Nothing changed while waiting for: \(description)", file: file, line: line)
            }
        }
    }

    private static func eventsFrame(cursor: Int, kind: String) -> KanbanStreamFrame {
        KanbanStreamFrameDecoder.decode(
            eventType: "events",
            data: #"{"events":[{"id":\#(cursor),"task_id":"CARD-1","kind":"\#(kind)","payload":{"value":"private"}}],"cursor":\#(cursor)}"#,
            frameID: String(cursor)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for condition")
    }
}

@MainActor @Observable
private final class KanbanStreamSpy: KanbanEventStreamingClient {
    struct Start: Equatable {
        let board: String
        let since: Int
    }

    private(set) var starts: [Start] = []
    private(set) var stopCount = 0
    @ObservationIgnored private var frameCallbacks: [@MainActor (KanbanStreamFrame) -> Void] = []
    @ObservationIgnored private var failureCallbacks: [@MainActor () -> Void] = []

    func start(
        board: String,
        since: Int,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        starts.append(Start(board: board, since: since))
        frameCallbacks.append(onFrame)
        failureCallbacks.append(onFailure)
    }

    func stop() { stopCount += 1 }

    func emit(_ frame: KanbanStreamFrame, startIndex: Int? = nil) {
        guard !frameCallbacks.isEmpty else { return }
        frameCallbacks[startIndex ?? (frameCallbacks.count - 1)](frame)
    }

    func failCurrent() {
        failureCallbacks.last?()
    }
}

/// Stands in for `Task.sleep`. A duration in `parking` waits until the test resumes it, and
/// throws `CancellationError` when its task is cancelled, like the real sleep; any other
/// returns at once. Observable, so a test waits for a sleep instead of polling for it.
@MainActor @Observable
private final class ScriptedClock {
    private(set) var durations: [Duration] = []
    private(set) var cancelledCount = 0
    @ObservationIgnored private let parking: Set<Duration>
    private var parked: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []

    init(parking: Set<Duration> = []) {
        self.parking = parking
    }

    var sleep: @MainActor @Sendable (Duration) async throws -> Void {
        { [self] duration in try await self.wait(duration) }
    }

    func parkedCount(_ duration: Duration) -> Int {
        parked.filter { $0.duration == duration }.count
    }

    /// Resumes the oldest waiting sleep of `duration`.
    func resume(_ duration: Duration, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = parked.firstIndex(where: { $0.duration == duration }) else {
            return XCTFail("No \(duration) sleep is waiting", file: file, line: line)
        }
        parked.remove(at: index).continuation.resume()
    }

    private func wait(_ duration: Duration) async throws {
        durations.append(duration)
        guard parking.contains(duration) else {
            await Task.yield()
            try Task.checkCancellation()
            return
        }
        let id = durations.count
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                parked.append((id, duration, continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let index = parked.firstIndex(where: { $0.id == id }) else { return }
        cancelledCount += 1
        parked.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// A scripted Hermes host for the Kanban socket: the fixture answers the sign-in and mints
/// `ticket-1`, `ticket-2`, … in order, and `script` stands in for the sockets.
@MainActor
private final class KanbanSocketHost {
    let script = KanbanSocketScript()
    private let id = UUID()

    func record(headers: [CustomHeader]? = nil) -> BotConnection {
        var record = BotConnection(id: id, name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        record.headers = headers
        return record
    }

    func connection(headers: [CustomHeader]? = nil) -> HermesConnection {
        var minted = 0
        return HermesConnection(connection: record(headers: headers), configuration: HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/auth/ws-ticket" else { return nil }
            minted += 1
            return .json(200, .object(["ticket": .string("ticket-\(minted)"), "ttl_seconds": .number(30)]))
        })
    }
}

/// The sockets one `KanbanWebSocketEventClient` opens, by index: it records each upgrade, parks
/// every ping until the test answers it, hands reads the frames the test delivers, and fails
/// both once the client cancels the socket, as a cancelled `URLSessionWebSocketTask` does.
@MainActor @Observable
private final class KanbanSocketScript {
    private(set) var upgrades: [URLRequest] = []
    /// Upgrade refusals by socket: its ping and read fail with this at once.
    var refusals: [Int: Error] = [:]
    private var pings: [Int: Int] = [:]
    private var closed: Set<Int> = []
    @ObservationIgnored private var parkedPings: [Int: [CheckedContinuation<Void, Error>]] = [:]
    @ObservationIgnored private var parkedReads: [Int: CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = [:]
    @ObservationIgnored private var queuedFrames: [Int: [String]] = [:]

    var makeSocket: (URLRequest) -> any KanbanSocket {
        { [unowned self] upgrade in
            self.upgrades.append(upgrade)
            return ScriptedKanbanSocket(index: self.upgrades.count - 1, script: self)
        }
    }

    func pingCount(_ socket: Int) -> Int { pings[socket, default: 0] }
    func isClosed(_ socket: Int) -> Bool { closed.contains(socket) }

    /// Answers `socket`'s oldest waiting ping.
    func pong(_ socket: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard var waiting = parkedPings[socket], !waiting.isEmpty else {
            return XCTFail("No ping is waiting on socket \(socket)", file: file, line: line)
        }
        let ping = waiting.removeFirst()
        parkedPings[socket] = waiting
        ping.resume()
    }

    /// Sends one text frame on `socket`, to the read waiting now or to its next one.
    func deliver(_ text: String, on socket: Int) {
        guard !closed.contains(socket) else { return }
        if let read = parkedReads.removeValue(forKey: socket) {
            read.resume(returning: .string(text))
        } else {
            queuedFrames[socket, default: []].append(text)
        }
    }

    fileprivate func ping(_ socket: Int, _ continuation: CheckedContinuation<Void, Error>) {
        pings[socket, default: 0] += 1
        if let refusal = refusals[socket] { return continuation.resume(throwing: refusal) }
        guard !closed.contains(socket) else { return continuation.resume(throwing: URLError(.cancelled)) }
        parkedPings[socket, default: []].append(continuation)
    }

    fileprivate func read(_ socket: Int, _ continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) {
        if let refusal = refusals[socket] { return continuation.resume(throwing: refusal) }
        guard !closed.contains(socket) else { return continuation.resume(throwing: URLError(.cancelled)) }
        if var queued = queuedFrames[socket], !queued.isEmpty {
            let text = queued.removeFirst()
            queuedFrames[socket] = queued
            return continuation.resume(returning: .string(text))
        }
        parkedReads[socket] = continuation
    }

    fileprivate func close(_ socket: Int) {
        closed.insert(socket)
        parkedReads.removeValue(forKey: socket)?.resume(throwing: URLError(.cancelled))
        for ping in parkedPings.removeValue(forKey: socket) ?? [] { ping.resume(throwing: URLError(.cancelled)) }
    }
}

/// One scripted socket; every call reaches its script on the main actor.
private final class ScriptedKanbanSocket: KanbanSocket, @unchecked Sendable {
    let index: Int
    let script: KanbanSocketScript

    init(index: Int, script: KanbanSocketScript) {
        self.index = index
        self.script = script
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in self.script.read(self.index, continuation) }
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in self.script.ping(self.index, continuation) }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func cancel() {
        Task { @MainActor in self.script.close(self.index) }
    }
}

/// What a `KanbanWebSocketEventClient` reported to its feature state.
@MainActor @Observable
private final class KanbanSocketEvents {
    private(set) var frames: [KanbanStreamFrame] = []
    private(set) var failures = 0

    var frame: @MainActor (KanbanStreamFrame) -> Void { { [weak self] in self?.frames.append($0) } }
    var failure: @MainActor () -> Void { { [weak self] in self?.failures += 1 } }
}

private actor LiveKanbanClient: KanbanDataClient {
    private var boardsResults: [Result<KanbanBoardsResponse, Error>]
    private var boardResults: [Result<KanbanBoardSnapshot, Error>]
    private let eventsResult: Result<KanbanEventsEnvelope, Error>
    private(set) var boardRequests: [KanbanBoardRequest] = []
    private(set) var boardsCallCount = 0
    private(set) var eventCallCount = 0
    private(set) var statsCallCount = 0
    private(set) var assigneeCallCount = 0
    private var statsFailuresRemaining: Int
    nonisolated let backend: KanbanBackend

    init(
        boards: KanbanBoardsResponse = .single,
        boardResults: [Result<KanbanBoardSnapshot, Error>],
        eventsResult: Result<KanbanEventsEnvelope, Error> = .success(.events(cursor: 11)),
        boardsResults: [Result<KanbanBoardsResponse, Error>]? = nil,
        statsFailures: Int = 0,
        backend: KanbanBackend = .webui
    ) {
        self.backend = backend
        self.boardsResults = boardsResults ?? [.success(boards)]
        self.boardResults = boardResults
        self.eventsResult = eventsResult
        statsFailuresRemaining = statsFailures
    }

    var boardCallCount: Int { boardRequests.count }

    func kanbanConfiguration() -> KanbanConfiguration { .liveConfiguration }
    func kanbanBoards() throws -> KanbanBoardsResponse {
        boardsCallCount += 1
        guard !boardsResults.isEmpty else { return .single }
        if boardsResults.count > 1 {
            return try boardsResults.removeFirst().get()
        }
        return try boardsResults[0].get()
    }

    func kanbanBoard(_ request: KanbanBoardRequest) throws -> KanbanBoardSnapshot {
        boardRequests.append(request)
        guard !boardResults.isEmpty else { return .newer }
        return try boardResults.removeFirst().get()
    }

    func kanbanStats(board: String) throws -> KanbanStats {
        statsCallCount += 1
        if statsFailuresRemaining > 0 {
            statsFailuresRemaining -= 1
            throw APIError.network(underlying: URLError(.timedOut))
        }
        return .emptyStats
    }

    func kanbanAssignees(board: String) -> KanbanAssigneeHistory {
        assigneeCallCount += 1
        return .emptyHistory
    }

    func dispatchKanban(_ request: KanbanDispatchRequest) -> KanbanDispatchResult {
        decode(
            #"{"spawned":[],"promoted":0,"reclaimed":0,"skipped_unassigned":[],"skipped_nonspawnable":[],"auto_blocked":[],"timed_out":[],"crashed":[]}"#
        )
    }

    func kanbanEvents(_ request: KanbanEventsRequest) throws -> KanbanEventsEnvelope {
        eventCallCount += 1
        return try eventsResult.get()
    }
}

/// Records whether the Board was refreshing each time the state started a sleep.
@MainActor
private final class RefreshingProbe {
    weak var state: KanbanFeatureState?
    private(set) var refreshingAtEachSleep: [Bool] = []

    func recordSleep() {
        refreshingAtEachSleep.append(state?.isRefreshing ?? true)
    }
}

/// Stands in for the polling timer: the first interval elapses at once and every
/// later one holds until the polling task is cancelled, so a test counts polls
/// exactly instead of racing a real timer. Other sleeps run for their duration.
@MainActor
private final class PollingProbe {
    static let interval = Duration.seconds(30)
    private(set) var intervalsStarted = 0

    func sleep(_ duration: Duration) async throws {
        guard duration == Self.interval else { return try await Task.sleep(for: duration) }
        intervalsStarted += 1
        if intervalsStarted > 1 { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// Returns the first Board load at once, then holds every later Board fetch until
/// the test releases it, so a burst can land while a live refresh is in flight.
/// `cancelsFirstStatsRead` models a pop that cancels the first load mid-reads.
private actor GatedLiveKanbanClient: KanbanDataClient {
    private(set) var boardCallCount = 0
    private(set) var statsCallCount = 0
    private(set) var assigneeCallCount = 0
    /// Held fetches that were released and handed their result back to the caller.
    private(set) var resumedFetchCount = 0
    private var pending: [CheckedContinuation<KanbanBoardSnapshot, Never>] = []
    private var cancelsNextStatsRead: Bool

    init(cancelsFirstStatsRead: Bool = false) {
        cancelsNextStatsRead = cancelsFirstStatsRead
    }

    func kanbanConfiguration() -> KanbanConfiguration { .liveConfiguration }
    func kanbanBoards() -> KanbanBoardsResponse { .single }

    func kanbanBoard(_ request: KanbanBoardRequest) async -> KanbanBoardSnapshot {
        boardCallCount += 1
        guard boardCallCount > 1 else { return .rich }
        let snapshot = await withCheckedContinuation { pending.append($0) }
        resumedFetchCount += 1
        return snapshot
    }

    /// Resumes the oldest held Board fetch with `snapshot`.
    func release(_ snapshot: KanbanBoardSnapshot) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: snapshot)
    }

    func kanbanStats(board: String) throws -> KanbanStats {
        statsCallCount += 1
        if cancelsNextStatsRead {
            cancelsNextStatsRead = false
            // Models a pop that cancels the Board's `.task` after the snapshot arrived.
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        return .emptyStats
    }

    func kanbanAssignees(board: String) -> KanbanAssigneeHistory {
        assigneeCallCount += 1
        return .emptyHistory
    }

    func kanbanEvents(_ request: KanbanEventsRequest) -> KanbanEventsEnvelope { .events(cursor: 11) }
}

private actor ForegroundBoardSwitchClient: KanbanDataClient {
    private var boardCallCount = 0
    private var foregroundContinuation: CheckedContinuation<Void, Never>?

    var foregroundRequestStarted: Bool { foregroundContinuation != nil }

    func kanbanConfiguration() -> KanbanConfiguration { .liveConfiguration }
    func kanbanBoards() -> KanbanBoardsResponse { .multiple }

    func kanbanBoard(_ request: KanbanBoardRequest) async -> KanbanBoardSnapshot {
        boardCallCount += 1
        switch boardCallCount {
        case 1:
            return .rich
        case 2:
            await withCheckedContinuation { foregroundContinuation = $0 }
            return .newer
        default:
            return request.board == "release" ? .release : .newer
        }
    }

    func finishForegroundRequest() {
        foregroundContinuation?.resume()
        foregroundContinuation = nil
    }

    func kanbanStats(board: String) -> KanbanStats { .emptyStats }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { .emptyHistory }
    func kanbanEvents(_ request: KanbanEventsRequest) -> KanbanEventsEnvelope { .events(cursor: 11) }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }
}

private extension KanbanConfiguration {
    static let liveConfiguration: Self = decode(#"{"columns":["triage","ready"],"read_only":false}"#)
}

private extension KanbanBoardsResponse {
    static let single: Self = decode(#"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#)
    static let multiple: Self = decode(#"{"boards":[{"slug":"main","name":"Main"},{"slug":"release","name":"Release"}],"current":"main","read_only":false}"#)
    static let incomplete: Self = decode(#"{"current":"main","read_only":false}"#)
}

private extension KanbanBoardSnapshot {
    static let rich: Self = decode(#"{"changed":true,"latest_event_id":11,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-1","status":"ready"}]}]}"#)
    static let newer: Self = decode(#"{"changed":true,"latest_event_id":13,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-2","status":"ready"}]}]}"#)
    static let cursor12: Self = decode(#"{"changed":true,"latest_event_id":12,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-1","status":"ready"}]}]}"#)
    static let cursor14: Self = decode(#"{"changed":true,"latest_event_id":14,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-3","status":"ready"}]}]}"#)
    static let cursor15: Self = decode(#"{"changed":true,"latest_event_id":15,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-4","status":"ready"}]}]}"#)
    static let release: Self = decode(#"{"changed":true,"latest_event_id":20,"read_only":false,"columns":[{"name":"triage","tasks":[]}]}"#)
    static func unchanged(latest: Int) -> Self {
        decode(#"{"changed":false,"latest_event_id":\#(latest),"read_only":false}"#)
    }
    /// The host's Kanban database was recreated: its ids restarted.
    static let recreated: Self = decode(#"{"changed":true,"latest_event_id":3,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-9","status":"ready"}]}]}"#)
    static let releaseUpdated: Self = decode(#"{"changed":true,"latest_event_id":21,"read_only":false,"columns":[{"name":"triage","tasks":[{"id":"REL-1","status":"triage"}]}]}"#)
}

private extension KanbanEventsEnvelope {
    static func events(cursor: Int) -> Self {
        decode(#"{"events":[{"id":\#(cursor),"task_id":"CARD-1","kind":"task.updated"}],"cursor":\#(cursor),"latest_event_id":\#(cursor),"read_only":false}"#)
    }
}

private extension KanbanStats {
    static let emptyStats: Self = decode(#"{"total":0,"by_status":{}}"#)
}

private extension KanbanAssigneeHistory {
    static let emptyHistory: Self = decode(#"{"assignees":[]}"#)
}

private func decode<T: Decodable>(_ json: String) -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(T.self, from: Data(json.utf8))
}
