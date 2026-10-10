import XCTest
import Observation
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

    // MARK: Bot Chat (#1145)

    /// A bot's Bot Chat keeps the Bot identity (#709): its turn starts the bot's activity,
    /// keyed by connection and Profile, whose tap opens the bot's chat and whose push id is the
    /// stored key. No `hermes:` session activity starts, and the turn's ending ends the bot's.
    func testABotChatsTurnDrivesTheBotsActivity() async throws {
        let chat = await openChat(target: .canonicalChat(profile: "default"))
        chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(Self.startedAt)]))
        chat.receive(event(2, "message.start"))
        chat.receive(event(3, "tool.start", ["name": .string("terminal"), "tool_id": .string("t1")]))

        let destination = BotDestination(server: Self.server, connectionID: Self.connection.id, profile: "default",
                                         conversation: "root")
        let url = try XCTUnwrap(HermesDeepLink.botURL(for: destination))
        XCTAssertEqual(chat.spy.botStarts, [.init(key: "bot:\(Self.connection.id.uuidString):default", destinationURL: url,
                                                  pushSessionID: "tip", title: "Hermes", turn: "1790000000.5",
                                                  startedAt: Date(timeIntervalSince1970: Self.startedAt))])
        XCTAssertEqual(chat.spy.starts, [], "never the interim hermes: identity")
        XCTAssertEqual(chat.spy.events.last, .toolStarted(name: "terminal"))

        chat.receive(event(4, "message.complete", ["text": .string("Done")]))
        chat.receive(event(5, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.spy.ends, [.init(status: .complete, activity: "Response complete")])
    }

    /// A Bot Chat's pill shows the turn as Bot Chat's title does (#757, #778): at rest while
    /// idle, working while the turn runs, waiting while a request is open, failed while the host
    /// keeps the turn's error, and at rest again once the socket drops. A session has no pill.
    func testABotChatsPillFaceFollowsTheTurn() async {
        let chat = await openChat(target: .canonicalChat(profile: "default"))
        XCTAssertEqual(chat.turn.botProfile?.name, "Hermes", "the bare Profile row until a roster read answers")
        XCTAssertEqual(chat.turn.titleFace, .resting)

        chat.receive(event(1, "message.start"))
        XCTAssertEqual(chat.turn.botTurn, .running)
        XCTAssertEqual(chat.turn.titleFace, .working)
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which file?")]))
        XCTAssertEqual(chat.turn.titleFace, .waiting)
        chat.receive(event(2, "request.cancel", ["id": .string("srq-c1"), "method": .string("clarify")]))
        XCTAssertEqual(chat.turn.titleFace, .working)
        chat.receive(event(3, "message.complete", ["status": .string("error"), "error": .string("Model failed")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.turn.titleFace, .failed)

        chat.model.suspendStreamForBackground()
        XCTAssertEqual(chat.turn.botTurn, .unknown, "a reconnect inside the turn starts no new beat")
        XCTAssertEqual(chat.turn.titleFace, .resting)

        let session = await openChat()
        XCTAssertNil(session.turn.botProfile)
    }

    /// Attaching to a running turn starts the bot's activity before the roster is read, from the
    /// bare Profile row. Once the roster answers, the same activity takes the bot's name and
    /// static avatar: no second start, and the turn, so the pill's beat, carries on. A later
    /// read while another bot holds the activity changes nothing.
    func testTheRosterNamesTheBotOnItsRunningActivity() async throws {
        let chat = await openChat(snapshot: resume(running: true), target: .canonicalChat(profile: "default"),
                                  roster: Self.roster(title: "Inbox Triage", expression: "sleepy"))
        await waitUntil("the roster") { !chat.turn.settings.bots.isEmpty }
        XCTAssertEqual(chat.spy.botStarts.map(\.title), ["Hermes"], "started from the bare Profile row")
        XCTAssertEqual(chat.spy.titles, ["Inbox Triage"])
        XCTAssertEqual(chat.spy.avatars, [.init(title: "Hermes", expression: nil), .init(title: "Inbox Triage", expression: "sleepy")])
        XCTAssertEqual(chat.turn.botTurn, .running)

        chat.spy.drivenSessionID = "bot:\(UUID().uuidString):helper"
        chat.host.always("profiles.list", .init(result: Self.roster(title: "Renamed", expression: nil)))
        await chat.turn.settings.refreshProfiles()
        XCTAssertEqual(chat.turn.botProfile?.title, "Renamed")
        XCTAssertEqual(chat.spy.titles, ["Inbox Triage"], "never another bot's activity")
        XCTAssertEqual(chat.spy.avatars.count, 2)
    }

    /// A Bot Chat's activity keeps Bot Chat's count chips (#584): the plan's step and the live
    /// worker count, written as they change and clear, again once a reattach adopts the
    /// activity, and never to an activity another run took over. A session's activity gets none.
    func testABotChatsActivityShowsItsPlanAndWorkerCounts() async {
        let chat = await openChat(target: .canonicalChat(profile: "default"), subagents: [worker("tests"), worker("docs")])
        let work = chat.turn.activity.delegatedWork
        await waitUntil("listed on connect") { work.activeCount == 2 }
        chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(Self.startedAt)]))
        chat.receive(event(2, "message.start"))
        XCTAssertEqual(chat.spy.summaries.last, ["2 workers"], "the workers listed before the turn")

        chat.receive(event(3, "todo.updated", todos(revision: 1, ["completed", "in_progress", "pending"])))
        XCTAssertEqual(chat.spy.summaries.last, ["Plan 2 of 3", "2 workers"])
        chat.host.always("subagent.list", .init(result: .object(["subagents": .array([worker("tests"), worker("docs"),
                                                                                      worker("lint")])])))
        chat.receive(event(4, "subagent.start", ["subagent_id": .string("lint")]))
        await waitUntil("a third worker") { work.activeCount == 3 }
        XCTAssertEqual(chat.spy.summaries.last, ["Plan 2 of 3", "3 workers"])

        chat.host.always("subagent.list", .init(result: .object(["subagents": .array([])])))
        chat.receive(event(5, "todo.updated", todos(revision: 2, [])))
        chat.receive(event(6, "subagent.complete", ["subagent_id": .string("lint")]))
        await waitUntil("the workers finished") { work.activeCount == 0 }
        XCTAssertEqual(chat.spy.summaries.last, [], "a cleared plan and finished workers clear the chips")

        chat.model.suspendStreamForBackground()
        chat.host.always("subagent.list", .init(result: .object(["subagents": .array([worker("docs"), worker("lint")])])))
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 6)))
        chat.host.always("session.resume", .init(result: resume(running: true, todos: todos(revision: 3, ["completed", "completed", "pending"]))))
        await chat.model.reconnectStreamIfNeeded()
        await waitUntil("listed on reattach") { work.activeCount == 2 }
        XCTAssertEqual(chat.spy.botStarts.count, 2, "the reattach adopted the bot's activity")
        XCTAssertEqual(chat.spy.summaries.last, ["Plan 3 of 3", "2 workers"])

        let shown = chat.spy.summaries.count
        chat.spy.drivenSessionID = "bot:\(UUID().uuidString):helper"
        chat.receive(event(7, "todo.updated", todos(revision: 4, ["completed", "completed", "completed"])))
        XCTAssertEqual(chat.spy.summaries.count, shown, "never another bot's activity")

        let session = await openChat(subagents: [worker("tests"), worker("docs")])
        await waitUntil("listed on connect") { session.turn.activity.delegatedWork.activeCount == 2 }
        session.receive(event(1, "message.start"))
        session.receive(event(2, "todo.updated", todos(revision: 1, ["in_progress", "pending"])))
        XCTAssertEqual(session.spy.starts.count, 1)
        XCTAssertEqual(session.spy.summaries, [], "a session's activity keeps its own chips")
    }

    /// A Bot Chat row opened from Archived resumes its key, and may be a deliberate archive that
    /// upstream's title lookup leaves out, or one the bot has since replaced. Its activity keeps
    /// the interim `hermes:` session identity, whose tap opens the app as it is, on this chat:
    /// no Bot route, so a tap never reaches the canonical lookup, opens the replacement or
    /// unarchives the original. The chat still keeps Bot Chat's rules.
    func testAnArchivedBotChatsActivityNeverTapsIntoTheCanonicalChat() async throws {
        let row = HermesSessionRow(id: "tip", title: "Bot Chat", archived: true, hidden: true, profile: "inbox-triage",
                                   lineageRootID: "root").summary(in: "default")
        let opened = try XCTUnwrap(row.hermesChat(on: Self.server, connection: Self.connection, listedIn: "default"))
        let excluded = BotJSON.object(["sessions": .array([])])
        let replaced = BotJSON.object(["sessions": .array([.object(["id": .string("newer"), "resolved_id": .string("newer")])])])
        for lookup in [excluded, replaced] {
            let chat = await openChat(snapshot: resume(running: false, profile: "inbox-triage"), target: opened.target,
                                      botChatRoot: opened.botChatRoot)
            chat.host.always("session.list", .init(result: lookup))
            XCTAssertEqual(chat.turn.policy, .botChat)
            chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(Self.startedAt)]))
            chat.receive(event(2, "message.start"))

            XCTAssertEqual(chat.spy.botStarts, [], "no Bot identity, whose tap would look the chat up by title")
            XCTAssertEqual(chat.spy.avatars, [])
            let start = try XCTUnwrap(chat.spy.starts.first)
            XCTAssertEqual(start.sessionID, "hermes:inbox-triage:tip")
            let attributes = AgentRunActivityAttributes(sessionID: start.sessionID, sessionTitle: start.title,
                                                        startedAt: start.startedAt, server: start.server)
            XCTAssertNil(AgentRunTapTarget.url(attributes: attributes, sessionID: start.sessionID, activityID: "a1"))
            XCTAssertFalse(chat.host.requests.contains { $0["method"].text == "session.list" },
                           "nothing looked up by title, so nothing replaced or restored")
        }
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
    /// A `.canonicalChat` target's title lookup finds root `root` at tip `tip`.
    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient
        let spy: Spy

        /// One event's params, or a host request envelope as is.
        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }
    }

    /// `roster` answers `profiles.list`; without one the read fails, so a Bot Chat keeps its
    /// bare Profile row. `subagents` answers `subagent.list`; without them the read fails.
    private func openChat(snapshot: BotJSON? = nil, excerpts: Bool = false,
                          target: ConversationTarget = .session(profile: "default", key: "tip"),
                          botChatRoot: String? = nil, roster: BotJSON? = nil, subagents: [BotJSON]? = nil) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: snapshot ?? resume(running: false)))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        if let roster { host.always("profiles.list", .init(result: roster)) }
        if let subagents { host.always("subagent.list", .init(result: .object(["subagents": .array(subagents)]))) }
        let client = BotClient(http: host.connection(Self.connection))
        // No automatic reconnect: a test reattaches when it says so.
        let engine = HermesConversation(server: Self.server, connection: Self.connection,
                                        target: target, wire: client,
                                        reconnectDelay: { _ in throw CancellationError() })
        let spy = Spy()
        let turn = HermesChatTurnCoordinator(engine: engine, botChatRoot: botChatRoot, liveActivities: spy,
                                             writeBotAvatar: { profile, _ in spy.writeAvatar(profile) },
                                             isNetworkAvailable: { true })
        // The chat's own webui manager is the same spy, so any write it made would show too.
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: Self.server, liveActivityManager: spy,
            showsLiveActivityResponseExcerpts: excerpts, streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, turn: turn, host: host, client: client, spy: spy)
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

    /// A roster whose `default` bot carries a saved name and a pinned face.
    private static func roster(title: String, expression: String?) -> BotJSON {
        var look: [String: BotJSON] = ["title": .string(title)]
        if let expression { look["expression"] = .string(expression) }
        return .object(["profiles": .array([.object(["name": .string("default"),
                                                     "ui_meta": .object(["hermes-bots": .object(look)])])])])
    }

    /// Waits on observation, never a clock, until `condition` holds.
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

    /// A live worker as `subagent.list` reports it.
    private func worker(_ id: String) -> BotJSON {
        .object(["subagent_id": .string(id), "goal": .string("Work on \(id)"), "depth": .number(0),
                 "started_at": .number(1_790_000_010), "status": .string("running")])
    }

    /// A `todo.updated` payload, or a snapshot's `todo_state`, with one step per status.
    private func todos(revision: Int, _ statuses: [String]) -> [String: BotJSON] {
        ["revision": .number(Double(revision)), "todos": .array(statuses.enumerated().map { index, status in
            .object(["id": .string("step-\(index)"), "content": .string("Step \(index + 1)"), "status": .string(status)])
        })]
    }

    private func resume(running: Bool, title: String? = nil, profile: String = "default",
                        todos: [String: BotJSON]? = nil) -> BotJSON {
        var info: [String: BotJSON] = ["profile_name": .string(profile)]
        if let title { info["title"] = .string(title) }
        var reply: [String: BotJSON] = [
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(running),
            "messages": .array([]), "info": .object(info)
        ]
        if running { reply["turn_started_at"] = .number(Self.startedAt) }
        if let todos { reply["todo_state"] = .object(todos) }
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

    /// A bot's activity as `startBot` asked for it.
    struct BotStart: Equatable {
        let key: String
        let destinationURL: URL
        let pushSessionID: String?
        let title: String
        let turn: String
        let startedAt: Date
    }

    /// The look a bot's avatar was drawn from.
    struct Avatar: Equatable {
        let title: String
        let expression: String?
    }

    private(set) var starts: [Start] = []
    private(set) var botStarts: [BotStart] = []
    private(set) var avatars: [Avatar] = []
    private(set) var events: [AgentLiveActivityEvent] = []
    private(set) var ends: [End] = []
    private(set) var staleCount = 0
    var drivenSessionID: String?

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {
        starts.append(Start(sessionID: sessionID, server: server, title: sessionTitle, streamID: streamID, startedAt: startedAt))
        drivenSessionID = sessionID
    }

    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date) {
        botStarts.append(BotStart(key: bot.key, destinationURL: bot.destinationURL, pushSessionID: bot.pushSessionID,
                                  title: title, turn: turn, startedAt: startedAt))
        drivenSessionID = bot.key
    }

    /// The titles `.sessionTitle` updates wrote.
    var titles: [String] {
        events.compactMap { if case .sessionTitle(let title) = $0 { title } else { nil } }
    }

    /// The count chips `.workSummary` updates wrote.
    var summaries: [[String]] {
        events.compactMap { if case .workSummary(let chips) = $0 { chips } else { nil } }
    }

    func writeAvatar(_ profile: BotProfile) -> String? {
        let look = BotProfileAppearance(profile: profile)
        avatars.append(Avatar(title: look.title, expression: look.expression))
        return "avatar.png"
    }

    func update(_ event: AgentLiveActivityEvent) { events.append(event) }
    func markStale() { staleCount += 1 }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity))
        drivenSessionID = nil
    }
}
