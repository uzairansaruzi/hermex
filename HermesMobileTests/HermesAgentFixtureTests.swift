import XCTest
@testable import HermesMobile

/// Real hermes-agent responses, recorded at the `HERMES_AGENT_TESTED_SHA` pin by
/// `scripts/capture-hermes-fixtures`. Hand-built payloads check our idea of the API;
/// these check the host's, so a renamed or dropped field fails here instead of
/// quietly blanking a screen. Read via `#filePath`, so they skip off-tree like the pin test.
@MainActor final class HermesAgentFixtureTests: XCTestCase {
    /// Every event type the canned turn emitted at the pin. A type missing here is new
    /// upstream: decide whether Bot Chat should consume it, then add it.
    private static let knownTurnEvents: Set<String> = [
        "session.info", "message.start", "message.delta", "message.complete", // turn state
        "thinking.delta", "reasoning.available", // activity, `BotConversation.applyActivity`
        "session.title" // unused; only schedules a snapshot read
    ]

    private static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let directory = tests.appendingPathComponent("Fixtures/HermesAgent")

    private func fixture(_ name: String) throws -> BotJSON {
        let file = Self.directory.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: file) else {
            throw XCTSkip("Could not read \(file.path); the source tree is not present (physical device or remote runner).")
        }
        return try JSONDecoder().decode(BotJSON.self, from: data)
    }

    override func tearDown() {
        FixtureStatusProtocol.status = nil
        super.tearDown()
    }

    func testFixturesWereCapturedAtThePin() throws {
        let manifest = try fixture("manifest")
        XCTAssertEqual(manifest["version"].text, BotConnection.testedHermesVersion)
        let pin = try String(contentsOf: Self.tests.deletingLastPathComponent().appendingPathComponent("HERMES_AGENT_TESTED_SHA"), encoding: .utf8)
        XCTAssertEqual(manifest["hermes_agent_sha"].text, pin.split(separator: "\n").first.map(String.init),
                       "Re-run scripts/capture-hermes-fixtures after advancing the pin")
    }

    /// The captured status goes through the real `BotClient.connect`. Password login
    /// is the next request, so reaching it (and its scripted 404) means the auth gate passed.
    func testCapturedStatusPassesTheClientAuthGate() async throws {
        let status = try fixture("status")
        FixtureStatusProtocol.status = try JSONEncoder().encode(status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureStatusProtocol.self]
        let client = BotClient(connection: BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                                         username: "user", password: "fixture"),
                               configuration: configuration) { _, _ in
            XCTFail("The fixture never reaches the socket")
            return FixtureUnreachableSocket()
        }
        do {
            try await client.connect()
            XCTFail("Login is scripted to fail")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(404), "Anything else means the auth gate refused the captured status")
        }
        XCTAssertEqual(client.serverVersion, BotConnection.testedHermesVersion)
    }

    func testEveryRosterRowBuildsAProfileWithItsChatAndLook() throws {
        let roster = try fixture("profiles-list")
        XCTAssertEqual(roster["bot_mode_protocol"].flag, true)
        let rows = try XCTUnwrap(roster["profiles"].list)
        XCTAssertFalse(rows.isEmpty)
        let profiles = rows.compactMap(BotProfile.init)
        XCTAssertEqual(profiles.count, rows.count)
        // `BotProfile` requires only `name`, so these catch a renamed `canonical_session`
        // or `ui_meta_revisions`, which would otherwise decode to an empty inbox row.
        let bot = try XCTUnwrap(profiles.first { $0.id == "inbox-triage" })
        XCTAssertNotNil(bot.preview)
        XCTAssertNotNil(bot.lastActive)
        XCTAssertNotNil(bot.lookRevision)
        // The inbox names and hides a bot from `display_name` and Desktop's look.
        XCTAssertNotNil(bot.displayName)
        XCTAssertNotNil(bot.title)
        let row = try XCTUnwrap(rows.first { $0["name"].text == "inbox-triage" })
        let hidden = try XCTUnwrap(row["ui_meta"]["hermes-bots"]["hidden"].flag, "The captured look carries `hidden`")
        XCTAssertEqual(bot.hidden, hidden)
    }

    /// The captured resume and turn, served through the scripted wire, settle Bot Chat
    /// on the canned exchange: the replay reconciles and the snapshot passes every guard.
    func testCapturedResumeAndReplaySettleTheConversation() async throws {
        let snapshot = try fixture("session-resume")
        let frames = try XCTUnwrap(fixture("turn-frames").list)
        let wire = BotFixtureWire()
        wire.runtimeID = try XCTUnwrap(snapshot["session_id"].text)
        wire.tip = try XCTUnwrap(snapshot["session_key"].text)
        wire.transformResume = { _ in snapshot }
        let events = frames.map { $0["params"] }
        wire.replay = BotFixtureWire.replay(latest: events.last?["seq"].integer ?? 0, events: events)
        let model = BotConversation(server: URL(string: "https://webui.example")!,
                                    connection: BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                                              username: "user", password: "fixture"),
                                    profile: BotProfile(.object(["name": .string("inbox-triage")]))!, wire: wire,
                                    drafts: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)))
        await model.recover()
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertEqual(model.turn, .idle)
        XCTAssertEqual(model.messages.first?.role, "user")
        XCTAssertEqual(model.messages.first?.content, "Reply with exactly: ok. Do not use tools.")
        let reply = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(reply.role, "assistant")
        XCTAssertEqual(reply.content?.isEmpty, false)
    }

    func testTurnFramesAreOneContiguousSettledTurn() throws {
        let frames = try XCTUnwrap(fixture("turn-frames").list)
        XCTAssertTrue(frames.allSatisfy { $0["method"].text == "event" })
        let params = frames.map { $0["params"] }
        XCTAssertEqual(Set(params.compactMap { $0["session_id"].text }).count, 1)
        XCTAssertTrue(params.allSatisfy { $0["session_id"].text != nil })
        let sequence = params.compactMap { $0["seq"].integer }
        XCTAssertEqual(sequence, Array((sequence.first ?? 1)..<((sequence.first ?? 1) + params.count)), "seq is contiguous")
        let types = params.compactMap { $0["type"].text }
        for required in ["message.start", "message.delta", "message.complete"] {
            XCTAssertTrue(types.contains(required), required)
        }
        let complete = try XCTUnwrap(params.first { $0["type"].text == "message.complete" })
        XCTAssertEqual(complete["payload"]["text"].text?.isEmpty, false)
        XCTAssertEqual(params.last?["type"].text, "session.info")
        XCTAssertEqual(params.last?["payload"]["running"].flag, false)
        XCTAssertEqual(Set(types).subtracting(Self.knownTurnEvents), [], "A new upstream event type")
    }
}

/// Serves the captured `/api/status` and refuses everything after it with a 404.
private final class FixtureStatusProtocol: URLProtocol {
    static var status: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.url?.path == "/api/status" ? Self.status : nil
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct FixtureUnreachableSocket: BotSocket {
    func receive() async throws -> URLSessionWebSocketTask.Message { throw BotFailure.transport }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { throw BotFailure.transport }
    func cancel() {}
}
