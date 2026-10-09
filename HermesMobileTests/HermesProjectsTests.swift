import XCTest
import Observation
@testable import HermesMobile

/// Hermes projects as folder lanes (#1052) on the scripted gateway: a real `BotClient` and
/// `HermesGateway` over `BotSocketHost`'s socket, and `HermesHostFixture` for the list's pages, in
/// the shapes the 0.21.5 pin answers (`tui_gateway/methods_projects.py`, `project_tree.py`,
/// `methods_session.py` `session.workspace.move`).
@MainActor final class HermesProjectsTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let record = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesProjectsTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { HermesHostFixture.reset() }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: Lanes

    /// The lanes are the user's projects, then the automatic per-repository ones, in the host's
    /// order; its "No project" bucket is the unfiltered list, never a lane. Each row shows in the
    /// lane that claims it.
    func testLanesAreTheHostsProjectsWithoutNoProject() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serve([0: [row("a"), row("b"), row("c")]])
        host.always("projects.tree", .init(result: tree([
            node(HermesProjectTree.noProjectID, "Home", path: nil, sessions: ["c"], isNoProject: true),
            node("p_1a2b3c4d", "Launch", path: "/Users/me/launch", sessions: ["a"], color: "#7cb9ff"),
            node("/Users/me/src/app", "app", path: "/Users/me/src/app", sessions: ["b"], isAuto: true)
        ])))
        let list = makeList(connection)

        await list.openHermes()

        XCTAssertEqual(list.projects.map(\.projectId), ["p_1a2b3c4d", "/Users/me/src/app"])
        XCTAssertEqual(list.projects.map(\.name), ["Launch", "app"])
        XCTAssertEqual(list.projects.map(\.color), ["#7cb9ff", nil])
        XCTAssertEqual(list.projects.map(\.hermes), [
            ProjectSummary.Hermes(folder: "/Users/me/launch", isAutomatic: false, sessionCount: 1, claimedCount: 1),
            ProjectSummary.Hermes(folder: "/Users/me/src/app", isAutomatic: true, sessionCount: 1, claimedCount: 1)
        ])
        XCTAssertEqual(lane("p_1a2b3c4d", in: list), ["a"])
        XCTAssertEqual(lane("/Users/me/src/app", in: list), ["b"])
        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).count, 3)
        XCTAssertEqual(writes(host, ["projects.tree"]), [["profile": .string("default")]])
    }

    /// A lane reads pages until it holds every session the host named for it, then stops, though
    /// the list itself goes on.
    func testALanePagesUntilItHoldsEverySessionTheHostNamed() async {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serve([0: (0..<100).map { row("s\($0)", lastActive: Double(1_000 - $0)) },
               100: (100..<200).map { row("s\($0)", lastActive: Double(1_000 - $0)) },
               200: (200..<210).map { row("s\($0)", lastActive: Double(1_000 - $0)) }])
        host.always("projects.tree", .init(result: tree([node("p_1", "Launch", path: "/Users/me/launch", sessions: ["s5", "s150"])])))
        let list = makeList(connection)
        await list.openHermes()
        XCTAssertEqual(lane("p_1", in: list), ["s5"])
        XCTAssertTrue(list.hermesLaneIsShort("p_1"))

        await list.fillHermesLane("p_1")

        XCTAssertEqual(lane("p_1", in: list), ["s5", "s150"])
        XCTAssertFalse(list.hermesLaneIsShort("p_1"))
        XCTAssertTrue(list.hasMoreSessions, "the list itself goes on")
        XCTAssertEqual(pageOffsets(), [0, 100])
    }

    /// The lanes are read after a list read's rows are in. A "Load more" that starts during that
    /// read keeps paging held until its own page lands, so a second read of the same page can't
    /// start and end the list early.
    func testALoadMoreDuringTheLaneReadKeepsPagingHeldUntilItsPageLands() async {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let firstPage = BotJSON.object(["sessions": .array((0..<100).map { row("s\($0)") })])
        _ = HermesHostFixture.configuration { request in
            guard request.httpMethod == "GET", let url = request.url, url.path == "/api/sessions" else { return nil }
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            return offset == 0 ? .json(200, firstPage) : .park
        }
        host.always("projects.tree", .init(result: tree([])))
        let list = makeList(connection)
        await list.openHermes()

        host.withhold("projects.tree")
        let lanesAsked = expectation(description: "the reload reads the lanes")
        host.expect(lanesAsked, onNext: "projects.tree")
        let reload = Task { await list.openHermes() }
        await fulfillment(of: [lanesAsked], timeout: 5)
        let parked = expectation(description: "the next page is in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        let more = Task { await list.loadMoreHermesSessions() }
        await fulfillment(of: [parked], timeout: 5)
        reload.cancel()
        await reload.value

        XCTAssertTrue(list.isLoadingMoreSessions, "the page read is still in flight")
        HermesHostFixture.releaseParked(.json(200, .object(["sessions": .array([])])))
        await more.value
        XCTAssertFalse(list.isLoadingMoreSessions)
        XCTAssertEqual(pageOffsets(), [0, 0, 100])
    }

    // MARK: Create, rename, delete

    /// New Project sends its name, color and folder, the folder as the primary. A folder another
    /// project has as its primary is refused (5063) with the host's words, which stay in the
    /// sheet; a created project shows as a lane.
    func testCreateSendsItsFolderAndADuplicateFolderShowsTheHostsWords() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serve([0: [row("a", cwd: "/Users/me/launch")]])
        host.always("projects.tree", .init(result: tree([])))
        let list = makeList(connection)
        await list.openHermes()
        let refusal = "folder already belongs to project 'launch' (p_1a2b3c4d); switch to it instead of creating a duplicate"
        host.next("projects.create", .init(error: 5063, message: refusal))

        let refused = await list.createHermesProject(named: "Launch", color: "#7cb9ff", folder: "/Users/me/launch/")
        XCTAssertNil(refused)
        XCTAssertEqual(list.projectSheetErrorMessage, refusal)

        host.always("projects.create", .init(result: .object(["project": .object(["id": .string("p_9")])])))
        host.always("projects.tree", .init(result: tree([node("p_9", "Launch", path: "/Users/me/launch", sessions: ["a"])])))
        let created = await list.createHermesProject(named: " Launch ", color: "#7cb9ff", folder: "/Users/me/launch/")

        XCTAssertEqual(created, "/Users/me/launch")
        XCTAssertNil(list.projectSheetErrorMessage)
        let create: [String: BotJSON] = ["profile": .string("default"), "name": .string("Launch"),
                                         "folders": .array([.string("/Users/me/launch")]),
                                         "primary_path": .string("/Users/me/launch"), "color": .string("#7cb9ff")]
        XCTAssertEqual(writes(host, ["projects.create"]), [create, create])
        XCTAssertEqual(lane("p_9", in: list), ["a"])
    }

    /// A lane read that began before a create can answer after the read the create made. Only
    /// the latest read applies, so the created project stays.
    func testAnOlderLaneReadAnsweringLastKeepsTheCreatedProject() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serve([0: [row("a", cwd: "/Users/me/launch")]])
        host.always("projects.tree", .init(result: tree([])))
        var wire: HeldTreeWire?
        let list = SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: record, profile: "default", makeWire: { _ in
                let held = HeldTreeWire(BotClient(http: connection))
                wire = held
                return held
            }, preferences: defaults, changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
        await list.openHermes()
        let held = try XCTUnwrap(wire)

        let holding = expectation(description: "the reload's lane read is held")
        held.holdNext = holding
        let reload = Task { await list.openHermes() }
        await fulfillment(of: [holding], timeout: 5)
        host.always("projects.create", .init(result: .object(["project": .object(["id": .string("p_9")])])))
        host.always("projects.tree", .init(result: tree([node("p_9", "Launch", path: "/Users/me/launch", sessions: ["a"])])))
        let created = await list.createHermesProject(named: "Launch", color: "#7cb9ff", folder: "/Users/me/launch")
        XCTAssertEqual(created, "/Users/me/launch")
        XCTAssertEqual(list.projects.map(\.projectId), ["p_9"])
        held.release()
        await reload.value

        XCTAssertEqual(list.projects.map(\.projectId), ["p_9"])
        XCTAssertEqual(lane("p_9", in: list), ["a"])
    }

    /// Rename and recolor are one `projects.update`. Delete removes only the project: its session
    /// stays listed, and the reply's `active_id`, which can still name the deleted project, is
    /// never read.
    func testRenameAndDeleteChangeOnlyTheProject() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serve([0: [row("a")]])
        host.always("projects.tree", .init(result: tree([node("p_1", "Launch", path: "/Users/me/launch", sessions: ["a"])])))
        host.always("projects.update", .init(result: .object(["project": .object(["id": .string("p_1")])])))
        host.always("projects.delete", .init(result: .object(["projects": .array([]), "active_id": .string("p_1")])))
        let list = makeList(connection)
        await list.openHermes()
        let project = try XCTUnwrap(list.projects.first)

        host.always("projects.tree", .init(result: tree([node("p_1", "Launch v2", path: "/Users/me/launch", sessions: ["a"])])))
        let renamed = await list.rename(project, named: "Launch v2", color: "#f5c542")
        XCTAssertTrue(renamed)
        XCTAssertEqual(list.projects.map(\.name), ["Launch v2"])

        host.always("projects.tree", .init(result: tree([
            node(HermesProjectTree.noProjectID, "Home", path: nil, sessions: ["a"], isNoProject: true)
        ], activeID: "p_1")))
        let deleted = await list.delete(project)

        XCTAssertTrue(deleted)
        XCTAssertEqual(writes(host, ["projects.update", "projects.delete"]), [
            ["profile": .string("default"), "id": .string("p_1"), "name": .string("Launch v2"), "color": .string("#f5c542")],
            ["profile": .string("default"), "id": .string("p_1")]
        ])
        XCTAssertEqual(list.projects, [])
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a"])
        XCTAssertNil(list.sessions.first?.projectId)
    }

    // MARK: Move

    /// Move to Project names the stored session and the project's folder under the row's
    /// Profile. A folder the host lacks (4017) says so, and there is nothing to undo.
    func testMoveNamesTheFolderAndAMissingFolderSaysSo() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serve([0: [row("a", cwd: "/Users/me/old", profile: "research")]])
        host.always("projects.tree", .init(result: tree([])))
        host.next("session.workspace.move", .init(error: 4017, message: "working directory does not exist: /Users/me/gone"))
        let list = makeList(connection)
        await list.openHermes()

        let undo = await list.moveHermesSession(try XCTUnwrap(list.sessions.first), toFolder: "/Users/me/gone")

        XCTAssertNil(undo)
        XCTAssertEqual(list.actionErrorMessage, "Hermes can't find the folder /Users/me/gone, so the session didn't move.")
        XCTAssertEqual(writes(host, ["session.workspace.move"]), [
            ["session_key": .string("a"), "cwd": .string("/Users/me/gone"), "profile": .string("research")]
        ])
    }

    /// A moved session shows in the lane that claims its new folder. Undo is the same move back
    /// to the folder it left, which takes it out again.
    func testAMovedSessionJoinsItsNewLaneAndUndoMovesItBack() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let before = tree([node("p_1", "Launch", path: "/Users/me/launch", sessions: [])])
        let after = tree([node("p_1", "Launch", path: "/Users/me/launch", sessions: ["a"])])
        serve([0: [row("a", cwd: "/Users/me/old")]])
        host.always("projects.tree", .init(result: before))
        host.always("session.workspace.move", .init(result: .object([
            "cwd": .string("/Users/me/launch"), "branch": .null, "git_repo_root": .null
        ])))
        let list = makeList(connection)
        await list.openHermes()
        let session = try XCTUnwrap(list.sessions.first)

        host.always("projects.tree", .init(result: after))
        let undo = await list.moveHermesSession(session, toFolder: "/Users/me/launch")
        await waitUntil("in the lane") { self.lane("p_1", in: list) == ["a"] }
        XCTAssertEqual(undo, "/Users/me/old")

        host.always("projects.tree", .init(result: before))
        _ = await list.moveHermesSession(session, toFolder: try XCTUnwrap(undo))
        await waitUntil("out of the lane") { self.lane("p_1", in: list).isEmpty }

        XCTAssertEqual(writes(host, ["session.workspace.move"]).map { $0["cwd"] }, [.string("/Users/me/launch"), .string("/Users/me/old")])
    }

    /// New Project from a row's Move menu ends with the session in the project: saved on the
    /// session's own folder, the session is already the project's; saved on any other, a parent
    /// included (a deeper project may still claim it), it asks the same Move to Project. The
    /// list's New Project moves nothing.
    func testANewProjectFromAMoveMenuAsksToMoveTheSessionOnlyWhenItWorksElsewhere() throws {
        let session = SessionSummary(sessionId: "a", workspace: "/Users/me/launch/app", profile: "default")
        let fromMenu = HermesProjectCreation(folder: "/Users/me/launch/app", session: session)

        XCTAssertNil(HermesProjectCreation(folder: "").move(intoProjectNamed: "Launch", savedOn: "/Users/me/other", isBusy: false))
        XCTAssertNil(fromMenu.move(intoProjectNamed: "Launch", savedOn: "/Users/me/launch/app", isBusy: false))
        XCTAssertEqual(fromMenu.move(intoProjectNamed: "Launch", savedOn: "/Users/me/launch", isBusy: false)?.folder, "/Users/me/launch")
        let move = try XCTUnwrap(fromMenu.move(intoProjectNamed: " Other ", savedOn: "/Users/me/other", isBusy: true))
        XCTAssertEqual(move.session.sessionId, "a")
        XCTAssertEqual(move.folder, "/Users/me/other")
        XCTAssertEqual(move.title, "Move to Other?")
        XCTAssertTrue(move.isBusy)
    }

    // MARK: Folder field

    /// The folder field's suggestions are the host's folders under the typed parent, typed as the
    /// user typed it and ending in `/`; files, and hidden folders until a `.` is typed, are left out.
    func testFolderSuggestionsAreTheHostsFoldersUnderTheTypedParent() {
        let listing = BotJSON.object(["items": .array([
            .object(["text": .string("../src/"), "display": .string("src/"), "meta": .string("dir")]),
            .object(["text": .string("../.git/"), "display": .string(".git/"), "meta": .string("dir")]),
            .object(["text": .string("../notes.md"), "display": .string("notes.md"), "meta": .string("")])
        ])])
        let hidden = BotJSON.object(["items": .array([
            .object(["text": .string("../.git/"), "display": .string(".git/"), "meta": .string("dir")])
        ])])

        XCTAssertEqual(HermesFolderCompletion.suggestions(from: listing, typed: "~/"), .init(folders: ["~/src/"]))
        XCTAssertEqual(
            HermesFolderCompletion.suggestions(from: hidden, typed: "/Users/me/.g"), .init(folders: ["/Users/me/.git/"])
        )
        // A listing under the host's limit is complete, so offering nothing needs no hint.
        XCTAssertEqual(HermesFolderCompletion.suggestions(from: hidden, typed: "~/"), .init())
    }

    /// The host lists 30 entries, hidden ones first, so a home folder's listing can end before
    /// any folder the field offers. The field then asks for more of the name instead of
    /// showing nothing.
    func testAFullListingOfHiddenEntriesAsksForMoreOfTheName() {
        let hiddenHome = BotJSON.object(["items": .array((0..<30).map { index in
            .object(["text": .string("~/.cache\(index)/"), "display": .string(".cache\(index)/"), "meta": .string("dir")])
        })])

        XCTAssertEqual(HermesFolderCompletion.suggestions(from: hiddenHome, typed: "~/"), .init(needsMoreTyping: true))
        XCTAssertEqual(
            HermesFolderCompletion.suggestions(from: hiddenHome, typed: "~/.c"), .init(folders: (0..<30).map { "~/.cache\($0)/" })
        )
    }

    // MARK: Chat folder picker (#1117)

    /// A chat's folder picker offers its current folder first, then the user's project folders,
    /// then the folders the Profile's recent sessions worked in, each once. Automatic lanes and
    /// rows another Profile names are left out.
    func testFolderChoicesAreCurrentThenProjectsThenRecentFolders() {
        let projects = HermesProjectTree(reply: tree([
            node("p_launch", "Launch", path: "/Users/me/launch", sessions: []),
            node("/Users/me/src/app", "app", path: "/Users/me/src/app", sessions: [], isAuto: true),
            node("p_notes", "Notes", path: "/Users/me/notes", sessions: []),
            node(HermesProjectTree.noProjectID, "Home", path: nil, sessions: [], isNoProject: true)
        ]))
        let recent = [
            HermesSessionRow(id: "a", cwd: "/Users/me/src/app", profile: "work"),
            HermesSessionRow(id: "b", cwd: "/Users/me/launch", profile: "work"),
            HermesSessionRow(id: "c", cwd: "/Users/me/elsewhere", profile: "default"),
            HermesSessionRow(id: "d", cwd: "/Users/me/src/app", profile: "work"),
            HermesSessionRow(id: "e", profile: "work"),
            HermesSessionRow(id: "f", cwd: "/tmp/scratch")
        ]

        XCTAssertEqual(
            HermesFolderCompletion.choices(current: "/Users/me/notes", projects: projects, sessions: recent, profile: "work"),
            ["/Users/me/notes", "/Users/me/launch", "/Users/me/src/app", "/tmp/scratch"]
        )
        XCTAssertEqual(HermesFolderCompletion.choices(current: nil, projects: nil, sessions: [], profile: "work"), [],
                       "a host that answers nothing offers nothing")
    }

    // MARK: Fixtures

    private func makeList(_ connection: HermesConnection) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }

    /// Answers the list's page reads by offset; a page past the last is empty. Call it after
    /// `BotSocketHost.connection`, whose sign-in script it replaces.
    private func serve(_ pages: [Int: [BotJSON]]) {
        _ = HermesHostFixture.configuration { request in
            guard request.httpMethod == "GET", let url = request.url, url.path == "/api/sessions" else { return nil }
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            return .json(200, .object(["sessions": .array(pages[offset] ?? [])]))
        }
    }

    private func pageOffsets() -> [Int] {
        HermesHostFixture.requests.filter { $0.url?.path == "/api/sessions" }.compactMap { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
                .first { $0.name == "offset" }?.value.flatMap(Int.init)
        }
    }

    /// One `/api/sessions` row in the host's shape.
    private func row(_ id: String, lastActive: Double = 100, cwd: String? = nil, profile: String = "default") -> BotJSON {
        var fields: [String: BotJSON] = ["id": .string(id), "last_active": .number(lastActive), "profile": .string(profile)]
        if let cwd { fields["cwd"] = .string(cwd) }
        return .object(fields)
    }

    /// One `projects.tree` reply (`methods_config.py`): the lanes, Desktop's `active_id`, and
    /// every claimed session id.
    private func tree(_ nodes: [BotJSON], activeID: String? = nil) -> BotJSON {
        .object(["projects": .array(nodes), "active_id": activeID.map(BotJSON.string) ?? .null,
                 "scoped_session_ids": .array(nodes.flatMap { $0["sessionIds"].list ?? [] })])
    }

    /// One lane in `project_tree._project_node`'s wire shape.
    private func node(_ id: String, _ label: String, path: String?, sessions: [String], color: String? = nil,
                      isAuto: Bool = false, isNoProject: Bool = false) -> BotJSON {
        .object([
            "id": .string(id), "label": .string(label), "path": path.map(BotJSON.string) ?? .null,
            "color": color.map(BotJSON.string) ?? .null, "icon": .null, "isAuto": .bool(isAuto),
            "isNoProject": .bool(isNoProject), "sessionCount": .number(Double(sessions.count)), "lastActive": .number(100),
            "totalTokens": .number(0), "totalCostUsd": .number(0), "repos": .array([]), "previewSessions": .array([]),
            "sessionIds": .array(sessions.map(BotJSON.string))
        ])
    }

    /// The session ids the lane `projectID` shows.
    private func lane(_ projectID: String, in list: SessionListViewModel) -> [String] {
        list.visibleSessions(searchText: "", selectedProjectID: projectID).compactMap(\.sessionId)
    }

    /// The params of every call to one of `methods`, in order.
    private func writes(_ host: BotSocketHost, _ methods: Set<String>) -> [[String: BotJSON]] {
        host.requests.filter { methods.contains($0["method"].text ?? "") }.compactMap { $0["params"].fields }
    }

    /// The list's client, with one `projects.tree` reply held back on request, so an older lane
    /// read can answer after a newer one.
    private final class HeldTreeWire: BotTransport {
        private let inner: BotClient
        /// Fulfilled when the next lane read's reply is held; its reply waits for `release()`.
        var holdNext: XCTestExpectation?
        private var held: CheckedContinuation<Void, Never>?

        init(_ inner: BotClient) { self.inner = inner }

        var replayEpoch: String? { inner.replayEpoch }
        var onEvent: ((BotJSON) -> Void)? {
            get { inner.onEvent }
            set { inner.onEvent = newValue }
        }
        var onDisconnect: ((Error) -> Void)? {
            get { inner.onDisconnect }
            set { inner.onDisconnect = newValue }
        }
        func connect() async throws { try await inner.connect() }
        func close() { inner.close() }
        func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
            try await inner.sessionPage(profile: profile, offset: offset, archived: archived)
        }
        func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
            let reply = try await inner.call(call, validateDispatch: validateDispatch)
            guard call.method == "projects.tree", let holding = holdNext else { return reply }
            holdNext = nil
            await withCheckedContinuation { held = $0; holding.fulfill() }
            return reply
        }
        func release() { held?.resume(); held = nil }
    }

    /// Waits on observation of the list, never a clock, and fails once nothing changes for 5 s.
    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            let changed = XCTestExpectation(description: description)
            withObservationTracking { _ = condition() } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 5) == .completed else {
                return XCTFail("Nothing changed while waiting for: \(description)", file: file, line: line)
            }
        }
    }
}
