import XCTest
@testable import HermesMobile

/// A Hermes session's turns drive the shared Live Activity (#1014): one activity per turn
/// under the interim `hermes:<profile>:<stored key>` identity, the turn's work and waits as
/// updates, and its ending as the outcome. Driven over #901's socket-level host.
@MainActor final class HermesChatLiveActivityTests: XCTestCase {
    private static let startedAt = 1_790_000_000.5

    // MARK: Start

    /// A turn starts one activity under the session's key and the host's `turn_started_at`;
    /// its frames start no second one, and a reattach inside the turn adopts it again.
    func testATurnStartsOneActivityAndAReattachAdoptsIt() async {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(Self.startedAt)]))
        chat.receive(event(2, "message.start"))
        chat.receive(event(3, "message.delta", ["text": .string("Working")]))
        chat.receive(event(4, "tool.start", ["name": .string("terminal"), "tool_id": .string("t1")]))
        XCTAssertEqual(chat.spy.starts, [.init(sessionID: "hermes:default:tip", server: Self.server,
                                               title: "Untitled Session", streamID: "1790000000.5",
                                               startedAt: Date(timeIntervalSince1970: Self.startedAt))])

        chat.model.suspendStreamForBackground()
        XCTAssertEqual(chat.spy.staleCount, 1, "leaving drops the socket, so the activity is no longer current")
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 4)))
        chat.host.always("session.resume", .init(result: resume(running: true)))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.spy.starts.map(\.sessionID), ["hermes:default:tip", "hermes:default:tip"])
        XCTAssertEqual(chat.spy.starts.map(\.streamID), ["1790000000.5", "1790000000.5"],
                       "the same identity, so the manager adopts the activity instead of starting another")
        XCTAssertEqual(chat.spy.ends, [])
    }

    /// Opening the session mid-turn starts the activity under the identity the turn's first
    /// chat used, titled from the snapshot, so the manager adopts the one already showing.
    func testOpeningARunningSessionAdoptsTheTurnsActivityUnderItsTitle() async {
        let chat = await openChat(snapshot: resume(running: true, title: "Release plan"))
        XCTAssertEqual(chat.spy.starts, [.init(sessionID: "hermes:default:tip", server: Self.server,
                                               title: "Release plan", streamID: "1790000000.5",
                                               startedAt: Date(timeIntervalSince1970: Self.startedAt))])
    }

    /// A turn the send's reply began, before its own frames, still gets one activity.
    func testATurnBegunBySendStartsOneActivity() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Write a haiku")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Autumn")]))
        XCTAssertEqual(chat.spy.starts.map(\.sessionID), ["hermes:default:tip"],
                       "its own message.start continues the same turn")
    }

    // MARK: Updates

    /// Reasoning, tools, reply text and the title reach the activity; reply text only while
    /// excerpts are on. Turning them off clears what it showed, and later text moves the
    /// status on without its words.
    func testTheTurnsWorkUpdatesTheActivity() async {
        let chat = await openChat(excerpts: true)
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "reasoning.delta", ["text": .string("Check the config first.")]))
        chat.receive(event(3, "tool.start", ["name": .string("terminal"), "tool_id": .string("t1")]))
        chat.receive(event(4, "tool.complete", ["name": .string("terminal"), "tool_id": .string("t1")]))
        chat.receive(event(5, "message.interim", ["text": .string("Let me look."), "already_streamed": .bool(false)]))
        chat.receive(event(6, "message.interim", ["text": .string("Already shown."), "already_streamed": .bool(true)]))
        chat.receive(event(7, "message.delta", ["text": .string("Done")]))
        chat.receive(event(8, "session.title", ["session_id": .string("tip"), "title": .string("Release plan")]))
        chat.model.setShowsLiveActivityResponseExcerpts(false)
        chat.receive(event(9, "message.delta", ["text": .string(" now")]))
        XCTAssertEqual(chat.spy.events, [
            .reasoning("Check the config first."), .toolStarted(name: "terminal"), .toolCompleted,
            .interimAssistant("Let me look."), .token("Done"), .sessionTitle("Release plan"), .clearResponseExcerpt,
            .responding
        ])
    }

    /// With excerpts off (the default), the reply that follows an answered question moves the
    /// activity off waiting, as in Bot Chat, instead of leaving the wait shown to the end.
    func testTheReplyAfterAnAnsweredQuestionMovesTheActivityOffWaiting() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which file?")]))
        chat.receive(event(2, "request.cancel", ["id": .string("srq-c1"), "method": .string("clarify")]))
        chat.receive(event(3, "message.delta", ["text": .string("Using config.yml")]))
        XCTAssertEqual(chat.spy.events, [.waitingForClarification, .responding])
    }

    /// An open approval shows as waiting for approval, and a question as needing an answer,
    /// once each.
    func testOpenRequestsShowAsWaiting() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        let approval = request("approval", id: "srq-a1", ["request_id": .string("q-1"), "command": .string("rm -rf build"),
                                                         "description": .string("recursive delete"),
                                                         "choices": .array([.string("once"), .string("deny")])])
        chat.receive(approval)
        chat.receive(approval)
        chat.receive(event(2, "request.cancel", ["id": .string("srq-a1"), "method": .string("approval")]))
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which file?")]))
        XCTAssertEqual(chat.spy.events, [.waitingForApproval, .waitingForClarification])
    }

    // MARK: End

    /// `message.complete`'s status ends the activity with the matching outcome once the host
    /// settles, and so does an `error` with no completion.
    func testTheTurnsEndingEndsTheActivityWithItsOutcome() async {
        let cases: [(frame: BotJSON, end: Spy.End)] = [
            (event(2, "message.complete", ["status": .string("complete"), "text": .string("ok")]),
             .init(status: .complete, activity: "Response complete")),
            (event(2, "message.complete", ["status": .string("interrupted")]),
             .init(status: .cancelled, activity: "Response cancelled")),
            (event(2, "message.complete", ["status": .string("error"), "error": .string("Model failed")]),
             .init(status: .failed, activity: "Response failed")),
            (event(2, "error", ["message": .string("Model failed")]),
             .init(status: .failed, activity: "Response failed"))
        ]
        for (frame, end) in cases {
            let chat = await openChat()
            chat.receive(event(1, "message.start"))
            chat.receive(frame)
            XCTAssertEqual(chat.spy.ends, [], "\(end.status) waits for the host to settle")
            chat.receive(event(3, "session.info", ["running": .bool(false)]))
            XCTAssertEqual(chat.spy.ends, [end])
        }
    }

    /// Stop ends the activity cancelled once the turn's own frames settle it.
    func testStopEndsTheActivityCancelled() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("session.interrupt", .init(result: .object(["status": .string("interrupted")])))
        let stopped = await chat.model.cancelActiveStream()
        XCTAssertTrue(stopped)
        XCTAssertEqual(chat.spy.ends, [], "accepted is not idle")
        chat.receive(event(2, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.spy.ends, [.init(status: .cancelled, activity: "Response cancelled")])
    }

    // MARK: Ownership

    /// A dropped socket marks the activity stale.
    func testADroppedSocketMarksTheActivityStale() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.client.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(chat.spy.staleCount, 1)
        XCTAssertEqual(chat.spy.ends, [], "the turn may still be running on the host")
    }

    /// Once a webui run or a bot takes the activity over, this chat never touches it again.
    func testAnActivityAnotherRunTookOverIsNeverTouched() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.spy.drivenSessionID = "webui-session"
        chat.receive(event(2, "tool.start", ["name": .string("terminal"), "tool_id": .string("t1")]))
        chat.receive(event(3, "message.complete", ["status": .string("complete")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.spy.events, [])
        XCTAssertEqual(chat.spy.ends, [])

        let leaving = await openChat()
        leaving.receive(event(1, "message.start"))
        leaving.spy.drivenSessionID = "bot:other"
        leaving.model.suspendStreamForBackground()
        XCTAssertEqual(leaving.spy.staleCount, 0)
    }

    // MARK: Tap

    /// A Hermes session's activity has no destination until #706: no webui route is built,
    /// so a tap opens the app as it is. A webui run on the same server still routes.
    func testATapOnAHermesSessionsActivityBuildsNoWebuiRoute() throws {
        let hermes = AgentRunActivityAttributes(sessionID: "hermes:default:tip", sessionTitle: "Run", startedAt: .now,
                                                server: Self.server)
        XCTAssertNil(AgentRunTapTarget.url(attributes: hermes, sessionID: "hermes:default:tip", activityID: "a1"))

        let webui = AgentRunActivityAttributes(sessionID: "20260925_023517_59d8c3", sessionTitle: "Run", startedAt: .now,
                                               server: Self.server)
        let url = try XCTUnwrap(AgentRunTapTarget.url(attributes: webui, sessionID: "20260925_023517_59d8c3",
                                                      activityID: "a2"))
        XCTAssertEqual(url.host, "webui-push")
    }

    // MARK: Fixture

    private static let server = URL(string: "https://hermes.example")!
    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    /// A Hermes chat attached to session `tip` on Profile `default`, whose frames the test feeds.
    private struct Chat {
        let model: ChatViewModel
        let host: BotSocketHost
        let client: BotClient
        let spy: Spy

        /// One event's params, or a host request envelope as is.
        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }
    }

    private func openChat(snapshot: BotJSON? = nil, excerpts: Bool = false) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: snapshot ?? resume(running: false)))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let client = BotClient(http: host.connection(Self.connection))
        // No automatic reconnect: a test reattaches when it says so.
        let engine = HermesConversation(server: Self.server, connection: Self.connection,
                                        target: .session(profile: "default", key: "tip"), wire: client,
                                        reconnectDelay: { _ in throw CancellationError() })
        let spy = Spy()
        let turn = HermesChatTurnCoordinator(engine: engine, liveActivities: spy, isNetworkAvailable: { true })
        // The chat's own webui manager is the same spy, so any write it made would show too.
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: Self.server, liveActivityManager: spy,
            showsLiveActivityResponseExcerpts: excerpts, streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, host: host, client: client, spy: spy)
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:]) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }

    /// A host request envelope on the chat's runtime.
    private func request(_ method: String, id: String, _ params: [String: BotJSON]) -> BotJSON {
        var params = params
        params["session_id"] = .string("runtime")
        return .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)])
    }

    private func resume(running: Bool, title: String? = nil) -> BotJSON {
        var info: [String: BotJSON] = ["profile_name": .string("default")]
        if let title { info["title"] = .string(title) }
        var reply: [String: BotJSON] = [
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(running),
            "messages": .array([]), "info": .object(info)
        ]
        if running { reply["turn_started_at"] = .number(Self.startedAt) }
        return .object(reply)
    }
}

/// Records what a chat asks of the shared Live Activity manager, and drives like it: a
/// start takes the activity over, and an end lets it go.
@MainActor private final class Spy: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let server: URL
        let title: String
        let streamID: String?
        let startedAt: Date
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
    }

    private(set) var starts: [Start] = []
    private(set) var events: [AgentLiveActivityEvent] = []
    private(set) var ends: [End] = []
    private(set) var staleCount = 0
    var drivenSessionID: String?

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {
        starts.append(Start(sessionID: sessionID, server: server, title: sessionTitle, streamID: streamID, startedAt: startedAt))
        drivenSessionID = sessionID
    }

    func update(_ event: AgentLiveActivityEvent) { events.append(event) }
    func markStale() { staleCount += 1 }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity))
        drivenSessionID = nil
    }
}
