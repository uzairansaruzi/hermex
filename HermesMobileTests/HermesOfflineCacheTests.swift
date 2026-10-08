import Observation
import SwiftData
import XCTest
@testable import HermesMobile

/// A Hermes server's offline cache (#1054) from its screens: the Sessions list and a session's
/// chat write what they read, and show it, read-only, while the host can't be reached, until a
/// read succeeds. The list runs on `HermesSessionListWire`, the chat on the scripted host below.
@MainActor final class HermesOfflineCacheTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesOfflineCacheTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: Sessions list

    /// With the host unreachable, the list shows the Profile's cached rows, pinned first and with
    /// their read marks, under the cached-data state, and refuses changes. A legacy chain keeps
    /// its identity and opens by its tip. Reconnecting shows the host's rows in their place.
    func testAnUnreachableHostShowsTheCachedListUntilAReadSucceeds() async throws {
        let context = try makeContext()
        let rows = [
            HermesSessionRow(id: "new", title: "Newest", lastActive: 30, unread: true),
            HermesSessionRow(id: "tip", title: "Chain", lastActive: 20, lineageRootID: "root"),
            HermesSessionRow(id: "pin", title: "Pinned", lastActive: 10, pinned: true)
        ]
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        let list = makeList(wire)
        await list.openHermes(modelContext: context)

        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertNil(list.errorMessage)
        let shown = list.visibleSessions(searchText: "", selectedProjectID: nil)
        XCTAssertEqual(shown.map(\.title), ["Pinned", "Newest", "Chain"])
        XCTAssertTrue(list.isUnread(shown[1]))
        XCTAssertEqual(shown[2].id, "root")
        XCTAssertEqual(shown[2].hermesTarget(listedIn: "default"), .session(profile: "default", key: "tip"))
        let renamed = await list.rename(shown[1], to: "Offline title")
        XCTAssertFalse(renamed)
        XCTAssertEqual(wire.changes, [])

        wire.connectFailure = nil
        wire.pages["default"] = [0: HermesSessionPage(rows: rows + [HermesSessionRow(id: "later", title: "Later", lastActive: 40)])]
        await list.openHermes()

        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).map(\.title),
                       ["Pinned", "Later", "Newest", "Chain"])
    }

    /// A search typed while the list shows cached rows filters them at once, and asks the host
    /// once a read replaces them, so a match the cache lacks shows too.
    func testASearchWhileCachedReachesTheHostOnceItAnswers() async throws {
        let context = try makeContext()
        let rows = [HermesSessionRow(id: "plan", title: "Nimbus plan", lastActive: 20)]
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old chat", profile: "default"),
                                                        snippet: "the >>>nimbus<<< cluster")]
        let list = makeList(wire)
        await list.openHermes(modelContext: context)
        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)
        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan"])

        wire.connectFailure = nil
        wire.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan", "old"])
        XCTAssertEqual(wire.searches.map(\.query), ["nimbus"])
    }

    /// A refresh that falls back to cached rows while a search is active drops the host's
    /// matches, since search reads only cached rows then, and searches the host again once a read
    /// succeeds.
    func testARefreshThatFallsBackToTheCacheDropsTheHostsMatchesUntilItSearchesAgain() async throws {
        let context = try makeContext()
        let rows = [HermesSessionRow(id: "plan", title: "Nimbus plan", lastActive: 20)]
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: rows)]
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old chat", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes(modelContext: context)
        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan", "old"])

        wire.pageFailure = .rejected(502)
        await list.refreshHermes()
        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan"])

        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "newer", title: "Newer chat", profile: "default"))]
        await list.refreshHermes()

        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan", "newer"])
    }

    /// With nothing cached, a list whose proxy answers for a host that isn't there says so in the
    /// connection's own words, not a webui server's unreachable copy.
    func testAnUnreachableHostWithNothingCachedKeepsItsAdvice() async throws {
        let context = try makeContext()
        let wire = HermesSessionListWire()
        wire.connectFailure = BotFailure.rejected(502)
        let list = makeList(wire)
        await list.openHermes(modelContext: context)

        XCTAssertFalse(list.isViewingCachedData)
        let content = SessionListRowsSection.errorContent(for: list.sessionLoadError, fallbackMessage: list.errorMessage ?? "")
        XCTAssertEqual(content.title, "Could not load sessions")
        XCTAssertEqual(content.description, "Your proxy answered, but Hermes didn't. Check that the dashboard is running on the host.")
    }

    /// A row archived or deleted on the phone leaves the cache once the host confirms, though
    /// the list's later reads, a full page that doesn't reach its end, never sweep.
    func testArchivingOrDeletingARowDropsItsCachedCopy() async throws {
        let context = try makeContext()
        let others = (0..<100).map { HermesSessionRow(id: "s\($0)", title: "S\($0)", lastActive: Double(1_000 - $0)) }
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "a", title: "A", lastActive: 2_000),
                                                             HermesSessionRow(id: "b", title: "B", lastActive: 1_999)]
                                                       + others.prefix(98))]
        let list = makeList(wire)
        await list.openHermes(modelContext: context)
        let a = try XCTUnwrap(list.sessions.first { $0.sessionId == "a" })
        let b = try XCTUnwrap(list.sessions.first { $0.sessionId == "b" })

        wire.pages["default"] = [0: HermesSessionPage(rows: others)]
        let archived = await list.archive(a)
        let deleted = await list.delete(b)
        XCTAssertTrue(archived)
        XCTAssertTrue(deleted)
        await waitUntil("the list read again") { list.sessions.count == 100 && list.sessions.first?.sessionId == "s0" }

        let cached = try CacheStore.cachedHermesSessions(serverURL: server, profile: "default", in: context)
        XCTAssertEqual(cached.compactMap(\.sessionId), others.map(\.id))
    }

    // MARK: A session's chat

    /// A session opened while its host can't be reached shows the transcript a visit cached,
    /// read-only: nothing is sent. The engine's reconnect puts the host's rows in its place,
    /// none of them twice.
    func testAnUnreachableSessionShowsItsCachedTranscriptUntilItReconnects() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)
        XCTAssertEqual(visit.model.messages.map(\.content), ["Hi", "Hello."])

        let wire = HermesOfflineWire(rows: [])
        wire.connectFailure = URLError(.cannotConnectToHost)
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
        XCTAssertEqual(chat.model.messages.map(\.rowID), [1, 2])
        let sent = await chat.model.sendMessage("Still there?")
        XCTAssertFalse(sent)
        XCTAssertEqual(chat.model.sendErrorMessage, "Reconnect to the server to send a message.")

        wire.connectFailure = nil
        wire.rows = [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")]
        chat.reconnect.open()
        await waitUntil("reattached") { !chat.model.isViewingCachedData }

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
        XCTAssertFalse(wire.methods.contains("prompt.submit"))
    }

    /// An attach that fails after the host named the session's runtime, here as its replay is
    /// read, shows the cached transcript. The next attach, on the same runtime, still reads the
    /// host's rows in its place.
    func testAnAttachThatFailsMidwayStillReadsTheHostsRowsOnReconnect() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        wire.replayFailure = BotFailure.transport
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)
        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])

        wire.replayFailure = nil
        chat.reconnect.open()
        await waitUntil("reattached") { !chat.model.isViewingCachedData }

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
    }

    /// A reattach whose history read fails keeps the cached transcript, read-only, and says why;
    /// the chat's retry puts the host's rows in its place.
    func testAFailedHistoryReadKeepsTheCachedTranscriptUntilARetry() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        wire.connectFailure = URLError(.cannotConnectToHost)
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)
        XCTAssertTrue(chat.model.isViewingCachedData)

        wire.connectFailure = nil
        wire.messagesFailure = BotFailure.rejected(502)
        chat.reconnect.open()
        await waitUntil("reattached") { chat.model.errorMessage != nil }

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])

        wire.messagesFailure = nil
        await chat.model.loadMessages(modelContext: context)

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
    }

    /// An attach that succeeds but whose first history read the host can't serve (a tunnel's
    /// 502) shows the cached transcript, read-only, as a failed attach does; the chat's retry
    /// puts the host's rows in its place.
    func testAFirstHistoryReadThatFailsShowsTheCachedTranscript() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        wire.messagesFailure = BotFailure.rejected(502)
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])

        wire.messagesFailure = nil
        await chat.model.loadMessages(modelContext: context)

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
    }

    /// The exchange an undo removed, here on another client, leaves the cached transcript at the
    /// next visit's newest read, though that read's row ids all sit below it.
    func testAVisitAfterAnUndoDropsTheUndoneRows() async throws {
        let context = try makeContext()
        let rows = [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Undo me"), row(4, "assistant", "Undone.")]
        let visit = makeChat(HermesOfflineWire(rows: rows))
        await visit.model.loadMessages(modelContext: context)
        let afterUndo = makeChat(HermesOfflineWire(rows: Array(rows.prefix(2))))
        await afterUndo.model.loadMessages(modelContext: context)

        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 10).map(\.content), ["Hi", "Hello."])
    }

    /// A host that answered and refused leaves the cache alone: the chat says why instead.
    func testARefusalShowsNoCachedTranscript() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [])
        wire.connectFailure = BotFailure.rejected(401)
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages, [])
        XCTAssertEqual(chat.model.errorMessage, "Hermes didn't accept the username or password.")
    }

    /// A legacy compression chain's transcript is cached under the lineage root its list row
    /// names, though the chat opens by the tip.
    func testAChainsTranscriptIsCachedUnderItsLineageRoot() async throws {
        let context = try makeContext()
        try CacheStore.cacheHermesSessions([HermesSessionRow(id: "tip", lineageRootID: "root").summary(in: "default")],
                                           profile: "default", reachedEnd: true, serverURL: server, in: context)
        let chat = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]))
        await chat.model.loadMessages(modelContext: context)

        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "root",
                                                           in: context, limit: 10).map(\.content), ["Hi"])
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 10), [])
    }

    /// All Profiles (#709) caches each Profile's rows under its own Profile and, with the host
    /// unreachable, shows every Profile's.
    func testAllProfilesShowsEveryProfilesCachedRowsOffline() async throws {
        let context = try makeContext()
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let online = HermesSessionListWire()
        online.pages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "d", lastActive: 1)])],
                        "research": [0: HermesSessionPage(rows: [HermesSessionRow(id: "r", lastActive: 2)])]]
        await makeList(online).openHermes(modelContext: context)
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: server, profile: "research", in: context).map(\.sessionId), ["r"])

        // The home's list starts without a Profile, which only the host settles.
        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        let list = makeList(wire, profile: nil)
        await list.openHermes(modelContext: context)

        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).map { "\($0.sessionId!)@\($0.profile!)" },
                       ["r@research", "d@default"])
    }

    /// The home's list, opened offline without a Profile, shows the server's pick's cached rows.
    func testAListWithoutAProfileShowsThePicksCachedRowsOffline() async throws {
        let context = try makeContext()
        let online = HermesSessionListWire()
        online.pages = ["research": [0: HermesSessionPage(rows: [HermesSessionRow(id: "r", lastActive: 2)])]]
        await makeList(online, profile: "research").openHermes(modelContext: context)
        HermesProfilePreference.save("research", for: server, in: defaults)

        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        let list = makeList(wire, profile: nil)
        await list.openHermes(modelContext: context)

        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertEqual(list.hermesProfile, "research", "its rows open, and New Session starts, in the pick")
    }

    // MARK: Fixture

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func makeList(_ wire: HermesSessionListWire, profile: String? = "default") -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: connection, profile: profile, makeWire: { _ in wire }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }

    private struct Chat {
        let model: ChatViewModel
        /// Holds the engine's reconnect until opened.
        let reconnect: Gate
    }

    /// A chat on session `tip` in `default`, over `wire`.
    private func makeChat(_ wire: HermesOfflineWire) -> Chat {
        let gate = Gate()
        let engine = HermesConversation(server: server, connection: connection, target: .session(profile: "default", key: "tip"),
                                        wire: wire, reconnectDelay: { _ in await gate.wait() })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: server, streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true }))
        )
        return Chat(model: model, reconnect: gate)
    }

    /// One display row as `GET /api/sessions/{id}/messages` returns it.
    private func row(_ id: Int, _ role: String, _ content: String) -> BotJSON {
        .object(["id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role), "content": .string(content),
                 "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(1), "compacted": .number(0),
                 "tool_call_id": .null, "tool_calls": .null, "display_kind": .null, "display_metadata": .null])
    }

    /// Waits on observation, never a clock, and fails once nothing it reads changes for 5 s.
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

/// Holds a wait until `open()`, then lets every wait through.
@MainActor private final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// A Hermes host for one idle session, `tip` in `default`: its attach calls and its newest
/// transcript page. `connectFailure` stands for a host it can't reach, or one that refuses;
/// `replayFailure` for a socket lost once the host named the runtime, `messagesFailure` for a
/// transcript read that fails.
@MainActor private final class HermesOfflineWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var connectFailure: Error?
    var replayFailure: Error?
    var messagesFailure: Error?
    var rows: [BotJSON]
    private(set) var methods: [String] = []

    init(rows: [BotJSON]) { self.rows = rows }

    func connect() async throws {
        if let connectFailure { throw connectFailure }
    }

    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        methods.append(call.method)
        switch call.method {
        case "session.resume":
            return .object(["session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
                            "messages": .array([]), "info": .object(["profile_name": .string("default")])])
        case "session.events.since":
            if let replayFailure { throw replayFailure }
            return BotFixtureWire.replay(latest: 0)
        default: throw BotFailure.unsupported
        }
    }

    func sessionMessages(_ key: String, profile: String, offset: Int?) async throws -> [BotJSON]? {
        if let messagesFailure { throw messagesFailure }
        return offset == 0 ? rows : []
    }
}
