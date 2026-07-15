import XCTest
@testable import HermesMobile

@MainActor
final class KanbanLiveUpdateTests: XCTestCase {
    func testVisibleBoardStartsAtSnapshotCursorAndCoalescesEventBurst() async throws {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)

        XCTAssertEqual(stream.startURLs.first?.queryValue("board"), "main")
        XCTAssertEqual(stream.startURLs.first?.queryValue("since"), "11")
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
        XCTAssertEqual(statsCallCount, 2)
        XCTAssertEqual(assigneeCallCount, 2)
        state.setVisible(false)
    }

    func testRepeatedFailuresFallBackToPollingWithoutRequestStorm() async throws {
        let client = LiveKanbanClient(
            boardResults: [.success(.rich), .success(.newer)],
            eventsResult: .success(.events(cursor: 13))
        )
        let stream = KanbanStreamSpy()
        let state = makeState(
            client: client,
            stream: stream,
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(5),
                reconnectDelays: [.zero, .zero],
                pollingInterval: .milliseconds(20),
                failuresBeforePolling: 3
            )
        )

        await state.load()
        state.setVisible(true)
        stream.failCurrent()
        try await waitUntil { stream.startURLs.count == 2 }
        stream.failCurrent()
        try await waitUntil { stream.startURLs.count == 3 }
        stream.failCurrent()

        try await waitUntil { state.liveUpdatesDelayed }
        try await waitUntil { await client.boardCallCount == 2 }
        let eventCallCount = await client.eventCallCount
        XCTAssertEqual(eventCallCount, 1)
        XCTAssertEqual(state.liveCursor, 13)
        XCTAssertEqual(stream.startURLs.count, 3)
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
        XCTAssertEqual(stream.startURLs.count, 2)
        state.setVisible(false)
    }

    func testBackgroundSuspendsAndForegroundReconcilesBeforeRestartingStream() async {
        let client = LiveKanbanClient(boardResults: [.success(.rich), .success(.newer)])
        let stream = KanbanStreamSpy()
        let state = makeState(client: client, stream: stream)

        await state.load()
        state.setVisible(true)
        XCTAssertEqual(stream.startURLs.count, 1)

        await state.setSceneActive(false)
        XCTAssertGreaterThanOrEqual(stream.stopCount, 1)
        stream.emit(.events(events: [], cursor: 99, frameID: 99), startIndex: 0)
        XCTAssertEqual(state.liveCursor, 11)

        await state.setSceneActive(true)

        let boardCallCount = await client.boardCallCount
        XCTAssertEqual(boardCallCount, 2)
        XCTAssertEqual(state.snapshot?.latestEventID, 13)
        XCTAssertEqual(stream.startURLs.count, 2)
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
        await state.setSceneActive(false)

        let foreground = Task { await state.setSceneActive(true) }
        try await waitUntil { await client.foregroundRequestStarted }
        await state.selectBoard("release")
        let stopCountAfterSwitch = stream.stopCount

        await client.finishForegroundRequest()
        await foreground.value

        XCTAssertEqual(state.selectedBoardSlug, "release")
        XCTAssertEqual(stream.startURLs.last?.queryValue("board"), "release")
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

        XCTAssertEqual(stream.startURLs.count, 2)
        XCTAssertEqual(stream.startURLs.last?.queryValue("board"), "release")
        XCTAssertEqual(stream.startURLs.last?.queryValue("since"), "20")
        stream.emit(.events(events: [], cursor: 99, frameID: 99), startIndex: 0)
        XCTAssertEqual(state.liveCursor, 20)
        stream.emit(Self.eventsFrame(cursor: 21, kind: "task.created"))

        try await waitUntil { await client.boardCallCount == 3 }
        XCTAssertEqual(state.snapshot?.latestEventID, 21)
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
            try await waitUntil { stream.startURLs.count == expectedStarts }
        }
        stream.failCurrent()
        try await waitUntil { state.liveUpdatesDelayed }

        await state.refresh()

        XCTAssertTrue(state.liveUpdatesDelayed)
        XCTAssertEqual(stream.startURLs.count, 4)
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
            try await waitUntil { stream.startURLs.count == expectedStarts }
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
        XCTAssertEqual(secondStream.startURLs.count, 1)
        second.setVisible(false)
    }

    private func makeState(
        client: LiveKanbanClient,
        stream: KanbanStreamSpy,
        timing: KanbanLiveUpdateTiming = KanbanLiveUpdateTiming(
            coalescingDelay: .milliseconds(5),
            reconnectDelays: [.milliseconds(5), .milliseconds(5)],
            pollingInterval: .seconds(60),
            failuresBeforePolling: 3
        )
    ) -> KanbanFeatureState {
        KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client,
            streamClient: stream,
            timing: timing
        )
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

@MainActor
private final class KanbanStreamSpy: KanbanEventStreamingClient {
    private(set) var startURLs: [URL] = []
    private(set) var stopCount = 0
    private var frameCallbacks: [@MainActor (KanbanStreamFrame) -> Void] = []
    private var failureCallbacks: [@MainActor () -> Void] = []

    func start(
        url: URL,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        startURLs.append(url)
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

private actor LiveKanbanClient: KanbanDataClient {
    private let boards: KanbanBoardsResponse
    private var boardResults: [Result<KanbanBoardSnapshot, Error>]
    private let eventsResult: Result<KanbanEventsEnvelope, Error>
    private(set) var boardRequests: [KanbanBoardRequest] = []
    private(set) var eventCallCount = 0
    private(set) var statsCallCount = 0
    private(set) var assigneeCallCount = 0

    init(
        boards: KanbanBoardsResponse = .single,
        boardResults: [Result<KanbanBoardSnapshot, Error>],
        eventsResult: Result<KanbanEventsEnvelope, Error> = .success(.events(cursor: 11))
    ) {
        self.boards = boards
        self.boardResults = boardResults
        self.eventsResult = eventsResult
    }

    var boardCallCount: Int { boardRequests.count }

    func kanbanConfiguration() -> KanbanConfiguration { .liveConfiguration }
    func kanbanBoards() -> KanbanBoardsResponse { boards }

    func kanbanBoard(_ request: KanbanBoardRequest) throws -> KanbanBoardSnapshot {
        boardRequests.append(request)
        guard !boardResults.isEmpty else { return .newer }
        return try boardResults.removeFirst().get()
    }

    func kanbanStats(board: String) -> KanbanStats {
        statsCallCount += 1
        return .emptyStats
    }

    func kanbanAssignees(board: String) -> KanbanAssigneeHistory {
        assigneeCallCount += 1
        return .emptyHistory
    }

    func kanbanEvents(_ request: KanbanEventsRequest) throws -> KanbanEventsEnvelope {
        eventCallCount += 1
        return try eventsResult.get()
    }
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
}

private extension KanbanBoardSnapshot {
    static let rich: Self = decode(#"{"changed":true,"latest_event_id":11,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-1","status":"ready"}]}]}"#)
    static let newer: Self = decode(#"{"changed":true,"latest_event_id":13,"read_only":false,"columns":[{"name":"ready","tasks":[{"id":"CARD-2","status":"ready"}]}]}"#)
    static let release: Self = decode(#"{"changed":true,"latest_event_id":20,"read_only":false,"columns":[{"name":"triage","tasks":[]}]}"#)
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
