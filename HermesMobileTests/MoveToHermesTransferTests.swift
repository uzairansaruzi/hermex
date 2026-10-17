import XCTest
@testable import HermesMobile

/// Move to Hermes's scan and copy (#1213) against scripted hosts: the webui through
/// `MoveWebuiFixture`, Hermes through `HermesHostFixture`. The export fixture follows the webui's
/// redacted `Session.__dict__` at c67fd2dd and is hand-made, not captured.
@MainActor
final class MoveToHermesTransferTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MoveToHermes")
    private let webuiURL = URL(string: "https://webui.example")!
    /// The scripted Hermes host: what each Profile holds, what its listing shows, and its answers.
    private var host = FakeHermes()

    override func tearDown() {
        MoveWebuiFixture.reset()
        HermesHostFixture.reset()
        super.tearDown()
    }

    // MARK: Conversion

    /// The import row keeps the id, content as exported (redaction and image parts included) and
    /// the webui's counters dated by `created_at`, and drops the title, folder, pin, system and
    /// webui-only fields.
    func testConversionKeepsTheExportsContentAndWebuiCounters() throws {
        let export = try fixture("webui-export")
        let row = try XCTUnwrap(WebuiSessionTransfer.importRow(fromExport: export, id: "a1b2c3d4e5f6"))

        XCTAssertEqual(row, try fixture("import-row"))
        XCTAssertNil(WebuiSessionTransfer.importRow(fromExport: export, id: "another"), "An export of another chat is unreadable")
    }

    /// A chat past 10,000 messages or 5 MB is reported, never trimmed; batches stay under 500
    /// sessions, 50,000 messages and 25 MB.
    func testLimits() {
        func export(messages: Int, text: String = "hi") -> Data {
            let rows = Array(repeating: BotJSON.object(["role": .string("user"), "content": .string(text)]), count: messages)
            return try! JSONEncoder().encode(BotJSON.object(["session_id": .string("x"), "messages": .array(rows)]))
        }
        XCTAssertEqual(WebuiSessionTransfer.prepare(export: export(messages: 10_001), id: "x"), .failed(.oversized))
        XCTAssertEqual(WebuiSessionTransfer.prepare(export: export(messages: 1, text: String(repeating: "a", count: 5 * 1024 * 1024)), id: "x"),
                       .failed(.oversized))
        guard case .ready(let small) = WebuiSessionTransfer.prepare(export: export(messages: 10_000), id: "x") else {
            return XCTFail("10,000 messages fit")
        }

        let tiny = WebuiSessionTransfer.Prepared(id: "t", encoded: Data("{}".utf8), messageCount: 1)
        XCTAssertTrue(WebuiSessionTransfer.fits(Array(repeating: tiny, count: 500), destination: "default"))
        XCTAssertFalse(WebuiSessionTransfer.fits(Array(repeating: tiny, count: 501), destination: "default"))
        XCTAssertTrue(WebuiSessionTransfer.fits(Array(repeating: small, count: 5), destination: "default"))
        XCTAssertFalse(WebuiSessionTransfer.fits(Array(repeating: small, count: 6), destination: "default"), "60,000 messages")
        let big = WebuiSessionTransfer.Prepared(id: "b", encoded: Data(count: 13 * 1024 * 1024), messageCount: 1)
        XCTAssertFalse(WebuiSessionTransfer.fits([big, big], destination: "default"), "26 MB")
    }

    // MARK: Scan

    /// Each Profile is paged until the host's `total`, past 500 rows and despite every page's pinned
    /// back-fill, and only ids no listing showed are read, each in every Profile, by exact id.
    func testScanPagesPastFiveHundredAndReadsOnlyUnlistedIDs() async throws {
        let many = (0..<650).map { "row\($0)" }
        host.listed = ["default": many + ["pinned"], "research": []]
        host.held = ["default": Set(many + ["pinned", "hidden"]), "research": []]
        host.prefixMatches = ["pre": "pre_longer"]
        MoveWebuiFixture.rows = ["row7", "row649", "pinned", "hidden", "gone", "pre"].map { ["session_id": .string($0)] }
        let hermes = try await hermesClient()
        var located: [Int] = []

        let result = try await MoveToHermesScan.run(webui: webuiClient(), hermes: hermes, hermesProfiles: ["default", "research"]) {
            located.append($0)
            XCTAssertEqual($1, 6)
        }

        XCTAssertEqual(result.entries.map(\.location), [
            .present(profile: "default"), .present(profile: "default"), .present(profile: "default"),
            .present(profile: "default"), .missing, .missing
        ])
        XCTAssertNil(result.onlyProfile)
        XCTAssertEqual(located.last, 6)
        let pages = HermesHostFixture.requests.filter { $0.url?.path == "/api/sessions" && Self.query($0, "profile") == "default" }
        XCTAssertEqual(pages.compactMap { Self.query($0, "offset") }, ["0", "100", "200", "300", "400", "500", "600"])
        XCTAssertEqual(Self.query(pages[0], "archived"), "include")
        XCTAssertNil(Self.query(pages[0], "exclude_sources"), "Machine-run rows count as present")
        let reads = HermesHostFixture.requests.compactMap { Self.rowRead($0) }
        XCTAssertEqual(Set(reads.map(\.id)), ["hidden", "gone", "pre"])
        XCTAssertEqual(reads.count, 6, "Each unlisted id is read in both Profiles")
        XCTAssertEqual(MoveWebuiFixture.requests.map { $0.url?.path }, ["/api/sessions"], "The scan never switches Profiles")
        XCTAssertEqual(Self.query(MoveWebuiFixture.requests[0], "all_profiles"), "1")
        XCTAssertFalse(HermesHostFixture.requests.contains { $0.url?.path.contains("pairing") == true }, "No pairing check")
    }

    /// A failed read leaves an id unknown, never absent; two Profiles holding it is ambiguous. An id
    /// one listing showed is still read in a Profile whose listing failed.
    func testFailedReadsAreUnknownAndTwoMatchesAreAmbiguous() async throws {
        host.listed = ["default": ["dup", "listed"], "research": ["dup"]]
        host.failedListings = ["triage"]
        host.held = ["default": ["dup", "listed"], "research": ["dup"], "triage": []]
        host.failures = ["flaky": .json(500, .object(["detail": .string("boom")])), "late": .fail(URLError(.timedOut))]
        MoveWebuiFixture.rows = ["dup", "listed", "flaky", "late"].map { ["session_id": .string($0), "profile": .string("research")] }
        MoveWebuiFixture.allProfiles = false
        let hermes = try await hermesClient()

        let result = try await MoveToHermesScan.run(webui: webuiClient(), hermes: hermes, hermesProfiles: ["default", "research", "triage"])

        XCTAssertEqual(result.entries.map(\.location), [
            .ambiguous(profiles: ["default", "research"]), .present(profile: "default"), .unknown, .unknown
        ])
        XCTAssertEqual(result.onlyProfile, "research", "The webui ignored all_profiles")
        let reads = HermesHostFixture.requests.compactMap { Self.rowRead($0) }
        XCTAssertTrue(reads.contains { $0 == ("listed", "triage") })
        XCTAssertFalse(reads.contains { $0 == ("listed", "research") })
    }

    /// With CLI and Claude Code rows shown, the scan keeps only the webui's own chats, cron and
    /// webhook runs included: external rows aren't counted, read on Hermes or treated as running.
    /// A webui chat with a stale CLI flag stays.
    /// Row shapes follow the webui's `get_cli_sessions` and Claude Code rows at c67fd2dd.
    func testScanSkipsCLIAndExternalAgentRows() async throws {
        host.listed = ["default": []]
        host.held = ["default": []]
        MoveWebuiFixture.rows = [
            ["session_id": .string("chat"), "session_source": .string("webui"), "is_cli_session": .bool(false)],
            ["session_id": .string("sidecar"), "session_source": .string("webui"), "is_cli_session": .bool(true)],
            ["session_id": .string("cron_job_1"), "source_tag": .string("cron"), "is_cli_session": .bool(false)],
            ["session_id": .string("hook"), "source_tag": .string("webhook"), "is_cli_session": .bool(false), "read_only": .bool(true)],
            ["session_id": .string("cli"), "source_tag": .string("cli"), "is_cli_session": .bool(true), "active_stream_id": .string("s1")],
            ["session_id": .string("claude_code_x"), "session_source": .string("external_agent"), "is_cli_session": .bool(true),
             "read_only": .bool(true), "is_streaming": .bool(true)],
            ["session_id": .string("agent_y"), "session_source": .string("external_agent")]
        ]
        let hermes = try await hermesClient()

        let result = try await MoveToHermesScan.run(webui: webuiClient(), hermes: hermes, hermesProfiles: ["default"])

        XCTAssertEqual(result.entries.map(\.chat.id), ["chat", "sidecar", "cron_job_1", "hook"])
        XCTAssertEqual(result.running, [])
        XCTAssertEqual(Set(HermesHostFixture.requests.compactMap { Self.rowRead($0)?.id }), ["chat", "sidecar", "cron_job_1", "hook"])
    }

    /// At most four reads are in flight; cancelling leaves every unread id unknown and sends no more.
    func testScanSendsAtMostFourRequestsAtOnceAndCancelsToUnknown() async throws {
        host.listed = ["default": []]
        host.held = ["default": []]
        host.parkReads = true
        MoveWebuiFixture.rows = (0..<9).map { ["session_id": .string("id\($0)")] }
        let hermes = try await hermesClient()
        let webui = webuiClient()
        let four = expectation(description: "four reads parked")
        four.expectedFulfillmentCount = 4
        HermesHostFixture.onPark = { four.fulfill() }

        let scan = Task { try await MoveToHermesScan.run(webui: webui, hermes: hermes, hermesProfiles: ["default"]) }
        await fulfillment(of: [four], timeout: 5)
        XCTAssertEqual(HermesHostFixture.requests.compactMap { Self.rowRead($0) }.count, 4)
        scan.cancel()
        let result = try await scan.value

        XCTAssertEqual(result.entries.count, 9)
        XCTAssertTrue(result.entries.allSatisfy { $0.location == .unknown })
        XCTAssertEqual(HermesHostFixture.requests.compactMap { Self.rowRead($0) }.count, 4, "No read starts after cancelling")
    }

    // MARK: Copy

    /// The copy switches each source Profile once, right before that Profile's exports.
    func testCopySwitchesEachSourceProfileBeforeItsExports() async throws {
        host.held = ["default": []]
        MoveWebuiFixture.exports = ["a": exportData("a"), "b": exportData("b")]
        let hermes = try await hermesClient()

        let outcomes = await copy([item("a", from: "research"), item("b", from: "ops")], hermes: hermes)

        XCTAssertEqual(outcomes, ["a": .imported(profile: "default"), "b": .imported(profile: "default")])
        let steps = MoveWebuiFixture.requests.map { request -> String in
            guard request.url?.path == "/api/profile/switch" else { return "export " + (Self.query(request, "session_id") ?? "") }
            let body = apiTestBodyData(from: request).flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) }
            return "switch " + (body?["name"].text ?? "")
        }
        XCTAssertEqual(steps, ["switch research", "export a", "switch ops", "export b"])
    }

    /// A switch whose reply names an error or another Profile leaves that Profile's chats
    /// unreadable, unexported, and the next Profile still copies.
    func testRefusedSwitchLeavesThatProfileUnreadable() async throws {
        host.held = ["default": []]
        MoveWebuiFixture.exports = ["a": exportData("a"), "b": exportData("b"), "c": exportData("c")]
        MoveWebuiFixture.switchReplies = ["research": #"{"error":"Profile is busy"}"#, "triage": #"{"active":"default"}"#]
        let hermes = try await hermesClient()

        let outcomes = await copy([item("a", from: "research"), item("c", from: "triage"), item("b", from: "ops")], hermes: hermes)

        XCTAssertEqual(outcomes, ["a": .unreadable, "c": .unreadable, "b": .imported(profile: "default")])
        XCTAssertEqual(MoveWebuiFixture.requests.compactMap { Self.query($0, "session_id") }, ["b"])
    }

    /// A rate-limited import, or one the write fence refused (#1300), wrote nothing but isn't
    /// refused for good: it is left for replay.
    func testRateLimitedOrFencedImportIsLeftForReplay() async throws {
        host.held = ["default": []]
        host.importReplies = [.json(429, .object(["detail": .string("Too Many Requests")])),
                              .json(409, .object(["detail": .string("revision_conflict")]))]
        MoveWebuiFixture.exports = ["a": exportData("a")]
        let hermes = try await hermesClient()

        for status in [429, 409] {
            let outcomes = await copy([item("a")], hermes: hermes)
            XCTAssertEqual(outcomes, ["a": .uncertain(profile: "default")], "\(status)")
        }
        XCTAssertEqual(host.imports.count, 2)
    }

    /// The copy's client has a jar of its own, seeded with the source's sign-in, so a Profile
    /// cookie a switch sets never reaches the shared jar the app's screens use, and no screen's
    /// switch reaches it. (URLProtocol fixtures never see cookies, so the jar is checked directly.)
    func testCopyClientKeepsItsOwnCookieJar() throws {
        let signIn = try XCTUnwrap(HTTPCookie(properties: [.name: "hermes_session", .value: "token.sig",
                                                           .domain: "webui.example", .path: "/"]))
        let first = APIClient.moveCopyClient(baseURL: webuiURL, headers: [], cookies: [signIn],
                                             configuration: Self.webuiConfiguration())
        let second = APIClient.moveCopyClient(baseURL: webuiURL, headers: [], cookies: [], configuration: .default)
        defer { first.session.invalidateAndCancel(); second.session.invalidateAndCancel() }
        let jar = try XCTUnwrap(first.session.configuration.httpCookieStorage)
        let otherJar = try XCTUnwrap(second.session.configuration.httpCookieStorage)

        XCTAssertFalse(jar === HTTPCookieStorage.shared)
        XCTAssertFalse(otherJar === HTTPCookieStorage.shared, "Even from the default configuration")
        XCTAssertFalse(jar === otherJar)
        XCTAssertEqual(jar.cookies(for: webuiURL)?.map(\.name), ["hermes_session"])
        XCTAssertTrue(first.session.configuration.httpShouldSetCookies)
        XCTAssertFalse((HTTPCookieStorage.shared.cookies(for: webuiURL) ?? []).contains { $0.name == "hermes_session" })
    }

    /// A 400 wrote nothing: the chats it named are reported (an over-limit one as oversized) and
    /// the rest are sent again, each send recorded first. A 400 naming none rejects the batch.
    func testA400DropsTheNamedChatsAndSendsTheRest() async throws {
        host.held = ["default": []]
        host.importReplies = [
            .json(400, .object(["detail": .object(["ok": .bool(false), "errors": .array([
                .object(["index": .number(1), "session_id": .string("b"), "error": .string("messages[0].role must be a non-empty string")]),
                .object(["index": .number(2), "session_id": .string("c"), "error": .string("session exceeds the import size limit")])
            ])])]))
        ]
        MoveWebuiFixture.exports = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { ($0, exportData($0)) })
        let hermes = try await hermesClient()
        var dispatched: [WebuiSessionTransfer.Dispatch] = []

        let outcomes = await copy(["a", "b", "c"].map { item($0) }, hermes: hermes) { dispatched.append($0) }

        XCTAssertEqual(outcomes, ["a": .imported(profile: "default"), "c": .oversized,
                                  "b": .rejected(reason: "messages[0].role must be a non-empty string")])
        XCTAssertEqual(dispatched.map(\.ids), [["a", "b", "c"], ["a"]])
        XCTAssertEqual(host.imports.map { $0.ids }, [["a", "b", "c"], ["a"]])

        host.imports = []
        host.importReplies = [.json(400, .object(["detail": .string("Invalid session import payload")]))]
        MoveWebuiFixture.exports["z"] = exportData("z")
        let refused = await copy([item("z")], hermes: hermes)
        XCTAssertEqual(refused, ["z": .rejected(reason: "Invalid session import payload")])
        XCTAssertEqual(host.imports.count, 1)
    }

    /// A 413 wrote nothing, so the batch is halved until a chat too large alone is oversized.
    func testA413SplitsTheBatch() async throws {
        host.held = ["default": []]
        host.tooLarge = "big"
        MoveWebuiFixture.exports = Dictionary(uniqueKeysWithValues: ["a", "big", "c", "d"].map { ($0, exportData($0)) })
        let hermes = try await hermesClient()

        let outcomes = await copy(["a", "big", "c", "d"].map { item($0) }, hermes: hermes)

        XCTAssertEqual(outcomes, ["a": .imported(profile: "default"), "big": .oversized,
                                  "c": .imported(profile: "default"), "d": .imported(profile: "default")])
        XCTAssertEqual(host.imports.map { $0.ids }, [["a", "big", "c", "d"], ["a", "big"], ["a"], ["big"], ["c", "d"]])
    }

    /// The recheck finds a chat another Profile already has, and the host's skip settles a repeat.
    func testRepeatedImportSettlesAsAlreadyPresent() async throws {
        host.held = ["default": [], "research": ["elsewhere"]]
        host.skipped = ["again"]
        MoveWebuiFixture.exports = Dictionary(uniqueKeysWithValues: ["elsewhere", "again", "new"].map { ($0, exportData($0)) })
        let hermes = try await hermesClient()

        let outcomes = await copy(["elsewhere", "again", "new"].map { item($0) }, hermes: hermes, profiles: ["default", "research"])

        XCTAssertEqual(outcomes, ["elsewhere": .alreadyPresent(profile: "research"), "again": .alreadyPresent(profile: "default"),
                                  "new": .imported(profile: "default")])
        XCTAssertEqual(host.imports.map { $0.ids }, [["again", "new"]])
    }

    /// An import whose reply never came is uncertain and not resent. Running it again, as the
    /// runner replays it (#1216), settles a chat that landed and sends one that didn't.
    func testDroppedImportIsUncertainAndARerunSettlesIt() async throws {
        host.held = ["default": []]
        host.importReplies = [.fail(URLError(.networkConnectionLost))]
        host.landsEvenWhenDropped = ["landed"]
        MoveWebuiFixture.exports = Dictionary(uniqueKeysWithValues: ["landed", "lost"].map { ($0, exportData($0)) })
        let hermes = try await hermesClient()
        let items = ["landed", "lost"].map { item($0) }

        let first = await copy(items, hermes: hermes)
        XCTAssertEqual(first, ["landed": .uncertain(profile: "default"), "lost": .uncertain(profile: "default")])
        XCTAssertEqual(host.imports.count, 1, "Never resent within the attempt")

        let rerun = await copy(items, hermes: hermes)
        XCTAssertEqual(rerun, ["landed": .alreadyPresent(profile: "default"), "lost": .imported(profile: "default")])
        XCTAssertEqual(host.imports.map { $0.ids }, [["landed", "lost"], ["lost"]])
    }

    /// When recording a send fails, nothing is sent; cancelling first sends nothing too.
    func testNothingIsSentWithoutARecordedDispatchOrAfterCancelling() async throws {
        struct JournalFull: Error {}
        host.held = ["default": []]
        MoveWebuiFixture.exports = ["a": exportData("a")]
        let hermes = try await hermesClient()

        let unrecorded = await copy([item("a")], hermes: hermes) { _ in throw JournalFull() }
        XCTAssertEqual(unrecorded, ["a": .notSent])

        let source = WebuiSource(baseURL: webuiURL, headers: [], cookies: [])
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await WebuiSessionTransfer.run([self.item("a")], hermesProfiles: ["default"], source: source, hermes: hermes,
                                                  configuration: Self.webuiConfiguration(), willDispatch: { _ in })
        }
        let outcome = await cancelled.value
        XCTAssertEqual(outcome, ["a": .notSent])
        XCTAssertTrue(host.imports.isEmpty)
    }

    // MARK: Helpers

    private func fixture(_ name: String) throws -> BotJSON {
        let file = Self.fixtures.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: file) else {
            throw XCTSkip("Could not read \(file.path); the source tree is not present (physical device or remote runner).")
        }
        return try JSONDecoder().decode(BotJSON.self, from: data)
    }

    private func item(_ id: String, from profile: String = "research") -> WebuiSessionTransfer.Item {
        WebuiSessionTransfer.Item(chat: MoveToHermesSourceChat(id: id, profile: profile), destination: "default")
    }

    private func exportData(_ id: String) -> Data {
        try! JSONEncoder().encode(BotJSON.object([
            "session_id": .string(id), "created_at": .number(1_791_000_000),
            "messages": .array([.object(["role": .string("user"), "content": .string("hello \(id)")])])
        ]))
    }

    private func copy(_ items: [WebuiSessionTransfer.Item], cookies: [HTTPCookie] = [], hermes: BotClient,
                      profiles: [String] = ["default"],
                      willDispatch: @escaping @MainActor (WebuiSessionTransfer.Dispatch) async throws -> Void = { _ in })
        async -> [String: WebuiSessionTransfer.Outcome] {
        await WebuiSessionTransfer.run(items, hermesProfiles: profiles, source: WebuiSource(baseURL: webuiURL, headers: [], cookies: cookies),
                                       hermes: hermes, configuration: Self.webuiConfiguration(), willDispatch: willDispatch)
    }

    private static func webuiConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoveWebuiFixture.self]
        return configuration
    }

    private func webuiClient() -> APIClient {
        APIClient(baseURL: webuiURL, session: URLSession(configuration: Self.webuiConfiguration()), customHeaderProvider: { [] })
    }

    /// A connected client on the scripted Hermes host `host` answers.
    private func hermesClient() async throws -> BotClient {
        let record = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        let client = BotClient(http: BotSocketHost().connection(record))
        let host = self.host
        _ = HermesHostFixture.configuration { host.answer($0) }
        try await client.connect()
        return client
    }

    private static func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }

    /// The id and Profile of an exact row read, `GET /api/sessions/{id}?profile=`.
    private static func rowRead(_ request: URLRequest) -> (id: String, profile: String)? {
        guard let path = request.url?.path, path.hasPrefix("/api/sessions/"), path != "/api/sessions/import",
              let profile = query(request, "profile") else { return nil }
        return (String(path.dropFirst("/api/sessions/".count)), profile)
    }
}

/// The scripted Hermes host's state and answers, read under `HermesHostFixture`'s lock.
private final class FakeHermes: @unchecked Sendable {
    /// Ids each Profile holds, as exact reads see them.
    var held: [String: Set<String>] = [:]
    /// Ids each Profile's listing shows, in order; a Profile without one lists nothing.
    var listed: [String: [String]] = [:]
    var failedListings: Set<String> = []
    /// Exact reads answered this way in every Profile.
    var failures: [String: HermesHostFixture.Reply] = [:]
    /// An id the host resolves to a longer one it holds, by unique prefix.
    var prefixMatches: [String: String] = [:]
    var parkReads = false
    /// Replies to the next imports, in order, ahead of the ordinary one.
    var importReplies: [HermesHostFixture.Reply] = []
    /// A chat whose import 413s while it is in the payload.
    var tooLarge: String?
    var skipped: Set<String> = []
    /// Ids a dropped import still wrote.
    var landsEvenWhenDropped: Set<String> = []
    /// Every import the host received: its Profile and ids.
    var imports: [(profile: String, ids: [String])] = []

    func answer(_ request: URLRequest) -> HermesHostFixture.Reply? {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if url.path == "/api/sessions", let profile = query["profile"] {
            if failedListings.contains(profile) { return .json(500, .object(["detail": .string("boom")])) }
            let all = listed[profile] ?? []
            let offset = Int(query["offset"] ?? "0") ?? 0
            let page = Array(all.dropFirst(offset).prefix(100)) + (all.contains("pinned") ? ["pinned"] : [])
            return .json(200, .object(["sessions": .array(page.map { .object(["id": .string($0)]) }),
                                       "total": .number(Double(all.count))]))
        }
        if url.path == "/api/sessions/import" { return importReply(request) }
        if url.path.hasPrefix("/api/sessions/"), let profile = query["profile"] {
            if parkReads { return .park }
            let id = String(url.path.dropFirst("/api/sessions/".count))
            if let failure = failures[id] { return failure }
            let resolved = held[profile]?.contains(id) == true ? id : prefixMatches[id]
            guard let resolved else { return .json(404, .object(["detail": .string("Session not found")])) }
            return .json(200, .object(["id": .string(resolved), "profile": .string(profile)]))
        }
        return nil
    }

    private func importReply(_ request: URLRequest) -> HermesHostFixture.Reply {
        let body = apiTestBodyData(from: request).flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) } ?? .null
        let profile = body["profile"].text ?? ""
        let ids = body["sessions"].list?.compactMap { $0["id"].text } ?? []
        imports.append((profile, ids))
        if let tooLarge, ids.contains(tooLarge) { return .json(413, .object(["detail": .string("Session import payload is too large")])) }
        if !importReplies.isEmpty {
            let reply = importReplies.removeFirst()
            if case .fail = reply { held[profile, default: []].formUnion(landsEvenWhenDropped.intersection(ids)) }
            return reply
        }
        let skippedIDs = ids.filter { skipped.contains($0) || held[profile]?.contains($0) == true }
        let importedIDs = ids.filter { !skippedIDs.contains($0) }
        held[profile, default: []].formUnion(importedIDs)
        return .json(200, .object(["ok": .bool(true), "imported": .number(Double(importedIDs.count)),
                                   "imported_ids": .array(importedIDs.map(BotJSON.string)),
                                   "skipped_ids": .array(skippedIDs.map(BotJSON.string)), "errors": .array([])]))
    }
}

/// A scripted webui: the scan listing, Profile switches and JSON exports. Answers only
/// `webui.example` and `studio.example`, the second webui server Move Next opens, with the
/// same script.
final class MoveWebuiFixture: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) static var rows: [[String: BotJSON]] = []
    nonisolated(unsafe) static var allProfiles = true
    /// When set, the scan listing answers this status with no body.
    nonisolated(unsafe) static var listingFailure: Int?
    nonisolated(unsafe) static var exports: [String: Data] = [:]
    /// Switch replies by Profile name, ahead of the ordinary `{"active": <name>}`.
    nonisolated(unsafe) static var switchReplies: [String: String] = [:]
    nonisolated(unsafe) private static var log: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { log } }

    static func reset() {
        lock.withLock { rows = []; allProfiles = true; listingFailure = nil; exports = [:]; switchReplies = [:]; log = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["webui.example", "studio.example"].contains(request.url?.host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let headers = ["Content-Type": "application/json"]
        let (status, body): (Int, Data) = Self.lock.withLock {
            Self.log.append(request)
            switch url.path {
            case "/api/sessions":
                if let failure = Self.listingFailure { return (failure, Data()) }
                let reply = BotJSON.object(["sessions": .array(Self.rows.map(BotJSON.object)), "all_profiles": .bool(Self.allProfiles),
                                            "active_profile": .string("research")])
                return (200, try! JSONEncoder().encode(reply))
            case "/api/profile/switch":
                let name = apiTestBodyData(from: request).flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) }?["name"].text ?? ""
                return (200, Data((Self.switchReplies[name] ?? #"{"active":"\#(name)"}"#).utf8))
            case "/api/session/export":
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "session_id" }?.value ?? ""
                return Self.exports[id].map { (200, $0) } ?? (404, Data(#"{"error":"Session not found"}"#.utf8))
            default:
                return (404, Data())
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
