import XCTest
import Observation
@testable import HermesMobile

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

    func testALoadMoreDuringTheLaneReadKeepsPagingHeldUntilItsPageLands() async {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let firstPage = BotJSON.object(["sessions": .array((0..<100).map { row("s\($0)") })])
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
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
        XCTAssertEqual(writes(host, ["projects.create"]).map { $0["primary_path"] }, [.string("/Users/me/launch"), .string("/Users/me/launch")])
        XCTAssertEqual(lane("p_9", in: list), ["a"])
    }

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
        XCTAssertEqual(HermesFolderCompletion.suggestions(from: hidden, typed: "~/"), .init())
    }

    func testAFullListingOfHiddenEntriesAsksForMoreOfTheName() {
        let hiddenHome = BotJSON.object(["items": .array((0..<30).map { index in
            .object(["text": .string("~/.cache\(index)/"), "display": .string(".cache\(index)/"), "meta": .string("dir")])
        })])

        XCTAssertEqual(HermesFolderCompletion.suggestions(from: hiddenHome, typed: "~/"), .init(needsMoreTyping: true))
        XCTAssertEqual(
            HermesFolderCompletion.suggestions(from: hiddenHome, typed: "~/.c"), .init(folders: (0..<30).map { "~/.cache\($0)/" })
        )
    }

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

    private func makeList(_ connection: HermesConnection) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }

    private func serve(_ pages: [Int: [BotJSON]]) {
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            guard request.httpMethod == "GET", let url = request.url, url.path == "/api/sessions" else { return nil }
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            return .json(200, .object(["sessions": .array(pages[offset] ?? [])]))
        }
    }

    private func pageOffsets() -> [Int] {
        HermesHostFixture.requests.filter { $0.url?.path == "/api/sessions" && HermesHostFixture.emptyScheduledPage($0) == nil }.compactMap { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
            guard items?.contains(URLQueryItem(name: "archived", value: "only")) != true else { return nil }
            return items?.first { $0.name == "offset" }?.value.flatMap(Int.init)
        }
    }

    private func row(_ id: String, lastActive: Double = 100, cwd: String? = nil, profile: String = "default") -> BotJSON {
        var fields: [String: BotJSON] = ["id": .string(id), "last_active": .number(lastActive), "profile": .string(profile)]
        if let cwd { fields["cwd"] = .string(cwd) }
        return .object(fields)
    }

    private func tree(_ nodes: [BotJSON], activeID: String? = nil) -> BotJSON {
        .object(["projects": .array(nodes), "active_id": activeID.map(BotJSON.string) ?? .null,
                 "scoped_session_ids": .array(nodes.flatMap { $0["sessionIds"].list ?? [] })])
    }

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

    private func lane(_ projectID: String, in list: SessionListViewModel) -> [String] {
        list.visibleSessions(searchText: "", selectedProjectID: projectID).compactMap(\.sessionId)
    }

    private func writes(_ host: BotSocketHost, _ methods: Set<String>) -> [[String: BotJSON]] {
        host.requests.filter { methods.contains($0["method"].text ?? "") }.compactMap { $0["params"].fields }
    }

    private final class HeldTreeWire: BotTransport {
        private let inner: BotClient
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
        func scheduledSessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
            try await inner.scheduledSessionPage(profile: profile, offset: offset, archived: archived)
        }
        func searchScheduledSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult] {
            try await inner.searchScheduledSessions(query: query, profile: profile, limit: limit)
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
}
