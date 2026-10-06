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

    func testHandshakeShowsTheHostsEightColumnsReadOnlyWithoutLiveUpdates() async {
        let stream = RecordingKanbanStream()
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host()), streamClient: stream)

        await state.load()
        state.setVisible(true)

        XCTAssertEqual(state.state, .partial)
        XCTAssertEqual(state.report?.warnings, [.readOnly], "no `changed` and no configured Columns are not warnings")
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

        XCTAssertFalse(state.canCreateCards)
        XCTAssertFalse(state.canUseCardWorkflow)
        XCTAssertFalse(state.canAddComments)
        XCTAssertFalse(state.canManageBoards)
        XCTAssertEqual(state.dispatcherAvailability, .readOnly)
        XCTAssertFalse(state.offersOnlyMine)
        XCTAssertEqual(stream.startCount, 0, "the host has no event stream until #1045")

        // Returning to the foreground reloads the Board instead.
        await state.setScenePhase(.background)
        await state.setScenePhase(.active)
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/board"), 2)
        XCTAssertEqual(stream.startCount, 0)
        XCTAssertFalse(state.liveUpdatesDelayed)
    }

    /// A foreground return while a pushed Card covers the Board reloads the Board when it
    /// reappears; without one, reappearing keeps the Board on screen.
    func testAForegroundReturnBehindACardReloadsTheBoardWhenItReappears() async {
        let state = KanbanFeatureState(server: server, client: HermesKanbanClient(http: host()))
        await state.load()
        state.setVisible(true)
        state.setVisible(false)
        await state.setScenePhase(.background)
        // The host retitles a Card while the app is in the background.
        _ = host(["/api/plugins/kanban/board": .json(200, Self.json(Self.board.replacingOccurrences(
            of: "Await review", with: "Reviewed while away")))])
        await state.setScenePhase(.active)
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/board"), 1, "the covered Board waits")

        state.setVisible(true)
        await state.loadIfNeeded()

        XCTAssertEqual(state.allCards.first { $0.cardID == "t_04fba87e" }?.title, "Reviewed while away")
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/board"), 2)

        state.setVisible(false)
        state.setVisible(true)
        await state.loadIfNeeded()
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/kanban/board"), 2)
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
        XCTAssertEqual(snapshot.readOnly, true)

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

    // MARK: - Host

    private func host(_ overrides: [String: HermesHostFixture.Reply] = [:]) -> HermesConnection {
        let pinned: [String: String] = [
            "/api/plugins/kanban/config": Self.config,
            "/api/plugins/kanban/boards": Self.boards,
            "/api/plugins/kanban/board": Self.board,
            "/api/plugins/kanban/stats": Self.stats,
            "/api/plugins/kanban/assignees": Self.assignees,
            "/api/plugins/kanban/tasks/t_9b1c2d3e": Self.detail,
            "/api/plugins/kanban/tasks/t_9b1c2d3e/log": Self.absentLog
        ]
        let replies = pinned.mapValues { HermesHostFixture.Reply.json(200, Self.json($0)) }
            .merging(overrides) { _, override in override }
        return HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            request.url.flatMap { replies[$0.path] }
        })
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

    private static let absentLog = #"""
    {"task_id":"t_9b1c2d3e","path":"/var/folders/sk/T/hermes/kanban/logs/t_9b1c2d3e.log","exists":false,"size_bytes":0,
    "content":"","truncated":false}
    """#
}

/// Counts live-update starts; a Hermes host must see none.
private final class RecordingKanbanStream: KanbanEventStreamingClient {
    private(set) var startCount = 0

    func start(
        url: URL,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        startCount += 1
    }

    func stop() {}
}
