import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesBranchDuplicateTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let record = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesBranchDuplicateTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { HermesHostFixture.reset() }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheCountIsTheHostsVisibleRowsThroughTheChosenOne() {
        let image = BotJSON.array([.object(["type": .string("text"), "text": .string(" ")]),
                                   .object(["type": .string("image_url"), "image_url": .object(["url": .string("a.png")])])])
        let rows: [BotJSON] = [
            row(7, "user", "Question 1"), row(8, "assistant", "Let me run a quick check.", calls: true),
            row(9, "tool", "{\"output\": \"1\"}"),
            row(3, "assistant", "The command returned: 1.", active: false), row(4, "user", "Question 2", active: false),
            row(5, "assistant", " ", calls: true, active: false),
            row(10, "assistant", "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted.",
                ["display_kind": .string("hidden"), "_compressed_summary": .bool(true)]),
            row(11, "user", "Question 3"), row(12, "user", image)
        ]

        XCTAssertEqual(HermesBranchCount.count(through: 8, in: rows), 2, "a reply that called a tool")
        XCTAssertEqual(HermesBranchCount.count(through: 3, in: rows), 3, "a compacted reply")
        XCTAssertEqual(HermesBranchCount.count(through: 11, in: rows), 6, "after the summary, the empty reply skipped")
        XCTAssertEqual(HermesBranchCount.count(through: 12, in: rows), 7, "a photo with no text")
        XCTAssertNil(HermesBranchCount.count(through: 9, in: rows), "a tool row is never copied")
        XCTAssertNil(HermesBranchCount.count(through: 99, in: rows))
    }

    func testForkFromHereBranchesThroughTheChosenReplyAndOpensIt() async throws {
        let chat = await openChat(pages: [0: twoToolTurns])
        chat.host.always("session.branch", .init(result: branched("fork", runtime: "fork-runtime")))
        let reply = try XCTUnwrap(chat.model.messages.firstIndex { $0.rowID == 8 })
        let context = try XCTUnwrap(chat.model.actionContext(for: chat.model.messages[reply], visibleIndex: reply))
        XCTAssertTrue(context.offersFork)

        let opened = await chat.model.forkHermesSession(from: context)

        XCTAssertEqual(chat.writes("session.branch"), [["session_id": .string("runtime"), "count": .number(6)]])
        XCTAssertEqual(HermesHostFixture.requests.filter { $0.url?.path == "/api/sessions/tip" }.map(\.url?.query),
                       ["profile=default"], "the session's own row, read once")
        XCTAssertEqual(opened?.target, .session(profile: "default", key: "fork"))
        XCTAssertEqual(opened?.parentKey, "tip")
        XCTAssertNil(chat.model.messageActionErrorMessage)
        XCTAssertTrue(chat.connection.attachedRuntimes.contains("fork-runtime"))
    }

    func testForkInALongSessionReadsTheOlderPagesFirst() async throws {
        let chat = await openChat(pages: [0: (101...200).map(alternating), 100: (1...100).map(alternating), 200: []])
        chat.host.always("session.branch", .init(result: branched("fork")))
        let reply = try XCTUnwrap(chat.model.messages.firstIndex { $0.rowID == 150 })
        let context = try XCTUnwrap(chat.model.actionContext(for: chat.model.messages[reply], visibleIndex: reply))

        _ = await chat.model.forkHermesSession(from: context)

        XCTAssertEqual(chat.pages.offsets, [0, 100, 200])
        XCTAssertEqual(chat.writes("session.branch"), [["session_id": .string("runtime"), "count": .number(150)]])
    }

    func testAForkInASessionThatContinuesAnotherIsRefused() async throws {
        var config: BotJSON = .string("{\"_reset_from\": \"root\"}")
        let chat = await openChat(pages: [0: twoToolTurns]) { request in
            guard request.url?.path == "/api/sessions/tip" else { return nil }
            return .json(200, .object(["id": .string("tip"), "parent_session_id": .string("root"), "model_config": config]))
        }
        chat.host.always("session.branch", .init(result: branched("fork")))
        let reply = try XCTUnwrap(chat.model.messages.firstIndex { $0.rowID == 4 })
        let context = try XCTUnwrap(chat.model.actionContext(for: chat.model.messages[reply], visibleIndex: reply))

        for continuation in [config, .null] {
            config = continuation
            let refused = await chat.model.forkHermesSession(from: context)
            XCTAssertNil(refused)
            XCTAssertEqual(chat.model.messageActionErrorMessage,
                           "This session continues an earlier one, so Fork From Here isn’t available. Run /branch to copy the whole conversation.")
        }
        XCTAssertEqual(chat.writes("session.branch"), [])

        let whole = await chat.model.runHermesSlashCommand("/branch")
        guard case .openedHermesSession? = whole else { return XCTFail("Expected /branch to open the branch") }
        XCTAssertEqual(chat.writes("session.branch"), [["session_id": .string("runtime")]])

        config = .string("{\"_branched_from\": \"root\"}")
        let forked = await chat.model.forkHermesSession(from: context)
        XCTAssertEqual(forked?.target, .session(profile: "default", key: "fork"))
        XCTAssertEqual(chat.writes("session.branch").last, ["session_id": .string("runtime"), "count": .number(3)])
    }

    func testAnUnsavedPromptOffersNoFork() async throws {
        let chat = await openChat(pages: [0: twoToolTurns])
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Third")
        let sent = try XCTUnwrap(chat.model.messages.lastIndex { $0.role == "user" })

        XCTAssertNil(chat.model.messages[sent].rowID)
        XCTAssertEqual(chat.model.actionContext(for: chat.model.messages[sent], visibleIndex: sent)?.offersFork, false)
    }

    func testBranchAndForkCopyTheWholeTranscriptAndOpenIt() async {
        let chat = await openChat(pages: [0: twoToolTurns])
        chat.host.always("session.branch", .init(result: branched("named")))

        let named = await chat.model.runHermesSlashCommand("/branch  Experiment ")
        let alias = await chat.model.runHermesSlashCommand("/fork")

        XCTAssertEqual(chat.writes("session.branch"), [
            ["session_id": .string("runtime"), "name": .string("Experiment")],
            ["session_id": .string("runtime")]
        ])
        for result in [named, alias] {
            guard case .openedHermesSession(let branch)? = result else { return XCTFail("Expected the branch to open") }
            XCTAssertEqual(branch.target, .session(profile: "default", key: "named"))
            XCTAssertEqual(branch.parentKey, "tip")
        }
        XCTAssertEqual(chat.writes("slash.exec"), [])
    }

    func testABranchTheHostRefusesSaysWhy() async {
        let chat = await openChat(pages: [0: twoToolTurns])
        let inUse = "branch failed: Title 'Experiment' is already in use by session 20261008_002836_2369bc"
        chat.host.next("session.branch", .init(error: 4008, message: "nothing to branch — send a message first"))
        chat.host.next("session.branch", .init(error: 5008, message: inUse))

        let empty = await chat.model.runHermesSlashCommand("/branch")
        XCTAssertEqual(empty, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "Send a message first, then run /branch.")

        let taken = await chat.model.runHermesSlashCommand("/branch Experiment")
        XCTAssertEqual(taken, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, inUse)
    }

    func testABranchShowsForkedFromItsParentAndAResetChildDoesNot() async throws {
        var config = "{\"_branched_from\": \"parent\"}"
        let chat = await openChat(pages: [0: twoToolTurns]) { Self.branchRows($0, config: config) }

        await chat.model.checkHermesForkParent("parent")
        let origin = chat.model.hermesForkOrigin
        XCTAssertEqual(origin?.title, "Forked from Plan the launch")
        XCTAssertEqual(origin?.parentSessionID, "parent")
        let parent = try XCTUnwrap(origin?.parent)
        XCTAssertEqual(chat.model.hermesChat(opening: parent)?.target, .session(profile: "default", key: "parent"))
        let reads = HermesHostFixture.count("/api/sessions/tip")
        XCTAssertEqual(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions/tip" }?.url?.query, "profile=default")

        config = "{\"_reset_from\": \"parent\"}"
        await chat.model.checkHermesForkParent("parent")
        XCTAssertNil(chat.model.hermesForkOrigin)
        await chat.model.checkHermesForkParent(nil)
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/tip"), reads + 1, "a chat opened without a parent reads nothing")
    }

    func testForkedFromWaitsForALaterAttach() async {
        let (retry, release) = AsyncStream<Void>.makeStream()
        let chat = await openChat(pages: [0: twoToolTurns], refusedFirst: true, reconnectDelay: { _ in
            for await _ in retry { return }
        }) { Self.branchRows($0, config: "{\"_branched_from\": \"parent\"}") }

        await chat.model.checkHermesForkParent("parent")
        XCTAssertNil(chat.model.hermesForkOrigin)
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/tip"), 0, "nothing to ask before the chat attaches")

        release.yield()
        await waitUntil("the reconnect asks again") { chat.model.hermesForkOrigin != nil }
        XCTAssertEqual(chat.model.hermesForkOrigin?.title, "Forked from Plan the launch")
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/tip"), 1)
    }

    func testTheCopyIsTheExportUnderANewIDWithoutItsParent() throws {
        let tool = BotJSON.object(["id": .number(795), "session_id": .string("tip"), "role": .string("tool"),
                                   "content": .string("{\"output\": \"1\", \"exit_code\": 0, \"error\": null}"),
                                   "tool_call_id": .string("call_2"), "tool_name": .string("terminal"),
                                   "timestamp": .number(1_791_433_459.9385269)])
        let export = BotJSON.object([
            "id": .string("tip"), "title": .string("Plan"), "parent_session_id": .string("root"), "archived": .number(1),
            "pinned": .number(1), "source": .string("tui"), "_lineage_root_id": .string("root"), "timings": .object([:]),
            "model_config": .string("{\"_branched_from\": \"root\"}"), "messages": .array([tool])
        ])

        let copy = try XCTUnwrap(HermesSessionDuplication.copy(of: export, id: "20261008_002420_fb927d"))

        var message = try XCTUnwrap(tool.fields)
        message["id"] = nil
        XCTAssertEqual(copy, .object([
            "id": .string("20261008_002420_fb927d"), "title": .null, "archived": .bool(false), "pinned": .bool(false),
            "source": .string("tui"), "model_config": .string("{\"_branched_from\": \"root\"}"),
            "messages": .array([.object(message)])
        ]))
        XCTAssertNil(HermesSessionDuplication.copy(of: .object(["id": .string("tip")]), id: "x"), "an export without messages")
    }

    func testANewIDHasTheHostsShape() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8,
                                                                            hour: 0, minute: 24, second: 20)))
        let id = HermesSessionDuplication.newID(at: date)
        XCTAssertTrue(id.hasPrefix("20261008_002420_"), id)
        XCTAssertNotNil(id.wholeMatch(of: #/\d{8}_\d{6}_[0-9a-f]{6}/#), id)
    }

    func testDuplicateImportsTheCopyTitlesItAndOpensIt() async throws {
        var imported: [BotJSON] = []
        var titles: [(path: String, body: BotJSON)] = []
        let list = await openList { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions/tip/export"): return .json(200, Self.export)
            case ("POST", "/api/sessions/import"):
                let body = Self.body(request)
                imported.append(body)
                let id = body["sessions"].list?.first?["id"] ?? .null
                return .json(200, .object(["ok": .bool(true), "imported": .number(1), "skipped": .number(0),
                                           "imported_ids": .array([id]), "skipped_ids": .array([]), "errors": .array([])]))
            case ("PATCH", let path?):
                let body = Self.body(request)
                titles.append((path, body))
                return body["title"] == .string("Plan (copy)")
                    ? .json(400, .object(["detail": .string("Title 'Plan (copy)' is already in use by session 20261008_002420_fb927d")]))
                    : .json(200, .object(["ok": .bool(true), "title": body["title"]]))
            default: return nil
            }
        }

        let copy = await list.duplicate(try XCTUnwrap(list.sessions.first))

        XCTAssertNil(list.actionErrorMessage)
        let key = try XCTUnwrap(imported.first?["sessions"].list?.first?["id"].text)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?["profile"], .string("research"))
        XCTAssertEqual(imported.first?["sessions"].list?.first?["messages"].list?.count, 4)
        XCTAssertEqual(imported.first?["sessions"].list?.first?["title"], .null)
        XCTAssertEqual(titles.map(\.path), ["/api/sessions/\(key)", "/api/sessions/\(key)"])
        XCTAssertEqual(titles.map(\.body), [
            .object(["title": .string("Plan (copy)"), "profile": .string("research")]),
            .object(["title": .string("Plan (copy 2)"), "profile": .string("research")])
        ])
        XCTAssertEqual(copy?.sessionId, key)
        XCTAssertEqual(copy?.title, "Plan (copy 2)")
        XCTAssertEqual(copy?.hermesTarget(listedIn: "research"), .session(profile: "research", key: key))
        XCTAssertNil(copy?.parentSessionId, "a copy has no parent")
    }

    func testACopyTheHostWontTitleStillOpens() async throws {
        let list = await openList { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions/tip/export"): return .json(200, Self.export)
            case ("POST", "/api/sessions/import"):
                let id = Self.body(request)["sessions"].list?.first?["id"] ?? .null
                return .json(200, .object(["ok": .bool(true), "imported": .number(1), "imported_ids": .array([id])]))
            case ("PATCH", _): return .json(500, .object(["detail": .string("database is locked")]))
            default: return nil
            }
        }

        let copy = await list.duplicate(try XCTUnwrap(list.sessions.first))

        XCTAssertNotNil(copy?.sessionId)
        XCTAssertNil(copy?.title)
        XCTAssertNil(list.actionErrorMessage)
        XCTAssertEqual(HermesHostFixture.requests.filter { $0.httpMethod == "PATCH" }.count, 1, "no retry after a failure")
    }

    func testATooLargeOrSkippedImportOpensNothing() async throws {
        var export = Self.export
        var reply = HermesHostFixture.Reply.json(413, .object(["detail": .string("Session import payload is too large")]))
        let list = await openList { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions/tip/export"): return .json(200, export)
            case ("POST", "/api/sessions/import"): return reply
            default: return nil
            }
        }
        let row = try XCTUnwrap(list.sessions.first)
        let tooMany = BotJSON.array(Array(repeating: .object(["role": .string("user"), "content": .string("Hi")]), count: 10_001))
        export = .object((Self.export.fields ?? [:]).merging(["messages": tooMany]) { $1 })

        let refused = await list.duplicate(row)
        XCTAssertNil(refused)
        XCTAssertEqual(list.actionErrorMessage, "This session is too large to duplicate.")
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/import"), 0)

        export = Self.export
        let rejected = await list.duplicate(row)
        XCTAssertNil(rejected)
        XCTAssertEqual(list.actionErrorMessage, "This session is too large to duplicate.")

        reply = .json(200, .object(["ok": .bool(true), "imported": .number(0), "skipped": .number(1),
                                    "imported_ids": .array([]), "skipped_ids": .array([.string("taken")])]))
        let skipped = await list.duplicate(row)
        XCTAssertNil(skipped)
        XCTAssertEqual(list.actionErrorMessage, "The server did not return the duplicated session.")
        XCTAssertEqual(HermesHostFixture.requests.filter { $0.httpMethod == "PATCH" }.count, 0)
    }

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let connection: HermesConnection
        let pages: Pages

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private func openChat(pages: [Int: [BotJSON]], refusedFirst: Bool = false,
                          // test-wait: a factory default; a reconnect waits 1 s or more, so a test that reaches one passes its own delay.
                          reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                          _ answer: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) async -> Chat {
        let host = BotSocketHost()
        if refusedFirst { host.next("session.resume", .init(error: 4007)) }
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let connection = host.connection(record)
        let script = Pages(pages)
        _ = HermesHostFixture.configuration { request in
            script.answer(request) ?? answer(request) ?? (request.url?.path == "/api/sessions/tip"
                ? .json(200, .object(["id": .string("tip"), "parent_session_id": .null, "model_config": .null])) : nil)
        }
        let engine = HermesConversation(server: server, connection: record, target: .session(profile: "default", key: "tip"),
                                        wire: BotClient(http: connection), reconnectDelay: reconnectDelay)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: server, streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)), backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState == .connected, !refusedFirst)
        return Chat(model: model, turn: turn, host: host, connection: connection, pages: script)
    }

    private func openList(_ answer: @escaping (URLRequest) -> HermesHostFixture.Reply?) async -> SessionListViewModel {
        let connection = BotSocketHost().connection(record)
        let page = BotJSON.object(["sessions": .array([.object(["id": .string("tip"), "title": .string("Plan"),
                                                                "profile": .string("research")])])])
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            return request.httpMethod == "GET" && request.url?.path == "/api/sessions" ? .json(200, page) : answer(request)
        }
        let list = SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: record, profile: "research", makeWire: { _ in BotClient(http: connection) }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
        await list.openHermes()
        return list
    }

    private final class Pages: @unchecked Sendable {
        private let lock = NSLock()
        private let pages: [Int: [BotJSON]]
        private var asked: [Int] = []

        init(_ pages: [Int: [BotJSON]]) { self.pages = pages }

        var offsets: [Int] { lock.withLock { asked } }

        func answer(_ request: URLRequest) -> HermesHostFixture.Reply? {
            guard request.url?.path == "/api/sessions/tip/messages",
                  let query = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems,
                  let offset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) else { return nil }
            return lock.withLock {
                asked.append(offset)
                return .json(200, .object(["session_id": .string("tip"), "profile": .string("default"),
                                           "messages": .array(pages[offset] ?? [])]))
            }
        }
    }

    private var twoToolTurns: [BotJSON] {
        [row(1, "user", "Question 1"), row(2, "assistant", "Let me run a quick check.", calls: true),
         row(3, "tool", "{\"output\": \"1\", \"exit_code\": 0, \"error\": null}"), row(4, "assistant", "The command returned: 1."),
         row(5, "user", "Question 2"), row(6, "assistant", "Let me run a quick check.", calls: true),
         row(7, "tool", "{\"output\": \"1\", \"exit_code\": 0, \"error\": null}"), row(8, "assistant", "The command returned: 1.")]
    }

    private static let export = BotJSON.object([
        "id": .string("tip"), "title": .string("Plan"), "parent_session_id": .null, "archived": .number(0),
        "pinned": .number(0), "source": .string("tui"), "model_config": .null, "message_count": .number(4),
        "messages": .array([
            .object(["id": .number(1), "session_id": .string("tip"), "role": .string("user"), "content": .string("Question 1")]),
            .object(["id": .number(2), "session_id": .string("tip"), "role": .string("assistant"),
                     "content": .string("Let me run a quick check."), "tool_calls": .string("[{\"id\": \"call_2\"}]")]),
            .object(["id": .number(3), "session_id": .string("tip"), "role": .string("tool"),
                     "content": .string("{\"output\": \"1\"}"), "tool_call_id": .string("call_2")]),
            .object(["id": .number(4), "session_id": .string("tip"), "role": .string("assistant"),
                     "content": .string("The command returned: 1.")])
        ])
    ])

    private func row(_ id: Int, _ role: String, _ content: String, calls: Bool = false, active: Bool = true,
                     _ extra: [String: BotJSON] = [:]) -> BotJSON {
        row(id, role, .string(content), calls: calls, active: active, extra)
    }

    private func row(_ id: Int, _ role: String, _ content: BotJSON, calls: Bool = false, active: Bool = true,
                     _ extra: [String: BotJSON] = [:]) -> BotJSON {
        var fields: [String: BotJSON] = [
            "id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role), "content": content,
            "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(active ? 1 : 0),
            "compacted": .number(active ? 0 : 1)
        ]
        if calls {
            fields["tool_calls"] = .array([.object(["id": .string("call_\(id)"), "type": .string("function"),
                                                    "function": .object(["name": .string("terminal"),
                                                                         "arguments": .string("{}")])])])
        }
        fields.merge(extra) { $1 }
        return .object(fields)
    }

    private func alternating(_ id: Int) -> BotJSON {
        id.isMultiple(of: 2) ? row(id, "assistant", "Answer \(id)") : row(id, "user", "Question \(id)")
    }

    private func branched(_ key: String, runtime: String = "branch-runtime") -> BotJSON {
        .object(["session_id": .string(runtime), "stored_session_id": .string(key), "title": .string("branch"),
                 "parent": .string("tip"), "message_count": .number(6), "messages": .array([]), "info": .object([:])])
    }

    private static func branchRows(_ request: URLRequest, config: String) -> HermesHostFixture.Reply? {
        switch request.url?.path {
        case "/api/sessions/tip":
            return .json(200, .object(["id": .string("tip"), "parent_session_id": .string("parent"),
                                       "model_config": .string(config), "archived": .number(0)]))
        case "/api/sessions/parent":
            return .json(200, .object(["id": .string("parent"), "title": .string("Plan the launch"),
                                       "parent_session_id": .null, "model_config": .null, "pinned": .number(0)]))
        default: return nil
        }
    }

    private static func body(_ request: URLRequest) -> BotJSON {
        apiTestBodyData(from: request).flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) } ?? .null
    }
}
