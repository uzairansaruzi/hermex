import XCTest
@testable import HermesMobile

@MainActor final class BotInboxTests: XCTestCase {
    private let server = URL(string: "https://one.example")!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "BotInboxTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testSessionsChangedBurstCoalescesIntoBoundedReloads() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage", lastActive: 100, preview: "old")])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.link, .live)
        XCTAssertEqual(inbox.profiles.map(\.preview), ["old"])

        wire.holdsList = true
        let parked = expectation(description: "reload parked")
        wire.onCall = { if $0 == "profiles.list" { parked.fulfill() } }
        wire.emit("sessions.changed")
        await fulfillment(of: [parked], timeout: 5)
        for _ in 0..<4 { wire.emit("sessions.changed") }

        wire.roster = [row("triage", lastActive: 200, preview: "new")]
        wire.holdsList = false
        let trailing = expectation(description: "one trailing reload")
        wire.onCall = { if $0 == "profiles.list" { trailing.fulfill() } }
        wire.release()
        await fulfillment(of: [trailing], timeout: 5)
        await settle(inbox) { $0.profiles.first?.preview == "new" }

        XCTAssertEqual(wire.listCalls, 3, "open, the parked reload and exactly one trailing reload")
        XCTAssertTrue(inbox.isUnread(inbox.profiles[0]))
    }

    func testStaleReloadAndEventsFromAReplacedWireAreDropped() async throws {
        let first = BotInboxFixtureWire(roster: [row("triage", lastActive: 100, preview: "first")])
        let second = BotInboxFixtureWire(roster: [row("triage", lastActive: 300, preview: "second")])
        let inbox = try makeInbox(wires: [first, second])
        await inbox.open()

        first.holdsList = true
        let parked = expectation(description: "reload parked")
        first.onCall = { if $0 == "profiles.list" { parked.fulfill() } }
        first.emit("sessions.changed")
        await fulfillment(of: [parked], timeout: 5)

        await inbox.open()
        XCTAssertEqual(first.closed, 1)
        XCTAssertEqual(inbox.profiles.map(\.preview), ["second"])

        first.roster = [row("triage", lastActive: 200, preview: "stale")]
        first.release()
        // The parked reply resumes on the main actor ahead of this task; one yield lets it be dropped.
        await Task.yield()
        first.emit("sessions.changed")
        await Task.yield()
        XCTAssertEqual(inbox.profiles.map(\.preview), ["second"])
        XCTAssertEqual(first.listCalls, 2)
        XCTAssertEqual(second.listCalls, 1)
        XCTAssertEqual(inbox.link, .live)
    }

    func testChangedCanonicalTipUpdatesPreviewAndUnreadFollowsActivity() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage", lastActive: 100, preview: "before", tip: "tip-1")])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertFalse(inbox.isUnread(inbox.profiles[0]), "the first load seeds the watermark")

        wire.roster = [row("triage", lastActive: 200, preview: "after", tip: "tip-2")]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.profiles.first?.preview == "after" }
        XCTAssertTrue(inbox.isUnread(inbox.profiles[0]))

        inbox.markSeen(inbox.profiles[0])
        XCTAssertFalse(inbox.isUnread(inbox.profiles[0]))
        XCTAssertEqual(BotUnreadStore(defaults: defaults).load(connectionID: inbox.connection!.id), ["triage": 200])
    }

    func testReturningFromChatMarksTheNextRosterSeenOnce() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage", lastActive: 100)])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        inbox.noteReturn(from: inbox.profiles[0])

        wire.roster = [row("triage", lastActive: 200)]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.profiles.first?.lastActive == Date(timeIntervalSince1970: 200) }
        XCTAssertFalse(inbox.isUnread(inbox.profiles[0]), "activity during the visit was on screen")

        wire.roster = [row("triage", lastActive: 300)]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.profiles.first?.lastActive == Date(timeIntervalSince1970: 300) }
        XCTAssertTrue(inbox.isUnread(inbox.profiles[0]))
    }

    func testUnreadSurvivesRelaunchAndStaysWithItsConnection() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage", lastActive: 100)])
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!,
                                       username: "u", password: "p", hermesVersion: nil)
        try store.save(connection, server: server)
        let inbox = try makeInbox(wires: [wire], store: store)
        await inbox.open()
        wire.roster = [row("triage", lastActive: 200)]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.profiles.first?.lastActive == Date(timeIntervalSince1970: 200) }
        XCTAssertTrue(inbox.isUnread(inbox.profiles[0]))
        inbox.close()

        let relaunched = try makeInbox(wires: [BotInboxFixtureWire(roster: [row("triage", lastActive: 200)])], store: store)
        await relaunched.open()
        XCTAssertTrue(relaunched.isUnread(relaunched.profiles[0]), "the watermark outlives the process")

        // A second host with the same Profile name has its own marks: nothing seen there yet.
        let otherServer = URL(string: "https://two.example")!
        let otherStore = BotConnectionStore(keychain: InMemoryKeychainStore())
        try otherStore.save(BotConnection(id: UUID(), name: "Other", address: URL(string: "https://other.example")!,
                                          username: "u", password: "p", hermesVersion: nil), server: otherServer)
        let other = try makeInbox(wires: [BotInboxFixtureWire(roster: [row("triage", lastActive: 200)])],
                                  store: otherStore, server: otherServer)
        await other.open()
        XCTAssertFalse(other.isUnread(other.profiles[0]))
        XCTAssertEqual(BotUnreadStore(defaults: defaults).load(connectionID: connection.id), ["triage": 100])
    }

    func testMissingMetadataReadsPlainAndPinWritesUnderRevisionZero() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage", look: nil, revision: nil)])
        var configured: [String: BotJSON]?
        wire.configure = { params in
            configured = params
            wire.roster = [self.row("triage", look: ["pinned": .bool(true)], revision: 1)]
            return .object(["ok": .bool(true), "applied": .object(["ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(1)])])])
        }
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        let plain = inbox.profiles[0]
        XCTAssertFalse(plain.pinned); XCTAssertFalse(plain.hidden); XCTAssertEqual(plain.look, [:]); XCTAssertNil(plain.lookRevision)
        XCTAssertEqual(inbox.rows(matching: "").others.map(\.id), ["triage"])

        await inbox.setPinned(true, plain)
        XCTAssertEqual(configured?["name"], .string("triage"))
        XCTAssertEqual(configured?["ui_meta"], .object(["hermes-bots": .object(["pinned": .bool(true)])]))
        XCTAssertEqual(configured?["ui_meta_expected_revisions"], .object(["hermes-bots": .number(0)]))
        XCTAssertEqual(Set(configured?.keys.map { $0 } ?? []), ["name", "ui_meta", "ui_meta_expected_revisions"])
        XCTAssertEqual(inbox.rows(matching: "").pinned.map(\.id), ["triage"], "the row moves only after the host applied and the roster was re-read")
        XCTAssertNil(inbox.notice)
        XCTAssertEqual(wire.listCalls, 2)
    }

    func testHideRoundTripsDesktopFieldsAndConflictShowsNoSuccess() async throws {
        let look: [String: BotJSON] = ["title": .string("Triage"), "sectionId": .string("sec-1"), "groups": .array([.string("ops")]),
                                       "color": .string("teal"), "pinned": .bool(true)]
        let wire = BotInboxFixtureWire(roster: [row("triage", look: look, revision: 4)])
        var configured: [String: BotJSON]?
        wire.configure = { params in
            configured = params
            wire.roster = [self.row("triage", look: look.merging(["title": .string("Renamed")]) { $1 }, revision: 5)]
            return .object(["ok": .bool(false), "applied": .object([
                "ui_meta": .bool(false),
                "ui_meta_conflicts": .object(["hermes-bots": .object(["expected": .number(4), "actual": .number(5)])]),
                "ui_meta_revisions": .object(["hermes-bots": .number(5)])])])
        }
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        let before = inbox.profiles[0]
        XCTAssertTrue(before.pinned)

        await inbox.setHidden(true, before)
        var expected = look; expected["hidden"] = .bool(true)
        XCTAssertEqual(configured?["ui_meta"], .object(["hermes-bots": .object(expected)]), "unrelated Desktop fields ride along untouched")
        XCTAssertEqual(configured?["ui_meta_expected_revisions"], .object(["hermes-bots": .number(4)]))
        XCTAssertEqual(inbox.notice, "This bot changed in Hermes Desktop. The list was refreshed; try again.")
        XCTAssertEqual(inbox.profiles[0].name, "Renamed", "the conflict re-read the roster")
        XCTAssertFalse(inbox.profiles[0].hidden)
        XCTAssertEqual(inbox.profiles[0].lookRevision, 5)
        XCTAssertTrue(inbox.mayEdit(inbox.profiles[0]))
    }

    func testHiddenBotsStayOutUntilRevealedOrSearched() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("alpha", look: ["pinned": .bool(true)], revision: 1),
            row("beta"),
            row("gamma", look: ["hidden": .bool(true)], revision: 2),
            row("gamma", preview: "duplicate row")
        ])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.profiles.map(\.id), ["alpha", "beta", "gamma"], "a repeated Profile name keeps its first row")
        XCTAssertEqual(inbox.hiddenCount, 1)

        var rows = inbox.rows(matching: "")
        XCTAssertEqual(rows.pinned.map(\.id), ["alpha"])
        XCTAssertEqual(rows.others.map(\.id), ["beta"])
        XCTAssertEqual(rows.hidden, [])

        inbox.showsHidden = true
        rows = inbox.rows(matching: "")
        XCTAssertEqual(rows.hidden.map(\.id), ["gamma"])

        inbox.showsHidden = false
        rows = inbox.rows(matching: "gam")
        XCTAssertEqual(rows.pinned, []); XCTAssertEqual(rows.others, [])
        XCTAssertEqual(rows.hidden.map(\.id), ["gamma"], "a search names hidden bots too")
    }

    func testChatsMixRoomsAndBotsByActivityWhileRespectingPinAndHiddenState() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("pinned", lastActive: 600, look: ["pinned": .bool(true)]),
            row("hidden", lastActive: 500, look: ["hidden": .bool(true)]),
            row("older", lastActive: 100),
            row("shared", lastActive: 300),
            row("undated", lastActive: nil)
        ])
        wire.rooms = [
            .object(["room_id": .string("shared"), "updated_at": .number(400)]),
            .object(["room_id": .string("middle"), "updated_at": .number(200)]),
            .object(["room_id": .string("undated")])
        ]
        let inbox = try makeInbox(wires: [wire, wire])
        await inbox.open()
        XCTAssertEqual(inbox.chats.map(\.id), [
            "room:shared", "bot:shared", "room:middle", "bot:older", "bot:undated", "room:undated"
        ])
        XCTAssertEqual(inbox.rows(matching: "").pinned.map(\.id), ["pinned"])
        inbox.showsHidden = true
        XCTAssertEqual(inbox.chats.first?.id, "bot:hidden")
        inbox.showsHidden = false
        XCTAssertFalse(inbox.chats.contains { $0.id == "bot:hidden" })

        // A host losing room support must remove its rooms from the timeline.
        wire.rooms = nil
        await inbox.open()
        XCTAssertEqual(inbox.chats.map(\.id), ["bot:shared", "bot:older", "bot:undated"])
    }

    func testEqualChatTimesUseStableDistinctIdentities() async throws {
        let wire = BotInboxFixtureWire(roster: [row("z"), row("a")])
        wire.rooms = [
            .object(["room_id": .string("z"), "updated_at": .number(100)]),
            .object(["room_id": .string("a"), "updated_at": .number(100)])
        ]
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.chats.map(\.id), ["bot:a", "bot:z", "room:a", "room:z"])
    }

    func testSocketLossKeepsTheRosterAndReconnectsQuietly() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.configure = { _ in XCTFail("no write on a dead socket"); return .null }
        let second = BotInboxFixtureWire(roster: [row("triage", preview: "back")])
        second.holdsConnect = true
        let inbox = try makeInbox(wires: [wire, second])
        await inbox.open()
        wire.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(inbox.link, .disconnected)
        XCTAssertNil(inbox.errorMessage, "a lost socket is not the user's problem")
        XCTAssertEqual(inbox.profiles.map(\.id), ["triage"])
        XCTAssertFalse(inbox.mayEdit(inbox.profiles[0]))
        await inbox.setPinned(true, inbox.profiles[0])
        wire.emit("sessions.changed")
        await Task.yield()
        XCTAssertEqual(wire.listCalls, 1)

        // The reconnect happens on its own; the roster stays up until it lands.
        await settle(inbox) { $0.link == .connecting }
        XCTAssertEqual(inbox.profiles.map(\.preview), ["hi"])
        second.release()
        await settle(inbox) { $0.link == .live }
        XCTAssertEqual(inbox.profiles.map(\.preview), ["back"])
        XCTAssertNil(inbox.errorMessage)
    }

    func testRefusedConnectionShowsTheMessageAndDoesNotRetryOnItsOwn() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.connectError = BotFailure.rejected(401)
        var spare = 0
        let inbox = BotInbox(server: server, store: try connectedStore(), unread: BotUnreadStore(defaults: defaults),
                             avatarStore: BotAvatarStore(), reloadSpacing: .zero, reconnectDelays: [.zero]) { _ in
            spare += 1; return wire
        }
        await inbox.open()
        XCTAssertEqual(inbox.link, .disconnected)
        XCTAssertEqual(inbox.errorMessage, BotFailure.rejected(401).localizedDescription)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(spare, 1, "no automatic retry after a refusal")
    }

    func testUnreadableSavedConnectionShowsTheFailureInsteadOfAStaleRoster() async throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("not json", forKey: .botConnection, scope: server.absoluteString)
        let inbox = try makeInbox(wires: [], store: BotConnectionStore(keychain: keychain))
        await inbox.open()
        XCTAssertEqual(inbox.link, .disconnected)
        XCTAssertNotNil(inbox.errorMessage)
    }

    func testActivityLabelUsesTimeTodayWeekdayThisWeekThenMonthAndDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        // Thursday 2026-09-10 15:00 UTC.
        let now = Date(timeIntervalSince1970: 1_789_052_400)
        let label = { (offset: TimeInterval) in
            BotInboxDateLabel.text(for: now.addingTimeInterval(offset), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(label(-6 * 3600), "9:00\u{202F}AM")
        XCTAssertEqual(label(-24 * 3600), "Wednesday")
        XCTAssertEqual(label(-6 * 86_400), "Friday")
        XCTAssertEqual(label(-7 * 86_400), "Sep 3")
        XCTAssertEqual(label(-40 * 86_400), "Aug 1")
    }

    // MARK: - Helpers

    private func makeInbox(wires: [BotInboxFixtureWire], store: BotConnectionStore? = nil, server: URL? = nil) throws -> BotInbox {
        let server = server ?? self.server
        let store = try store ?? connectedStore(server: server)
        var queue = wires
        return BotInbox(server: server, store: store, unread: BotUnreadStore(defaults: defaults),
                        avatarStore: BotAvatarStore(), reloadSpacing: .zero, reconnectDelays: [.zero]) { _ in queue.removeFirst() }
    }

    private func connectedStore(server: URL? = nil) throws -> BotConnectionStore {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!,
                                     username: "u", password: "p", hermesVersion: nil), server: server ?? self.server)
        return store
    }

    private func row(_ name: String, lastActive: Double? = 100, preview: String = "hi", tip: String = "tip",
                     look: [String: BotJSON]? = nil, revision: Int? = nil) -> BotJSON {
        var fields: [String: BotJSON] = [
            "name": .string(name), "display_name": .string(""), "description": .string(""), "has_avatar": .bool(false),
            "canonical_session": .object([
                "id": .string("root"), "resolved_id": .string(tip), "preview": .string(preview),
                "last_active": lastActive.map(BotJSON.number) ?? .null
            ])
        ]
        if let look { fields["ui_meta"] = .object(["hermes-bots": .object(look)]) }
        if let revision { fields["ui_meta_revisions"] = .object(["hermes-bots": .number(Double(revision))]) }
        return .object(fields)
    }

    /// Waits for `condition` through Observation rather than sleeping: each change to
    /// the inbox re-evaluates it, and the expectation bounds a broken test.
    private func settle(_ inbox: BotInbox, until condition: @escaping @MainActor (BotInbox) -> Bool) async {
        let done = expectation(description: "inbox settled")
        Task { @MainActor in
            while !condition(inbox) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = condition(inbox) } onChange: { continuation.resume() }
                }
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }
}

/// Answers `profiles.list` from `roster`, `profiles.configure` from `configure`, and
/// lets a test park a list reply or push gateway events.
@MainActor final class BotInboxFixtureWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var roster: [BotJSON]
    var rooms: [BotJSON]?
    var configure: (([String: BotJSON]) -> BotJSON)?
    var delete: ((String) throws -> Void)?
    var deleted: [String] = []
    var calls: [(String, [String: BotJSON])] = []
    var onCall: ((String) -> Void)?
    /// While true, `profiles.list` waits for `release()`.
    var holdsList = false
    /// While true, `connect()` waits for `release()`; `connectError` makes it throw instead.
    var holdsConnect = false
    var connectError: Error?
    private(set) var closed = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    init(roster: [BotJSON]) { self.roster = roster }

    var listCalls: Int { calls.filter { $0.0 == "profiles.list" }.count }

    func connect() async throws {
        if holdsConnect { await withCheckedContinuation { held.append($0) } }
        if let connectError { throw connectError }
    }
    func close() { closed += 1 }

    func deleteProfile(_ name: String) async throws {
        guard let delete else { throw BotFailure.unsupported }
        try delete(name)
        deleted.append(name)
    }

    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append((method, params))
        onCall?(method)
        switch method {
        case "groups.capabilities":
            guard rooms != nil else { throw BotFailure.unsupported }
            return .object(["driver": .bool(true), "methods": .array(
                ["groups.list", "groups.state", "groups.log"].map(BotJSON.string))])
        case "groups.list":
            return .object(["rooms": .array(rooms ?? [])])
        case "profiles.list":
            if holdsList { await withCheckedContinuation { held.append($0) } }
            return .object(["profiles": .array(roster), "bot_mode_protocol": .bool(true)])
        case "profiles.configure":
            guard let configure else { throw BotFailure.unsupported }
            return configure(params)
        default:
            throw BotFailure.unsupported
        }
    }

    func release() {
        let waiting = held; held = []
        for continuation in waiting { continuation.resume() }
    }

    func emit(_ type: String) {
        onEvent?(.object(["type": .string(type), "session_id": .string("")]))
    }
}
