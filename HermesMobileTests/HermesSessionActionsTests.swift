import XCTest
import Observation
import SwiftData
@testable import HermesMobile

@MainActor final class HermesSessionActionsTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let record = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesSessionActionsTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { HermesHostFixture.reset() }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDeleteClosesThisPhonesIdleRuntimeThenDeletesTheSession() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serveList([HermesSessionRow(id: "tip", title: "Plan", profile: "default")], until: "session.delete", on: host)
        host.always("session.active_list", .init(result: .object(["sessions": .array([live("runtime", "tip", "idle")])])))
        host.always("session.close", .init(result: .object(["closed": .bool(true)])))
        host.always("session.delete", .init(result: .object(["deleted": .string("tip")])))
        try await attachChat(on: connection)
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        let deleted = await list.delete(row)

        XCTAssertTrue(deleted)
        XCTAssertEqual(writes(host, ["session.close", "session.delete"]), [
            ["session_id": .string("runtime")],
            ["session_id": .string("tip"), "profile": .string("default")]
        ])
        XCTAssertFalse(list.sessions.contains { $0.sessionId == "tip" })
        XCTAssertNil(list.actionErrorMessage)
        XCTAssertFalse(connection.attachedRuntimes.contains("runtime"), "a closed runtime is no longer this phone's")
    }

    func testACanonicalDeleteIsOneFencedEditAndClosesNoRuntime() async throws {
        let recorded = try canonicalMutations()
        let host = BotSocketHost()
        let connection = host.connection(record, canonical: true)
        serveList([HermesSessionRow(id: "tip", title: "Plan", profile: "default")], until: "session.mutate", on: host)
        host.always("session.resume", .init(result: .object([
            "session_id": .string("tip"), "stored_session_id": .string("tip"), "replay_epoch": .string("epoch"),
            "subscription_id": .string("sub-1"), "revision": .number(6), "execution_generation": .number(4), "running": .bool(false)
        ])))
        let busy = recorded["busy_delete"]["error"]
        host.next("session.mutate", .init(error: busy["code"].integer, message: busy["message"].text ?? "", data: busy["data"]))
        host.next("session.mutate", .init(result: recorded["delete"]["result"]))
        let list = makeList(connection)
        await list.openHermes()

        let refused = await list.delete(try XCTUnwrap(list.sessions.first))
        XCTAssertFalse(refused)
        XCTAssertEqual(list.actionErrorMessage, "This session is still replying here. Stop the reply first, then delete it.")
        let deleted = await list.delete(try XCTUnwrap(list.sessions.first))
        XCTAssertTrue(deleted)

        let edit = try XCTUnwrap(writes(host, ["session.mutate"]).last)
        XCTAssertEqual(edit["operation"], .string("delete"))
        XCTAssertEqual(edit["session_id"], .string("tip"))
        XCTAssertEqual(edit["expected_revision"], .number(6))
        XCTAssertEqual(edit["expected_generation"], .number(4))
        XCTAssertEqual(writes(host, ["session.close", "session.delete"]), [])
        XCTAssertFalse(list.sessions.contains { $0.sessionId == "tip" })
    }

    func testABusyRuntimeOnThisPhoneRefusesTheDelete() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serveList([HermesSessionRow(id: "tip", profile: "default")], on: host)
        host.always("session.active_list", .init(result: .object(["sessions": .array([live("runtime", "tip", "streaming")])])))
        try await attachChat(on: connection)
        let list = makeList(connection)
        await list.openHermes()

        let deleted = await list.delete(try XCTUnwrap(list.sessions.first))

        XCTAssertFalse(deleted)
        XCTAssertEqual(list.actionErrorMessage, "This session is still replying here. Stop the reply first, then delete it.")
        XCTAssertEqual(writes(host, ["session.close", "session.delete"]), [])
        XCTAssertEqual(list.sessions.map(\.sessionId), ["tip"])
    }

    func testASessionOpenInAnotherAppIsRefusedWithNothingChanged() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        serveList([HermesSessionRow(id: "tip", profile: "default")], on: host)
        host.always("session.active_list", .init(result: .object(["sessions": .array([live("dashboard", "tip", "idle")])])))
        host.always("session.delete", .init(error: 4023, message: "cannot delete an active session"))
        let list = makeList(connection)
        await list.openHermes()

        let deleted = await list.delete(try XCTUnwrap(list.sessions.first))

        XCTAssertFalse(deleted)
        XCTAssertEqual(list.actionErrorMessage,
                       "This session is open in another app, so nothing was deleted. Close it there, then try again.")
        XCTAssertEqual(writes(host, ["session.close", "session.delete"]), [
            ["session_id": .string("tip"), "profile": .string("default")]
        ])
        XCTAssertEqual(list.sessions.map(\.sessionId), ["tip"])
    }

    func testARefusedRenameStaysInTheSheetAndATakenOneShowsTheHostsTitle() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let detail = "Title 'Plan' is already in use by session 20261007_003046_925526"
        var refuses = true
        serveList([HermesSessionRow(id: "tip", title: "Draft", profile: "default")], on: host) { request in
            guard request.httpMethod == "PATCH" else { return nil }
            return refuses ? .json(400, .object(["detail": .string(detail)]))
                : .json(200, .object(["ok": .bool(true), "title": .string("Probe B two")]))
        }
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        let refused = await list.rename(row, to: "Plan")
        XCTAssertFalse(refused)
        XCTAssertEqual(list.renameErrorMessage, detail)
        XCTAssertNil(list.actionErrorMessage, "no alert behind the sheet")
        XCTAssertEqual(list.sessions.first?.title, "Draft")

        refuses = false
        let renamed = await list.rename(row, to: "Probe \u{202E}B\n two")
        XCTAssertTrue(renamed)
        XCTAssertNil(list.renameErrorMessage)
        XCTAssertEqual(list.sessions.first?.title, "Probe B two")
    }

    func testARefusedArchivePutsTheRowBackInPlace() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let rows = [HermesSessionRow(id: "a", lastActive: 3, profile: "default"),
                    HermesSessionRow(id: "b", lastActive: 2, profile: "default"),
                    HermesSessionRow(id: "c", lastActive: 1, profile: "default")]
        serveList(rows, on: host) { $0.httpMethod == "PATCH" ? .park : nil }
        let parked = expectation(description: "archive parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first { $0.sessionId == "b" })

        let archive = Task { await list.archive(row) }
        await fulfillment(of: [parked], timeout: 5)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a", "c"], "the row leaves before the host answers")
        HermesHostFixture.releaseParked(.json(500, .object(["detail": .string("database is locked")])))
        let archived = await archive.value

        XCTAssertFalse(archived)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a", "b", "c"])
        XCTAssertNotNil(list.actionErrorMessage)
    }

    func testAnArchiveAnsweredAfterTheListClosedIsNotRolledBack() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let rows = [HermesSessionRow(id: "a", lastActive: 2, profile: "default"),
                    HermesSessionRow(id: "b", lastActive: 1, profile: "default")]
        serveList(rows, on: host) { $0.httpMethod == "PATCH" ? .park : nil }
        let parked = expectation(description: "archive parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first { $0.sessionId == "a" })

        let archive = Task { await list.archive(row) }
        await fulfillment(of: [parked], timeout: 5)
        list.closeHermes()
        HermesHostFixture.releaseParked(.json(200, .object(["ok": .bool(true), "title": .null, "archived": .bool(true)])))
        let archived = await archive.value

        XCTAssertFalse(archived, "no Undo for an answer the list never read")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["b"])
        XCTAssertNil(list.actionErrorMessage)
    }

    func testARefusalAfterAProfileSwitchLeavesTheNewProfilesRows() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            switch request.httpMethod {
            case "PATCH": return .park
            case "GET" where request.url?.path == "/api/sessions":
                let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
                let ids = query.contains { $0.name == "profile" && $0.value == "research" } ? ["r"] : ["a", "b"]
                return .json(200, .object(["sessions": .array(ids.map { .object(["id": .string($0)]) })]))
            default: return nil
            }
        }
        let parked = expectation(description: "pin parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let list = makeList(connection)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first { $0.sessionId == "a" })

        let pin = Task { await list.setPinned(true, for: row) }
        await fulfillment(of: [parked], timeout: 5)
        await list.selectHermesProfile("research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        HermesHostFixture.releaseParked(.json(500, .object(["detail": .string("database is locked")])))
        let pinned = await pin.value

        XCTAssertFalse(pinned)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertNotNil(list.actionErrorMessage)
    }

    func testTheArchivedScreenListsABotChatDropsTheBackFilledPinAndRestores() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        var patches: [BotJSON] = []
        let page = BotJSON.object(["sessions": .array([
            .object(["id": .string("old"), "title": .string("Old plan"), "archived": .bool(true), "hidden": .number(0)]),
            .object(["id": .string("bot"), "title": .string("Bot Chat"), "archived": .bool(true), "hidden": .number(1)]),
            .object(["id": .string("pin"), "title": .string("Pinned"), "pinned": .bool(true), "archived": .bool(false)])
        ])])
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions"): return .json(200, page)
            case ("PATCH", "/api/sessions/bot"?):
                patches.append(Self.body(request))
                return .json(200, .object(["ok": .bool(true), "title": .string("Bot Chat"), "archived": .bool(false)]))
            default: return nil
            }
        }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "research", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))

        await archive.load()

        XCTAssertEqual(archive.sessions.map(\.sessionId), ["old", "bot"])
        XCTAssertEqual(archive.sessions.map(\.title), ["Old plan", "Bot Chat · research"])
        let read = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions" }?.url)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: read, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["archived"], "only")
        XCTAssertEqual(query["profile"], "research")

        let restored = await archive.unarchive(try XCTUnwrap(archive.sessions.last))
        XCTAssertTrue(restored)
        XCTAssertEqual(patches, [.object(["archived": .bool(false), "profile": .string("research")])])
        XCTAssertEqual(archive.sessions.map(\.sessionId), ["old"])
    }

    func testDeletingAnArchivedBotChatClearsItsOwnCachedTranscriptOnly() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let page = BotJSON.object(["sessions": .array([
            .object(["id": .string("bot"), "title": .string("Bot Chat"), "archived": .bool(true), "hidden": .number(1)])
        ])])
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            guard request.httpMethod == "GET", request.url?.path == "/api/sessions" else { return nil }
            return .json(200, page)
        }
        host.always("session.active_list", .init(result: .object(["sessions": .array([])])))
        host.always("session.delete", .init(result: .object(["deleted": .string("bot")])))
        let context = ModelContext(try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let message = ChatMessage(role: "user", content: "Hi", timestamp: 1, messageId: "m", rowID: 1)
        let other = UUID()
        let scopes = [
            ("bot", CacheStore.hermesBotChatScope(connectionID: record.id, profile: "research", root: "bot")),
            ("archive", CacheStore.hermesArchivedBotChatScope(connectionID: record.id, profile: "research", root: "bot")),
            ("root", CacheStore.hermesBotChatScope(connectionID: record.id, profile: "research", root: "kept")),
            ("profile", CacheStore.hermesBotChatScope(connectionID: record.id, profile: "other", root: "bot")),
            ("connection", CacheStore.hermesBotChatScope(connectionID: other, profile: "research", root: "bot"))
        ]
        for (_, scope) in scopes {
            try CacheStore.cacheHermesMessages([message], newestCoverage: .all, serverURL: server, scope: scope, in: context)
        }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "research", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))
        await archive.load()
        let epoch = CacheStore.hermesCacheEpoch(serverURL: server)

        let deleted = await archive.delete(try XCTUnwrap(archive.sessions.first), modelContext: context)

        XCTAssertTrue(deleted)
        let cached = { (scope: String) in try CacheStore.cachedHermesMessages(serverURL: self.server, scope: scope, in: context, limit: 100).count }
        XCTAssertEqual(try scopes.map { try cached($0.1) }, [0, 0, 1, 1, 1])
        XCTAssertEqual(try CacheStore.cachedHermesBotChatRoot(serverURL: server, connectionID: record.id, profile: "research", in: context),
                       "kept")
        XCTAssertNotEqual(CacheStore.hermesCacheEpoch(serverURL: server), epoch)
    }

    func testArchivedRoomSessionsAreLeftOutAndABotChatRowOpensItsBot() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let page = BotJSON.object(["sessions": .array([
            .object(["id": .string("old"), "title": .string("Old plan"), "archived": .bool(true), "hidden": .number(0)]),
            .object(["id": .string("room"), "title": .string("Group: room-1"), "archived": .bool(true), "hidden": .number(1)]),
            .object(["id": .string("desktop-room"), "title": .string("Group: Launch · Ops"), "archived": .bool(true),
                     "hidden": .number(1)]),
            .object(["id": .string("bot"), "title": .string("Bot Chat"), "archived": .bool(true), "hidden": .number(1)])
        ])])
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions"): return .json(200, page)
            default: return nil
            }
        }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "research", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))

        await archive.load()

        XCTAssertEqual(archive.sessions.map(\.sessionId), ["old", "bot"])
        let plain = archive.sessions[0], bot = archive.sessions[1]
        XCTAssertEqual(archive.hermesBot(for: bot), BotDestination(server: server, connectionID: record.id, profile: "research"))
        XCTAssertNil(archive.hermesChat(for: bot))
        XCTAssertNil(archive.hermesBot(for: plain))
        XCTAssertEqual(archive.hermesChat(for: plain)?.target, .session(profile: "research", key: "old"))
    }

    func testArchivedReadsPastAFirstPageOfRoomsAlone() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let rows: [BotJSON] = (0..<HermesREST.sessionPageSize).map {
            .object(["id": .string("room\($0)"), "title": .string("Group: room-\($0)"), "archived": .bool(true), "hidden": .number(1)])
        } + [.object(["id": .string("old"), "title": .string("Old plan"), "archived": .bool(true), "hidden": .number(0)])]
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            guard request.httpMethod == "GET", request.url?.path == "/api/sessions" else { return nil }
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? 0
            return .json(200, .object(["sessions": .array(Array(rows.dropFirst(offset).prefix(HermesREST.sessionPageSize)))]))
        }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "research", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))

        await archive.load()

        XCTAssertEqual(archive.sessions.map(\.sessionId), ["old"])
        XCTAssertFalse(archive.hasMore)
    }

    func testLoadMoreDuringARestoreSkipsNoRow() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        var archived = (0...200).map { "s\($0)" }
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            switch request.httpMethod {
            case "PATCH": return .park
            case "GET" where request.url?.path == "/api/sessions":
                let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
                let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? 0
                let rows = archived.dropFirst(offset).prefix(HermesREST.sessionPageSize)
                return .json(200, .object(["sessions": .array(rows.map { .object(["id": .string($0), "archived": .bool(true)]) })]))
            default: return nil
            }
        }
        let parked = expectation(description: "restore parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))
        await archive.load()
        let row = try XCTUnwrap(archive.sessions.first { $0.sessionId == "s5" })

        let restore = Task { await archive.unarchive(row) }
        await fulfillment(of: [parked], timeout: 5)
        await archive.loadMore()
        HermesHostFixture.script { archived.removeAll { $0 == "s5" } }
        HermesHostFixture.releaseParked(.json(200, .object(["ok": .bool(true), "title": .null, "archived": .bool(false)])))
        let restored = await restore.value
        for _ in 0..<5 where archive.hasMore { await archive.loadMore() }

        XCTAssertTrue(restored)
        XCTAssertEqual(Set(archive.sessions.compactMap(\.sessionId)), Set(archived))
        XCTAssertEqual(archive.sessions.count, 200)
    }

    func testARefreshDuringARestoreDoesNotBringTheRowBack() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let page = BotJSON.object(["sessions": .array(["a", "b", "c"].map { .object(["id": .string($0), "archived": .bool(true)]) })])
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            switch request.httpMethod {
            case "PATCH": return .park
            case "GET" where request.url?.path == "/api/sessions": return .json(200, page)
            default: return nil
            }
        }
        let parked = expectation(description: "restore parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))
        await archive.load()
        let row = try XCTUnwrap(archive.sessions.first { $0.sessionId == "b" })

        let restore = Task { await archive.unarchive(row) }
        await fulfillment(of: [parked], timeout: 5)
        await archive.load()
        XCTAssertEqual(archive.sessions.map(\.sessionId), ["a", "c"])
        HermesHostFixture.releaseParked(.json(200, .object(["ok": .bool(true), "title": .null, "archived": .bool(false)])))
        let restored = await restore.value

        XCTAssertTrue(restored)
        XCTAssertEqual(archive.sessions.map(\.sessionId), ["a", "c"])
    }

    func testARestoreRefusedAfterARefreshSkipsNoRow() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let archived = (0...250).map { "s\($0)" }
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            switch request.httpMethod {
            case "PATCH": return .park
            case "GET" where request.url?.path == "/api/sessions":
                let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
                let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? 0
                let rows = archived.dropFirst(offset).prefix(HermesREST.sessionPageSize)
                return .json(200, .object(["sessions": .array(rows.map { .object(["id": .string($0), "archived": .bool(true)]) })]))
            default: return nil
            }
        }
        let parked = expectation(description: "restore parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))
        await archive.load()
        await archive.loadMore()
        let row = try XCTUnwrap(archive.sessions.first { $0.sessionId == "s150" })

        let restore = Task { await archive.unarchive(row) }
        await fulfillment(of: [parked], timeout: 5)
        await archive.load()
        HermesHostFixture.releaseParked(.json(500, .object(["detail": .string("database is locked")])))
        let restored = await restore.value
        for _ in 0..<5 where archive.hasMore { await archive.loadMore() }

        XCTAssertFalse(restored)
        XCTAssertNotNil(archive.actionErrorMessage)
        XCTAssertEqual(archive.sessions.compactMap(\.sessionId), archived)
    }

    func testAConnectTheScreenClosedDuringLeavesNoClient() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        _ = HermesHostFixture.configuration { $0.url?.path == "/api/auth/ws-ticket" ? .park : nil }
        let parked = expectation(description: "connect parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let archive = ArchivedSessionsViewModel(server: server, hermes: HermesArchiveSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults
        ))

        let load = Task { await archive.load() }
        await fulfillment(of: [parked], timeout: 5)
        archive.close()
        HermesHostFixture.releaseParked()
        await load.value

        XCTAssertFalse(archive.isConnected)
    }

    func testExportWritesTheHostsJSONNamedAfterTheTitle() async throws {
        let host = BotSocketHost()
        let connection = host.connection(record)
        let export = BotJSON.object(["id": .string("tip"), "messages": .array([.object(["role": .string("user")])])])
        serveList([HermesSessionRow(id: "tip", title: "Plan the launch", profile: "default")], on: host) { request in
            request.url?.path == "/api/sessions/tip/export" ? .json(200, export) : nil
        }
        let list = makeList(connection)
        await list.openHermes()

        let exported = await list.export(try XCTUnwrap(list.sessions.first), format: .json)
        let file = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        XCTAssertEqual(file.lastPathComponent, "Plan the launch.json")
        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: Data(contentsOf: file)), export)
        let request = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions/tip/export" })
        XCTAssertEqual(request.url?.query, "profile=default")
    }

    private func canonicalMutations() throws -> BotJSON {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/HermesAgent/canonical-mutations.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("The source tree is not present (physical device or remote runner).") }
        return try JSONDecoder().decode(BotJSON.self, from: data)["reply"]
    }

    private func makeList(_ connection: HermesConnection) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: record, profile: "default", makeWire: { _ in BotClient(http: connection) }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }

    private func serveList(_ rows: [HermesSessionRow], until method: String? = nil, on host: BotSocketHost,
                           _ answer: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) {
        let page = BotJSON.object(["sessions": .array(rows.map(Self.json))])
        _ = HermesHostFixture.configuration { request in
            if let empty = HermesHostFixture.emptyScheduledPage(request) { return empty }
            guard request.httpMethod == "GET", request.url?.path == "/api/sessions" else { return answer(request) }
            let gone = method.map { method in host.requests.contains { $0["method"].text == method } } ?? false
            return .json(200, gone ? .object(["sessions": .array([])]) : page)
        }
    }

    private func attachChat(on connection: HermesConnection) async throws {
        let chat = BotClient(http: connection)
        try await chat.connect()
        _ = try await chat.call(.sessionResume(profile: "default", sessionID: "tip", omitMessages: true))
        chat.close()
    }

    private func writes(_ host: BotSocketHost, _ methods: Set<String>) -> [[String: BotJSON]] {
        host.requests.filter { methods.contains($0["method"].text ?? "") }.compactMap { $0["params"].fields }
    }

    private func live(_ runtime: String, _ key: String, _ status: String) -> BotJSON {
        .object(["id": .string(runtime), "session_key": .string(key), "status": .string(status), "current": .bool(false),
                 "last_active": .number(100), "started_at": .number(90), "message_count": .number(2),
                 "model": .string("m"), "preview": .string(""), "title": .string("")])
    }

    private static func json(_ row: HermesSessionRow) -> BotJSON {
        var fields: [String: BotJSON] = ["id": .string(row.id)]
        if let title = row.title { fields["title"] = .string(title) }
        if let lastActive = row.lastActive { fields["last_active"] = .number(lastActive) }
        if let profile = row.profile { fields["profile"] = .string(profile) }
        return .object(fields)
    }

    private static func body(_ request: URLRequest) -> BotJSON {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}
