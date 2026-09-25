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
        let look: [String: BotJSON] = ["title": .string("Triage"), "sectionId": .string("sec-1"), "sectionName": .string("Ops"),
                                       "groups": .array([.string("ops")]),
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

    func testNewSectionWritesADesktopIDAndTheTrimmedNameUnderTheRowRevision() async throws {
        let look: [String: BotJSON] = ["title": .string("Triage"), "color": .string("teal"), "groups": .array([.string("ops")])]
        let wire = BotInboxFixtureWire(roster: [row("triage", look: look, revision: 3)])
        var written: [String: BotJSON]?
        wire.configure = { params in
            XCTAssertEqual(params["ui_meta_expected_revisions"], .object(["hermes-bots": .number(3)]))
            written = params["ui_meta"]?["hermes-bots"].fields
            wire.roster = [self.row("triage", look: written, revision: 4)]
            return .object(["ok": .bool(true), "applied": .object(["ui_meta": .bool(true)])])
        }
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.sections.map(\.name), [nil])

        await inbox.moveToNewSection(inbox.profiles[0], name: "  Clients \n")
        let id = try XCTUnwrap(written?["sectionId"]?.text)
        XCTAssertNotNil(id.wholeMatch(of: #/sec-[0-9a-z]+-[0-9a-z]{5}/#), id)
        XCTAssertEqual(written, look.merging(["sectionId": .string(id), "sectionName": .string("Clients")]) { $1 },
                       "other Desktop fields come back unchanged")
        XCTAssertEqual(inbox.sections.map(\.name), ["Clients"], "the row moves once the host applied and the roster was re-read")
        XCTAssertNil(inbox.notice)
        XCTAssertTrue(BotInbox.newSectionID(now: Date(timeIntervalSince1970: 1_700_000_000.123)).hasPrefix("sec-loyw3v5n-"),
                      "the time part is epoch milliseconds in base 36, as Desktop's Date.now().toString(36)")
    }

    func testFilingOffersEverySectionAndJoinsAnExistingOneByIDOrTypedName() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("writer", revision: 2),
            row("chief", look: section("sec-leads", "Leads", ["pinned": .bool(true)])),
            row("legacy", look: section("sec-archive", "Archive", ["hidden": .bool(true)])),
            row("acme", look: section("sec-clients", "Clients"))
        ])
        var written: [[String: BotJSON]] = []
        wire.configure = { params in
            written.append(params["ui_meta"]?["hermes-bots"].fields ?? [:])
            XCTAssertEqual(params["ui_meta_expected_revisions"], .object(["hermes-bots": .number(2)]))
            return .object(["ok": .bool(true), "applied": .object(["ui_meta": .bool(true)])])
        }
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.sectionNames.map(\.name), ["Archive", "Clients", "Leads"],
                       "a pinned-only or unrevealed hidden-only section is still a destination")
        let writer = inbox.profiles[0]

        await inbox.moveToSection(writer, try XCTUnwrap(inbox.sectionNames.first { $0.id == "sec-leads" }))
        await inbox.moveToNewSection(writer, name: " Archive ")
        await inbox.moveToNewSection(writer, name: "archive")
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(written[0], section("sec-leads", "Leads"))
        XCTAssertEqual(written[1], section("sec-archive", "Archive"), "an exactly matching name joins that section")
        XCTAssertEqual(written[2]["sectionName"], .string("archive"))
        XCTAssertNotEqual(written[2]["sectionId"], .string("sec-archive"), "only an exact match joins")

        let acme = inbox.profiles[3]
        await inbox.moveToSection(acme, try XCTUnwrap(inbox.sectionNames.first { $0.id == "sec-clients" }))
        await inbox.moveToNewSection(acme, name: "   ")
        await inbox.moveToNewSection(acme, name: "Clients")
        XCTAssertEqual(written.count, 3, "its own section and a blank name make no call")
        XCTAssertEqual(wire.calls.filter { $0.0 == "profiles.configure" }.count, 3)
    }

    func testRemoveFromSectionWritesExplicitNullsAndAConflictClaimsNoSuccess() async throws {
        let wire = BotInboxFixtureWire(roster: [row("acme", look: section("sec-clients", "Clients", ["color": .string("teal")]), revision: 6)])
        var configured: [String: BotJSON]?
        wire.configure = { params in
            configured = params
            wire.roster = [self.row("acme", look: self.section("sec-clients", "Clients", ["color": .string("red")]), revision: 7)]
            return .object(["ok": .bool(false), "applied": .object([
                "ui_meta": .bool(false),
                "ui_meta_conflicts": .object(["hermes-bots": .object(["expected": .number(6), "actual": .number(7)])])])])
        }
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()

        await inbox.removeFromSection(inbox.profiles[0])
        XCTAssertEqual(configured?["ui_meta"], .object(["hermes-bots": .object([
            "color": .string("teal"), "sectionId": .null, "sectionName": .null])]))
        let encoded = String(decoding: try JSONEncoder().encode(try XCTUnwrap(configured?["ui_meta"])), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"sectionId\":null") && encoded.contains("\"sectionName\":null"), encoded)
        XCTAssertEqual(configured?["ui_meta_expected_revisions"], .object(["hermes-bots": .number(6)]))
        XCTAssertEqual(inbox.notice, "This bot changed in Hermes Desktop. The list was refreshed; try again.")
        XCTAssertEqual(inbox.sections.map(\.name), ["Clients"], "a conflict leaves the bot filed")
        XCTAssertEqual(inbox.profiles[0].lookRevision, 7)
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
        XCTAssertEqual(chatIDs(inbox), [
            "room:shared", "bot:shared", "room:middle", "bot:older", "bot:undated", "room:undated"
        ])
        XCTAssertEqual(inbox.rows(matching: "").pinned.map(\.id), ["pinned"])
        XCTAssertEqual(inbox.sections.map(\.name), [nil], "no named section leaves one headerless block, the flat list")
        inbox.showsHidden = true
        XCTAssertEqual(chatIDs(inbox).first, "bot:hidden")
        inbox.showsHidden = false
        XCTAssertFalse(chatIDs(inbox).contains("bot:hidden"))

        // A host losing room support must remove its rooms from the timeline.
        wire.rooms = nil
        await inbox.open()
        XCTAssertEqual(chatIDs(inbox), ["bot:shared", "bot:older", "bot:undated"])
    }

    func testNamedSectionsSortAToZWithActivityInsideAndUnfiledChatsLast() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("deploy", lastActive: 100, look: section("sec-ops", "Ops")),
            row("globex", lastActive: 200, look: section("sec-clients", "  Clients ")),
            row("acme", lastActive: 300, look: section("sec-clients", "Clients")),
            row("chief", lastActive: 900, look: section("sec-clients", "Clients", ["pinned": .bool(true)])),
            row("writer", lastActive: 400),
            row("orphan", lastActive: 500, look: ["sectionId": .string("sec-ops")]),
            row("blank", lastActive: 50, look: section("sec-ops", "   ")),
            row("deleted", lastActive: 60, look: ["sectionId": .null, "sectionName": .null])
        ])
        wire.rooms = [.object(["room_id": .string("standup"), "updated_at": .number(450)])]
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()

        XCTAssertEqual(inbox.sectionNames, [.init(id: "sec-clients", name: "Clients"), .init(id: "sec-ops", name: "Ops")])
        XCTAssertEqual(inbox.sections.map(\.name), ["Clients", "Ops", nil])
        XCTAssertEqual(inbox.sections.map { $0.chats.map(\.id) }, [
            ["bot:acme", "bot:globex"],
            ["bot:deploy"],
            // A member without a name cannot be headed, and rooms are never sectioned.
            ["bot:orphan", "room:standup", "bot:writer", "bot:deleted", "bot:blank"]
        ])
        XCTAssertEqual(inbox.pinned.map(\.id), ["bot:chief"], "a pinned bot sits only in the tiles")
    }

    func testSectionTakesItsMembersMajorityNameAndTheFirstMemberBreaksATie() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("a", look: section("sec-1", "Old")),
            row("b", look: section("sec-1", "New")),
            row("c", look: section("sec-1", "New")),
            row("d", look: section("sec-2", "First")),
            row("e", look: section("sec-2", "Second"))
        ])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.sectionNames.map(\.name), ["First", "New"])
    }

    func testRevealedHiddenBotsStayDimmedInTheirOwnSection() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("acme", lastActive: 100, look: section("sec-clients", "Clients")),
            row("old", lastActive: 200, look: section("sec-clients", "Clients", ["hidden": .bool(true)])),
            row("legacy", lastActive: 300, look: section("sec-archive", "Archive", ["hidden": .bool(true)])),
            row("writer", lastActive: 50)
        ])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.sections.map(\.name), ["Clients", nil], "a section of only hidden bots draws nothing")
        inbox.showsHidden = true
        XCTAssertEqual(inbox.sections.map(\.name), ["Archive", "Clients", nil])
        XCTAssertEqual(inbox.sections.map { $0.chats.map(\.id) }, [["bot:legacy"], ["bot:old", "bot:acme"], ["bot:writer"]])
    }

    func testReorderOffersOnlySectionsTheListCanHead() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("acme", look: section("sec-clients", "Clients")),
            row("chief", look: section("sec-leads", "Leads", ["pinned": .bool(true)])),
            row("legacy", look: section("sec-archive", "Archive", ["hidden": .bool(true)])),
            row("vault", look: section("sec-vault", "Vault", ["pinned": .bool(true), "hidden": .bool(true)]))
        ])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(inbox.sectionNames.map(\.name), ["Archive", "Clients", "Leads", "Vault"])
        XCTAssertEqual(inbox.reorderableSectionNames.map(\.name), ["Archive", "Clients", "Vault"],
                       "a pinned-only section lives in the tiles; hidden ones can be revealed")
    }

    func testDraggingKeepsThePlacedSlotOfASectionTheSheetLeavesOut() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("a", look: section("sec-a", "Alpha")),
            row("b", look: section("sec-b", "Bravo")),
            row("c", look: section("sec-c", "Charlie", ["pinned": .bool(true)])),
            row("d", look: section("sec-d", "Delta")),
            row("e", look: section("sec-e", "Echo", ["pinned": .bool(true)]))
        ])
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        inbox.setSectionOrder(["sec-c", "sec-b"])
        XCTAssertEqual(inbox.reorderableSectionNames.map(\.id), ["sec-b", "sec-a", "sec-d"])

        inbox.placeReorderableSections(["sec-d", "sec-b", "sec-a"])
        XCTAssertEqual(inbox.sectionOrder, ["sec-c", "sec-d", "sec-b", "sec-a"],
                       "the pinned-only Charlie keeps its placed slot; the never-placed Echo stays A–Z")
        XCTAssertEqual(inbox.sectionNames.map(\.name), ["Charlie", "Delta", "Bravo", "Alpha", "Echo"])
    }

    func testPlacedSectionsKeepTheirOrderPerConnectionAndResetReturnsToAToZ() async throws {
        let roster = [
            row("a", look: section("sec-a", "Alpha")),
            row("b", look: section("sec-b", "Bravo")),
            row("c", look: section("sec-c", "Charlie"))
        ]
        let store = try connectedStore()
        let inbox = try makeInbox(wires: [BotInboxFixtureWire(roster: roster)], store: store)
        await inbox.open()
        inbox.setSectionOrder(["sec-c", "gone", "sec-a"])
        XCTAssertEqual(inbox.sectionNames.map(\.name), ["Charlie", "Alpha", "Bravo"],
                       "placed first, a missing id ignored, the unplaced rest A–Z")

        // The order survives a fresh inbox on the same connection; a section
        // Desktop adds later follows A–Z after the placed ones.
        let grown = roster + [row("z", look: section("sec-0", "Aardvark"))]
        let again = try makeInbox(wires: [BotInboxFixtureWire(roster: grown)], store: store)
        await again.open()
        XCTAssertEqual(again.sectionNames.map(\.name), ["Charlie", "Alpha", "Aardvark", "Bravo"])

        // Another connection, or the same connection id on another server, starts A–Z.
        let other = try makeInbox(wires: [BotInboxFixtureWire(roster: roster)])
        await other.open()
        XCTAssertEqual(other.sectionNames.map(\.name), ["Alpha", "Bravo", "Charlie"])
        let connectionID = try XCTUnwrap(inbox.connection?.id)
        XCTAssertEqual(BotSectionOrderStore(defaults: defaults).load(server: URL(string: "https://two.example")!,
                                                                    connectionID: connectionID), [])

        again.resetSectionOrder()
        XCTAssertEqual(again.sectionNames.map(\.name), ["Aardvark", "Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(BotSectionOrderStore(defaults: defaults).load(server: server, connectionID: connectionID), [])
    }

    func testEqualChatTimesUseStableDistinctIdentities() async throws {
        let wire = BotInboxFixtureWire(roster: [row("z"), row("a")])
        wire.rooms = [
            .object(["room_id": .string("z"), "updated_at": .number(100)]),
            .object(["room_id": .string("a"), "updated_at": .number(100)])
        ]
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        XCTAssertEqual(chatIDs(inbox), ["bot:a", "bot:z", "room:a", "room:z"])
    }

    func testRoomPinAndHideLiveOnThisPhoneAndStayWithTheirConnection() async throws {
        let wire = BotInboxFixtureWire(roster: [row("bot", lastActive: 100)])
        wire.rooms = [
            .object(["room_id": .string("standup"), "updated_at": .number(300)]),
            .object(["room_id": .string("triage"), "updated_at": .number(200)]),
            .object(["room_id": .string("old"), "updated_at": .number(50)])
        ]
        let store = try connectedStore()
        let inbox = try makeInbox(wires: [wire, wire], store: store)
        await inbox.open()
        let standup = try XCTUnwrap(inbox.rooms.first { $0.id == "standup" })
        let triage = try XCTUnwrap(inbox.rooms.first { $0.id == "triage" })

        inbox.setRoomPinned(true, standup)
        inbox.setRoomHidden(true, triage)
        XCTAssertEqual(inbox.pinned.map(\.id), ["room:standup"], "a pinned room joins the tiles")
        XCTAssertEqual(chatIDs(inbox), ["bot:bot", "room:old"], "pinned and hidden rooms leave the timeline")
        XCTAssertEqual(inbox.hiddenCount, 1)
        inbox.showsHidden = true
        XCTAssertEqual(chatIDs(inbox), ["room:triage", "bot:bot", "room:old"])
        // Hiding a pinned room takes it off the tiles but keeps it reachable.
        inbox.setRoomHidden(true, standup)
        XCTAssertTrue(inbox.pinned.isEmpty)
        XCTAssertEqual(chatIDs(inbox), ["room:standup", "room:triage", "bot:bot", "room:old"])
        inbox.setRoomHidden(false, standup)
        inbox.showsHidden = false

        // Both marks survive a fresh inbox on the same connection, and a room the
        // host no longer lists takes its marks with it.
        wire.rooms = [.object(["room_id": .string("standup"), "updated_at": .number(300)])]
        let again = try makeInbox(wires: [wire], store: store)
        await again.open()
        XCTAssertEqual(again.pinned.map(\.id), ["room:standup"])
        XCTAssertEqual(again.hiddenCount, 0)
        XCTAssertEqual(again.roomFlags, .init(pinned: ["standup"], hidden: []))

        // Another connection starts clean; a pin never leaks across hosts.
        let other = try makeInbox(wires: [wire], store: connectedStore())
        await other.open()
        XCTAssertTrue(other.pinned.isEmpty)
        XCTAssertEqual(chatIDs(other), ["room:standup", "bot:bot"])
    }

    func testRenameAndDisbandGoToTheHostAndOnlyApplyOnItsWord() async throws {
        let wire = BotInboxFixtureWire(roster: [row("bot")])
        wire.rooms = [.object(["room_id": .string("standup"), "name": .string("Standup"), "updated_at": .number(300)])]
        wire.roomMethods += ["groups.rename", "groups.disband"]
        var refused = false
        wire.roomCommand = { method, params in
            if refused { throw BotRoomFailure(code: 4090, reason: nil) }
            switch method {
            case "groups.rename":
                return .object(["room": .object(["room_id": .string("standup"), "name": params["name"] ?? .null,
                                                 "updated_at": .number(400)])])
            default:
                return .object(["tombstone": .object(["room_id": .string("standup"), "disbanded_at": .number(500)])])
            }
        }
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        let room = try XCTUnwrap(inbox.rooms.first)
        XCTAssertTrue(inbox.mayRenameRoom(room))
        inbox.setRoomPinned(true, room)

        await inbox.renameRoom(room, to: "Daily")
        XCTAssertEqual(inbox.rooms.first?.name, "Daily")
        XCTAssertNil(inbox.notice)

        refused = true
        await inbox.disbandRoom(try XCTUnwrap(inbox.rooms.first))
        XCTAssertEqual(inbox.rooms.count, 1, "a refused disband keeps the room")
        XCTAssertNotNil(inbox.notice)

        refused = false
        await inbox.disbandRoom(try XCTUnwrap(inbox.rooms.first))
        XCTAssertTrue(inbox.rooms.isEmpty)
        XCTAssertTrue(inbox.pinned.isEmpty, "the disbanded room's local marks go with it")
        XCTAssertEqual(wire.calls.map(\.0).filter { $0.hasPrefix("groups.rename") || $0.hasPrefix("groups.disband") },
                       ["groups.rename", "groups.disband", "groups.disband"])
    }

    func testRoomsUnderAnotherGatewayAreReadOnlyFromTheInbox() async throws {
        let wire = BotInboxFixtureWire(roster: [row("bot")])
        wire.rooms = [.object(["room_id": .string("standup"), "authority_gateway_id": .string("other")])]
        wire.roomMethods += ["groups.rename", "groups.disband"]
        wire.roomAuthority = "mine"
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        let room = try XCTUnwrap(inbox.rooms.first)
        XCTAssertFalse(inbox.mayRenameRoom(room))
        XCTAssertFalse(inbox.mayDisbandRoom(room))
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

    func testTransientServerErrorRetriesQuietlyBehindTheSkeleton() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.connectError = BotFailure.rejected(-32603)
        let second = BotInboxFixtureWire(roster: [row("triage")])
        let inbox = try makeInbox(wires: [wire, second])
        XCTAssertTrue(inbox.isLoadingRoster, "a saved connection shows the skeleton before the first open")
        await inbox.open()
        XCTAssertEqual(inbox.link, .disconnected)
        XCTAssertNil(inbox.errorMessage, "a server-side hiccup is not the user's problem")
        XCTAssertTrue(inbox.isLoadingRoster)
        await settle(inbox) { $0.link == .live }
        XCTAssertFalse(inbox.isLoadingRoster)
        XCTAssertEqual(inbox.profiles.map(\.id), ["triage"])
    }

    func testNotAHermesHostShowsTheMessageInsteadOfRetryingForever() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.connectError = BotFailure.rejected(404)
        var spare = 0
        let inbox = BotInbox(server: server, store: try connectedStore(), unread: BotUnreadStore(defaults: defaults),
                             avatarStore: BotAvatarStore(), reloadSpacing: .zero, reconnectDelays: [.zero]) { _ in
            spare += 1; return wire
        }
        await inbox.open()
        XCTAssertNotNil(inbox.errorMessage, "a permanent client error is the user's to fix")
        XCTAssertFalse(inbox.isLoadingRoster)
        await Task.yield(); await Task.yield()
        XCTAssertEqual(spare, 1, "no automatic retry after a 404")
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

    // MARK: - Live status

    func testLiveStatusFollowsTheRootOrTipAndTheMostUrgentMatchWins() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("a"), row("b"), row("c"), row("d"), row("e"),
            row("twin1", root: "shared-root"), row("twin2", root: "shared-root")
        ])
        wire.active = [
            live("a-tip", "working"), live("a-root", "waiting"),
            // Before the agent exists the key is the stored root.
            live("b-root", "starting"),
            live("c-tip", "streaming"),
            // Idle, a status this build does not know, and a missing key all read as nothing.
            live("d-root", "idle"), live("d-tip", "resuming"), live("d-tip", "compacting"),
            .object(["status": .string("working")]),
            // A key two bots share names neither; a key only one bot has still marks it.
            live("shared-root", "waiting"), live("twin1-tip", "working")
        ]
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        defer { inbox.close() }

        XCTAssertEqual(inbox.liveStatuses, ["a": .waiting, "b": .working, "c": .working, "twin1": .working])
        XCTAssertEqual(wire.calls.filter { $0.0 == "session.active_list" }.map(\.1), [[:]], "read-only, no parameters")
        XCTAssertEqual(inbox.link, .live)
    }

    func testATipRotatedAfterTheRosterReadMatchesNoBotUntilTheNextReload() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage", tip: "tip-1")])
        wire.active = [live("tip-1", "working")]
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        defer { inbox.close() }
        XCTAssertEqual(inbox.liveStatuses, ["triage": .working])

        wire.active = [live("tip-2", "working")]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.liveStatuses.isEmpty }

        wire.roster = [row("triage", tip: "tip-2")]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.liveStatuses == ["triage": .working] }
    }

    func testAHostWithoutActiveListKeepsTodaysInboxForTheLifeOfTheSocket() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage", preview: "one")])
        let inbox = try makeInbox(wires: [wire, wire])
        await inbox.open()
        XCTAssertEqual(inbox.link, .live)
        XCTAssertNil(inbox.errorMessage); XCTAssertNil(inbox.notice)
        XCTAssertEqual(inbox.liveStatuses, [:])
        XCTAssertEqual(wire.activeCalls, 1)

        wire.roster = [row("triage", preview: "two")]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.profiles.first?.preview == "two" }
        XCTAssertEqual(wire.activeCalls, 1, "method-not-found holds for this socket")

        await inbox.open()
        XCTAssertEqual(wire.activeCalls, 2, "a new socket asks again")
        inbox.close()
    }

    func testAStaleStatusReplyIsDroppedAfterANewerReload() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.active = [live("triage-tip", "working")]
        wire.configure = { _ in .object(["applied": .object(["ui_meta": .bool(true)])]) }
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        defer { inbox.close() }

        wire.holdsActive = true
        let parked = expectation(description: "event reload's status read parked")
        wire.onCall = { if $0 == "session.active_list" { parked.fulfill() } }
        wire.emit("sessions.changed")
        await fulfillment(of: [parked], timeout: 5)

        // A pin write re-reads the roster and statuses while the older read is parked.
        wire.onCall = nil
        wire.holdsActive = false
        wire.active = []
        await inbox.setPinned(true, inbox.profiles[0])
        await settle(inbox) { $0.liveStatuses.isEmpty }

        // The parked read now answers with what was true before; it must not land.
        wire.active = [live("triage-tip", "working")]
        let next = expectation(description: "the queued reload's status read")
        var seenAtNextRead: [String: BotLiveStatus]?
        wire.onCall = { method in
            guard method == "session.active_list", seenAtNextRead == nil else { return }
            seenAtNextRead = inbox.liveStatuses; wire.active = []; next.fulfill()
        }
        wire.emit("sessions.changed")
        wire.release()
        await fulfillment(of: [next], timeout: 5)
        XCTAssertEqual(seenAtNextRead, [:])
    }

    func testStatusesClearWhenTheSocketDropsAndWhenTheConnectionChanges() async throws {
        let store = try connectedStore()
        let first = BotInboxFixtureWire(roster: [row("triage")])
        first.active = [live("triage-tip", "waiting")]
        let second = BotInboxFixtureWire(roster: [row("triage")])
        second.active = [live("triage-tip", "waiting")]
        let third = BotInboxFixtureWire(roster: [row("triage")])
        third.holdsConnect = true
        let inbox = try makeInbox(wires: [first, second, third], store: store)
        await inbox.open()
        XCTAssertEqual(inbox.liveStatuses, ["triage": .waiting])

        first.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(inbox.liveStatuses, [:], "a dropped socket cannot vouch for any turn")
        XCTAssertEqual(inbox.profiles.map(\.id), ["triage"], "the roster stays")

        await settle(inbox) { $0.liveStatuses == ["triage": .waiting] }
        try store.save(BotConnection(id: UUID(), name: "Other", address: URL(string: "https://other.example")!,
                                     username: "u", password: "p", hermesVersion: nil), server: server)
        let reopened = Task { await inbox.open() }
        await settle(inbox) { $0.link == .connecting }
        XCTAssertEqual(inbox.liveStatuses, [:], "another connection's statuses never show")
        third.release()
        await reopened.value
        inbox.close()
    }

    func testEachGroupSortsWaitingThenWorkingThenUnreadThenNewest() async throws {
        let wire = BotInboxFixtureWire(roster: [
            row("p-idle", lastActive: 900, look: ["pinned": .bool(true)]),
            row("p-work", lastActive: 100, look: ["pinned": .bool(true)]),
            row("p-wait", lastActive: 50, look: ["pinned": .bool(true)]),
            row("o-idle", lastActive: 800, look: section("sec-ops", "Ops")),
            row("o-wait", lastActive: 10, look: section("sec-ops", "Ops")),
            row("u-new", lastActive: 700),
            row("u-unread", lastActive: 100),
            row("u-work", lastActive: 20)
        ])
        wire.rooms = [.object(["room_id": .string("standup"), "updated_at": .number(600)])]
        wire.active = []
        let inbox = try makeInbox(wires: [wire])
        await inbox.open()
        defer { inbox.close() }

        wire.roster[6] = row("u-unread", lastActive: 650)
        wire.active = [live("p-work-tip", "working"), live("p-wait-tip", "waiting"),
                       live("o-wait-tip", "waiting"), live("u-work-tip", "working")]
        wire.emit("sessions.changed")
        await settle(inbox) { $0.liveStatuses.count == 4 && $0.profiles[6].lastActive == Date(timeIntervalSince1970: 650) }

        XCTAssertEqual(inbox.pinned.map(\.id), ["bot:p-wait", "bot:p-work", "bot:p-idle"])
        XCTAssertEqual(inbox.sections.map { $0.chats.map(\.id) }, [
            ["bot:o-wait", "bot:o-idle"],
            // The room has no status or unread mark, so it ranks with idle bots.
            ["bot:u-work", "bot:u-unread", "bot:u-new", "room:standup"]
        ])
    }

    func testBusyBotsAreReReadUntilIdleWithoutARosterRead() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.active = [live("triage-tip", "working")]
        let inbox = try makeInbox(wires: [wire], statusPollInterval: .zero)
        await inbox.open()
        defer { inbox.close() }
        XCTAssertEqual(inbox.liveStatuses, ["triage": .working])

        // The turn ends with no `sessions.changed` after the last read.
        wire.active = []
        await settle(inbox) { $0.liveStatuses.isEmpty }
        let reads = wire.activeCalls
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(wire.activeCalls, reads, "an idle inbox stops re-reading")
        XCTAssertEqual(wire.listCalls, 1, "status re-reads never re-read the roster")
    }

    func testAFailedReReadWhileABotIsBusyTriesAgainUntilOneAnswers() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.active = [live("triage-tip", "working")]
        let inbox = try makeInbox(wires: [wire], statusPollInterval: .zero)
        await inbox.open()
        defer { inbox.close() }

        wire.failsActive = 2
        await settle(inbox) { $0.liveStatuses.isEmpty }
        await settle(inbox) { $0.liveStatuses == ["triage": .working] }
        XCTAssertEqual(inbox.link, .live, "a failed status read never drops the socket")
        XCTAssertEqual(wire.listCalls, 1, "the retry is a status read, not a roster read")
    }

    func testStatusReReadsStopWhenTheInboxCloses() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.active = [live("triage-tip", "working")]
        let inbox = try makeInbox(wires: [wire], statusPollInterval: .zero)
        await inbox.open()

        wire.holdsActive = true
        let parked = expectation(description: "re-read parked")
        wire.onCall = { if $0 == "session.active_list" { parked.fulfill() } }
        await fulfillment(of: [parked], timeout: 5)
        let reads = wire.activeCalls

        inbox.close()
        wire.onCall = nil
        wire.active = []
        wire.holdsActive = false
        wire.release()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(wire.activeCalls, reads, "no read after close")
        XCTAssertEqual(inbox.liveStatuses, ["triage": .working], "a closed inbox's late reply is dropped")
    }

    func testTheInboxGoesLiveWithRoomsWhileTheStatusReadIsStillOut() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.rooms = [.object(["room_id": .string("standup"), "updated_at": .number(600)])]
        wire.active = [live("triage-tip", "working")]
        wire.holdsActive = true
        let inbox = try makeInbox(wires: [wire])
        let opened = Task { await inbox.open() }
        defer { inbox.close() }

        await settle(inbox) { $0.link == .live }
        XCTAssertEqual(inbox.rooms.map(\.id), ["standup"])
        XCTAssertEqual(inbox.liveStatuses, [:])

        wire.release()
        await opened.value
        XCTAssertEqual(inbox.liveStatuses, ["triage": .working], "open ends once the statuses are in")
    }

    func testAReplacedStatusReReadNeverSendsItsRead() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.active = [live("triage-tip", "working")]
        let inbox = try makeInbox(wires: [wire], statusPollInterval: .zero)
        await inbox.open()
        defer { inbox.close() }

        // Event reloads keep replacing the zero-interval re-read, often just as its
        // sleep ends. A replaced re-read must neither send its read nor clear the rows.
        for _ in 0..<200 {
            wire.emit("sessions.changed")
            await Task.yield()
        }
        XCTAssertEqual(wire.cancelledCalls, 0)
        XCTAssertEqual(inbox.liveStatuses, ["triage": .working])
    }

    func testAFailedConnectionReadClearsTheStatusesAClosedInboxKept() async throws {
        let keychain = InMemoryKeychainStore()
        let store = BotConnectionStore(keychain: keychain)
        try store.save(BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!,
                                     username: "u", password: "p", hermesVersion: nil), server: server)
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.active = [live("triage-tip", "waiting")]
        let inbox = try makeInbox(wires: [wire], store: store)
        await inbox.open()
        inbox.close()
        XCTAssertEqual(inbox.liveStatuses, ["triage": .waiting], "leaving the screen keeps them")

        try keychain.save("{", forKey: .botConnection, scope: server.absoluteString)
        await inbox.open()
        XCTAssertEqual(inbox.link, .disconnected)
        XCTAssertNotNil(inbox.errorMessage)
        XCTAssertEqual(inbox.liveStatuses, [:], "no socket can vouch for them")
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

    /// Status re-reads default to an hour apart, so only a test that asks for them sees one.
    private func makeInbox(wires: [BotInboxFixtureWire], store: BotConnectionStore? = nil, server: URL? = nil,
                           statusPollInterval: Duration = .seconds(3600)) throws -> BotInbox {
        let server = server ?? self.server
        let store = try store ?? connectedStore(server: server)
        var queue = wires
        return BotInbox(server: server, store: store, unread: BotUnreadStore(defaults: defaults),
                        roomStore: BotRoomOrganizeStore(defaults: defaults),
                        sectionOrderStore: BotSectionOrderStore(defaults: defaults),
                        avatarStore: BotAvatarStore(), reloadSpacing: .zero, reconnectDelays: [.zero],
                        statusPollInterval: statusPollInterval) { _ in queue.removeFirst() }
    }

    private func connectedStore(server: URL? = nil) throws -> BotConnectionStore {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!,
                                     username: "u", password: "p", hermesVersion: nil), server: server ?? self.server)
        return store
    }

    /// A roster row whose canonical chat is `<name>-root`, resolved to `<name>-tip`, unless named.
    private func row(_ name: String, lastActive: Double? = 100, preview: String = "hi", root: String? = nil, tip: String? = nil,
                     look: [String: BotJSON]? = nil, revision: Int? = nil) -> BotJSON {
        var fields: [String: BotJSON] = [
            "name": .string(name), "display_name": .string(""), "description": .string(""), "has_avatar": .bool(false),
            "canonical_session": .object([
                "id": .string(root ?? name + "-root"), "resolved_id": .string(tip ?? name + "-tip"), "preview": .string(preview),
                "last_active": lastActive.map(BotJSON.number) ?? .null
            ])
        ]
        if let look { fields["ui_meta"] = .object(["hermes-bots": .object(look)]) }
        if let revision { fields["ui_meta_revisions"] = .object(["hermes-bots": .number(Double(revision))]) }
        return .object(fields)
    }

    /// One `session.active_list` item in the host's shape (`server.py` `_session_live_item`).
    private func live(_ key: String, _ status: String) -> BotJSON {
        .object(["id": .string("runtime-" + key), "session_key": .string(key), "status": .string(status),
                 "last_active": .number(100), "started_at": .number(90), "message_count": .number(2),
                 "model": .string("m"), "preview": .string(""), "title": .string("Bot Chat"), "current": .bool(false)])
    }

    /// The whole list under the tiles, flattened across sections.
    private func chatIDs(_ inbox: BotInbox) -> [String] { inbox.sections.flatMap(\.chats).map(\.id) }

    /// Desktop's `ui_meta["hermes-bots"]` for a bot filed under one section.
    private func section(_ id: String, _ name: String, _ extra: [String: BotJSON] = [:]) -> [String: BotJSON] {
        extra.merging(["sectionId": .string(id), "sectionName": .string(name)]) { $1 }
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

/// Answers `profiles.list` from `roster`, `session.active_list` from `active`,
/// `profiles.configure` from `configure`, and lets a test park a list or status
/// reply or push gateway events.
@MainActor final class BotInboxFixtureWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var roster: [BotJSON]
    var rooms: [BotJSON]?
    var roomMethods = ["groups.list", "groups.state", "groups.log"]
    var roomAuthority: String?
    /// Answers `groups.rename` and `groups.disband`.
    var roomCommand: ((String, [String: BotJSON]) throws -> BotJSON)?
    var configure: (([String: BotJSON]) -> BotJSON)?
    var delete: ((String) throws -> Void)?
    var deleted: [String] = []
    var calls: [(String, [String: BotJSON])] = []
    /// Calls made from an already cancelled task, which the real client refuses as stale.
    private(set) var cancelledCalls = 0
    var onCall: ((String) -> Void)?
    /// While true, `profiles.list` waits for `release()`.
    var holdsList = false
    /// Live runtimes for `session.active_list`; nil answers "method not found", as an older host does.
    var active: [BotJSON]?
    /// While true, `session.active_list` waits for `release()`, then answers from `active` as it is then.
    var holdsActive = false
    /// The next this many `session.active_list` calls fail as a transport error.
    var failsActive = 0
    /// While true, `connect()` waits for `release()`; `connectError` makes it throw instead.
    var holdsConnect = false
    var connectError: Error?
    private(set) var closed = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    init(roster: [BotJSON]) { self.roster = roster }

    var listCalls: Int { calls.filter { $0.0 == "profiles.list" }.count }
    var activeCalls: Int { calls.filter { $0.0 == "session.active_list" }.count }

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
        if Task.isCancelled { cancelledCalls += 1 }
        calls.append((method, params))
        onCall?(method)
        switch method {
        case "groups.capabilities":
            guard rooms != nil else { throw BotFailure.unsupported }
            var value: [String: BotJSON] = ["driver": .bool(true), "methods": .array(roomMethods.map(BotJSON.string))]
            if let roomAuthority { value["authority_gateway_id"] = .string(roomAuthority) }
            return .object(value)
        case "groups.rename", "groups.disband":
            guard let roomCommand else { throw BotFailure.unsupported }
            return try roomCommand(method, params)
        case "groups.list":
            return .object(["rooms": .array(rooms ?? [])])
        case "profiles.list":
            if holdsList { await withCheckedContinuation { held.append($0) } }
            return .object(["profiles": .array(roster), "bot_mode_protocol": .bool(true)])
        case "profiles.configure":
            guard let configure else { throw BotFailure.unsupported }
            return configure(params)
        case "session.active_list":
            if holdsActive { await withCheckedContinuation { held.append($0) } }
            if failsActive > 0 { failsActive -= 1; throw BotFailure.transport }
            guard let active else { throw BotFailure.rejected(-32601) }
            return .object(["sessions": .array(active)])
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
