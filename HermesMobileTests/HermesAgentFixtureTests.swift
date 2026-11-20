import XCTest
@testable import HermesMobile

@MainActor final class HermesAgentFixtureTests: XCTestCase {
    private static let knownTurnEvents: Set<String> = [
        "session.info", "message.start", "message.delta", "message.complete",
        "thinking.delta", "reasoning.available",
        "session.title"
    ]
    private static let knownToolEvents: Set<String> = [
        "tool.start", "tool.complete",
        "request.cancel",
        "message.interim", "session.usage"
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
        XCTAssertEqual(manifest["version"].text, HermesCompatibility.testedVersion)
        let pin = try String(contentsOf: Self.tests.deletingLastPathComponent().appendingPathComponent("HERMES_AGENT_TESTED_SHA"), encoding: .utf8)
        XCTAssertEqual(manifest["hermes_agent_sha"].text, pin.split(separator: "\n").first.map(String.init),
                       "Re-run scripts/capture-hermes-fixtures after advancing the pin")
    }

    func testCapturedStatusPassesTheClientAuthGate() async throws {
        let status = try fixture("status")
        FixtureStatusProtocol.status = try JSONEncoder().encode(status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureStatusProtocol.self]
        let client = BotClient(connection: BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                                         username: "user", password: "fixture"),
                               configuration: configuration) { _ in
            XCTFail("The fixture never reaches the socket")
            return FixtureUnreachableSocket()
        }
        do {
            try await client.connect()
            XCTFail("Login is scripted to fail")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(404), "Anything else means the auth gate refused the captured status")
        }
        XCTAssertEqual(client.serverVersion, HermesCompatibility.testedVersion)
    }

    func testEveryRosterRowBuildsAProfileWithItsChatAndLook() throws {
        let roster = try fixture("profiles-list")
        XCTAssertEqual(roster["bot_mode_protocol"].flag, true)
        let rows = try XCTUnwrap(roster["profiles"].list)
        XCTAssertFalse(rows.isEmpty)
        let profiles = rows.compactMap(BotProfile.init)
        XCTAssertEqual(profiles.count, rows.count)
        let bot = try XCTUnwrap(profiles.first { $0.id == "hermex-fixtures" })
        XCTAssertNotNil(bot.preview)
        XCTAssertNotNil(bot.lastActive)
        XCTAssertNotNil(bot.lookRevision)
        XCTAssertNotNil(bot.displayName)
        XCTAssertNotNil(bot.title)
        let row = try XCTUnwrap(rows.first { $0["name"].text == "hermex-fixtures" })
        let hidden = try XCTUnwrap(row["ui_meta"]["hermes-bots"]["hidden"].flag, "The captured look carries `hidden`")
        XCTAssertEqual(bot.hidden, hidden)
    }

    func testCapturedResumeAndReplayAttachTheBotsChat() async throws {
        let snapshot = try fixture("session-resume")
        let frames = try XCTUnwrap(fixture("turn-frames").list)
        let wire = BotFixtureWire()
        wire.runtimeID = try XCTUnwrap(snapshot["session_id"].text)
        wire.tip = try XCTUnwrap(snapshot["session_key"].text)
        wire.transformResume = { _ in snapshot }
        let events = frames.map { $0["params"] }
        wire.replay = BotFixtureWire.replay(latest: events.last?["seq"].integer ?? 0, events: events)
        let engine = HermesConversation(server: URL(string: "https://webui.example")!,
                                        connection: BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                                                  username: "user", password: "fixture"),
                                        target: .canonicalChat(profile: "hermex-fixtures"), wire: wire)
        await engine.activate()
        defer { engine.suspend() }
        XCTAssertEqual(engine.connectionState, .connected)
        XCTAssertEqual(engine.sequence, events.last?["seq"].integer)
        XCTAssertTrue(engine.isCurrent(snapshot))
        XCTAssertEqual(snapshot["running"].flag, false)
    }

    func testAWebappsInstallIsCheckedOnceSignedInAndAForeignRefreshTokenExpires() async throws {
        let signedOut = try fixture("canonical-status-signed-out")["reply"]
        let signedIn = try fixture("canonical-status-signed-in")["reply"]
        let refused = try fixture("canonical-refresh-refused")["reply"]
        let live = try XCTUnwrap(signedIn["install_id"].text)
        let record = BotConnection(id: UUID(), name: "Webapp", address: URL(string: "https://webapp.example")!,
                                   username: "user", password: "secret")
        defer { HermesHostFixture.reset() }
        for saved in [String?.none, live, "another-install"] {
            HermesHostFixture.reset()
            var statuses = 0
            let configuration = HermesHostFixture.configuration { request in
                guard request.url?.path == "/api/status" else { return nil }
                statuses += 1
                return .json(200, statuses == 1 ? signedOut : signedIn)
            }
            var expected = record
            expected.installID = saved
            let http = HermesConnection(connection: expected, configuration: configuration)
            if saved == "another-install" {
                do { try await http.signIn(); XCTFail("another install was refused") }
                catch { XCTAssertEqual(error as? BotFailure, .differentHost) }
                XCTAssertEqual(HermesHostFixture.requests.map(\.url?.path).last, "/api/status", "nothing loads after")
            } else {
                try await http.signIn()
                XCTAssertEqual(http.connection.installID, live, saved ?? "first sign-in")
                XCTAssertTrue(http.servesWebapp)
            }
        }

        HermesHostFixture.reset()
        var browser = record
        browser.oauth = HermesOAuth(provider: "basic", userID: "user", refreshToken: "issued-elsewhere")
        let http = HermesConnection(connection: browser, configuration: HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/api/status": return .json(200, signedOut)
            case "/auth/native/refresh": return .json(refused["status"].integer ?? 0, refused["body"])
            default: return nil
            }
        })
        do { try await http.signIn(); XCTFail("the foreign refresh token was refused") }
        catch { XCTAssertEqual(error as? BotFailure, .signInExpired) }
        XCTAssertEqual(HermesHostFixture.count("/auth/native/refresh"), 1, "refused once, never retried")
    }

    func testCanonicalSnapshotAndReplayAttachUnderTheSessionsEpoch() async throws {
        let ready = try fixture("canonical-ready")["reply"]
        let snapshot = try fixture("canonical-resume-running")["reply"]
        let replay = try fixture("canonical-replay")["reply"]
        XCTAssertEqual(ready["session_authority"].flag, true)
        let epoch = try XCTUnwrap(snapshot["replay_epoch"].text)
        XCTAssertNotEqual(ready["replay_epoch"].text, epoch, "a session replays under its own epoch")
        let session = try XCTUnwrap(snapshot["session_id"].text)

        let host = BotSocketHost()
        host.always("session.resume", .init(result: snapshot))
        host.always("session.events.since", .init(result: replay))
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.record,
                                        target: .session(profile: "default", key: session),
                                        wire: BotClient(http: host.connection(Self.record, canonical: true)))
        await engine.activate()
        defer { engine.suspend(); HermesHostFixture.reset() }
        XCTAssertEqual(engine.connectionState, .connected)
        XCTAssertTrue(engine.isCurrent(snapshot))
        XCTAssertEqual(engine.sequence, replay["latest_seq"].integer)
        let sent = host.requests.first { $0["method"].text == "session.events.since" }?["params"]
        XCTAssertEqual(sent?["replay_epoch"].text, epoch)
        await engine.activate()
        XCTAssertFalse(engine.replayWasReset, "a reattach under the same epoch continues")

        for refusal in ["canonical-replay-epoch-mismatch", "canonical-replay-gap"] {
            let reply = try fixture(refusal)["reply"]
            XCTAssertEqual(reply["snapshot_required"].flag, true, refusal)
            host.next("session.events.since", .init(result: reply))
            await engine.activate()
            XCTAssertEqual(engine.connectionState, .connected, refusal)
            XCTAssertTrue(engine.replayWasReset, "\(refusal) rebuilds from the snapshot")
        }
    }

    func testCanonicalSettingsFixtureKeepsReplyShapes() throws {
        let settings = try fixture("canonical-settings")["reply"]
        XCTAssertEqual(settings["config_set_model"]["error"]["data"]["reason"].text, "use_session_mutation_model")
        XCTAssertNotNil(settings["fast_scoped"]["error"]["code"].integer)
        XCTAssertEqual(settings["model"]["result"]["operation"].text, "model")
        XCTAssertEqual(settings["fast_normal"]["result"], .object(["key": .string("fast"), "value": .string("normal")]))
        XCTAssertEqual(settings["reasoning"]["result"]["key"].text, "reasoning")
        XCTAssertEqual(settings["personality"]["result"]["key"].text, "personality")
        XCTAssertEqual(settings["approval_mode"]["result"], .object(["key": .string("approvals.mode"), "value": .string("manual")]))
    }

    private static let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                              username: "user", password: "fixture")

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

    func testToolApprovalTurnDecodesAndSettles() throws {
        _ = try fixture("manifest")
        let file = Self.directory.appendingPathComponent("turn-tool-approval-frames.json")
        guard let data = try? Data(contentsOf: file) else {
            return XCTFail("Missing turn-tool-approval-frames.json; run scripts/capture-hermes-fixtures --local against scripts/local-hermes")
        }
        let capture = try JSONDecoder().decode(BotJSON.self, from: data)
        XCTAssertEqual(capture["version"].text, HermesCompatibility.testedVersion)
        let pin = try String(contentsOf: Self.tests.deletingLastPathComponent().appendingPathComponent("HERMES_AGENT_TESTED_SHA"), encoding: .utf8)
        XCTAssertEqual(capture["hermes_agent_sha"].text, pin.split(separator: "\n").first.map(String.init))
        let frames = try XCTUnwrap(capture["frames"].list)

        let requests = frames.filter { $0["method"].text != "event" }
        XCTAssertEqual(requests.count, 1, "One server request: the approval")
        let request = try XCTUnwrap(requests.first.flatMap(BotServerRequest.init))
        guard case .approval(let approval) = request.pending else { return XCTFail("\(request.method) is not an approval") }
        XCTAssertEqual(approval.command?.contains("python3 -c"), true)
        XCTAssertEqual(approval.choices.first, .once)
        XCTAssertEqual(approval.choices.last, .deny)

        let events = frames.filter { $0["method"].text == "event" }.map { $0["params"] }
        XCTAssertTrue(events.allSatisfy { $0["session_id"].text == request.sessionID }, "One runtime carries the turn")
        let types = events.compactMap { $0["type"].text }
        XCTAssertEqual(Set(types).subtracting(Self.knownTurnEvents.union(Self.knownToolEvents)), [], "A new upstream event type")
        let starts = events.filter { $0["type"].text == "tool.start" }.map { $0["payload"] }
        let completes = events.filter { $0["type"].text == "tool.complete" }.map { $0["payload"] }
        XCTAssertEqual(starts.map { $0["name"].text }, ["terminal"])
        XCTAssertEqual(completes.map { $0["tool_id"].text }, starts.map { $0["tool_id"].text }, "the one call completed")
        XCTAssertNotNil(completes.first?["result"].toolResultPreview)
        let completed = try XCTUnwrap(types.lastIndex(of: "message.complete"), "The turn completes")
        XCTAssertLessThan(try XCTUnwrap(types.firstIndex(of: "tool.complete")), completed, "The tool finished inside the turn")
        XCTAssertEqual(events.last?["type"].text, "session.info")
        XCTAssertEqual(events.last?["payload"]["running"].flag, false)
    }
}

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
