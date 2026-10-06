import XCTest
@testable import HermesMobile

/// Kanban on a Hermes host (#1043): the real `HermesKanbanClient` on a scripted host whose
/// replies are the shapes `scripts/local-hermes` returned at the pin (ca678285, 0.21.5), read
/// through `KanbanFeatureState` and `KanbanCardDetailState` where the screen is the subject.
@MainActor final class HermesKanbanClientTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private let server = URL(string: "https://hermes-home.example")!

    override func setUp() {
        super.setUp()
        clearSavedKanbanBoards()
    }

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testHandshakeShowsTheHostsEightColumnsWritableAndStreamsFromTheBoardsCursor() async {
        let stream = RecordingKanbanStream()
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host()), streamClient: stream)

        await state.load()
        state.setVisible(true)

        XCTAssertEqual(state.state, .compatible)
        XCTAssertEqual(state.report?.warnings, [], "no `changed` and no configured Columns are not warnings")
        XCTAssertEqual(state.availableStatuses,
                       ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"])
        XCTAssertEqual(["scheduled", "review", "running"].map(state.statusCount), [1, 1, 1])
        XCTAssertEqual(kanbanRequests(), [
            "/api/plugins/kanban/config",
            "/api/plugins/kanban/boards",
            "/api/plugins/kanban/board?board=default",
            "/api/plugins/kanban/stats?board=default",
            "/api/plugins/kanban/assignees?board=default"
        ])
        XCTAssertEqual(state.stats?.byStatus?["scheduled"], 1)
        XCTAssertEqual(state.assigneeHistory?.assignees, ["default", "reviewer"])

        XCTAssertTrue(state.canCreateCards)
        XCTAssertTrue(state.canEditCards)
        XCTAssertTrue(state.canUseCardWorkflow)
        XCTAssertTrue(state.canUseBulkActions)
        XCTAssertTrue(state.canAddComments)
        XCTAssertTrue(state.canManageBoards)
        XCTAssertEqual(state.dispatcherAvailability, .available)
        XCTAssertFalse(state.offersOnlyMine)
        XCTAssertEqual(stream.starts, ["default@14"], "live updates start at the Board's `latest_event_id`")

        // The foreground asks whether the Board moved, keeps it unmoved, and reopens the socket.
        let detailRevision = state.detailRefreshRevision
        await state.setScenePhase(.background)
        await state.setScenePhase(.active)
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/board"), 2)
        XCTAssertEqual(state.detailRefreshRevision, detailRevision, "an unmoved Board is not applied again")
        XCTAssertEqual(stream.starts, ["default@14", "default@14"])
        XCTAssertFalse(state.liveUpdatesDelayed)
        state.setVisible(false)
    }

    /// The host's `/board` takes no `since`, so its `latest_event_id` answers one: unchanged
    /// only while it still equals `since`. A recreated database's lower id is a change.
    func testASinceReadIsUnchangedOnlyWhileTheBoardsLatestEventIsTheSame() async throws {
        let client = HermesKanbanClient(http: host())

        let full = try await client.kanbanBoard(KanbanBoardRequest(board: "default"))
        let unchanged = try await client.kanbanBoard(KanbanBoardRequest(board: "default", since: 14))
        let moved = try await client.kanbanBoard(KanbanBoardRequest(board: "default", since: 13))
        let recreated = try await client.kanbanBoard(KanbanBoardRequest(board: "default", since: 40))

        XCTAssertNil(full.changed)
        XCTAssertEqual(unchanged.changed, false)
        XCTAssertEqual(moved.changed, true)
        XCTAssertEqual(recreated.changed, true)
        XCTAssertEqual(unchanged.latestEventID, 14)
        XCTAssertEqual(kanbanRequests(), Array(repeating: "/api/plugins/kanban/board?board=default", count: 4),
                       "the host never sees `since`")
    }

    /// A Card's workspace path, claim and worker PID, a run's worker PID, a Board's database
    /// path and workdir, an attachment's stored path and a log's path never reach a model.
    func testHostPathsAndProcessDataAreDroppedBeforeDecoding() async throws {
        let client = HermesKanbanClient(http: host())

        let snapshot = try await client.kanbanBoard(KanbanBoardRequest(board: "default"))
        let running = try XCTUnwrap(snapshot.columns?.flatMap { $0.cards ?? [] }.first { $0.status?.rawValue == "running" })
        XCTAssertEqual(running.cardID, "t_9b1c2d3e")
        XCTAssertEqual(running.workspaceKind, "worktree")
        XCTAssertNil(running.workspacePath)
        XCTAssertNil(running.claimLock)
        XCTAssertNil(running.workerID)
        XCTAssertEqual(running.ageSeconds, 900, "a running Card's age is how long it has run")
        XCTAssertEqual(running.staleness, .warning)
        XCTAssertEqual(snapshot.readOnly, false)

        let detail = try await client.kanbanCardDetail(KanbanCardDetailRequest(cardID: "t_9b1c2d3e", board: "default"))
        XCTAssertNil(detail.card?.workspacePath)
        XCTAssertEqual(detail.runs?.map(\.runID), ["1"])
        XCTAssertEqual(detail.runs?.map(\.workerID), [nil])

        let adapted = try XCTUnwrap(String(data: HermesKanbanClient.adapted(Data(Self.boards.utf8)), encoding: .utf8))
        for key in ["db_path", "default_workdir", "/Users/"] {
            XCTAssertFalse(adapted.contains(key), key)
        }
        let detailBody = try XCTUnwrap(String(data: HermesKanbanClient.adapted(Data(Self.detail.utf8)), encoding: .utf8))
        for key in ["stored_path", "workspace_path", "worker_pid", "claim_lock", "/Users/", "4242"] {
            XCTAssertFalse(detailBody.contains(key), key)
        }
        let log = try XCTUnwrap(String(data: HermesKanbanClient.adapted(Data(Self.absentLog.utf8)), encoding: .utf8))
        XCTAssertFalse(log.contains("/var/folders"))
        let archived = #"{"result":{"slug":"scratch","action":"archived","new_path":"/var/folders/sk/T/kanban/boards/_archived/scratch-1"},"current":"default"}"#
        let archive = try XCTUnwrap(String(data: HermesKanbanClient.adapted(Data(archived.utf8)), encoding: .utf8))
        XCTAssertFalse(archive.contains("/var/folders"))
    }

    func testCardDetailCommentsDependenciesAndAnAbsentLogLoad() async throws {
        let detail = KanbanCardDetailState(cardID: "t_9b1c2d3e", board: "default",
                                           client: HermesKanbanClient(http: host()))

        await detail.load()
        await detail.loadWorkerLog()

        XCTAssertEqual(detail.loadState, .loaded)
        XCTAssertEqual(detail.detail?.card?.title, "Run the read contracts")
        XCTAssertEqual(detail.detail?.comments?.map(\.body), ["Fixtures should cover eight Columns."])
        XCTAssertEqual(detail.detail?.links?.prerequisites, ["t_017edf3a"])
        XCTAssertEqual(detail.detail?.links?.dependents, [])
        XCTAssertEqual(detail.workerLogState, .absent, "`exists: false` is a Card that never ran, not a failure")
        XCTAssertEqual(Array(kanbanRequests().suffix(2)), [
            "/api/plugins/kanban/tasks/t_9b1c2d3e?board=default",
            "/api/plugins/kanban/tasks/t_9b1c2d3e/log?board=default&tail=65536"
        ])
    }

    func testACardTheHostNoLongerHasReadsAsMissing() async {
        let detail = KanbanCardDetailState(cardID: "t_gone", board: "default", client: HermesKanbanClient(http: host([
            "/api/plugins/kanban/tasks/t_gone": .json(404, .object(["detail": .string("task t_gone not found")]))
        ])))

        await detail.load()

        XCTAssertEqual(detail.loadState, .missingCard)
    }

    /// Absent means 404 on `/config`: a plugin the host never mounted, or one disabled at runtime.
    func testAHostWithoutTheKanbanPluginShowsKanbanUnavailable() async {
        for body in ["No such API endpoint: /api/plugins/kanban/config", "Plugin not found"] {
            HermesHostFixture.reset()
            let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
                "/api/plugins/kanban/config": .json(404, .object(["detail": .string(body)]))
            ])))

            await state.load()

            XCTAssertEqual(state.state, .unavailable, body)
            XCTAssertEqual(kanbanRequests(), ["/api/plugins/kanban/config"], body)
        }
    }

    func testHermesFailuresKeepTodaysStates() async {
        let rows: [(path: String, reply: HermesHostFixture.Reply, state: KanbanCompatibilityState)] = [
            ("/api/plugins/kanban/config", .fail(URLError(.notConnectedToInternet)), .networkUnavailable),
            ("/api/plugins/kanban/config", .json(503, .object([:])), .serverUnavailable),
            ("/api/plugins/kanban/config", .json(530, .object([:])), .serverUnavailable),
            ("/api/plugins/kanban/config", .json(500, .object(["detail": .string("boom")])), .incompatibleContract),
            ("/api/plugins/kanban/boards", .json(200, .array([])), .incompatibleContract),
            ("/auth/password-login", .json(401, .object(["error": .string("invalid_credentials")])), .authenticationRequired)
        ]
        for row in rows {
            HermesHostFixture.reset()
            var forwarded: [Error] = []
            let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([row.path: row.reply])),
                                           onAPIError: { forwarded.append($0) })

            await state.load()

            XCTAssertEqual(state.state, row.state, "\(row.path) \(row.reply)")
            XCTAssertTrue(forwarded.isEmpty, "a Hermes sign-out goes through the connection, not onAPIError")
        }
    }

    func testALostConnectionKeepsTheBoardAndShowsOffline() async {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host()))
        await state.load()
        // Every later request fails in transit.
        _ = HermesHostFixture.configuration { _ in .fail(URLError(.networkConnectionLost)) }

        await state.refresh()

        XCTAssertTrue(state.isOffline)
        XCTAssertEqual(state.statusCount("review"), 1, "the loaded Board stays on screen")
        XCTAssertFalse(state.canUseServerAuthoritativeActions)
    }

    /// The host's `/board` filters by tenant and archive only, so the Assigned Profile filter
    /// runs on the client.
    func testFiltersTheHostCannotApplyRunOnTheClient() async {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host()))
        await state.load()

        await state.applyFilters(profile: "reviewer", tenant: "app", includeArchived: true, onlyMine: false)

        XCTAssertEqual(kanbanRequests().last, "/api/plugins/kanban/board?board=default&tenant=app&include_archived=true")
        XCTAssertEqual(state.allCards.map(\.cardID), ["t_04fba87e"])
        XCTAssertEqual(state.availableStatuses.last, "archived")
    }

    // MARK: - Writes (#1044)

    /// Create is `POST /tasks?board=`: Triage is `triage: true` and never a `status`, and no
    /// Assigned Profile is an explicit null, because the host refuses `""` with a 400.
    func testCreateSendsTriageAndANullAssigneeAndNeverAStatus() async throws {
        let client = HermesKanbanClient(http: host([
            "POST /api/plugins/kanban/tasks": .json(200, Self.json(Self.createdTriage))
        ]))

        let envelope = try await client.createKanbanCard(KanbanCreateCardRequest(
            board: "default", title: "Shape the next slice", body: nil, status: "triage", priority: nil,
            assignee: nil, tenant: "app", workspaceKind: "worktree", workspacePath: nil, skills: nil,
            maxRuntimeSeconds: nil, prerequisiteID: nil, idempotencyKey: "key-1"
        ))

        XCTAssertEqual(envelope.card?.cardID, "t_5ff898b1")
        XCTAssertEqual(envelope.readOnly, false)
        XCTAssertEqual(writes(), ["POST /api/plugins/kanban/tasks?board=default"])
        XCTAssertEqual(body(of: "POST /api/plugins/kanban/tasks"), .object([
            "title": .string("Shape the next slice"), "assignee": .null, "tenant": .string("app"),
            "workspace_kind": .string("worktree"), "triage": .bool(true), "idempotency_key": .string("key-1")
        ]))
    }

    /// A repeat block lands the Card in Triage with a 200 (the host's block-loop breaker): the
    /// block succeeded, and the Card shows where the host put it.
    func testABlockTheHostLandsInTriageShowsTheCardInTriage() async throws {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWithReadyCard)),
            "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, Self.json(Self.card("t_2ad0ddc5", status: "triage")))
        ], after: [
            "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5": ["/api/plugins/kanban/board": .json(200, Self.json(Self.boardWith(
                "t_2ad0ddc5", in: "triage")))]
        ])))
        await state.load()
        let ready = try XCTUnwrap(state.allCards.first { $0.cardID == "t_2ad0ddc5" })

        await state.blockCard(ready, reason: nil)

        XCTAssertEqual(state.mutationState(for: "t_2ad0ddc5")?.phase, .succeeded)
        XCTAssertEqual(state.allCards.first { $0.cardID == "t_2ad0ddc5" }?.status?.rawValue, "triage")
        XCTAssertEqual(body(of: "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5"), .object(["status": .string("blocked")]))
    }

    /// The board reloads after a Hermes Card write, because the host reports no `changed`.
    func testABlockReloadsTheBoardOnce() async throws {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWithReadyCard)),
            "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, Self.json(Self.card("t_2ad0ddc5", status: "blocked")))
        ])))
        await state.load()
        let ready = try XCTUnwrap(state.allCards.first { $0.cardID == "t_2ad0ddc5" })

        await state.blockCard(ready, reason: "Waiting on design")

        XCTAssertEqual(state.mutationState(for: "t_2ad0ddc5")?.phase, .succeeded)
        XCTAssertEqual(body(of: "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5"),
                       .object(["status": .string("blocked"), "block_reason": .string("Waiting on design")]))
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/board"), 2, "the load, then one reload after the write")
    }

    /// No To Do anywhere on Hermes: a Card goes to Triage or Ready, and Scheduled and Review are
    /// never destinations, though a Card in either moves out to them. Block is offered only on
    /// Ready and Running Cards, the only ones the host blocks, and Complete only on a Card in
    /// Review, the only one the host completes without a result.
    func testHermesOffersTriageAndReadyButNeverToDoScheduledOrReview() async throws {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWithReadyCard))
        ])))
        await state.load()
        func card(_ id: String) throws -> KanbanCard { try XCTUnwrap(state.allCards.first { $0.cardID == id }) }

        XCTAssertEqual(state.moveDestinations(for: try card("t_017edf3a")), ["ready"])
        XCTAssertEqual(state.moveDestinations(for: try card("t_ded419c6")), ["triage", "ready"], "out of Scheduled")
        XCTAssertEqual(state.moveDestinations(for: try card("t_04fba87e")), ["triage", "ready"], "out of Review")
        XCTAssertEqual(state.moveDestinations(for: try card("t_2ad0ddc5")), ["triage"])
        XCTAssertEqual(state.bulkStatusOptions, ["triage", "ready", "blocked", "done"])
        XCTAssertFalse(state.canSubmitBulkAction(.changeStatus("todo")))
        XCTAssertEqual(["t_017edf3a", "t_ded419c6", "t_2ad0ddc5", "t_9b1c2d3e", "t_04fba87e", "t_ed0bb193"]
            .map { state.canBlock(try! card($0)) }, [false, false, true, true, false, false])
        XCTAssertEqual(["t_017edf3a", "t_ded419c6", "t_2ad0ddc5", "t_9b1c2d3e", "t_04fba87e", "t_ed0bb193"]
            .map { state.canComplete(try! card($0)) }, [false, false, false, false, true, false])

        await state.completeCard(try card("t_2ad0ddc5"))

        XCTAssertEqual(writes(), [], "the host refuses Done for a Ready Card without a result")
    }

    /// Unblock succeeds wherever the host lands the Card but Blocked: To Do while a prerequisite
    /// is open, Review when the Card was blocked out of a review.
    func testUnblockSucceedsWhereverTheHostLandsTheCardButBlocked() async throws {
        for (landed, phase) in [("todo", KanbanCardMutationPhase.succeeded), ("review", .succeeded), ("blocked", .failed)] {
            HermesHostFixture.reset()
            let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
                "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWith("t_2ad0ddc5", in: "blocked"))),
                "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, Self.json(Self.card("t_2ad0ddc5", status: landed))),
                "GET /api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, Self.json(Self.detail("t_2ad0ddc5", status: landed)))
            ], after: [
                "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5": ["/api/plugins/kanban/board": .json(200, Self.json(Self.boardWith(
                    "t_2ad0ddc5", in: landed)))]
            ])))
            await state.load()
            let blocked = try XCTUnwrap(state.allCards.first { $0.cardID == "t_2ad0ddc5" })

            await state.unblockCard(blocked)

            XCTAssertEqual(state.mutationState(for: "t_2ad0ddc5")?.phase, phase, landed)
            XCTAssertEqual(state.status(ofCard: "t_2ad0ddc5"), landed, "the Card shows where the host put it")
            XCTAssertEqual(body(of: "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5"), .object(["status": .string("ready")]), landed)
        }
    }

    /// A refused move shows the host's own words, and the Card stays where the host has it.
    func testARefusedMoveShowsTheHostsMessageAndPutsTheCardBack() async throws {
        let detail = "Cannot move to 'ready': blocked by parent(s) not done — 'Shape the next slice' (t_017edf3a, status=triage)"
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWith("t_07aac7b2", in: "todo", title: "Child card"))),
            "PATCH /api/plugins/kanban/tasks/t_07aac7b2": .json(409, .object(["detail": .string(detail)]))
        ])))
        await state.load()
        let todo = try XCTUnwrap(state.allCards.first { $0.cardID == "t_07aac7b2" })

        await state.moveCard(todo, to: "ready")

        XCTAssertEqual(state.mutationState(for: "t_07aac7b2"), KanbanCardMutationState(kind: .status("ready"), phase: .failed,
                                                                                       message: detail))
        XCTAssertEqual(state.status(ofCard: "t_07aac7b2"), "todo")
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/tasks/t_07aac7b2"), 1, "a refusal is not checked again")
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/board"), 2, "the Board is read again after the write")
    }

    /// The host echoes no ids for a prerequisite, so the reply is filled from the request; a
    /// `gated` link sends the Ready dependent back to To Do, which the Board reload shows.
    func testAPrerequisiteTheHostGatesMovesTheDependentToToDo() async throws {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWithReadyCard)),
            "POST /api/plugins/kanban/links": .json(200, .object(["ok": .bool(true), "gated": .bool(true)]))
        ], after: [
            "POST /api/plugins/kanban/links": [
                "/api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, Self.json(Self.detail("t_2ad0ddc5", status: "todo",
                                                                                          parents: ["t_017edf3a"]))),
                "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWith("t_2ad0ddc5", in: "todo")))
            ]
        ])))
        await state.load()
        let ready = try XCTUnwrap(state.allCards.first { $0.cardID == "t_2ad0ddc5" })

        await state.addPrerequisite("t_017edf3a", to: ready)

        XCTAssertEqual(state.mutationState(for: "t_2ad0ddc5")?.phase, .succeeded)
        XCTAssertEqual(state.status(ofCard: "t_2ad0ddc5"), "todo")
        XCTAssertEqual(writes(), ["POST /api/plugins/kanban/links?board=default"])
        XCTAssertEqual(body(of: "POST /api/plugins/kanban/links"),
                       .object(["parent_id": .string("t_017edf3a"), "child_id": .string("t_2ad0ddc5")]))
    }

    /// Removing a prerequisite is a DELETE with query ids, 200 `{ok: false}` when the link was
    /// already gone; either way the reply is filled from the request and passes validation.
    func testRemovingAPrerequisiteIsADeleteFilledFromTheRequest() async throws {
        let client = HermesKanbanClient(http: host([
            "DELETE /api/plugins/kanban/links": .json(200, .object(["ok": .bool(false)]))
        ]))
        let request = KanbanDependencyMutationRequest(board: "default", prerequisiteID: "t_017edf3a", dependentID: "t_9b1c2d3e")

        let envelope = try await client.removeKanbanDependency(request)

        XCTAssertNoThrow(try KanbanDependencyMutationValidator.validate(envelope, request: request))
        XCTAssertEqual([envelope.prerequisiteID, envelope.dependentID], ["t_017edf3a", "t_9b1c2d3e"])
        XCTAssertEqual(envelope.readOnly, false)
        XCTAssertEqual(writes(), ["DELETE /api/plugins/kanban/links?board=default&parent_id=t_017edf3a&child_id=t_9b1c2d3e"])
    }

    /// The host's comment reply is `{ok: true}` without the comment, so the Card is read again.
    func testACommentAppearsAfterPosting() async throws {
        let detail = KanbanCardDetailState(cardID: "t_9b1c2d3e", board: "default", client: HermesKanbanClient(http: host([
            "POST /api/plugins/kanban/tasks/t_9b1c2d3e/comments": .json(200, .object(["ok": .bool(true)]))
        ], after: [
            "POST /api/plugins/kanban/tasks/t_9b1c2d3e/comments": [
                "GET /api/plugins/kanban/tasks/t_9b1c2d3e": .json(200, Self.json(Self.detail.replacingOccurrences(
                    of: #""created_at":1791251517}]"#,
                    with: #""created_at":1791251517},{"id":2,"task_id":"t_9b1c2d3e","author":"dashboard","body":"Looks good.","created_at":1791251600}]"#
                )))
            ]
        ])))
        await detail.load()
        detail.commentDraft = "Looks good."

        await detail.submitComment(allowsMutation: true)

        XCTAssertEqual(detail.commentSubmission, .succeeded)
        XCTAssertEqual(detail.detail?.comments?.map(\.body), ["Fixtures should cover eight Columns.", "Looks good."])
        XCTAssertEqual(body(of: "POST /api/plugins/kanban/tasks/t_9b1c2d3e/comments"), .object(["body": .string("Looks good.")]))
    }

    /// A Bulk Action is 200 with per-Card failures; each Card is read again, and the ones the host
    /// left where they were show as failed and stay selected.
    func testBulkShowsTheCardsTheHostRefused() async throws {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "POST /api/plugins/kanban/tasks/bulk": .json(200, Self.json(#"""
            {"results":[{"id":"t_017edf3a","ok":true},{"id":"t_ed0bb193","ok":false,"error":"transition to 'ready' refused"}]}
            """#))
        ], after: [
            "POST /api/plugins/kanban/tasks/bulk": [
                "/api/plugins/kanban/tasks/t_017edf3a": .json(200, Self.json(Self.detail("t_017edf3a", status: "ready"))),
                "/api/plugins/kanban/tasks/t_ed0bb193": .json(200, Self.json(Self.detail("t_ed0bb193", status: "done")))
            ]
        ])))
        await state.load()
        state.beginSelectingCards()
        for id in ["t_017edf3a", "t_ed0bb193"] { state.toggleCardSelection(try XCTUnwrap(state.allCards.first { $0.cardID == id })) }

        await state.performBulkAction(.changeStatus("ready"))

        XCTAssertEqual(body(of: "POST /api/plugins/kanban/tasks/bulk"),
                       .object(["ids": .array([.string("t_017edf3a"), .string("t_ed0bb193")]), "status": .string("ready")]))
        XCTAssertEqual(state.bulkActionSummary?.succeededCount, 1)
        XCTAssertEqual(state.bulkActionSummary?.failedCardIDs, ["t_ed0bb193"])
        XCTAssertEqual(state.selectedCardIDs, ["t_ed0bb193"])
    }

    /// Preview Dispatch shows today's summary from the host's `DispatchResult`.
    func testPreviewDispatchShowsTodaysSummary() async {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "POST /api/plugins/kanban/dispatch": .json(200, Self.json(#"""
            {"reclaimed":0,"promoted":1,"reconciled_orphans":[],"spawned":[],"skipped_unassigned":["t_ee7161bc","t_2ad0ddc5"],
            "skipped_nonspawnable":[],"crashed":[],"auto_blocked":[],"timed_out":[],"stale":[],"skipped_locked":false}
            """#))
        ])))
        await state.load()

        await state.previewDispatch()

        XCTAssertEqual(writes(), ["POST /api/plugins/kanban/dispatch?board=default&dry_run=true&max=8"])
        XCTAssertEqual(state.dispatchState?.phase, .succeeded)
        XCTAssertEqual(state.dispatchState?.result?.promoted, 1)
        XCTAssertEqual(state.dispatchState?.result?.skippedUnassigned, 2)
        XCTAssertEqual(state.dispatchState?.result?.spawned, 0)
    }

    /// Board writes never send a directory or project, archive without deleting, and leave the
    /// Board this server browses where it was.
    func testBoardWritesReachTheHostAndKeepThePerServerBoard() async throws {
        let withScratch = Self.boards.replacingOccurrences(of: #"],"current":"default"}"#, with: #",{"slug":"scratch","name":"Scratch","#
            + #""description":"","icon":"","color":"","archived":false,"is_current":false,"counts":{},"total":0}],"current":"default"}"#)
        let scratchCurrent = withScratch.replacingOccurrences(of: #""current":"default""#, with: #""current":"scratch""#)
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "POST /api/plugins/kanban/boards": .json(200, .object(["board": .object(["slug": .string("scratch")]),
                                                                   "current": .string("default")])),
            "POST /api/plugins/kanban/boards/scratch/switch": .json(200, .object(["current": .string("scratch")])),
            "PATCH /api/plugins/kanban/boards/scratch": .json(200, .object(["board": .object(["slug": .string("scratch")])])),
            "DELETE /api/plugins/kanban/boards/scratch": .json(200, .object(["current": .string("default")]))
        ], after: [
            "POST /api/plugins/kanban/boards": ["GET /api/plugins/kanban/boards": .json(200, Self.json(withScratch))],
            "POST /api/plugins/kanban/boards/scratch/switch": ["GET /api/plugins/kanban/boards": .json(200, Self.json(scratchCurrent))],
            "DELETE /api/plugins/kanban/boards/scratch": ["GET /api/plugins/kanban/boards": .json(200, Self.json(Self.boards))]
        ])))
        await state.load()

        await state.createBoard(KanbanCreateBoardRequest(slug: "scratch", name: "Scratch", description: "", icon: "", color: ""))
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        await state.makeBoardActive(slug: "scratch")
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        await state.editBoard(KanbanEditBoardRequest(slug: "scratch", name: "Scratch", description: "", icon: "", color: ""))
        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        await state.archiveBoard(slug: "scratch")

        XCTAssertEqual(state.boardMutationState?.phase, .succeeded)
        XCTAssertEqual(state.selectedBoardSlug, "default", "browsing stays local to Hermex")
        XCTAssertEqual(writes(), [
            "POST /api/plugins/kanban/boards",
            "POST /api/plugins/kanban/boards/scratch/switch",
            "PATCH /api/plugins/kanban/boards/scratch",
            "DELETE /api/plugins/kanban/boards/scratch?delete=false"
        ])
        XCTAssertEqual(body(of: "POST /api/plugins/kanban/boards"), .object([
            "slug": .string("scratch"), "name": .string("Scratch"), "description": .string(""), "icon": .string(""),
            "color": .string("")
        ]))
        XCTAssertEqual(KanbanBoardPreference.savedSlug(for: server, in: .standard), "default")
    }

    /// A 400 or 409 carries the host's `detail`; any other refusal is the status alone.
    func testARefusalCarriesTheHostsDetail() async {
        let rows: [(reply: HermesHostFixture.Reply, error: Error)] = [
            (.json(409, .object(["detail": .string("status transition to 'blocked' not valid from current state")])),
             KanbanWriteRefusal(status: 409, message: "status transition to 'blocked' not valid from current state")),
            (.json(400, .object(["detail": .string("unknown status: bogus")])),
             KanbanWriteRefusal(status: 400, message: "unknown status: bogus")),
            (.json(409, .object([:])), BotFailure.rejected(409)),
            (.json(500, .object(["detail": .string("boom")])), BotFailure.rejected(500))
        ]
        for row in rows {
            HermesHostFixture.reset()
            let client = HermesKanbanClient(http: host(["PATCH /api/plugins/kanban/tasks/t_9b1c2d3e": row.reply]))
            do {
                _ = try await client.setKanbanCardStatus(KanbanCardStatusRequest(cardID: "t_9b1c2d3e", board: "default",
                                                                                 status: "blocked"))
                XCTFail("\(row.reply) should throw")
            } catch {
                XCTAssertEqual(error as? KanbanWriteRefusal, row.error as? KanbanWriteRefusal, "\(row.reply)")
                XCTAssertEqual(error as? BotFailure, row.error as? BotFailure, "\(row.reply)")
            }
        }
    }

    /// The editor on Hermes: Triage and Ready, the Board's workspace kind sent as shown, because
    /// an omitted one is Scratch on a Board with a directory but no project, and a Card asked
    /// into Ready that the host parks in To Do behind its open prerequisite. The host's warning
    /// becomes the Board's notice.
    func testCreateOffersTriageAndReadyAndSendsTheBoardsWorkspaceKind() async throws {
        let warning = "No gateway is running — the task will sit in 'ready' until you start it."
        let projectBoards = Self.boards.replacingOccurrences(of: #""default_workspace_kind":"scratch""#,
                                                             with: #""default_workspace_kind":"worktree""#)
        let created = Self.card("t_07aac7b2", status: "todo", tenant: "app")
            .replacingOccurrences(of: #""title":"Ready card""#, with: #""title":"Child card""#)
            .replacingOccurrences(of: #""workspace_kind":"scratch""#, with: #""workspace_kind":"worktree""#)
            .replacingOccurrences(of: "}}}", with: #"}},"warning":""# + warning + #""}"#)
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "/api/plugins/kanban/boards": .json(200, Self.json(projectBoards)),
            "POST /api/plugins/kanban/tasks": .json(200, Self.json(created))
        ])))
        await state.load()
        let editor = try XCTUnwrap(state.makeCreateCardEditorState())
        XCTAssertEqual(editor.createStatuses, ["triage", "ready"])
        XCTAssertEqual(editor.workspaceKind, "worktree", "the Board's default")
        XCTAssertFalse(editor.offersWorkspacePath)
        editor.title = "Child card"
        editor.status = "ready"
        editor.prerequisiteID = "t_017edf3a"

        await editor.save(allowsMutation: state.canCreateCards, readyUnassignedConfirmed: true)
        await state.reconcileAfterCardMutation(notice: editor.notice)

        XCTAssertEqual(editor.submission, .succeeded(cardID: "t_07aac7b2"))
        XCTAssertEqual(body(of: "POST /api/plugins/kanban/tasks"), .object([
            "title": .string("Child card"), "assignee": .null, "triage": .bool(false), "workspace_kind": .string("worktree"),
            "parents": .array([.string("t_017edf3a")]), "idempotency_key": .string(editor.idempotencyKey)
        ]))
        XCTAssertEqual(state.cardNotice, warning)
    }

    /// A Scratch nobody picked is left out, so a project Board gives the Card its project; a
    /// picked Scratch is sent, which opts out of the project.
    func testCreateLeavesOutOnlyAScratchNobodyPicked() async throws {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
            "POST /api/plugins/kanban/tasks": .json(200, Self.json(Self.card("t_5ff898b1", status: "triage")))
        ])))
        await state.load()

        var sent: [BotJSON?] = []
        for picked in [false, true] {
            let editor = try XCTUnwrap(state.makeCreateCardEditorState())
            XCTAssertEqual(editor.workspaceKind, "scratch", "the Board's default")
            editor.title = "Ready card"
            if picked { editor.workspaceKind = "scratch" }
            await editor.save(allowsMutation: state.canCreateCards)
            XCTAssertEqual(editor.submission, .succeeded(cardID: "t_5ff898b1"))
            sent.append(body(of: "POST /api/plugins/kanban/tasks")?.fields?["workspace_kind"])
        }

        XCTAssertEqual(sent, [nil, .string("scratch")])
    }

    /// The editor on Hermes: tenant read-only, never sent; the assignee sent only when it
    /// changed, `""` to unassign; a refusal shows the host's words.
    func testEditKeepsTenantReadOnlyAndUnassignsWithAnEmptyString() async throws {
        let refusal = "cannot reassign t_9b1c2d3e: currently running (claimed). Wait for completion or reclaim the stale lock first."
        let client = HermesKanbanClient(http: host([
            "PATCH /api/plugins/kanban/tasks/t_9b1c2d3e": .json(409, .object(["detail": .string(refusal)]))
        ]))
        let state = KanbanFeatureState(server: server, client: client)
        await state.load()
        let detail = try await client.kanbanCardDetail(KanbanCardDetailRequest(cardID: "t_9b1c2d3e", board: "default"))
        let editor = try XCTUnwrap(state.makeEditCardEditorState(detail: detail))
        XCTAssertFalse(editor.canEditTenant)
        XCTAssertEqual(editor.createStatuses, ["triage", "ready"])

        editor.assignee = nil
        await editor.save(allowsMutation: state.canEditCards)

        XCTAssertEqual(editor.submission, .failed)
        XCTAssertEqual(editor.failureMessage, refusal)
        XCTAssertEqual(body(of: "PATCH /api/plugins/kanban/tasks/t_9b1c2d3e"), .object([
            "title": .string("Run the read contracts"), "body": .string("- Dense board"), "priority": .number(1),
            "assignee": .string("")
        ]))

        editor.assignee = "default"
        editor.title = "Run the write contracts"
        await editor.save(allowsMutation: state.canEditCards)

        XCTAssertEqual(body(of: "PATCH /api/plugins/kanban/tasks/t_9b1c2d3e"), .object([
            "title": .string("Run the write contracts"), "body": .string("- Dense board"), "priority": .number(1)
        ]), "an unchanged assignee is not sent: the host refuses any reassign of a running Card")
    }

    /// Review and Overwrite sends the draft's assignee when it differs from the newer server
    /// Card it overwrites, even if the draft kept the one the editor opened.
    func testOverwritingARemotelyReassignedCardSendsTheDraftsAssignee() async throws {
        let opened = Self.json(Self.detail("t_2ad0ddc5", status: "ready"))
        let reassigned = Self.json(Self.detail("t_2ad0ddc5", status: "ready")
            .replacingOccurrences(of: #""assignee":null"#, with: #""assignee":"reviewer""#))
        let client = HermesKanbanClient(http: host([
            "/api/plugins/kanban/board": .json(200, Self.json(Self.boardWithReadyCard)),
            "/api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, opened),
            "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, Self.json(Self.card("t_2ad0ddc5", status: "ready")))
        ], after: [
            "/api/plugins/kanban/tasks/t_2ad0ddc5": ["/api/plugins/kanban/tasks/t_2ad0ddc5": .json(200, reassigned)]
        ]))
        let state = KanbanFeatureState(server: server, client: client)
        await state.load()
        let detail = try await client.kanbanCardDetail(KanbanCardDetailRequest(cardID: "t_2ad0ddc5", board: "default"))
        let editor = try XCTUnwrap(state.makeEditCardEditorState(detail: detail))

        await editor.save(allowsMutation: state.canEditCards)
        XCTAssertEqual(editor.submission, .conflict)
        await editor.save(allowsMutation: state.canEditCards, overwriteConflict: true)

        XCTAssertEqual(editor.submission, .succeeded(cardID: "t_2ad0ddc5"))
        XCTAssertEqual(body(of: "PATCH /api/plugins/kanban/tasks/t_2ad0ddc5")?["assignee"], .string(""))
    }

    /// Undo Archive on Hermes restores to Ready unless the Card came from Triage, and a Done
    /// Card offers none: the host refuses Done from Archived, and Ready would dispatch it again.
    func testArchiveUndoRestoresToAnOrdinaryDestination() async throws {
        for (id, from, restore) in [("t_04fba87e", "review", "ready" as String?), ("t_017edf3a", "triage", "triage"),
                                    ("t_ed0bb193", "done", nil)] {
            HermesHostFixture.reset()
            let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host([
                "PATCH /api/plugins/kanban/tasks/\(id)": .json(200, Self.json(Self.card(id, status: "archived")))
            ])))
            await state.load()

            await state.archiveCard(try XCTUnwrap(state.allCards.first { $0.cardID == id }))

            XCTAssertEqual(state.mutationState(for: id)?.phase, .succeeded, from)
            XCTAssertEqual(state.archiveUndo?.previousStatus, restore, from)
        }
    }

    // MARK: - Host

    /// The scripted host: the pinned replies with `overrides`, by `METHOD /path` or `/path`.
    /// Once a request matches a key of `after`, its replies take over, as the host's state moves.
    private func host(_ overrides: [String: HermesHostFixture.Reply] = [:],
                      after writes: [String: [String: HermesHostFixture.Reply]] = [:]) -> HermesConnection {
        let pinned: [String: String] = [
            "/api/plugins/kanban/config": Self.config,
            "/api/plugins/kanban/boards": Self.boards,
            "/api/plugins/kanban/board": Self.board,
            "/api/plugins/kanban/stats": Self.stats,
            "/api/plugins/kanban/assignees": Self.assignees,
            "/api/plugins/kanban/tasks/t_9b1c2d3e": Self.detail,
            "/api/plugins/kanban/tasks/t_9b1c2d3e/log": Self.absentLog
        ]
        var replies = pinned.mapValues { HermesHostFixture.Reply.json(200, Self.json($0)) }
            .merging(overrides) { _, override in override }
        return HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            guard let path = request.url?.path else { return nil }
            let call = "\(request.httpMethod ?? "GET") \(path)"
            let reply = replies[call] ?? replies[path]
            if let moved = writes[call] ?? writes[path] { replies.merge(moved) { _, moved in moved } }
            return reply
        })
    }

    /// The Kanban writes the host saw, as method, path and query.
    private func writes() -> [String] {
        HermesHostFixture.requests.filter { $0.httpMethod != "GET" }.compactMap { request in
            request.url.flatMap { url in
                guard url.path.hasPrefix("/api/plugins/kanban") else { return nil }
                return "\(request.httpMethod ?? "") \(url.query.map { "\(url.path)?\($0)" } ?? url.path)"
            }
        }
    }

    /// The JSON body of the last request sent as `call`, such as `PATCH /api/plugins/kanban/tasks/t_1`.
    private func body(of call: String) -> BotJSON? {
        HermesHostFixture.requests.last { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" == call }
            .flatMap(apiTestBodyData(from:))
            .flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) }
    }

    /// The Kanban requests the host saw, as path and query.
    private func kanbanRequests() -> [String] {
        HermesHostFixture.requests.compactMap(\.url).filter { $0.path.hasPrefix("/api/plugins/kanban") }.map { url in
            url.query.map { "\(url.path)?\($0)" } ?? url.path
        }
    }

    private static func json(_ text: String) -> BotJSON {
        try! JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))
    }

    // MARK: - Pinned shapes (scripts/local-hermes, ca678285)

    private static let config = #"""
    {"default_tenant":"","lane_by_profile":true,"include_archived_by_default":false,"render_markdown":true}
    """#

    private static let boards = #"""
    {"boards":[{"slug":"default","name":"Default","description":"","icon":"","color":"","default_workdir":"/Users/hermex/project",
    "project_id":null,"created_at":null,"archived":false,"db_path":"/Users/hermex/.hermes/kanban.db","is_current":true,
    "counts":{"triage":1,"scheduled":1,"running":1,"review":1,"done":1},"total":5,"default_workspace_kind":"scratch",
    "project_name":null}],"current":"default"}
    """#

    private static let board = #"""
    {"columns":[
      {"name":"triage","tasks":[{"id":"t_017edf3a","title":"Shape the next slice","body":"Review **requirements**.","assignee":null,
        "status":"triage","priority":0,"created_at":1791251508,"started_at":null,"workspace_kind":"scratch","workspace_path":null,
        "claim_lock":null,"worker_pid":null,"tenant":null,"age":{"created_age_seconds":14,"started_age_seconds":null,
        "time_to_complete_seconds":null},"latest_summary":null,"link_counts":{"parents":0,"children":1},"comment_count":0,"progress":null}]},
      {"name":"todo","tasks":[]},
      {"name":"scheduled","tasks":[{"id":"t_ded419c6","title":"Nightly cleanup","assignee":"default","status":"scheduled",
        "priority":0,"created_at":1791251508,"tenant":"app","age":{"created_age_seconds":14,"started_age_seconds":null},
        "link_counts":{"parents":0,"children":0},"comment_count":0}]},
      {"name":"ready","tasks":[]},
      {"name":"running","tasks":[{"id":"t_9b1c2d3e","title":"Run the read contracts","assignee":"default","status":"running",
        "priority":1,"created_at":1791240000,"started_at":1791250608,"workspace_kind":"worktree",
        "workspace_path":"/Users/hermex/.hermes/kanban/worktrees/t_9b1c2d3e","claim_lock":"mac.local:4242","claim_expires":1791252508,
        "worker_pid":4242,"current_run_id":1,"tenant":"app","age":{"created_age_seconds":11508,"started_age_seconds":900,
        "time_to_complete_seconds":null},"link_counts":{"parents":1,"children":0},"comment_count":1,
        "warnings":{"count":1,"kinds":{"slow":1},"latest_at":1791251500,"highest_severity":"info"}}]},
      {"name":"blocked","tasks":[]},
      {"name":"review","tasks":[{"id":"t_04fba87e","title":"Await review","assignee":"reviewer","status":"review","priority":0,
        "created_at":1791251508,"tenant":"app","age":{"created_age_seconds":14,"started_age_seconds":null},
        "link_counts":{"parents":0,"children":0},"comment_count":0}]},
      {"name":"done","tasks":[{"id":"t_ed0bb193","title":"Verify read contracts","assignee":null,"status":"done","priority":0,
        "created_at":1791251508,"completed_at":1791251517,"age":{"created_age_seconds":14,"started_age_seconds":null,
        "time_to_complete_seconds":9},"link_counts":{"parents":0,"children":0},"comment_count":0}]}
    ],"tenants":["app"],"assignees":["default","reviewer"],"latest_event_id":14,"now":1791251522}
    """#

    private static let stats = #"""
    {"by_status":{"triage":1,"scheduled":1,"running":1,"review":1,"done":1},
    "by_assignee":{"default":{"scheduled":1,"running":1},"reviewer":{"review":1}},"oldest_ready_age_seconds":null,"now":1791251522}
    """#

    private static let assignees = #"""
    {"assignees":[{"name":"default","on_disk":true,"counts":{"scheduled":1,"running":1}},
    {"name":"reviewer","on_disk":false,"counts":{"review":1}}]}
    """#

    private static let detail = #"""
    {"task":{"id":"t_9b1c2d3e","title":"Run the read contracts","body":"- Dense board","assignee":"default","status":"running",
      "priority":1,"created_at":1791240000,"started_at":1791250608,"workspace_kind":"worktree",
      "workspace_path":"/Users/hermex/.hermes/kanban/worktrees/t_9b1c2d3e","claim_lock":"mac.local:4242","worker_pid":4242,
      "current_run_id":1,"tenant":"app","age":{"created_age_seconds":11508,"started_age_seconds":900},"latest_summary":null},
    "comments":[{"id":1,"task_id":"t_9b1c2d3e","author":"hermex","body":"Fixtures should cover eight Columns.","created_at":1791251517}],
    "events":[{"id":2,"task_id":"t_9b1c2d3e","kind":"created","payload":{"status":"ready","workspace_path":null},
      "created_at":1791240000,"run_id":null},
      {"id":14,"task_id":"t_9b1c2d3e","kind":"linked","payload":{"parent":"t_017edf3a","child":"t_9b1c2d3e"},
      "created_at":1791251517,"run_id":null}],
    "attachments":[{"id":3,"task_id":"t_9b1c2d3e","filename":"spec.md","content_type":"text/markdown","size":120,
      "uploaded_by":"dashboard","stored_path":"/Users/hermex/.hermes/kanban/attachments/spec.md","created_at":1791251500}],
    "links":{"parents":["t_017edf3a"],"children":[]},
    "link_tasks":[{"id":"t_017edf3a","title":"Shape the next slice","status":"triage"}],
    "child_results":[],
    "runs":[{"id":1,"task_id":"t_9b1c2d3e","profile":"default","step_key":null,"status":"running","claim_lock":"mac.local:4242",
      "claim_expires":1791252508,"worker_pid":4242,"max_runtime_seconds":null,"last_heartbeat_at":1791251500,
      "started_at":1791250608,"ended_at":null,"outcome":null,"summary":null,"metadata":null,"error":null}]}
    """#

    /// One Card as the host's `{task}` write reply carries it.
    private static func card(_ id: String, status: String, assignee: String? = nil, tenant: String? = nil) -> String {
        let assignee = assignee.map { "\"\($0)\"" } ?? "null", tenant = tenant.map { "\"\($0)\"" } ?? "null"
        return #"{"task":{"id":""# + id + #"","title":"Ready card","body":null,"assignee":"# + assignee + #","status":""#
            + status + #"","priority":0,"created_at":1791259050,"workspace_kind":"scratch","workspace_path":null,"tenant":"#
            + tenant + #","claim_lock":null,"worker_pid":null,"age":{"created_age_seconds":0,"started_age_seconds":null}}}"#
    }

    /// One Card's detail as the host's `/tasks/{id}` carries it, with its prerequisites.
    private static func detail(_ id: String, status: String, parents: [String] = []) -> String {
        let parents = parents.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"task":{"id":""# + id + #"","title":"Ready card","body":null,"assignee":null,"status":""# + status
            + #"","priority":0,"created_at":1791259050,"tenant":null,"age":{"created_age_seconds":0}},"comments":[],"#
            + #""events":[],"attachments":[],"links":{"parents":["# + parents + #"],"children":[]},"link_tasks":[],"#
            + #""child_results":[],"runs":[]}"#
    }

    private static let createdTriage = #"""
    {"task":{"id":"t_5ff898b1","title":"Shape the next slice","body":null,"assignee":null,"status":"triage","priority":0,
    "created_by":"dashboard","created_at":1791259058,"workspace_kind":"worktree","workspace_path":null,"claim_lock":null,
    "tenant":"app","idempotency_key":"key-1","worker_pid":null,"skills":null,"max_runtime_seconds":null,
    "age":{"created_age_seconds":0,"started_age_seconds":null,"time_to_complete_seconds":null},"latest_summary":null}}
    """#

    /// The pinned Board with one more Card, `t_2ad0ddc5`, in Ready.
    private static let boardWithReadyCard = boardWith("t_2ad0ddc5", in: "ready")

    /// The pinned Board with one more Card, `id`, first in the Column `status`.
    private static func boardWith(_ id: String, in status: String, title: String = "Ready card") -> String {
        let card = #"{"id":""# + id + #"","title":""# + title + #"","assignee":null,"status":""# + status
            + #"","priority":0,"created_at":1791259050,"age":{"created_age_seconds":0,"started_age_seconds":null},"#
            + #""link_counts":{"parents":0,"children":0},"comment_count":0}"#
        let column = #"{"name":""# + status + #"","tasks":["#
        let empty = board.replacingOccurrences(of: column + "]}", with: column + card + "]}")
        return empty != board ? empty : board.replacingOccurrences(of: column, with: column + card + ",")
    }

    private static let absentLog = #"""
    {"task_id":"t_9b1c2d3e","path":"/var/folders/sk/T/hermes/kanban/logs/t_9b1c2d3e.log","exists":false,"size_bytes":0,
    "content":"","truncated":false}
    """#
}

/// Records live-update starts as `board@since`.
private final class RecordingKanbanStream: KanbanEventStreamingClient {
    private(set) var starts: [String] = []

    func start(
        board: String,
        since: Int,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        starts.append("\(board)@\(since)")
    }

    func stop() {}
}
