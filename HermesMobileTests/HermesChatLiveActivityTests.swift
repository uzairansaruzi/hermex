import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesChatLiveActivityTests: XCTestCase {
    private static let startedAt = 1_790_000_000.5

    func testATurnStartsOneActivityAndAReattachAdoptsIt() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(Self.startedAt)]))
        chat.receive(event(2, "message.start"))
        chat.receive(event(3, "message.delta", ["text": .string("Working")]))
        chat.receive(event(4, "tool.start", ["name": .string("terminal"), "tool_id": .string("t1")]))
        XCTAssertEqual(chat.spy.starts, [.init(sessionID: "hermes:default:tip", server: Self.server,
                                               title: "Untitled Session", streamID: "1790000000.5",
                                               startedAt: Date(timeIntervalSince1970: Self.startedAt),
                                               destinationURL: try Self.link(profile: "default", key: "tip"),
                                               pushSessionID: "tip")])

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

    func testOpeningARunningSessionAdoptsTheTurnsActivityUnderItsTitle() async throws {
        let chat = await openChat(snapshot: resume(running: true, title: "Release plan"))
        XCTAssertEqual(chat.spy.starts, [.init(sessionID: "hermes:default:tip", server: Self.server,
                                               title: "Release plan", streamID: "1790000000.5",
                                               startedAt: Date(timeIntervalSince1970: Self.startedAt),
                                               destinationURL: try Self.link(profile: "default", key: "tip"),
                                               pushSessionID: "tip")])
    }

    func testAKeyMoveMidTurnKeepsTheActivityAndMovesItsPushes() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(Self.startedAt)]))
        chat.receive(event(2, "message.start"))
        chat.receive(event(3, "session.info", ["running": .bool(true), "stored_session_id": .string("tip-2")]))
        chat.receive(event(4, "session.info", ["running": .bool(true), "stored_session_id": .string("tip-2")]))
        XCTAssertEqual(chat.spy.moves, ["tip-2"])

        chat.model.suspendStreamForBackground()
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 4)))
        chat.host.always("session.resume", .init(result: resume(running: true, key: "tip-2")))
        await chat.model.reconnectStreamIfNeeded()
        let link = try Self.link(profile: "default", key: "tip")
        XCTAssertEqual(chat.spy.starts.map(\.sessionID), ["hermes:default:tip", "hermes:default:tip"])
        XCTAssertEqual(chat.spy.starts.map(\.streamID), ["1790000000.5", "1790000000.5"])
        XCTAssertEqual(chat.spy.starts.map(\.destinationURL), [link, link])
        XCTAssertEqual(chat.spy.starts.map(\.pushSessionID), ["tip", "tip-2"])
        XCTAssertEqual(chat.spy.moves, ["tip-2"], "the reattach found the key already moved")
        XCTAssertEqual(chat.spy.ends, [])
    }

    func testATurnBegunBySendStartsOneActivity() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Write a haiku")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Autumn")]))
        XCTAssertEqual(chat.spy.starts.map(\.sessionID), ["hermes:default:tip"],
                       "its own message.start continues the same turn")
    }

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

    func testTheReplyAfterAnAnsweredQuestionMovesTheActivityOffWaiting() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which file?")]))
        chat.receive(event(2, "request.cancel", ["id": .string("srq-c1"), "method": .string("clarify")]))
        chat.receive(event(3, "message.delta", ["text": .string("Using config.yml")]))
        XCTAssertEqual(chat.spy.events, [.waitingForClarification, .responding])
    }

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

    func testADroppedSocketMarksTheActivityStale() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.client.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(chat.spy.staleCount, 1)
        XCTAssertEqual(chat.spy.ends, [], "the turn may still be running on the host")
    }

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
        XCTAssertEqual(chat.spy.starts, [], "never the hermes: session identity")
        XCTAssertEqual(chat.spy.events.last, .toolStarted(name: "terminal"))

        chat.receive(event(4, "session.info", ["running": .bool(true), "stored_session_id": .string("tip-2")]))
        XCTAssertEqual(chat.spy.moves, ["tip-2"])
        XCTAssertEqual(chat.spy.botStarts.count, 1)

        chat.receive(event(5, "message.complete", ["text": .string("Done")]))
        chat.receive(event(6, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.spy.ends, [.init(status: .complete, activity: "Response complete")])
    }

    func testAMovedKeySurvivesAnotherRunTakingTheActivityBeforeAReattach() async throws {
        var bot = try XCTUnwrap(AgentRunActivityBot(BotDestination(server: Self.server, connectionID: Self.connection.id,
                                                                   profile: "default", conversation: "root")))
        bot.pushSessionID = "tip"
        let cases: [(target: ConversationTarget, attributes: AgentRunActivityAttributes)] = [
            (.canonicalChat(profile: "default"),
             AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Hermes", streamID: bot.streamID(turn: "1790000000.5"),
                                        startedAt: .now, bot: bot)),
            (.session(profile: "default", key: "tip"),
             AgentRunActivityAttributes(sessionID: "hermes:default:tip", sessionTitle: "Untitled Session",
                                        streamID: "1790000000.5", startedAt: .now, server: Self.server,
                                        pushSessionID: "tip"))
        ]
        for (target, attributes) in cases {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "HermesChatLiveActivityTests-\(UUID())"))
            let manager = AgentLiveActivityManager(pushKeys: LiveActivityPushKeys(defaults: defaults))
            let chat = await openChat(target: target, manager: manager)
            chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(Self.startedAt)]))
            chat.receive(event(2, "message.start"))
            chat.receive(event(3, "session.info", ["running": .bool(true), "stored_session_id": .string("tip-2")]))
            XCTAssertEqual(manager.drivenSessionID, attributes.sessionID)
            XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip-2")

            chat.model.suspendStreamForBackground()
            manager.start(sessionID: "webui-session", server: Self.server, sessionTitle: "Other run", streamID: "s1",
                          startedAt: .now)
            chat.host.always("session.list", .init(result: .object(["sessions": .array([
                .object(["id": .string("root"), "resolved_id": .string("tip-2")])])])))
            chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 3)))
            chat.host.always("session.resume", .init(result: resume(running: true, key: "tip-2")))
            await chat.model.reconnectStreamIfNeeded()
            XCTAssertEqual(manager.drivenSessionID, attributes.sessionID, "\(target): the chat drives its turn again")
            XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip-2", "\(target): its token registers under the moved key")
            let relaunched = LiveActivityPushKeys(defaults: defaults)
            XCTAssertEqual(relaunched.pushTarget(for: attributes)?.sessionID, "tip-2", "\(target): a relaunch finds the moved key")
        }
    }

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

    func testABotsPictureArrivingRedrawsItsRunningActivity() async throws {
        let chat = await openChat(snapshot: resume(running: true), target: .canonicalChat(profile: "default"),
                                  roster: Self.roster(title: "Inbox Triage", expression: nil, pictured: true), pictures: true)
        await waitUntil("the picture") { chat.turn.settings.avatars["default"] != nil }
        XCTAssertEqual(chat.spy.botStarts.count, 1)
        XCTAssertEqual(chat.spy.avatarPhotos, [false, false, true], "drawn again once the picture arrived")
        XCTAssertEqual(chat.spy.titles, ["Inbox Triage", "Inbox Triage"])
    }

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

    func testAnArchivedBotChatsActivityTapsBackToItsKey() async throws {
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
                                                        startedAt: start.startedAt, server: start.server,
                                                        destinationURL: start.destinationURL, pushSessionID: start.pushSessionID)
            let tap = try XCTUnwrap(AgentRunTapTarget.url(attributes: attributes, sessionID: start.sessionID, activityID: "a1"))
            XCTAssertNil(HermesDeepLink.botDestination(from: tap))
            XCTAssertEqual(HermesSessionDestination(url: tap),
                           HermesSessionDestination(server: Self.server, profile: "inbox-triage", key: "tip"),
                           "the link reopens the row by its key, which keeps its Bot Chat root")
            XCTAssertFalse(chat.host.requests.contains { $0["method"].text == "session.list" },
                           "nothing looked up by title, so nothing replaced or restored")
        }
    }

    func testATapOnAHermesSessionsActivityOpensItsSession() throws {
        let link = try Self.link(profile: "Research & review", key: "20260925_023517_59d8c3")
        let hermes = AgentRunActivityAttributes(sessionID: "hermes:Research & review:20260925_023517_59d8c3",
                                                sessionTitle: "Run", startedAt: .now, server: Self.server,
                                                destinationURL: link, pushSessionID: "20260925_023517_59d8c3")
        let tap = try XCTUnwrap(AgentRunTapTarget.url(attributes: hermes, sessionID: hermes.sessionID, activityID: "a1"))
        XCTAssertEqual(AgentRunTapTarget.activityID(from: tap), "a1")
        XCTAssertEqual(HermesSessionDestination(url: tap),
                       HermesSessionDestination(server: Self.server, profile: "Research & review", key: "20260925_023517_59d8c3"))

        let older = AgentRunActivityAttributes(sessionID: "hermes:default:tip", sessionTitle: "Run", startedAt: .now,
                                               server: Self.server)
        XCTAssertNil(AgentRunTapTarget.url(attributes: older, sessionID: "hermes:default:tip", activityID: "a1"))

        let webui = AgentRunActivityAttributes(sessionID: "20260925_023517_59d8c3", sessionTitle: "Run", startedAt: .now,
                                               server: Self.server)
        let url = try XCTUnwrap(AgentRunTapTarget.url(attributes: webui, sessionID: "20260925_023517_59d8c3",
                                                      activityID: "a2"))
        XCTAssertEqual(url.host, "webui-push")
    }

    private static let server = URL(string: "https://hermes.example")!

    private static func link(profile: String, key: String) throws -> URL {
        try XCTUnwrap(HermesDeepLink.sessionURL(for: HermesSessionDestination(server: server, profile: profile, key: key)))
    }
    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient
        let spy: Spy

        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }
    }

    private func openChat(snapshot: BotJSON? = nil, excerpts: Bool = false,
                          target: ConversationTarget = .session(profile: "default", key: "tip"),
                          botChatRoot: String? = nil, roster: BotJSON? = nil, subagents: [BotJSON]? = nil,
                          pictures: Bool = false, manager: AgentLiveActivityManager? = nil) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        BotAvatarStore.shared.removeAll(connectionID: Self.connection.id)
        let host = BotSocketHost()
        host.always("session.resume", .init(result: snapshot ?? resume(running: false)))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        if let roster { host.always("profiles.list", .init(result: roster)) }
        if let subagents { host.always("subagent.list", .init(result: .object(["subagents": .array(subagents)]))) }
        if pictures {
            host.always("profiles.get_asset", .init(result: .object(["found": .bool(true), "data": .string(botAvatarDataURL(side: 4))])))
        }
        let client = BotClient(http: host.connection(Self.connection))
        let engine = HermesConversation(server: Self.server, connection: Self.connection,
                                        target: target, wire: client,
                                        reconnectDelay: { _ in throw CancellationError() })
        let spy = Spy()
        let turn = HermesChatTurnCoordinator(engine: engine, botChatRoot: botChatRoot, liveActivities: manager ?? spy,
                                             writeBotAvatar: { profile, destination in spy.writeAvatar(profile, destination) },
                                             isNetworkAvailable: { true })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: Self.server, liveActivityManager: manager ?? spy,
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

    private func request(_ method: String, id: String, _ params: [String: BotJSON]) -> BotJSON {
        var params = params
        params["session_id"] = .string("runtime")
        return .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)])
    }

    private static func roster(title: String, expression: String?, pictured: Bool = false) -> BotJSON {
        var look: [String: BotJSON] = ["title": .string(title)]
        if let expression { look["expression"] = .string(expression) }
        return .object(["profiles": .array([.object(["name": .string("default"), "has_avatar": .bool(pictured),
                                                     "ui_meta": .object(["hermes-bots": .object(look)])])])])
    }

    private func worker(_ id: String) -> BotJSON {
        .object(["subagent_id": .string(id), "goal": .string("Work on \(id)"), "depth": .number(0),
                 "started_at": .number(1_790_000_010), "status": .string("running")])
    }

    private func todos(revision: Int, _ statuses: [String]) -> [String: BotJSON] {
        ["revision": .number(Double(revision)), "todos": .array(statuses.enumerated().map { index, status in
            .object(["id": .string("step-\(index)"), "content": .string("Step \(index + 1)"), "status": .string(status)])
        })]
    }

    private func resume(running: Bool, title: String? = nil, profile: String = "default", key: String = "tip",
                        todos: [String: BotJSON]? = nil) -> BotJSON {
        var info: [String: BotJSON] = ["profile_name": .string(profile)]
        if let title { info["title"] = .string(title) }
        var reply: [String: BotJSON] = [
            "session_id": .string("runtime"), "session_key": .string(key), "running": .bool(running),
            "messages": .array([]), "info": .object(info)
        ]
        if running { reply["turn_started_at"] = .number(Self.startedAt) }
        if let todos { reply["todo_state"] = .object(todos) }
        return .object(reply)
    }
}

@MainActor private final class Spy: AgentLiveActivityManaging {
    struct Start: Equatable {
        let sessionID: String
        let server: URL
        let title: String
        let streamID: String?
        let startedAt: Date
        var destinationURL: URL?
        var pushSessionID: String?
    }

    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
    }

    struct BotStart: Equatable {
        let key: String
        let destinationURL: URL
        let pushSessionID: String?
        let title: String
        let turn: String
        let startedAt: Date
    }

    struct Avatar: Equatable {
        let title: String
        let expression: String?
    }

    private(set) var starts: [Start] = []
    private(set) var botStarts: [BotStart] = []
    private(set) var avatars: [Avatar] = []
    private(set) var avatarPhotos: [Bool] = []
    private(set) var events: [AgentLiveActivityEvent] = []
    private(set) var ends: [End] = []
    private(set) var staleCount = 0
    private(set) var moves: [String] = []
    private var drivenPushSessionID: String?
    var drivenSessionID: String?

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {
        starts.append(Start(sessionID: sessionID, server: server, title: sessionTitle, streamID: streamID, startedAt: startedAt))
        drivenSessionID = sessionID
    }

    func startSession(sessionID: String, server: URL, destinationURL: URL?, pushSessionID: String,
                      sessionTitle: String, turn: String, startedAt: Date) {
        starts.append(Start(sessionID: sessionID, server: server, title: sessionTitle, streamID: turn, startedAt: startedAt,
                            destinationURL: destinationURL, pushSessionID: pushSessionID))
        drivenSessionID = sessionID
        drivenPushSessionID = pushSessionID
    }

    func movePushSession(to key: String) {
        guard key != drivenPushSessionID else { return }
        drivenPushSessionID = key
        moves.append(key)
    }

    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date) {
        botStarts.append(BotStart(key: bot.key, destinationURL: bot.destinationURL, pushSessionID: bot.pushSessionID,
                                  title: title, turn: turn, startedAt: startedAt))
        drivenSessionID = bot.key
        drivenPushSessionID = bot.pushSessionID
    }

    var titles: [String] {
        events.compactMap { if case .sessionTitle(let title) = $0 { title } else { nil } }
    }

    var summaries: [[String]] {
        events.compactMap { if case .workSummary(let chips) = $0 { chips } else { nil } }
    }

    func writeAvatar(_ profile: BotProfile, _ destination: BotDestination) -> String? {
        let look = BotProfileAppearance(profile: profile)
        avatars.append(Avatar(title: look.title, expression: look.expression))
        avatarPhotos.append(BotAvatarStore.shared.images(connectionID: destination.connectionID)[profile.id] != nil)
        return "avatar.png"
    }

    func update(_ event: AgentLiveActivityEvent) { events.append(event) }
    func markStale() { staleCount += 1 }

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity))
        drivenSessionID = nil
    }
}
