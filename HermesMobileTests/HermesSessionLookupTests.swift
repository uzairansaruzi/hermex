import XCTest
@testable import HermesMobile

/// How a Hermes session link finds its stored session (#1176), on an in-memory host: one read
/// for a named Profile, the default Profile for `""`, every Profile for none, where one hit
/// opens, none is gone and two are ambiguous. A prefix match never counts, a legacy compression
/// chain is identified under its root, a Bot Chat opens in its bot and a room never opens.
@MainActor final class HermesSessionLookupTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")

    private func link(_ key: String, profile: String?) -> HermesSessionDestination {
        HermesSessionDestination(server: server, profile: profile, key: key)
    }

    /// A stored row as `GET /api/sessions/{id}` returns it: `profile` is the Profile asked.
    private func row(_ id: String, _ profile: String, title: String? = "Plan", parent: String? = nil,
                     endReason: String? = nil, hidden: Bool = false) -> BotJSON {
        .object(["id": .string(id), "source": .string("tui"), "title": title.map(BotJSON.string) ?? .null,
                 "parent_session_id": parent.map(BotJSON.string) ?? .null, "end_reason": endReason.map(BotJSON.string) ?? .null,
                 "hidden": .bool(hidden), "archived": .bool(false), "profile": .string(profile),
                 "is_default_profile": .bool(profile == "default")])
    }

    private func found(_ outcome: HermesSessionLookup.Outcome, file: StaticString = #filePath, line: UInt = #line) throws -> SessionSummary {
        guard case .found(let session) = outcome else {
            return try XCTUnwrap(nil, "Expected a session, got \(outcome)", file: file, line: line)
        }
        return session
    }

    func testANamedProfileReadsOnlyThatProfile() async throws {
        let wire = LookupWire()
        wire.rows = ["research": ["abc": row("abc", "research")], "default": ["abc": row("abc", "default")]]

        let session = try found(try await HermesSessionLookup.resolve(link("abc", profile: "research"), on: wire))

        XCTAssertEqual(session.sessionId, "abc")
        XCTAssertEqual(session.profile, "research")
        XCTAssertEqual(wire.reads, ["research/abc"])
        XCTAssertEqual(wire.methods, [], "A named Profile needs no Profile list")
    }

    /// `""` is the host's default Profile, whatever its name, as `profiles.list` marks it.
    func testAnEmptyProfileReadsTheHostsDefaultProfile() async throws {
        let wire = LookupWire()
        wire.profiles = [("research", false), ("main", true)]
        wire.rows = ["main": ["abc": row("abc", "main")]]

        let session = try found(try await HermesSessionLookup.resolve(link("abc", profile: ""), on: wire))

        XCTAssertEqual(session.profile, "main")
        XCTAssertEqual(wire.methods, ["profiles.list"])
        XCTAssertEqual(wire.reads, ["main/abc"])
    }

    func testAMissingProfileOpensTheOneProfileThatHasTheSession() async throws {
        let wire = LookupWire()
        wire.profiles = [("default", true), ("research", false), ("triage", false)]
        wire.rows = ["triage": ["abc": row("abc", "triage")]]

        let session = try found(try await HermesSessionLookup.resolve(link("abc", profile: nil), on: wire))

        XCTAssertEqual(session.profile, "triage")
        XCTAssertEqual(Set(wire.reads), ["default/abc", "research/abc", "triage/abc"])
    }

    func testAMissingProfileWithNoMatchIsGone() async throws {
        let wire = LookupWire()
        wire.profiles = [("default", true), ("research", false)]

        let outcome = try await HermesSessionLookup.resolve(link("abc", profile: nil), on: wire)

        XCTAssertEqual(outcome, .gone)
    }

    /// The same key under two Profiles opens nothing.
    func testAMissingProfileWithTwoMatchesIsAmbiguous() async throws {
        let wire = LookupWire()
        wire.profiles = [("default", true), ("research", false), ("triage", false)]
        wire.rows = ["default": ["abc": row("abc", "default")], "triage": ["abc": row("abc", "triage")]]

        let outcome = try await HermesSessionLookup.resolve(link("abc", profile: nil), on: wire)

        XCTAssertEqual(outcome, .ambiguous)
    }

    /// The host answers a key it doesn't have with the one session it prefixes; the link's key
    /// must come back as the row's `id`.
    func testAPrefixMatchIsNoMatch() async throws {
        let wire = LookupWire()
        wire.profiles = [("default", true), ("research", false)]
        wire.rows = ["research": ["abc": row("abcdef", "research")], "default": ["abc": row("abc", "default")]]

        let named = try await HermesSessionLookup.resolve(link("abc", profile: "research"), on: wire)
        let probed = try found(try await HermesSessionLookup.resolve(link("abc", profile: nil), on: wire))

        XCTAssertEqual(named, .gone)
        XCTAssertEqual(probed.profile, "default", "Only the exact match counts, so the probe is not ambiguous")
    }

    /// A legacy compression chain: the link names its tip, whose parents ended in compression.
    /// The chat opens by the link's key and caches under the chain's root, as the list row does;
    /// a parent that ended otherwise (a branch's) is not the chain.
    func testACompressedSessionIsIdentifiedUnderItsLineageRoot() async throws {
        let wire = LookupWire()
        wire.rows = ["research": [
            "tip": row("tip", "research", title: nil, parent: "middle"),
            "middle": row("middle", "research", title: nil, parent: "root", endReason: "compression"),
            "root": row("root", "research", title: "Planning", parent: "forked-from", endReason: "compression"),
            "forked-from": row("forked-from", "research", endReason: "user_exit")
        ]]

        let session = try found(try await HermesSessionLookup.resolve(link("tip", profile: "research"), on: wire))
        let chat = try XCTUnwrap(session.hermesChat(on: server, connection: connection, listedIn: "research"))

        XCTAssertEqual(session.hermes?.lineageRoot, "root")
        XCTAssertEqual(session.title, "Planning", "An untitled tip shows its root's title, as the list does")
        XCTAssertEqual(chat.target, .session(profile: "research", key: "tip"))
        XCTAssertEqual(chat.lineageRoot, "root")
        XCTAssertEqual(chat.parentKey, "middle")
        XCTAssertEqual(wire.reads, ["research/tip", "research/middle", "research/root", "research/forked-from"])
    }

    func testTheLineageWalkStopsAfterEightHops() async throws {
        let wire = LookupWire()
        var rows = ["s0": row("s0", "research", parent: "s1")]
        for hop in 1...12 { rows["s\(hop)"] = row("s\(hop)", "research", parent: "s\(hop + 1)", endReason: "compression") }
        wire.rows = ["research": rows]

        let session = try found(try await HermesSessionLookup.resolve(link("s0", profile: "research"), on: wire))

        XCTAssertEqual(session.hermes?.lineageRoot, "s8")
        XCTAssertEqual(wire.reads.count, 9)
    }

    /// A bot's Bot Chat opens through the bot route, so one chat keeps one screen (#1146).
    func testABotChatOpensInItsBot() async throws {
        let wire = LookupWire()
        wire.rows = ["inbox-triage": ["abc": row("abc", "inbox-triage", title: HermesCall.botChatTitle, hidden: true)]]

        let session = try found(try await HermesSessionLookup.resolve(link("abc", profile: "inbox-triage"), on: wire))

        XCTAssertEqual(session.hermesBot(on: server, connectionID: connection.id),
                       BotDestination(server: server, connectionID: connection.id, profile: "inbox-triage"))
    }

    func testARoomSessionNeverOpens() async throws {
        let wire = LookupWire()
        wire.rows = ["default": ["abc": row("abc", "default", title: "Group: room-7", hidden: true)]]

        let outcome = try await HermesSessionLookup.resolve(link("abc", profile: "default"), on: wire)

        XCTAssertEqual(outcome, .room)
    }

    /// A subagent's push opens the session that delegated to it, one hop up, found in the
    /// child's Profile; a parent that is gone is gone, and a child naming none opens itself (#1177).
    func testASubagentLinkOpensItsParent() async throws {
        let wire = LookupWire()
        wire.profiles = [("default", true), ("research", false)]
        wire.rows = ["research": [
            "child": row("child", "research", title: "Subtask", parent: "parent"),
            "parent": row("parent", "research", title: "Planning", parent: "grandparent"),
            "orphan": row("orphan", "research", title: "Subtask", parent: "deleted"),
            "solo": row("solo", "research", title: "Solo")
        ]]
        func resolve(_ key: String) async throws -> HermesSessionLookup.Outcome {
            try await HermesSessionLookup.resolve(
                HermesSessionDestination(server: server, profile: nil, key: key, opensParent: true), on: wire)
        }

        let parent = try found(try await resolve("child"))
        XCTAssertEqual(parent.sessionId, "parent")
        XCTAssertEqual(parent.title, "Planning")
        XCTAssertEqual(parent.profile, "research")
        let solo = try found(try await resolve("solo"))
        XCTAssertEqual(solo.sessionId, "solo")
        let gone = try await resolve("orphan")
        XCTAssertEqual(gone, .gone)
    }

    /// A Profile that can't be read leaves the link unproven: nothing opens, and the failure
    /// (here a store the host can't read) reaches the caller, which drops the link.
    func testAProbeThatFailsOpensNothing() async throws {
        let wire = LookupWire()
        wire.profiles = [("default", true), ("research", false)]
        wire.rows = ["default": ["abc": row("abc", "default")]]
        wire.failures = ["research": BotFailure.rejected(503)]

        do {
            let outcome = try await HermesSessionLookup.resolve(link("abc", profile: nil), on: wire)
            XCTFail("Expected the failure, got \(outcome)")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(503))
        }
    }

    /// The default Profile the host doesn't mark is no Profile to guess at.
    func testAnEmptyProfileWithoutADefaultOpensNothing() async throws {
        let wire = LookupWire()
        wire.profiles = [("research", false)]
        wire.rows = ["research": ["abc": row("abc", "research")]]

        do {
            let outcome = try await HermesSessionLookup.resolve(link("abc", profile: ""), on: wire)
            XCTFail("Expected a failure, got \(outcome)")
        } catch {
            XCTAssertEqual(wire.reads, [])
        }
    }
}

/// A Hermes host's stored rows by Profile, keyed by the key a read asks for: a row whose `id`
/// differs stands for the host's prefix match. `failures` refuses a Profile's reads.
@MainActor private final class LookupWire: BotTransport {
    var profiles: [(name: String, isDefault: Bool)] = []
    var rows: [String: [String: BotJSON]] = [:]
    var failures: [String: Error] = [:]
    /// Each row read, as `<profile>/<key>`, in order.
    private(set) var reads: [String] = []
    /// Each socket call's method, in order.
    private(set) var methods: [String] = []

    var replayEpoch: String? { nil }
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    func connect() async throws {}
    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        methods.append(call.method)
        guard case .profilesList(includeSessions: false) = call else { throw BotFailure.unsupported }
        return .object(["profiles": .array(profiles.map { .object(["name": .string($0.name), "is_default": .bool($0.isDefault)]) })])
    }

    func sessionRow(key: String, profile: String) async throws -> BotJSON? {
        reads.append("\(profile)/\(key)")
        if let failure = failures[profile] { throw failure }
        return rows[profile]?[key]
    }
}
