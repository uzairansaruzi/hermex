import XCTest
@testable import HermesMobile

@MainActor
final class KanbanCardDetailStateTests: XCTestCase {
    func testCommentSuccessClearsDraftAndRefreshesCanonicalDetail() async {
        let client = CardDetailClient(
            details: [.success(.baseline), .success(.withComment)],
            commentResult: .success(.accepted)
        )
        let state = makeState(client: client)

        await state.load()
        state.commentDraft = "  Ready for review  "
        await state.submitComment(allowsMutation: true)

        XCTAssertEqual(state.commentSubmission, .succeeded)
        XCTAssertEqual(state.commentDraft, "")
        XCTAssertEqual(state.detail?.comments?.last?.body, "Ready for review")
        let bodies = await client.submittedBodies
        XCTAssertEqual(bodies, ["Ready for review"])
    }

    func testBlankAndDefinitiveFailureNeverBlindlyRetry() async {
        let client = CardDetailClient(
            details: [.success(.baseline)],
            commentResult: .failure(APIError.http(statusCode: 400, body: #"{"error":"body is required"}"#))
        )
        let state = makeState(client: client)
        await state.load()

        state.commentDraft = "  \n "
        await state.submitComment(allowsMutation: true)
        XCTAssertEqual(state.commentSubmission, .validationFailed)
        var calls = await client.commentCallCount
        XCTAssertEqual(calls, 0)

        state.commentDraft = "Retry only when asked"
        await state.submitComment(allowsMutation: true)
        XCTAssertEqual(state.commentSubmission, .failed)
        calls = await client.commentCallCount
        XCTAssertEqual(calls, 1)
    }

    func testAmbiguousCommentOutcomeReconcilesPresentAbsentAndUncertain() async {
        let network = APIError.network(underlying: URLError(.networkConnectionLost))

        let presentClient = CardDetailClient(
            details: [.success(.baseline), .success(.withComment)],
            commentResult: .failure(network)
        )
        let present = makeState(client: presentClient)
        await present.load()
        present.commentDraft = "Ready for review"
        await present.submitComment(allowsMutation: true)
        XCTAssertEqual(present.commentSubmission, .succeeded)
        XCTAssertEqual(present.commentDraft, "")

        let absentClient = CardDetailClient(
            details: [.success(.baseline), .success(.baseline)],
            commentResult: .failure(network)
        )
        let absent = makeState(client: absentClient)
        await absent.load()
        absent.commentDraft = "Ready for review"
        await absent.submitComment(allowsMutation: true)
        XCTAssertEqual(absent.commentSubmission, .failed)
        XCTAssertEqual(absent.commentDraft, "Ready for review")

        let uncertainClient = CardDetailClient(
            details: [.success(.baseline), .failure(network), .success(.withComment)],
            commentResult: .failure(network)
        )
        let uncertain = makeState(client: uncertainClient)
        await uncertain.load()
        uncertain.commentDraft = "Ready for review"
        await uncertain.submitComment(allowsMutation: true)
        XCTAssertEqual(uncertain.commentSubmission, .outcomeUncertain)
        await uncertain.refresh()
        XCTAssertEqual(uncertain.commentSubmission, .succeeded)
    }

    func testCancelledCommentDoesNotSpawnOutcomeOrMissingEntityReads() async {
        let client = CardDetailClient(
            details: [.success(.baseline)],
            commentResult: .failure(APIError.network(underlying: URLError(.cancelled)))
        )
        let state = makeState(client: client)
        await state.load()
        state.commentDraft = "Do not reconcile after cancellation"

        await state.submitComment(allowsMutation: true)

        XCTAssertEqual(state.commentSubmission, .submitting)
        let detailCalls = await client.detailCallCount
        let boardCalls = await client.boardCallCount
        XCTAssertEqual(detailCalls, 1)
        XCTAssertEqual(boardCalls, 0)
    }

    func testLiveReconciliationKeepsDetailOpenAndAppliesRemoteStatus() async {
        let client = CardDetailClient(details: [.success(.baseline), .success(.done)])
        let state = makeState(client: client)

        await state.load()
        await state.reconcile(revision: 1)

        XCTAssertEqual(state.loadState, .loaded)
        XCTAssertEqual(state.detail?.card?.status?.rawValue, "done")
    }

    func testRefreshStartedBeforeCommentCannotReplaceNewerDetail() async throws {
        let client = StaleDetailClient()
        let state = makeState(client: client)
        await state.load()

        let staleRefresh = Task { await state.reconcile(revision: 1) }
        try await waitUntil { await client.staleReadStarted }
        state.commentDraft = "Ready for review"
        await state.submitComment(allowsMutation: true)
        await client.finishStaleRead()
        await staleRefresh.value

        XCTAssertEqual(state.commentSubmission, .succeeded)
        XCTAssertEqual(state.detail?.comments?.last?.body, "Ready for review")
        XCTAssertEqual(state.detail?.card?.status?.rawValue, "done")
    }

    func testStaleMissingEntityCheckCannotReplaceNewerSuccessfulDetail() async throws {
        let client = StaleMissingEntityClient()
        let state = makeState(client: client)

        let missingLoad = Task { await state.load() }
        try await waitUntil { await client.boardReadStarted }
        await state.refresh()
        XCTAssertEqual(state.loadState, .loaded)

        await client.finishBoardRead()
        await missingLoad.value

        XCTAssertEqual(state.loadState, .loaded)
        XCTAssertEqual(state.detail?.card?.cardID, "CARD-1")
    }

    func testMissingCardAndBoardUseReconciledExplanatoryStates() async {
        let notFound = APIError.http(statusCode: 404, body: #"{"error":"not found"}"#)
        let missingCardClient = CardDetailClient(
            details: [.failure(notFound)],
            boards: .main
        )
        let missingCard = makeState(client: missingCardClient)
        await missingCard.load()
        XCTAssertEqual(missingCard.loadState, .missingCard)

        let missingBoardClient = CardDetailClient(
            details: [.failure(notFound)],
            boards: .other
        )
        let missingBoard = makeState(client: missingBoardClient)
        await missingBoard.load()
        XCTAssertEqual(missingBoard.loadState, .missingBoard)
    }

    func testWorkerLogDistinguishesAbsentTruncatedAndFailed() async {
        let absentClient = CardDetailClient(logResult: .success(.absent))
        let absent = makeState(client: absentClient)
        await absent.loadWorkerLog()
        XCTAssertEqual(absent.workerLogState, .absent)

        let truncatedClient = CardDetailClient(logResult: .success(.truncatedFixture))
        let truncated = makeState(client: truncatedClient)
        await truncated.loadWorkerLog()
        guard case let .loaded(log) = truncated.workerLogState else {
            return XCTFail("Expected loaded log")
        }
        XCTAssertEqual(log.truncated, true)

        let failedClient = CardDetailClient(
            logResult: .failure(APIError.network(underlying: URLError(.notConnectedToInternet)))
        )
        let failed = makeState(client: failedClient)
        await failed.loadWorkerLog()
        XCTAssertEqual(failed.workerLogState, .failed)
    }

    func testSeparateStatesNeverCrossServerData() async {
        let first = makeState(client: CardDetailClient(details: [.success(.baseline)]))
        let second = KanbanCardDetailState(
            cardID: "CARD-2",
            board: "other",
            client: CardDetailClient(details: [.success(.otherServer)])
        )

        await first.load()
        await second.load()

        XCTAssertEqual(first.detail?.card?.cardID, "CARD-1")
        XCTAssertEqual(second.detail?.card?.cardID, "CARD-2")
        XCTAssertEqual(second.board, "other")
    }

    private func makeState(client: any KanbanDataClient) -> KanbanCardDetailState {
        KanbanCardDetailState(cardID: "CARD-1", board: "main", client: client)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met before timeout")
    }
}

private actor CardDetailClient: KanbanDataClient {
    private var details: [Result<KanbanCardDetailEnvelope, Error>]
    private let boardsResponse: KanbanBoardsResponse
    private let commentResult: Result<KanbanAddCommentResponse, Error>
    private let logResult: Result<KanbanWorkerLog, Error>
    private(set) var submittedBodies: [String] = []
    private(set) var commentCallCount = 0
    private(set) var detailCallCount = 0
    private(set) var boardCallCount = 0

    init(
        details: [Result<KanbanCardDetailEnvelope, Error>] = [],
        boards: KanbanBoardsResponse = .main,
        commentResult: Result<KanbanAddCommentResponse, Error> = .success(.accepted),
        logResult: Result<KanbanWorkerLog, Error> = .success(.absent)
    ) {
        self.details = details
        boardsResponse = boards
        self.commentResult = commentResult
        self.logResult = logResult
    }

    func kanbanConfiguration() -> KanbanConfiguration { decode(#"{"columns":["ready"],"read_only":false}"#) }
    func kanbanBoards() -> KanbanBoardsResponse {
        boardCallCount += 1
        return boardsResponse
    }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot { decode(#"{"changed":true,"columns":[{"name":"ready","tasks":[]}],"read_only":false}"#) }
    func kanbanStats(board: String) -> KanbanStats { decode("{}") }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { decode("{}") }
    func kanbanEvents(_ request: KanbanEventsRequest) -> KanbanEventsEnvelope { decode("{}") }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) throws -> KanbanCardDetailEnvelope {
        detailCallCount += 1
        guard !details.isEmpty else { return .baseline }
        return try details.removeFirst().get()
    }

    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) throws -> KanbanWorkerLog {
        try logResult.get()
    }

    func addKanbanComment(_ request: KanbanAddCommentRequest) throws -> KanbanAddCommentResponse {
        commentCallCount += 1
        submittedBodies.append(request.body)
        return try commentResult.get()
    }
}

private actor StaleMissingEntityClient: KanbanDataClient {
    private var detailCallCount = 0
    private var boardContinuation: CheckedContinuation<KanbanBoardsResponse, Never>?
    private(set) var boardReadStarted = false

    func kanbanConfiguration() -> KanbanConfiguration { decode(#"{"columns":["ready"],"read_only":false}"#) }
    func kanbanBoards() async -> KanbanBoardsResponse {
        boardReadStarted = true
        return await withCheckedContinuation { boardContinuation = $0 }
    }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot { decode(#"{"changed":true,"columns":[{"name":"ready","tasks":[]}],"read_only":false}"#) }
    func kanbanStats(board: String) -> KanbanStats { decode("{}") }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { decode("{}") }
    func kanbanEvents(_ request: KanbanEventsRequest) -> KanbanEventsEnvelope { decode("{}") }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) throws -> KanbanCardDetailEnvelope {
        detailCallCount += 1
        if detailCallCount == 1 {
            throw APIError.http(statusCode: 404, body: nil)
        }
        return .baseline
    }

    func finishBoardRead() {
        boardContinuation?.resume(returning: .other)
        boardContinuation = nil
    }
}

private actor StaleDetailClient: KanbanDataClient {
    private var detailCallCount = 0
    private var staleContinuation: CheckedContinuation<KanbanCardDetailEnvelope, Never>?
    private(set) var staleReadStarted = false

    func kanbanConfiguration() -> KanbanConfiguration { decode(#"{"columns":["ready"],"read_only":false}"#) }
    func kanbanBoards() -> KanbanBoardsResponse { .main }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot { decode(#"{"changed":true,"columns":[{"name":"ready","tasks":[]}],"read_only":false}"#) }
    func kanbanStats(board: String) -> KanbanStats { decode("{}") }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { decode("{}") }
    func kanbanEvents(_ request: KanbanEventsRequest) -> KanbanEventsEnvelope { decode("{}") }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async -> KanbanCardDetailEnvelope {
        detailCallCount += 1
        switch detailCallCount {
        case 1:
            return .baseline
        case 2:
            staleReadStarted = true
            return await withCheckedContinuation { staleContinuation = $0 }
        default:
            return .withComment
        }
    }

    func addKanbanComment(_ request: KanbanAddCommentRequest) -> KanbanAddCommentResponse { .accepted }

    func finishStaleRead() {
        staleContinuation?.resume(returning: .baseline)
        staleContinuation = nil
    }
}

private extension KanbanCardDetailEnvelope {
    static let baseline: Self = decodeDetail(
        #"{"task":{"id":"CARD-1","title":"One","status":"ready"},"comments":[],"events":[],"links":{"parents":[],"children":[]},"runs":[],"read_only":false}"#
    )
    static let withComment: Self = decodeDetail(
        #"{"task":{"id":"CARD-1","title":"One","status":"done"},"comments":[{"id":1,"body":"Ready for review"}],"events":[],"links":{"parents":[],"children":[]},"runs":[],"read_only":false}"#
    )
    static let done: Self = decodeDetail(
        #"{"task":{"id":"CARD-1","title":"One","status":"done"},"comments":[],"read_only":false}"#
    )
    static let otherServer: Self = decodeDetail(
        #"{"task":{"id":"CARD-2","title":"Two","status":"ready"},"comments":[],"read_only":false}"#
    )
}

private extension KanbanBoardsResponse {
    static let main: Self = decode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#)
    static let other: Self = decode(#"{"boards":[{"slug":"other"}],"current":"other","read_only":false}"#)
}

private extension KanbanAddCommentResponse {
    static let accepted: Self = decode(#"{"ok":true,"comment_id":1,"read_only":false}"#)
}

private extension KanbanWorkerLog {
    static let absent: Self = decode(#"{"task_id":"CARD-1","exists":false,"size_bytes":0,"content":"","truncated":false}"#)
    static let truncatedFixture: Self = decode(#"{"task_id":"CARD-1","exists":true,"size_bytes":70000,"content":"tail","truncated":true}"#)
}

private func decodeDetail(_ json: String) -> KanbanCardDetailEnvelope {
    decode(json)
}

private func decode<T: Decodable>(_ json: String) -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(T.self, from: Data(json.utf8))
}
