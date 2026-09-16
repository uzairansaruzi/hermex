import XCTest
@testable import HermesMobile

/// Creating, duplicating and deleting bots: the host writes, their order, what a
/// retry repeats, and what the phone forgets after a delete.
@MainActor final class BotLifecycleTests: XCTestCase {
    private let server = URL(string: "https://one.example")!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "BotLifecycleTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Names

    func testProfileNamesFollowTheHostRules() {
        XCTAssertEqual(BotProfileName.slug(from: "  Chief of Staff! "), "chief-of-staff")
        XCTAssertEqual(BotProfileName.slug(from: "Émilie's Bot 2"), "emilie-s-bot-2")
        XCTAssertEqual(BotProfileName.slug(from: "---"), "")
        XCTAssertEqual(BotProfileName.slug(from: String(repeating: "a", count: 80)).count, 64)
        XCTAssertTrue(BotProfileName.isValid("home-hunter_2"))
        XCTAssertFalse(BotProfileName.isValid("default"), "the built-in Profile cannot be created")
        XCTAssertFalse(BotProfileName.isValid("hermes"), "reserved by the host")
        XCTAssertFalse(BotProfileName.isValid("-lead"), "must start with a letter or digit")
        XCTAssertFalse(BotProfileName.isValid("Chief"), "the host lowercases; the slug already did")
        XCTAssertFalse(BotProfileName.isValid(""))
    }

    func testTakenAndReservedNamesBlockCreateBeforeAnyWrite() throws {
        let (creator, wire) = try makeCreator(roster: [row("triage")])
        creator.setTitle("Triage")
        XCTAssertFalse(creator.canCreate)
        XCTAssertEqual(creator.nameProblem, "A bot named “triage” already exists on this Hermes.")
        creator.setTitle("Default")
        XCTAssertFalse(creator.canCreate)
        XCTAssertNotNil(creator.nameProblem)
        creator.setTitle("Home Hunter")
        XCTAssertTrue(creator.canCreate)
        XCTAssertNil(creator.nameProblem)
        XCTAssertEqual(wire.calls.map(\.0), [])
    }

    // MARK: - Create

    func testCreateWritesProfileLookAndChatInOrder() async throws {
        var created: [String] = []
        let (creator, wire) = try makeCreator(roster: []) { created.append($0) }
        creator.setTitle("Home Hunter")
        creator.setRole("Finds apartments")
        creator.setShape(.hexagon); creator.setColor("#f97316"); creator.setExpression(.happy)
        creator.setModel(ModelCatalogOption(id: "gpt-6", displayName: "gpt-6", providerID: "openai"))

        await creator.create()

        XCTAssertEqual(wire.calls.map(\.0), ["profiles.create", "profiles.configure", "session.list", "session.create", "session.title"])
        let create = wire.calls[0].1
        XCTAssertEqual(create["name"], .string("home-hunter"))
        XCTAssertEqual(create["description"], .string("Finds apartments"))
        XCTAssertEqual(create["model"], .string("gpt-6")); XCTAssertEqual(create["provider"], .string("openai"))
        XCTAssertEqual(create["share_auth"], .bool(true), "sharing is the default; nothing is copied")
        XCTAssertNil(create["mirror_credentials"]); XCTAssertNil(create["clone_from"])
        let look = wire.calls[1].1
        XCTAssertEqual(look["name"], .string("home-hunter"))
        XCTAssertEqual(look["ui_meta_expected_revisions"], .object(["hermes-bots": .number(0)]))
        XCTAssertEqual(look["ui_meta"]?["hermes-bots"].fields, [
            "title": .string("Home Hunter"), "shape": .string("hexagon"), "color": .string("#f97316"),
            "expression": .string("happy"), "custom": .bool(true), "imageKind": .string("shape")
        ])
        XCTAssertEqual(wire.calls[3].1, ["profile": .string("home-hunter"), "title": .string("Bot Chat"),
                                         "hidden": .bool(true), "follow_profile_config": .bool(true)])
        XCTAssertEqual(wire.calls[4].1, ["session_id": .string("runtime-1"), "title": .string("Bot Chat")])
        XCTAssertEqual(creator.phase, .created)
        XCTAssertEqual(created, ["home-hunter"])
        XCTAssertNil(creator.note)
    }

    func testDuplicateClonesTheSourceAndCopiesItsLookNotItsChat() async throws {
        let source = try XCTUnwrap(BotProfile(row("triage", look: ["title": .string("Triage"), "shape": .string("drop"), "color": .string("#14b8a6"),
                                                                     "sectionId": .string("desk"), "pinned": .bool(true)], description: "Sorts mail")))
        let (creator, wire) = try makeCreator(roster: [row("triage")], source: source)
        XCTAssertEqual(creator.draft.title, "Triage copy")
        XCTAssertEqual(creator.name, "triage-copy")
        XCTAssertEqual(creator.draft.role, "Sorts mail")
        creator.setSharesCredentials(false)

        await creator.create()

        let create = wire.calls[0].1
        XCTAssertEqual(create["clone_from"], .string("triage"))
        XCTAssertEqual(create["mirror_credentials"], .bool(false))
        XCTAssertNil(create["share_auth"])
        let look = try XCTUnwrap(wire.calls[1].1["ui_meta"]?["hermes-bots"].fields)
        XCTAssertEqual(look["shape"], .string("drop")); XCTAssertEqual(look["color"], .string("#14b8a6"))
        XCTAssertEqual(look["title"], .string("Triage copy"))
        XCTAssertNil(look["sectionId"]); XCTAssertNil(look["pinned"], "Desktop organization stays with the original")
        XCTAssertEqual(wire.calls[3].1["profile"], .string("triage-copy"), "the copy gets its own Bot Chat")
        XCTAssertEqual(creator.phase, .created)
    }

    func testHostRefusingTheNameStopsBeforeLookAndChat() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        wire.create = { _ in throw BotFailure.rejected(4062) }
        creator.setTitle("Fresh")

        await creator.create()

        XCTAssertEqual(wire.calls.map(\.0), ["profiles.create"])
        XCTAssertEqual(creator.outcomes[.profile], .failed("Hermes refused this name. It may already exist on the host."))
        XCTAssertNil(creator.outcomes[.look]); XCTAssertNil(creator.outcomes[.chat])
        XCTAssertEqual(creator.phase, .editing)
        XCTAssertTrue(creator.canCreate, "the user can try again after fixing things on the host")
    }

    func testPartialCreateRetriesOnlyTheStepsThatAreNotDone() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        wire.configure = { _ in throw BotFailure.rejected(5064) }
        wire.sessionCreate = { _ in throw BotFailure.rejected(5001) }

        await creator.create()
        XCTAssertEqual(creator.outcomes[.profile], .done)
        XCTAssertEqual(creator.outcomes[.look], .failed("The look was not saved. Edit the bot to set it."))
        guard case .failed = creator.outcomes[.chat] else { return XCTFail("chat step should have failed") }
        XCTAssertEqual(creator.phase, .editing)
        XCTAssertTrue(creator.hasStarted); XCTAssertTrue(creator.canCreate)
        XCTAssertNil(creator.nameProblem, "the name is committed to the bot that now exists")

        wire.configure = nil; wire.sessionCreate = nil
        wire.calls = []
        await creator.create()

        XCTAssertEqual(wire.calls.map(\.0), ["profiles.configure", "session.list", "session.create", "session.title"],
                       "no second profiles.create")
        XCTAssertEqual(creator.outcomes, [.profile: .done, .look: .done, .chat: .done])
        XCTAssertEqual(creator.phase, .created)
    }

    func testLostReplyMakesTheRetryReadTheHostBeforeCreatingAgain() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        wire.create = { _ in throw BotFailure.transport }

        await creator.create()
        XCTAssertEqual(creator.outcomes[.profile], .uncertain)
        XCTAssertEqual(creator.phase, .editing)

        // The host did create it; the retry must find it instead of minting a twin.
        wire.roster = [row("fresh")]
        wire.create = { _ in XCTFail("no second create"); return .null }
        wire.calls = []
        await creator.create()

        XCTAssertEqual(wire.calls.map(\.0), ["profiles.list", "profiles.configure", "session.list", "session.create", "session.title"])
        XCTAssertEqual(creator.phase, .created)
    }

    func testExistingBotChatIsAdoptedNeverMinted() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        wire.sessions = [.object(["id": .string("root"), "resolved_id": .string("tip")])]

        await creator.create()

        XCTAssertEqual(wire.calls.map(\.0), ["profiles.create", "profiles.configure", "session.list"])
        XCTAssertEqual(creator.outcomes[.chat], .done)
    }

    func testTitleTakenByAnotherWriterAdoptsTheirChat() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        wire.title = { _ in
            wire.sessions = [.object(["id": .string("theirs"), "resolved_id": .string("theirs")])]
            throw BotFailure.rejected(4022)
        }

        await creator.create()

        XCTAssertEqual(wire.calls.map(\.0), ["profiles.create", "profiles.configure", "session.list", "session.create", "session.title", "session.list"])
        XCTAssertEqual(creator.phase, .created)
    }

    func testMissingModelAfterCreateIsNotedNotHidden() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        wire.create = { _ in .object(["ok": .bool(true), "name": .string("fresh"), "model_set": .bool(false),
                                      "mirrored": .object(["env": .bool(false), "auth": .bool(false), "model_inherited": .bool(false)])]) }

        await creator.create()

        XCTAssertEqual(creator.phase, .created)
        XCTAssertEqual(creator.note, "No model is set for this bot yet. Pick one in Edit or in Hermes Desktop before chatting.")
    }

    func testReplacedConnectionAbortsBeforeAnyWrite() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!,
                                     username: "u", password: "p", hermesVersion: nil), server: server)
        let (creator, wire) = try makeCreator(roster: [], store: store)
        creator.setTitle("Fresh")
        // The user re-pointed the Bot connection while the sheet was open.
        try store.save(BotConnection(id: UUID(), name: "Other", address: URL(string: "https://other.example")!,
                                     username: "u", password: "p", hermesVersion: nil), server: server)

        await creator.create()

        XCTAssertEqual(wire.calls.map(\.0), [])
        guard case .failed = creator.outcomes[.profile] else { return XCTFail("expected a stale failure") }
        XCTAssertEqual(creator.phase, .editing)
    }

    func testDisconnectDuringCreateReleasesTheSheetWithAnUncertainStep() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        // BotClient closes and reports the disconnect before the suspended call throws.
        wire.create = { _ in
            wire.onDisconnect?(BotFailure.transport)
            throw BotFailure.transport
        }

        await creator.create()

        XCTAssertEqual(creator.phase, .editing, "the spinner must not stay up")
        XCTAssertEqual(creator.outcomes[.profile], .uncertain)
        XCTAssertTrue(creator.canCreate)
    }

    func testCreateWithLeftoversStaysUpAndACleanOneIsComplete() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        wire.configure = { _ in throw BotFailure.rejected(5064) }
        await creator.create()
        XCTAssertEqual(creator.phase, .created)
        XCTAssertTrue(creator.needsAttention, "a look that did not save is worth reading before Done")

        let (clean, _) = try makeCreator(roster: [])
        clean.setTitle("Fresh")
        await clean.create()
        XCTAssertEqual(clean.phase, .created)
        XCTAssertFalse(clean.needsAttention)
    }

    func testLeavingMidCreateMarksPendingStepsUncertain() async throws {
        let (creator, wire) = try makeCreator(roster: [])
        creator.setTitle("Fresh")
        wire.holdsCreate = true
        let parked = expectation(description: "create parked")
        wire.onCall = { if $0 == "profiles.create" { parked.fulfill() } }
        let run = Task { await creator.create() }
        await fulfillment(of: [parked], timeout: 5)

        creator.close()
        wire.release()
        await run.value

        XCTAssertEqual(creator.outcomes, [.profile: .uncertain, .look: .uncertain, .chat: .uncertain])
        XCTAssertEqual(creator.phase, .editing)
        XCTAssertEqual(wire.calls.map(\.0), ["profiles.create"], "the late reply wrote nothing")
    }

    // MARK: - Delete

    func testDeleteRemovesTheHostProfileThenLocalStateAndRereadsTheRoster() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage"), row("keep")])
        wire.delete = { _ in wire.roster = [self.row("keep")] }
        var purged: [(UUID, String)] = []
        let inbox = try makeInbox(wires: [wire]) { purged.append(($0, $1)) }
        await inbox.open()
        let triage = inbox.profiles[0]
        XCTAssertTrue(inbox.mayDelete(triage))

        await inbox.delete(triage)

        XCTAssertEqual(wire.deleted, ["triage"])
        XCTAssertEqual(purged.map(\.1), ["triage"])
        XCTAssertEqual(purged.first?.0, inbox.connection?.id)
        XCTAssertEqual(inbox.profiles.map(\.id), ["keep"])
        XCTAssertNil(inbox.notice)
        XCTAssertEqual(BotUnreadStore(defaults: defaults).load(connectionID: inbox.connection!.id).keys.sorted(), ["keep"])
    }

    func testDefaultProfileCannotBeDeleted() async throws {
        let wire = BotInboxFixtureWire(roster: [row("default")])
        wire.delete = { _ in XCTFail("never sent") }
        var purged = 0
        let inbox = try makeInbox(wires: [wire]) { _, _ in purged += 1 }
        await inbox.open()
        XCTAssertFalse(inbox.mayDelete(inbox.profiles[0]))
        await inbox.delete(inbox.profiles[0])
        XCTAssertEqual(wire.deleted, []); XCTAssertEqual(purged, 0)
    }

    func testRefusedAndLostDeletesKeepThePhoneState() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage")])
        wire.delete = { _ in throw BotFailure.rejected(400) }
        var purged = 0
        let inbox = try makeInbox(wires: [wire]) { _, _ in purged += 1 }
        await inbox.open()

        await inbox.delete(inbox.profiles[0])
        XCTAssertEqual(inbox.notice, "Hermes did not delete this bot. It is still on the host.")
        XCTAssertEqual(inbox.profiles.map(\.id), ["triage"]); XCTAssertEqual(purged, 0)
        XCTAssertTrue(inbox.mayEdit(inbox.profiles[0]))

        wire.delete = { _ in throw BotFailure.transport }
        await inbox.delete(inbox.profiles[0])
        XCTAssertEqual(inbox.notice, "Could not confirm whether the bot was deleted. Pull down to refresh.")
        XCTAssertEqual(purged, 0)
        XCTAssertEqual(wire.listCalls, 1, "no automatic retry or re-read")

        // The bot survived: the next roster read keeps its local state.
        wire.emit("sessions.changed")
        await settle(inbox) { $0.profiles.map(\.id) == ["triage"] && wire.listCalls == 2 }
        XCTAssertEqual(purged, 0)
    }

    func testLostDeleteReplyIsSettledByTheNextRosterRead() async throws {
        let wire = BotInboxFixtureWire(roster: [row("triage"), row("keep")])
        wire.delete = { _ in wire.roster = [self.row("keep")]; throw BotFailure.transport }
        var purged: [String] = []
        let inbox = try makeInbox(wires: [wire]) { purged.append($1) }
        await inbox.open()

        await inbox.delete(inbox.profiles[0])
        XCTAssertEqual(purged, [], "nothing is dropped on a guess")

        wire.emit("sessions.changed")
        await settle(inbox) { $0.profiles.map(\.id) == ["keep"] }
        XCTAssertEqual(purged, ["triage"], "the host confirmed the bot is gone, so its drafts and cache go too")
        XCTAssertEqual(BotUnreadStore(defaults: defaults).load(connectionID: inbox.connection!.id).keys.sorted(), ["keep"])
    }

    // MARK: - Helpers

    private func makeCreator(roster: [BotJSON], source: BotProfile? = nil, store: BotConnectionStore? = nil,
                             onCreated: @escaping (String) -> Void = { _ in }) throws -> (BotCreator, BotLifecycleFixtureWire) {
        let store = try store ?? {
            let store = BotConnectionStore(keychain: InMemoryKeychainStore())
            try store.save(BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!,
                                         username: "u", password: "p", hermesVersion: nil), server: server)
            return store
        }()
        let connection = try XCTUnwrap(store.load(server: server))
        let wire = BotLifecycleFixtureWire(roster: roster)
        let creator = BotCreator(server: server, connection: connection, roster: roster.compactMap(BotProfile.init),
                                 source: source, store: store, makeWire: { _ in wire }, onCreated: onCreated)
        return (creator, wire)
    }

    /// Waits for `condition` through Observation rather than sleeping.
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

    private func makeInbox(wires: [BotInboxFixtureWire], purge: @escaping @MainActor (UUID, String) async -> Void) throws -> BotInbox {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!,
                                     username: "u", password: "p", hermesVersion: nil), server: server)
        var queue = wires
        return BotInbox(server: server, store: store, unread: BotUnreadStore(defaults: defaults),
                        avatarStore: BotAvatarStore(), reloadSpacing: .zero, reconnectDelays: [.zero],
                        makeWire: { _ in queue.removeFirst() }, purgeLocalState: purge)
    }

    private func row(_ name: String, look: [String: BotJSON]? = nil, description: String = "") -> BotJSON {
        var fields: [String: BotJSON] = [
            "name": .string(name), "display_name": .string(""), "description": .string(description), "has_avatar": .bool(false),
            "canonical_session": .object(["id": .string("root"), "resolved_id": .string("tip"), "preview": .string("hi"), "last_active": .number(100)])
        ]
        if let look { fields["ui_meta"] = .object(["hermes-bots": .object(look)]); fields["ui_meta_revisions"] = .object(["hermes-bots": .number(3)]) }
        return .object(fields)
    }
}

/// Answers the create flow's calls with overridable handlers and lets a test park
/// `profiles.create` to leave the screen mid-write.
@MainActor final class BotLifecycleFixtureWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var roster: [BotJSON]
    var sessions: [BotJSON] = []
    var create: (([String: BotJSON]) throws -> BotJSON)?
    var configure: (([String: BotJSON]) throws -> BotJSON)?
    var sessionCreate: (([String: BotJSON]) throws -> BotJSON)?
    var title: (([String: BotJSON]) throws -> BotJSON)?
    var calls: [(String, [String: BotJSON])] = []
    var onCall: ((String) -> Void)?
    var holdsCreate = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(roster: [BotJSON]) { self.roster = roster }

    func connect() async throws {}
    func close() {}

    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append((method, params))
        onCall?(method)
        switch method {
        case "model.options": return .object(["providers": .array([])])
        case "profiles.list": return .object(["profiles": .array(roster)])
        case "profiles.create":
            if holdsCreate { await withCheckedContinuation { held.append($0) } }
            try validateDispatch?()
            if let create { return try create(params) }
            return .object(["ok": .bool(true), "name": params["name"] ?? .null, "model_set": .bool(true),
                            "mirrored": .object(["auth": .string("shared")])])
        case "profiles.configure":
            if let configure { return try configure(params) }
            return .object(["ok": .bool(true), "applied": .object(["ui_meta": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(1)])])])
        case "session.list": return .object(["sessions": .array(sessions)])
        case "session.create":
            if let sessionCreate { return try sessionCreate(params) }
            return .object(["session_id": .string("runtime-1"), "stored_session_id": .string("stored-1")])
        case "session.title":
            if let title { return try title(params) }
            return .object(["pending": .bool(false), "title": .string("Bot Chat")])
        default: throw BotFailure.unsupported
        }
    }

    func release() {
        let waiting = held; held = []
        for continuation in waiting { continuation.resume() }
    }
}
