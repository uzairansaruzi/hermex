import XCTest
import Observation
@testable import HermesMobile

/// A Hermes server's Sessions list (#1046): `SessionListViewModel` with a Hermes backend on a
/// scripted wire whose pages, read marks and live states are the shapes the 0.21.5 pin answers.
@MainActor final class HermesSessionListTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesSessionListTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: Paging

    func testPagesLoadInTurnAndAShortPageEndsTheList() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(rows(0..<100)), 100: page(rows(100..<130))]
        let list = makeList(wire)

        await list.openHermes()
        XCTAssertTrue(list.hasMoreSessions)
        await list.loadMoreHermesSessions()
        await list.loadMoreHermesSessions()

        XCTAssertEqual(wire.pageReads.map(\.offset), [0, 100])
        XCTAssertEqual(list.sessions.count, 130)
        XCTAssertFalse(list.hasMoreSessions)
    }

    /// Every page repeats the pinned rows it missed, archived ones included: each shows once,
    /// pinned first, and an archived one never.
    func testPinnedBackFillShowsOnceAndArchivedPinnedRowsNever() async {
        let wire = HermesSessionListWire()
        let pinned = HermesSessionRow(id: "pinned", lastActive: 1, pinned: true)
        let archived = HermesSessionRow(id: "archived", lastActive: 2, pinned: true, archived: true)
        wire.pages["default"] = [0: page(rows(0..<100) + [pinned, archived]),
                                 100: page([pinned, archived] + rows(100..<110))]
        let list = makeList(wire)

        await list.openHermes()
        await list.loadMoreHermesSessions()

        let shown = list.visibleSessions(searchText: "", selectedProjectID: nil).compactMap(\.sessionId)
        XCTAssertEqual(shown.count, 111)
        XCTAssertEqual(shown.first, "pinned")
        XCTAssertEqual(shown.filter { $0 == "pinned" }.count, 1)
        XCTAssertFalse(shown.contains("archived"))
    }

    /// A list read that begins while "Load more" waits replaces it and reads that page itself,
    /// so the list still pages past 100 rows and "Load more" never stays disabled.
    func testAListReadDuringLoadMoreReadsThatPageItself() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(rows(0..<100)), 100: page(rows(100..<130))]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        let more = Task { await list.loadMoreHermesSessions() }
        await waitUntil("next page parked") { wire.pageReads.count == 2 }
        wire.emit("sessions.changed")
        await waitUntil("list read parked") { wire.pageReads.count == 3 }
        XCTAssertTrue(list.isLoadingMoreSessions, "the next page is still on its way")
        wire.holdsPages = false
        wire.release()
        await more.value
        await waitUntil("both pages applied") { !list.isLoadingMoreSessions }

        XCTAssertEqual(wire.pageReads.map(\.offset), [0, 100, 0, 100])
        XCTAssertEqual(list.sessions.count, 130)
        XCTAssertFalse(list.hasMoreSessions)
    }

    // MARK: Rows

    /// The attachment-title rule (#1046 comment of 2026-10-05): a title or `preview` drops the
    /// reference lines a Hermex send appends, whole or cut off by the host, and falls back to
    /// the first attachment's name, or to nothing.
    func testTitlesAndPreviewsDropAttachmentReferences() {
        let image = "[The user attached an image: dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"
        let examine = "[Examine it with the vision_analyze tool using image_url: /h/.hermes/images/dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"
        let rows: [(text: String, shown: String?)] = [
            (image + "\n" + examine, "IMG_2041.jpg"),
            (image + " " + examine, "IMG_2041.jpg"),
            ("[The user attached an image: dashboard_20261005_120000_0123a...", nil),
            ("[The user attached an image…", nil),
            ("What breed is this?\n\n" + image + "\n" + examine, "What breed is this?"),
            ("What breed is this?  [The user attached an image: dashboard_202...", "What breed is this?"),
            ("@file:`/Users/someone/.hermes/attachments/1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed-report.pdf`", "report.pdf"),
            ("Summarize report.pdf @file:`/Users/someone/.hermes/attach...", "Summarize report.pdf"),
            ("Plan the launch for the new pricing page and draft the e...", "Plan the launch for the new pricing page and draft the e..."),
            ("Email bob@example.com about [the plan]", "Email bob@example.com about [the plan]")
        ]
        for row in rows {
            XCTAssertEqual(MessageAttachment.hermesTitle(row.text), row.shown, row.text)
        }

        let untitled = HermesSessionRow(id: "a", preview: "What breed is this?  [The user attached an image: dashb...")
        XCTAssertEqual(SessionRowView.displayTitle(for: untitled.summary(in: "default")), "What breed is this?")
        let photoOnly = HermesSessionRow(id: "b", title: "[The user attached an image…",
                                         preview: "[The user attached an image: dashboard_20261005_120000_0123a...")
        XCTAssertEqual(SessionRowView.displayTitle(for: photoOnly.summary(in: "default")), "Untitled Session")
    }

    // MARK: Unread

    /// Opening a row clears its dot at once and marks it read on the host, so Desktop agrees.
    /// A write the host refuses shows the host's mark again.
    func testOpeningARowMarksItReadAndARefusedWriteShowsItUnreadAgain() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: true, profile: "default")])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)
        XCTAssertTrue(list.isUnread(row))

        wire.holdsUnread = true
        wire.unreadFails = true
        list.beginViewing(row)
        XCTAssertFalse(list.isUnread(row), "the dot clears before the host answers")
        await waitUntil("write sent") { wire.unreadWrites.count == 1 }
        XCTAssertEqual(wire.unreadWrites.first, .init(key: "a", profile: "default", unread: false))
        wire.release()
        await waitUntil("rolled back") { list.isUnread(row) }
    }

    func testMarkAsUnreadWritesTheHostsMark() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false)])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        list.toggleUnread(row)

        XCTAssertTrue(list.isUnread(row))
        await waitUntil("write sent") { wire.unreadWrites.count == 1 }
        XCTAssertEqual(wire.unreadWrites, [.init(key: "a", profile: "default", unread: true)])
    }

    /// Marking a row unread and opening it at once makes two marks. Sent together they could
    /// land in either order and leave the older one on the host, so the newer waits for the
    /// older to land.
    func testASessionsMarksReachTheHostInTheOrderTheyWereMade() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false)])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        wire.holdsUnread = true
        list.toggleUnread(row)
        await waitUntil("unread mark sent") { wire.unreadWrites.count == 1 }
        list.beginViewing(row)
        // One main-queue turn: a write started alongside the first would be on the wire now.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(wire.unreadWrites.count, 1, "the read mark waits while the unread mark is out")
        XCTAssertFalse(list.isUnread(row), "the newer mark shows at once")

        wire.holdsUnread = false
        wire.release()
        await waitUntil("read mark sent") { wire.unreadWrites.count == 2 }
        XCTAssertEqual(wire.unreadWrites.map(\.unread), [true, false])
        XCTAssertFalse(list.isUnread(row))
    }

    /// The reply you just watched finished after the chat marked the session read, so the
    /// host calls it unread: the first read after returning marks it read again, and only it.
    func testReturningFromAChatMarksItReadAgain() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false), HermesSessionRow(id: "b", unread: true)])]
        let list = makeList(wire)
        await list.openHermes()
        list.beginViewing(try XCTUnwrap(list.sessions.first { $0.sessionId == "a" }))
        list.pauseHermes()
        await waitUntil("open write") { wire.unreadWrites.count == 1 }

        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: true), HermesSessionRow(id: "b", unread: true)])]
        list.noteHermesReturn(from: "a")
        await list.openHermes()
        await waitUntil("marked read again") { wire.unreadWrites.count == 2 }

        XCTAssertEqual(wire.unreadWrites.map(\.key), ["a", "a"])
        XCTAssertEqual(wire.unreadWrites.map(\.unread), [false, false])
        XCTAssertEqual(list.sessions.map { list.isUnread($0) }, [false, true])
    }

    // MARK: Live state

    /// `session.active_list` marks the listed rows by session key; idle and other Profiles'
    /// runtimes mark nothing.
    func testLiveStatesMarkListedRowsBySessionKey() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(["a", "b", "c"].map { HermesSessionRow(id: $0) })]
        wire.active = [live("a", "streaming"), live("b", "waiting"), live("b", "working"), live("c", "idle"),
                       live("elsewhere", "working")]
        let list = makeList(wire)

        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }

        XCTAssertEqual(list.attentionStatesBySessionID, ["a": .working, "b": .input])
    }

    // MARK: Refresh

    /// A burst of `sessions.changed` reads once; events while that read is out ask for one more
    /// after it, and the list ends on the host's latest rows.
    func testSessionsChangedBurstsReadOnceAndQueueOneMore() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "First")])]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        for _ in 0..<3 { wire.emit("sessions.changed") }
        await waitUntil("burst read parked") { wire.pageReads.count == 2 }
        for _ in 0..<3 { wire.emit("sessions.changed") }
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Latest")])]
        wire.holdsPages = false
        wire.release()
        await waitUntil("trailing read applied") { list.sessions.first?.title == "Latest" }

        XCTAssertEqual(wire.pageReads.count, 3, "open, the burst's read and exactly one more")
    }

    /// A read that began before a newer one never replaces the newer one's rows.
    func testOnlyTheNewestReadApplies() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Old")])]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        wire.emit("sessions.changed")
        await waitUntil("stale read parked") { wire.pageReads.count == 2 }
        wire.holdsPages = false
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "New")])]
        await list.openHermes()
        XCTAssertEqual(list.sessions.first?.title, "New")

        wire.release()
        await waitUntil("stale read answered") { wire.answeredPages == 3 }
        XCTAssertEqual(list.sessions.first?.title, "New")
    }

    // MARK: Connection

    /// A lost socket reconnects quietly over the rows. A refusal the user has to act on, such
    /// as a host below the minimum release, stops there and is kept as the list's error.
    func testOnlyALostSocketReconnects() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire, reconnectDelays: [.zero])
        await list.openHermes()

        wire.onDisconnect?(BotFailure.transport)
        await waitUntil("reconnected") { wire.connects == 2 }
        XCTAssertNil(list.sessionLoadError)

        wire.onDisconnect?(BotFailure.outdated("0.20.0"))
        XCTAssertFalse(list.isHermesConnected)
        XCTAssertEqual(list.sessionLoadError as? BotFailure, .outdated("0.20.0"))
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a"], "the rows stay")
    }

    /// A client that left the socket without a word answers every read `.stale`: the next read
    /// reconnects instead of leaving the list stale for as long as it is open.
    func testAClientThatLeftTheSocketReconnects() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Old")])]
        let list = makeList(wire, reconnectDelays: [.zero])
        await list.openHermes()

        wire.pageFailure = .stale
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "New")])]
        await list.openHermes()
        await waitUntil("reconnected and read") { list.sessions.first?.title == "New" }

        XCTAssertEqual(wire.connects, 2)
    }

    // MARK: Profiles

    func testSwitchingProfileListsItsSessionsAndSavesThePick() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([HermesSessionRow(id: "d")])], "research": [0: page([HermesSessionRow(id: "r")])]]
        let list = makeList(wire)
        await list.openHermes()
        XCTAssertEqual(list.hermesProfiles, ["default", "research"])

        await list.selectHermesProfile("research")

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertEqual(wire.calls.last { $0.method == "session.most_recent" }?.profile, "research",
                       "the host watches the new Profile's store")
        XCTAssertEqual(defaults.string(forKey: HermesProfilePreference.key(for: server)), "research",
                       "the composer's Profile chip shares the pick")
    }

    /// A Profile deleted on the host answers 4064: the list drops it as the server's pick and
    /// moves to the Profile the host's dashboard runs.
    func testARemovedProfileMovesToTheHostsCurrentProfile() async {
        let wire = HermesSessionListWire()
        wire.removed = ["gone"]
        wire.current = "research"
        wire.pages = ["research": [0: page([HermesSessionRow(id: "r")])]]
        HermesProfilePreference.save("gone", for: server, in: defaults)
        let list = makeList(wire, profile: "gone")

        await list.openHermes()

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertNil(list.errorMessage)
        XCTAssertNil(defaults.string(forKey: HermesProfilePreference.key(for: server)))
    }

    // MARK: All Profiles (#709)

    /// All Profiles lists every Profile's sessions, each row in its own Profile, watches every
    /// Profile's store and is remembered for the server; New Session keeps the pick. Picking a
    /// Profile goes back to its sessions alone.
    func testAllProfilesListsEveryProfileUntilOneIsPicked() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([HermesSessionRow(id: "d", lastActive: 1)])],
                      "research": [0: page([HermesSessionRow(id: "r", lastActive: 2)])]]
        let list = makeList(wire)
        await list.openHermes()

        await list.showAllHermesProfiles()

        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).map { "\($0.sessionId!)@\($0.profile!)" },
                       ["r@research", "d@default"])
        XCTAssertEqual(Set(wire.calls.filter { $0.method == "session.most_recent" }.compactMap(\.profile)), ["default", "research"])
        XCTAssertTrue(HermesProfilePreference.showsAllProfiles(for: server, in: defaults))
        XCTAssertEqual(list.hermesProfile, "default", "New Session still opens in the pick")

        await list.selectHermesProfile("research")

        XCTAssertFalse(list.hermesShowsAllProfiles)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertFalse(HermesProfilePreference.showsAllProfiles(for: server, in: defaults))
    }

    /// A merged list holds back rows older than the oldest row a Profile with more pages has read,
    /// pinned rows aside, so the next page never lands above rows already shown. "Load more" reads
    /// the next page of each Profile with more, and none of a Profile at its end.
    func testAllProfilesHoldsBackOlderRowsUntilTheNextPagesAreIn() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page(rows(0..<100)), 100: page(rows(100..<110))],
                      "research": [0: page([HermesSessionRow(id: "new", lastActive: 20_000),
                                            HermesSessionRow(id: "old", lastActive: 1),
                                            HermesSessionRow(id: "pinned", lastActive: 0, pinned: true)])]]
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire)

        await list.openHermes()

        var shown = Set(list.sessions.compactMap(\.sessionId))
        XCTAssertTrue(shown.isSuperset(of: ["new", "pinned"]))
        XCTAssertFalse(shown.contains("old"), "the default Profile's next page may hold newer rows")
        XCTAssertEqual(shown.count, 102)
        XCTAssertTrue(list.hasMoreSessions)

        await list.loadMoreHermesSessions()

        shown = Set(list.sessions.compactMap(\.sessionId))
        XCTAssertTrue(shown.contains("old"))
        XCTAssertEqual(shown.count, 113)
        XCTAssertFalse(list.hasMoreSessions)
        XCTAssertEqual(wire.pageReads.filter { $0.profile == "research" }.map(\.offset), [0])
    }

    /// A Profile added on another client joins All Profiles on the next refresh, which names it on
    /// the socket so its changes reach the list too.
    func testRefreshingAllProfilesListsAProfileAddedElsewhere() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([HermesSessionRow(id: "d", lastActive: 1)])],
                      "research": [0: page([])], "ops": [0: page([HermesSessionRow(id: "o", lastActive: 3)])]]
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire)
        await list.openHermes()
        XCTAssertEqual(list.sessions.map(\.sessionId), ["d"])

        wire.profiles = ["default", "research", "ops"]
        await list.refreshHermes()

        XCTAssertEqual(Set(list.sessions.compactMap(\.sessionId)), ["d", "o"])
        XCTAssertEqual(wire.calls.last { $0.method == "session.most_recent" && $0.profile == "ops" }?.profile, "ops")
    }

    /// A pick removed on another client while All Profiles shows (here, opened offline on the saved
    /// pick) moves to the host's current Profile, so New Session never opens in a missing one.
    func testAllProfilesMovesOffAPickTheHostNoLongerHas() async {
        let wire = HermesSessionListWire()
        wire.current = "research"
        wire.pages = ["default": [0: page([])], "research": [0: page([])]]
        HermesProfilePreference.save("gone", for: server, in: defaults)
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire, profile: "gone")

        await list.openHermes()

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertNil(defaults.string(forKey: HermesProfilePreference.key(for: server)))
        XCTAssertTrue(list.hermesShowsAllProfiles)
    }

    /// The home's list opens on no Profile (#709): it takes the one the host's dashboard runs.
    func testAListWithoutAProfileOpensOnTheHostsCurrentProfile() async {
        let wire = HermesSessionListWire()
        wire.current = "research"
        wire.pages = ["research": [0: page([HermesSessionRow(id: "r")])]]
        let list = makeList(wire, profile: nil)

        await list.openHermes()

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
    }

    /// A search of All Profiles asks the host once for each Profile.
    func testAllProfilesSearchesEveryProfile() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([])], "research": [0: page([])]]
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "far", title: "Nimbus plan"))]
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire)
        await list.openHermes()

        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)

        XCTAssertEqual(wire.searches.map(\.profile).sorted(), ["default", "research"])
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["far"])
    }

    // MARK: Fixture

    private func makeList(_ wire: HermesSessionListWire, profile: String? = "default",
                          reconnectDelays: [Duration] = [.seconds(3600)]) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: connection, profile: profile, makeWire: { _ in wire }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: reconnectDelays
        ))
    }

    private func page(_ rows: [HermesSessionRow]) -> HermesSessionPage { HermesSessionPage(rows: rows) }

    /// Rows `s<n>`, newest first.
    private func rows(_ range: Range<Int>) -> [HermesSessionRow] {
        range.map { HermesSessionRow(id: "s\($0)", lastActive: Double(10_000 - $0)) }
    }

    /// One `session.active_list` item in the host's shape (`server.py` `_session_live_item`).
    private func live(_ key: String, _ status: String) -> BotJSON {
        .object(["id": .string("runtime-" + key), "session_key": .string(key), "status": .string(status),
                 "last_active": .number(100), "started_at": .number(90), "message_count": .number(2),
                 "model": .string("m"), "preview": .string(""), "title": .string(""), "current": .bool(false)])
    }

    /// Waits on observation of the list and the wire, never a clock, and fails once nothing
    /// changes for 5 s.
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

/// A Hermes server's Sessions list search (#1053): the host's matches merged into the loaded
/// rows, their snippets, labels and Bot Chat routing, on the scripted wire below.
@MainActor final class HermesSessionSearchTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesSessionSearchTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Every parameter is sent: the Profile, a limit, and the sources the list leaves out, so a
    /// search never finds a row the list never shows. A typed `+` stays a `+`.
    func testTheSearchAsksForTheQueryInTheListedProfile() throws {
        let request = try HermesREST.sessionSearch(query: "c++ nimb", profile: "research")
            .request(base: URL(string: "https://hermes.example/base")!)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/base/api/sessions/search")
        XCTAssertEqual(request.url?.query, "q=c%2B%2B%20nimb&profile=research&limit=50&exclude_sources=cron,kanban,oneshot,subagent,tool")
        XCTAssertThrowsError(try HermesREST.sessionSearch(query: "", profile: "research").request(base: server))
        XCTAssertThrowsError(try HermesREST.sessionSearch(query: "nimb", profile: "").request(base: server))
    }

    /// The pin's shapes, as `scripts/local-hermes` answered them: a content match carries the
    /// message's marked snippet, an id match only the preview, and a match without the
    /// session's row has no `last_active`, so recency falls back to `session_started`. A result
    /// without an id is skipped.
    func testResultsReadAsRowsWithTheirSnippetsAndRecency() throws {
        let reply = Data(#"""
        {"results": [
          {"snippet": "Plan the >>>Nimbus<<< cloud migration", "role": "user", "source": "cli", "model": "hermex-stub",
           "session_started": 1791400926.3, "last_active": 1791400927.2, "session_id": "tip", "lineage_root": "root",
           "profile": "default", "id": "tip", "title": null, "started_at": 1791400926.3, "message_count": 4,
           "preview": "Plan the Nimbus cloud migration", "parent_session_id": null, "archived": false},
          {"snippet": "Draft release notes", "role": null, "session_started": 1791400930.9, "last_active": 1791400931.6,
           "session_id": "20261007_152208_588bfb", "lineage_root": "20261007_152208_588bfb", "profile": "default",
           "title": "Release notes", "archived": true},
          {"snippet": "the >>>nimbus<<< cluster", "role": "assistant", "session_started": 1791400900, "last_active": null,
           "session_id": "orphan", "lineage_root": "orphan", "profile": "default"},
          {"snippet": "no id", "role": "user"}
        ]}
        """#.utf8)

        let results = try JSONDecoder().decode(HermesSessionSearch.self, from: reply).results

        XCTAssertEqual(results.map(\.row.id), ["tip", "20261007_152208_588bfb", "orphan"])
        XCTAssertEqual(results.map(\.row.identity), ["root", "20261007_152208_588bfb", "orphan"])
        XCTAssertEqual(results.map(\.snippet), ["Plan the >>>Nimbus<<< cloud migration", nil, "the >>>nimbus<<< cluster"])
        XCTAssertEqual(results.map(\.row.lastActive), [1_791_400_927.2, 1_791_400_931.6, 1_791_400_900])
        XCTAssertEqual(results.map(\.row.archived), [false, true, nil])
        XCTAssertEqual(results[0].row.preview, "Plan the Nimbus cloud migration")
        XCTAssertEqual(results[0].row.messageCount, 4)
    }

    /// The loaded rows filter at once; the host's matches follow in its order, each merged by
    /// identity (a compression lineage's root): a loaded row shows as listed, pin and read mark
    /// included, with the host's snippet, and one the pages lack shows from the result. A row
    /// both found is listed once.
    func testHostMatchesMergeByLineageRootWithTheLoadedRows() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: [
            HermesSessionRow(id: "plan", title: "Nimbus plan", lastActive: 30),
            HermesSessionRow(id: "tip", title: "Deploy notes", lastActive: 20, pinned: true, unread: true, lineageRootID: "root"),
            HermesSessionRow(id: "lunch", title: "Lunch", lastActive: 10)
        ])]
        wire.searchResults = [
            HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old chat", lastActive: 1, profile: "default",
                                                            lineageRootID: "old"), snippet: "the >>>nimbus<<< cluster"),
            HermesSessionSearchResult(row: HermesSessionRow(id: "tip", title: "Deploy notes", profile: "default", lineageRootID: "root"),
                                      snippet: ">>>Nimbus<<< rollout"),
            HermesSessionSearchResult(row: HermesSessionRow(id: "plan", title: "Nimbus plan", profile: "default", lineageRootID: "plan"))
        ]
        let list = makeList(wire)
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan"],
                       "the loaded rows filter before the host answers")
        await list.searchSessions(query: " Nimbus ", debounceNanoseconds: 0)

        let shown = list.visibleSessions(searchText: "Nimbus", selectedProjectID: nil)
        XCTAssertEqual(shown.compactMap(\.sessionId), ["plan", "old", "tip"])
        XCTAssertEqual(wire.searches.map(\.query), ["nimbus"])
        XCTAssertEqual(wire.searches.map(\.profile), ["default"])
        let tip = shown[2]
        XCTAssertEqual(tip.pinned, true)
        XCTAssertTrue(list.isUnread(tip))
        XCTAssertEqual(list.searchExcerpt(for: tip, searchText: "Nimbus")?.text, "Nimbus rollout")
        XCTAssertEqual(list.searchExcerpt(for: shown[1], searchText: "Nimbus")?.text, "the nimbus cluster")
        XCTAssertNil(list.searchExcerpt(for: shown[0], searchText: "Nimbus"), "an id or title match has no excerpt")
        XCTAssertNil(list.searchExcerpt(for: tip, searchText: "rollout"), "another screen's query shows none")
    }

    /// An archived match is labeled "Archived" and opens as a session. A bot's Bot Chat is named
    /// after its Profile and opens in that bot, not as a session, without the session actions.
    func testArchivedAndBotChatMatchesAreLabeledAndRouted() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = [
            HermesSessionSearchResult(row: HermesSessionRow(id: "gone", title: "Old launch", archived: true, profile: "default")),
            HermesSessionSearchResult(row: HermesSessionRow(id: "bot", title: "Bot Chat", hidden: true, profile: "default"))
        ]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "launch", debounceNanoseconds: 0)

        let shown = list.visibleSessions(searchText: "launch", selectedProjectID: nil)
        let archived = try XCTUnwrap(shown.first { $0.sessionId == "gone" })
        XCTAssertTrue(SessionRowView.accessibilityStateLabels(for: archived, isViewingCachedData: false, labelsArchived: true)
            .contains("Archived"))
        XCTAssertFalse(SessionRowView.accessibilityStateLabels(for: archived, isViewingCachedData: false).contains("Archived"),
                       "the Archived screen's rows go unlabeled")
        XCTAssertEqual(archived.hermesTarget(listedIn: "default"), .session(profile: "default", key: "gone"))
        XCTAssertNil(archived.hermesBot(on: server, connectionID: connection.id))
        XCTAssertTrue(SessionRowActionPolicy.offersMutationActions(for: archived))
        XCTAssertFalse(SessionRowActionPolicy.offersArchive(for: archived), "the Archived screen restores it")

        let bot = try XCTUnwrap(shown.first { $0.sessionId == "bot" })
        XCTAssertEqual(SessionRowView.displayTitle(for: bot), "Bot Chat · default")
        XCTAssertEqual(bot.hermesBot(on: server, connectionID: connection.id),
                       BotDestination(server: server, connectionID: connection.id, profile: "default"))
        XCTAssertFalse(SessionRowActionPolicy.offersMutationActions(for: bot), "pinning would unhide it")
        XCTAssertFalse(list.canToggleUnread(bot), "the Bots inbox keeps its own read mark")
        XCTAssertTrue(list.canToggleUnread(archived))
    }

    /// No list read refreshes the host's matches, so a delete, archive or rename confirmed here
    /// shows on them: the deleted match leaves, the archived one is labeled, the renamed one
    /// shows its new title, and the host is not searched again.
    func testAMatchChangedHereShowsTheChange() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = ["gone", "old", "draft"].map { id in
            HermesSessionSearchResult(row: HermesSessionRow(id: id, title: "Plan \(id)", profile: "default"), snippet: ">>>nimbus<<<")
        }
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)
        let shown = list.visibleSessions(searchText: "nimbus", selectedProjectID: nil)
        XCTAssertEqual(shown.compactMap(\.sessionId), ["gone", "old", "draft"])

        let deleted = await list.delete(shown[0])
        let archived = await list.archive(shown[1])
        let renamed = await list.rename(shown[2], to: "Nimbus draft")

        XCTAssertEqual([deleted, archived, renamed], [true, true, true])
        XCTAssertEqual(wire.changes, [.archived(true), .title("Nimbus draft")])
        let after = list.visibleSessions(searchText: "nimbus", selectedProjectID: nil)
        XCTAssertEqual(after.compactMap(\.sessionId), ["old", "draft"])
        XCTAssertEqual(after.map(\.archived), [true, nil])
        XCTAssertEqual(after.map(\.title), ["Plan old", "Nimbus draft"])
        XCTAssertEqual(wire.searches.count, 1)
    }

    /// A pin confirmed on an archived match shows on it: the list's pages never hold an
    /// archived row, so no list read brings the pin back.
    func testPinningAnArchivedMatchShowsThePin() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "gone", title: "Old launch", archived: true,
                                                                              profile: "default"))]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "launch", debounceNanoseconds: 0)
        let match = try XCTUnwrap(list.visibleSessions(searchText: "launch", selectedProjectID: nil).first)

        let pinned = await list.setPinned(true, for: match)

        XCTAssertTrue(pinned)
        XCTAssertEqual(wire.changes, [.pinned(true)])
        XCTAssertEqual(list.visibleSessions(searchText: "launch", selectedProjectID: nil).map(\.pinned), [true])
    }

    /// A search that found the list's socket not yet attached, as a list opened searching
    /// starts one, runs once the socket is, and says nothing went wrong meanwhile.
    func testASearchBeforeTheSocketIsAttachedRunsOnceItIs() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        wire.holdsConnect = true
        let list = makeList(wire)
        let open = Task { await list.openHermes() }
        await waitUntil("connecting") { wire.connects == 1 }

        await list.searchSessions(query: "old", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil), [])
        XCTAssertNil(list.searchErrorMessage)

        wire.release()
        await open.value

        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["old"])
        XCTAssertEqual(wire.searches.map(\.query), ["old"])
    }

    /// The host's matches follow the project lanes as the list reads them again, so a match the
    /// loaded pages lack shows in the lane that now claims it.
    func testMatchesFollowTheProjectLanesReadAfterTheSearch() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: "p_1"), [])

        wire.projectTree = .object(["projects": .array([.object([
            "id": .string("p_1"), "label": .string("Launch"), "path": .string("/Users/me/launch"), "isAuto": .bool(false),
            "isNoProject": .bool(false), "sessionCount": .number(1), "sessionIds": .array([.string("old")])
        ])])])
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: "p_1").compactMap(\.sessionId), ["old"])
    }

    /// Clearing the search shows the loaded list again, without the host's matches or snippets.
    func testClearingTheSearchRestoresTheList() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "a", title: "Alpha", lastActive: 2),
                                                             HermesSessionRow(id: "b", title: "Beta", lastActive: 1)])]
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"),
                                                        snippet: ">>>alpha<<<")]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "alpha", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "alpha", selectedProjectID: nil).compactMap(\.sessionId), ["a", "old"])

        await list.searchSessions(query: "", debounceNanoseconds: 0)

        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).compactMap(\.sessionId), ["a", "b"])
        XCTAssertEqual(wire.searches.count, 1, "an empty query never asks the host")
    }

    /// The same search running again, as when a chat opened from its matches closes, keeps them
    /// on screen until the host answers; a new query clears them at once.
    func testRepeatingTheSearchKeepsItsMatchesUntilTheHostAnswers() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)

        wire.holdsSearch = true
        let again = Task { await list.searchSessions(query: "old", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 2 }
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["old"])
        wire.release()
        await again.value

        let other = Task { await list.searchSessions(query: "older", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 3 }
        XCTAssertEqual(list.visibleSessions(searchText: "older", selectedProjectID: nil), [])
        wire.release()
        await other.value
    }

    /// A delete confirmed while the same search runs again may postdate the host's answer, so
    /// that answer is dropped and the host asked again: the deleted match stays gone.
    func testAWriteConfirmedDuringARepeatedSearchIsNotUndoneByItsAnswer() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = ["gone", "kept"].map { HermesSessionSearchResult(row: HermesSessionRow(id: $0, title: "Old \($0)", profile: "default")) }
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)
        let gone = try XCTUnwrap(list.visibleSessions(searchText: "old", selectedProjectID: nil).first)

        wire.holdsSearch = true
        let again = Task { await list.searchSessions(query: "old", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 2 }
        let deleted = await list.delete(gone)
        wire.searchResults.removeFirst()
        wire.holdsSearch = false
        wire.release()
        await again.value

        XCTAssertTrue(deleted)
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["kept"])
        XCTAssertEqual(wire.searches.count, 3)
    }

    /// A list that reconnects (the socket dropped, or the app came back) searches again, since a
    /// match past the loaded pages that another device deleted meanwhile changes only then.
    func testAReconnectSearchesAgainSoAMatchDeletedElsewhereGoes() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = ["gone", "kept"].map { HermesSessionSearchResult(row: HermesSessionRow(id: $0, title: "Old \($0)", profile: "default")) }
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)

        wire.searchResults.removeFirst()
        wire.onDisconnect?(BotFailure.transport)
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["kept"])
        XCTAssertEqual(wire.searches.count, 2)
    }

    /// Pull to refresh searches again too, so a match another device deleted goes.
    func testPullToRefreshSearchesAgain() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = ["gone", "kept"].map { HermesSessionSearchResult(row: HermesSessionRow(id: $0, title: "Old \($0)", profile: "default")) }
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)

        wire.searchResults.removeFirst()
        await list.refreshHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["kept"])
        XCTAssertEqual(wire.searches.count, 2)
    }

    /// A search the list moved off its Profile from never applies there.
    func testASearchAnotherProfileReplacedIsDropped() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsSearch = true
        let search = Task { await list.searchSessions(query: "old", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 1 }
        await list.selectHermesProfile("research")
        wire.release()
        await search.value

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil), [])
    }

    private func makeList(_ wire: HermesSessionListWire) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: connection, profile: "default", makeWire: { _ in wire }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }

    /// Waits on observation of the wire, never a clock, and fails once nothing changes for 5 s.
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

/// A scripted Hermes host for the Sessions list: pages by Profile and offset, read marks and
/// other changes, `session.active_list`, `profiles.list`, `session.most_recent`,
/// `session.delete`, `projects.tree` and the search (#1053). A test
/// can park page reads, read-mark writes or searches, and push gateway events.
@MainActor @Observable final class HermesSessionListWire: BotTransport {
    struct UnreadWrite: Equatable { let key: String; let profile: String; let unread: Bool }

    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var pages: [String: [Int: HermesSessionPage]] = [:]
    var active: [BotJSON] = []
    var profiles = ["default", "research"]
    var current = "default"
    /// Profiles the host no longer has: 4064 over the socket, 404 over REST.
    var removed: Set<String> = []
    /// While true, page reads wait for `release()`, answering what they read when they arrived.
    var holdsPages = false
    var holdsUnread = false
    var unreadFails = false
    /// Thrown by the next page read instead of its page.
    var pageFailure: BotFailure?
    /// What every search answers, whatever its query. A search before `connect()` finishes is
    /// refused as `BotClient`'s is, with `.stale`.
    var searchResults: [HermesSessionSearchResult] = []
    var holdsSearch = false
    /// While true, `connect()` waits for `release()`.
    var holdsConnect = false
    /// Thrown by every `connect()` while set: a host that can't be reached, or a proxy answering for it (#1054).
    var connectFailure: Error?
    /// `projects.tree`'s reply; nil refuses the call.
    var projectTree: BotJSON?
    private(set) var attached = false
    private(set) var searches: [(query: String, profile: String)] = []
    private(set) var connects = 0
    private(set) var pageReads: [(profile: String, offset: Int)] = []
    private(set) var answeredPages = 0
    private(set) var unreadWrites: [UnreadWrite] = []
    /// Every other change written, each accepted with the title as sent.
    private(set) var changes: [HermesSessionChange] = []
    private(set) var calls: [(method: String, profile: String?)] = []
    @ObservationIgnored private var held: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {
        connects += 1
        if holdsConnect { await withCheckedContinuation { held.append($0) } }
        if let connectFailure { throw connectFailure }
        attached = true
    }
    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let params = try call.params()
        calls.append((call.method, params["profile"]?.text))
        switch call.method {
        case "session.most_recent":
            if removed.contains(params["profile"]?.text ?? "") { throw BotFailure.rejected(4064) }
            return .object(["session_id": .null])
        case "session.active_list": return .object(["sessions": .array(active)])
        case "profiles.list": return .object(["profiles": .array(profiles.map { .object(["name": .string($0)]) })])
        case "session.delete": return .object([:])
        case "projects.tree":
            guard let projectTree else { throw BotFailure.unsupported }
            return projectTree
        default: throw BotFailure.unsupported
        }
    }

    func currentProfile() async throws -> String { current }

    func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        pageReads.append((profile, offset))
        let reply = pages[profile]?[offset] ?? HermesSessionPage(rows: [])
        if holdsPages { await withCheckedContinuation { held.append($0) } }
        answeredPages += 1
        if let failure = pageFailure { pageFailure = nil; throw failure }
        if removed.contains(profile) { throw BotFailure.rejected(404) }
        return reply
    }

    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String? {
        guard case .unread(let unread) = change else { changes.append(change); return nil }
        unreadWrites.append(UnreadWrite(key: key, profile: profile, unread: unread))
        if holdsUnread { await withCheckedContinuation { held.append($0) } }
        if unreadFails { throw BotFailure.rejected(500) }
        return nil
    }

    func searchSessions(query: String, profile: String) async throws -> [HermesSessionSearchResult] {
        guard attached else { throw BotFailure.stale }
        searches.append((query, profile))
        let reply = searchResults
        if holdsSearch { await withCheckedContinuation { held.append($0) } }
        return reply
    }

    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func emit(_ type: String) {
        onEvent?(.object(["type": .string(type), "session_id": .string("")]))
    }
}
