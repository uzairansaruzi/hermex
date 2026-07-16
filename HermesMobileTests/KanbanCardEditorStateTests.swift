import XCTest
@testable import HermesMobile

@MainActor
final class KanbanCardEditorStateTests: XCTestCase {
    func testValidationBlocksBlankTitleInvalidPriorityRuntimeWorkspaceAndPrerequisite() async {
        let client = CardEditorClient()
        let state = makeCreateState(client: client)

        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .validationFailed(.title))

        state.title = "Valid"
        state.priorityText = "1.5"
        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .validationFailed(.priority))

        state.priorityText = "0"
        state.workspaceKind = "worktree"
        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .validationFailed(.workspacePath))

        state.workspacePath = "/workspace"
        state.maximumRuntimeText = "0"
        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .validationFailed(.maximumRuntime))

        state.maximumRuntimeText = "60"
        state.prerequisiteID = String(repeating: "x", count: 256)
        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .validationFailed(.prerequisite))
        let callCount = await client.createCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testReadyUnassignedRequiresConfirmationAndOfflineGateBlocksWrite() async {
        let client = CardEditorClient(createResults: [.success(.createdReady)])
        let state = makeCreateState(client: client)
        state.title = "Ready work"
        state.status = "ready"

        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .idle)
        var callCount = await client.createCallCount
        XCTAssertEqual(callCount, 0)

        await state.save(allowsMutation: false, readyUnassignedConfirmed: true)
        XCTAssertEqual(state.submission, .failed)
        callCount = await client.createCallCount
        XCTAssertEqual(callCount, 0)

        state.dismissError()
        await state.save(allowsMutation: true, readyUnassignedConfirmed: true)
        XCTAssertEqual(state.submission, .succeeded(cardID: "CARD-153"))
        callCount = await client.createCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testRetryReusesOriginalIdempotencyKey() async {
        let client = CardEditorClient(createResults: [
            .failure(APIError.http(statusCode: 400, body: nil)),
            .success(.createdTriage)
        ])
        let state = makeCreateState(client: client, idempotencyKey: "fixed-intent")
        state.title = "Retry me"

        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .failed)
        state.dismissError()
        await state.save(allowsMutation: true)

        XCTAssertEqual(state.submission, .succeeded(cardID: "CARD-153"))
        let keys = await client.idempotencyKeys
        XCTAssertEqual(keys, ["fixed-intent", "fixed-intent"])
    }

    func testAmbiguousCreateReconcilesPresentAbsentAndUncertainWithoutBlindRetry() async {
        let lost = APIError.network(underlying: URLError(.networkConnectionLost))

        let presentClient = CardEditorClient(
            createResults: [.failure(lost)],
            boardResults: [.success(.withCreatedTriage)]
        )
        let present = makeCreateState(client: presentClient)
        present.title = "Retry me"
        await present.save(allowsMutation: true)
        XCTAssertEqual(present.submission, .succeeded(cardID: "CARD-153"))
        let presentCalls = await presentClient.createCallCount
        XCTAssertEqual(presentCalls, 1)

        let absentClient = CardEditorClient(
            createResults: [.failure(lost)],
            boardResults: [.success(.empty)]
        )
        let absent = makeCreateState(client: absentClient)
        absent.title = "Retry me"
        await absent.save(allowsMutation: true)
        XCTAssertEqual(absent.submission, .failed)
        let absentCalls = await absentClient.createCallCount
        XCTAssertEqual(absentCalls, 1)

        let uncertainClient = CardEditorClient(
            createResults: [.failure(lost)],
            boardResults: [.failure(lost)]
        )
        let uncertain = makeCreateState(client: uncertainClient)
        uncertain.title = "Retry me"
        await uncertain.save(allowsMutation: true)
        XCTAssertEqual(uncertain.submission, .outcomeUncertain)
        let uncertainCalls = await uncertainClient.createCallCount
        XCTAssertEqual(uncertainCalls, 1)
    }

    func testEditConflictPreservesDraftAndOffersReloadOrOverwrite() async {
        let client = CardEditorClient(
            editResults: [.success(.overwritten)],
            detailResults: [.success(.remoteChanged)]
        )
        let state = makeEditState(client: client)
        state.title = "My local draft"

        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .conflict)
        XCTAssertEqual(state.title, "My local draft")
        XCTAssertEqual(state.remoteCard?.title, "Changed remotely")
        var editCalls = await client.editCallCount
        XCTAssertEqual(editCalls, 0)

        await state.save(allowsMutation: true, overwriteConflict: true)
        XCTAssertEqual(state.submission, .succeeded(cardID: "CARD-1"))
        editCalls = await client.editCallCount
        XCTAssertEqual(editCalls, 1)

        let reloadClient = CardEditorClient(detailResults: [.success(.remoteChanged)])
        let reload = makeEditState(client: reloadClient)
        reload.title = "Discard me"
        await reload.save(allowsMutation: true)
        reload.reloadServerVersion()
        XCTAssertEqual(reload.submission, .idle)
        XCTAssertEqual(reload.title, "Changed remotely")
    }

    func testPreflightReadFailureIsNotReportedAsUncertainWrite() async {
        let client = CardEditorClient(detailResults: [
            .failure(APIError.network(underlying: URLError(.notConnectedToInternet)))
        ])
        let state = makeEditState(client: client)
        state.title = "Draft"

        await state.save(allowsMutation: true)

        XCTAssertEqual(state.submission, .failed)
        let calls = await client.editCallCount
        XCTAssertEqual(calls, 0)
    }

    func testConflictOverwriteAcceptsServerStatusWhenDraftDidNotChangeStatus() async {
        let client = CardEditorClient(
            editResults: [.success(.overwrittenRunning)],
            detailResults: [.success(.remoteChangedRunning)]
        )
        let state = makeEditState(client: client)
        state.title = "My local draft"

        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .conflict)
        XCTAssertEqual(state.remoteCard?.status?.rawValue, "running")

        await state.save(allowsMutation: true, overwriteConflict: true)
        XCTAssertEqual(state.submission, .succeeded(cardID: "CARD-1"))
        let request = await client.lastEditRequest
        XCTAssertNil(request?.status)
    }

    func testAmbiguousEditReconcilesCanonicalResultAndPreservesCreateOnlyFields() async {
        let lost = APIError.network(underlying: URLError(.cancelled))
        let client = CardEditorClient(
            editResults: [.failure(lost)],
            detailResults: [.success(.baseline), .success(.edited)]
        )
        let state = makeEditState(client: client)
        state.title = "Edited"
        state.workspaceKind = "scratch"
        state.workspacePath = ""
        state.skillsText = "changed"
        state.maximumRuntimeText = "1"
        state.prerequisiteID = "OTHER"

        await state.save(allowsMutation: true)

        XCTAssertEqual(state.submission, .succeeded(cardID: "CARD-1"))
        let request = await client.lastEditRequest
        XCTAssertEqual(request?.title, "Edited")
        XCTAssertEqual(request?.status, nil)
    }

    func testEditingRunningCardDoesNotMoveItUnlessUserChoosesDestination() async {
        let client = CardEditorClient(
            editResults: [.success(.runningEdited)],
            detailResults: [.success(.runningBaseline)]
        )
        let state = KanbanCardEditorState(
            mode: .edit(cardID: "CARD-1"),
            board: "main",
            client: client,
            card: .runningBaseline
        )
        state.title = "Edited while running"

        await state.save(allowsMutation: true)

        XCTAssertEqual(state.submission, .succeeded(cardID: "CARD-1"))
        let request = await client.lastEditRequest
        XCTAssertNil(request?.status)
    }

    func testSaveIsSerializedWhilePreflightIsInFlight() async throws {
        let client = StaleEditorClient()
        let state = KanbanCardEditorState(
            mode: .edit(cardID: "CARD-1"),
            board: "main",
            client: client,
            card: .baseline
        )
        state.title = "Edited"

        let staleSave = Task { await state.save(allowsMutation: true) }
        try await waitUntil { await client.firstReadStarted }
        await state.save(allowsMutation: true)
        await client.finishFirstRead(with: .baseline)
        await staleSave.value

        XCTAssertEqual(state.submission, .succeeded(cardID: "CARD-1"))
        let calls = await client.editCallCount
        XCTAssertEqual(calls, 1)
    }

    func testDraftInvalidatedDuringPreflightFailsValidationWithoutWriting() async throws {
        let client = StaleEditorClient()
        let state = KanbanCardEditorState(
            mode: .edit(cardID: "CARD-1"),
            board: "main",
            client: client,
            card: .baseline
        )
        state.title = "Edited"

        let save = Task { await state.save(allowsMutation: true) }
        try await waitUntil { await client.firstReadStarted }
        state.priorityText = "5.5"
        await client.finishFirstRead(with: .baseline)
        await save.value

        XCTAssertEqual(state.submission, .validationFailed(.priority))
        let calls = await client.editCallCount
        XCTAssertEqual(calls, 0)
    }

    func testReloadServerVersionRefreshesDisplayedCreateOnlyPrerequisite() async {
        let client = CardEditorClient(detailResults: [.success(.remoteChangedPrerequisite)])
        let state = makeEditState(client: client)
        state.title = "Local draft"

        await state.save(allowsMutation: true)
        XCTAssertEqual(state.submission, .conflict)
        state.reloadServerVersion()

        XCTAssertEqual(state.prerequisiteID, "CARD-2")
        XCTAssertEqual(state.title, "Changed remotely")
    }

    private func makeCreateState(
        client: CardEditorClient,
        idempotencyKey: String = "intent"
    ) -> KanbanCardEditorState {
        KanbanCardEditorState(
            mode: .create,
            board: "main",
            client: client,
            prerequisiteOptions: [.prerequisite],
            idempotencyKey: idempotencyKey
        )
    }

    private func makeEditState(client: CardEditorClient) -> KanbanCardEditorState {
        KanbanCardEditorState(
            mode: .edit(cardID: "CARD-1"),
            board: "main",
            client: client,
            card: .baseline,
            prerequisiteID: "CARD-0",
            prerequisiteOptions: [.prerequisite]
        )
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

final class KanbanLabClientMutationTests: XCTestCase {
    @MainActor
    func testCompleteEditorSubmissionSucceedsAgainstLabAdapter() async throws {
        let client = KanbanLabClient(scenario: .dense)
        let state = KanbanCardEditorState(
            mode: .create,
            board: "main",
            client: client,
            idempotencyKey: "editor-intent"
        )
        state.title = "Complete fixture Card"
        state.body = "Every create field"
        state.priorityText = "2"
        state.assignee = "builder"
        state.tenant = "app"
        state.workspaceKind = "dir"
        state.workspacePath = "/Users/hermes"
        state.skillsText = "x-writing-guide, grill-me"
        state.maximumRuntimeText = "20"
        state.prerequisiteID = "CARD-1"

        await state.save(allowsMutation: true)

        guard case let .succeeded(cardID) = state.submission else {
            return XCTFail("Expected the lab editor submission to succeed, got \(state.submission)")
        }
        let board = try await client.kanbanBoard(KanbanBoardRequest(board: "main"))
        XCTAssertEqual(
            (board.columns ?? []).flatMap { $0.cards ?? [] }.first { $0.cardID == cardID }?.title,
            "Complete fixture Card"
        )
    }

    func testCreatePersistsFullCardAndReusesIdempotencyKey() async throws {
        let client = KanbanLabClient(scenario: .dense)
        let request = KanbanCreateCardRequest(
            board: "main",
            title: "Complete fixture Card",
            body: "Every create field",
            status: "triage",
            priority: 2,
            assignee: "builder",
            tenant: "app",
            workspaceKind: "dir",
            workspacePath: "/Users/hermes",
            skills: ["x-writing-guide", "grill-me"],
            maxRuntimeSeconds: 20,
            prerequisiteID: "CARD-1",
            idempotencyKey: "lab-intent"
        )

        let first = try await client.createKanbanCard(request)
        let retry = try await client.createKanbanCard(request)
        let cardID = try XCTUnwrap(first.card?.cardID)

        XCTAssertEqual(retry.card?.cardID, cardID)
        let board = try await client.kanbanBoard(KanbanBoardRequest(board: "main"))
        let matches = (board.columns ?? []).flatMap { $0.cards ?? [] }.filter { $0.cardID == cardID }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.title, request.title)
        XCTAssertEqual(matches.first?.workspaceKind, request.workspaceKind)
        XCTAssertEqual(matches.first?.workspacePath, request.workspacePath)
        XCTAssertEqual(matches.first?.skills, request.skills)
        XCTAssertEqual(matches.first?.maxRuntimeSeconds, request.maxRuntimeSeconds)

        let detail = try await client.kanbanCardDetail(
            KanbanCardDetailRequest(cardID: cardID, board: "main")
        )
        XCTAssertEqual(detail.links?.prerequisites, ["CARD-1"])
    }

    func testEditPersistsSupportedFieldsAndPreservesCreateOnlyFields() async throws {
        let client = KanbanLabClient(scenario: .dense)
        let created = try await client.createKanbanCard(KanbanCreateCardRequest(
            board: "main",
            title: "Before",
            body: "Original",
            status: "triage",
            priority: 1,
            assignee: "builder",
            tenant: "app",
            workspaceKind: "worktree",
            workspacePath: "/workspace",
            skills: ["swiftui-patterns"],
            maxRuntimeSeconds: 900,
            prerequisiteID: "CARD-1",
            idempotencyKey: "edit-intent"
        ))
        let cardID = try XCTUnwrap(created.card?.cardID)

        _ = try await client.editKanbanCard(KanbanEditCardRequest(
            cardID: cardID,
            board: "main",
            title: "After",
            body: "Edited",
            tenant: nil,
            priority: -3,
            assignee: nil,
            status: "todo"
        ))

        let detail = try await client.kanbanCardDetail(
            KanbanCardDetailRequest(cardID: cardID, board: "main")
        )
        XCTAssertEqual(detail.card?.title, "After")
        XCTAssertEqual(detail.card?.body, "Edited")
        XCTAssertEqual(detail.card?.status?.rawValue, "todo")
        XCTAssertEqual(detail.card?.priority, -3)
        XCTAssertNil(detail.card?.assignee)
        XCTAssertNil(detail.card?.tenant)
        XCTAssertEqual(detail.card?.workspaceKind, "worktree")
        XCTAssertEqual(detail.card?.workspacePath, "/workspace")
        XCTAssertEqual(detail.card?.skills, ["swiftui-patterns"])
        XCTAssertEqual(detail.card?.maxRuntimeSeconds, 900)
        XCTAssertEqual(detail.links?.prerequisites, ["CARD-1"])
    }
}

private actor CardEditorClient: KanbanDataClient {
    private var createResults: [Result<KanbanCardMutationEnvelope, Error>]
    private var editResults: [Result<KanbanCardMutationEnvelope, Error>]
    private var detailResults: [Result<KanbanCardDetailEnvelope, Error>]
    private var boardResults: [Result<KanbanBoardSnapshot, Error>]
    private(set) var idempotencyKeys: [String] = []
    private(set) var createCallCount = 0
    private(set) var editCallCount = 0
    private(set) var lastEditRequest: KanbanEditCardRequest?

    init(
        createResults: [Result<KanbanCardMutationEnvelope, Error>] = [],
        editResults: [Result<KanbanCardMutationEnvelope, Error>] = [],
        detailResults: [Result<KanbanCardDetailEnvelope, Error>] = [],
        boardResults: [Result<KanbanBoardSnapshot, Error>] = []
    ) {
        self.createResults = createResults
        self.editResults = editResults
        self.detailResults = detailResults
        self.boardResults = boardResults
    }

    func kanbanConfiguration() -> KanbanConfiguration { decode(#"{"columns":["triage","todo","ready"],"read_only":false}"#) }
    func kanbanBoards() -> KanbanBoardsResponse { decode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#) }
    func kanbanStats(board: String) -> KanbanStats { decode(#"{"total":0}"#) }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { decode(#"{"assignees":[]}"#) }
    func kanbanEvents(_ request: KanbanEventsRequest) -> KanbanEventsEnvelope { decode(#"{"events":[],"cursor":0}"#) }

    func kanbanBoard(_ request: KanbanBoardRequest) throws -> KanbanBoardSnapshot {
        try boardResults.removeFirst().get()
    }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) throws -> KanbanCardDetailEnvelope {
        try detailResults.removeFirst().get()
    }

    func createKanbanCard(_ request: KanbanCreateCardRequest) throws -> KanbanCardMutationEnvelope {
        createCallCount += 1
        idempotencyKeys.append(request.idempotencyKey)
        return try createResults.removeFirst().get()
    }

    func editKanbanCard(_ request: KanbanEditCardRequest) throws -> KanbanCardMutationEnvelope {
        editCallCount += 1
        lastEditRequest = request
        return try editResults.removeFirst().get()
    }
}

private actor StaleEditorClient: KanbanDataClient {
    private var detailCallCount = 0
    private var firstContinuation: CheckedContinuation<KanbanCardDetailEnvelope, Never>?
    private(set) var editCallCount = 0

    var firstReadStarted: Bool { firstContinuation != nil }

    func finishFirstRead(with detail: KanbanCardDetailEnvelope) {
        firstContinuation?.resume(returning: detail)
        firstContinuation = nil
    }

    func kanbanConfiguration() -> KanbanConfiguration { decode(#"{"columns":["triage","todo","ready"],"read_only":false}"#) }
    func kanbanBoards() -> KanbanBoardsResponse { decode(#"{"boards":[{"slug":"main"}],"current":"main","read_only":false}"#) }
    func kanbanBoard(_ request: KanbanBoardRequest) -> KanbanBoardSnapshot { .empty }
    func kanbanStats(board: String) -> KanbanStats { decode(#"{"total":0}"#) }
    func kanbanAssignees(board: String) -> KanbanAssigneeHistory { decode(#"{"assignees":[]}"#) }
    func kanbanEvents(_ request: KanbanEventsRequest) -> KanbanEventsEnvelope { decode(#"{"events":[],"cursor":0}"#) }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async -> KanbanCardDetailEnvelope {
        detailCallCount += 1
        if detailCallCount == 1 {
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return .baseline
    }

    func editKanbanCard(_ request: KanbanEditCardRequest) -> KanbanCardMutationEnvelope {
        editCallCount += 1
        return decode(#"{"task":{"id":"CARD-1","title":"Edited","body":"Body","status":"ready","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900}}"#)
    }
}

private extension KanbanCard {
    static let baseline: KanbanCard = decode(#"{"id":"CARD-1","title":"Original","body":"Body","status":"ready","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900}"#)
    static let prerequisite: KanbanCard = decode(#"{"id":"CARD-0","title":"First","status":"done"}"#)
    static let runningBaseline: KanbanCard = decode(#"{"id":"CARD-1","title":"Original","body":"Body","status":"running","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"scratch"}"#)
}

private extension KanbanCardDetailEnvelope {
    static let baseline: KanbanCardDetailEnvelope = decode(#"{"task":{"id":"CARD-1","title":"Original","body":"Body","status":"ready","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900}}"#)
    static let remoteChanged: KanbanCardDetailEnvelope = decode(#"{"task":{"id":"CARD-1","title":"Changed remotely","body":"Body","status":"ready","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900}}"#)
    static let edited: KanbanCardDetailEnvelope = decode(#"{"task":{"id":"CARD-1","title":"Edited","body":"Body","status":"ready","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900}}"#)
    static let runningBaseline: KanbanCardDetailEnvelope = decode(#"{"task":{"id":"CARD-1","title":"Original","body":"Body","status":"running","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"scratch"}}"#)
    static let remoteChangedRunning: KanbanCardDetailEnvelope = decode(#"{"task":{"id":"CARD-1","title":"Changed remotely","body":"Body","status":"running","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900}}"#)
    static let remoteChangedPrerequisite: KanbanCardDetailEnvelope = decode(#"{"task":{"id":"CARD-1","title":"Changed remotely","body":"Body","status":"ready","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900},"links":{"parents":["CARD-2"]}}"#)
}

private extension KanbanCardMutationEnvelope {
    static let createdTriage: KanbanCardMutationEnvelope = decode(#"{"task":{"id":"CARD-153","title":"Retry me","status":"triage","priority":0,"workspace_kind":"scratch"},"read_only":false}"#)
    static let createdReady: KanbanCardMutationEnvelope = decode(#"{"task":{"id":"CARD-153","title":"Ready work","status":"ready","priority":0,"workspace_kind":"scratch"},"read_only":false}"#)
    static let overwritten: KanbanCardMutationEnvelope = decode(#"{"task":{"id":"CARD-1","title":"My local draft","body":"Body","status":"ready","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900},"read_only":false}"#)
    static let runningEdited: KanbanCardMutationEnvelope = decode(#"{"task":{"id":"CARD-1","title":"Edited while running","body":"Body","status":"running","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"scratch"},"read_only":false}"#)
    static let overwrittenRunning: KanbanCardMutationEnvelope = decode(#"{"task":{"id":"CARD-1","title":"My local draft","body":"Body","status":"running","priority":0,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900},"read_only":false}"#)
}

private extension KanbanBoardSnapshot {
    static let empty: KanbanBoardSnapshot = decode(#"{"changed":true,"columns":[{"name":"triage","tasks":[]}],"read_only":false}"#)
    static let withCreatedTriage: KanbanBoardSnapshot = decode(#"{"changed":true,"columns":[{"name":"triage","tasks":[{"id":"CARD-153","title":"Retry me","status":"triage","priority":0,"workspace_kind":"scratch"}]}],"read_only":false}"#)
}

private func decode<T: Decodable>(_ json: String) -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(T.self, from: Data(json.utf8))
}
