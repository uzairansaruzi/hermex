import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesChatSideTaskTests: XCTestCase {
    func testGoalSendShowsTheNoticeAndSubmitsTheMessageOnce() async {
        let chat = await openChat()
        chat.host.always("command.dispatch", .init(result: .object([
            "type": .string("send"), "notice": .string("⊙ Goal set (20-turn budget): write three haiku"),
            "message": .string("write three haiku")
        ])))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

        let submitted = await chat.model.submitGoal(args: "write three haiku")
        XCTAssertTrue(submitted)
        XCTAssertEqual(chat.writes("command.dispatch"), [[
            "name": .string("goal"), "arg": .string("write three haiku"), "session_id": .string("runtime")
        ]])
        XCTAssertEqual(chat.writes("prompt.submit"), [[
            "session_id": .string("runtime"), "text": .string("write three haiku"), "queued": .bool(true)
        ]])
        XCTAssertEqual(chat.model.messages.map(\.role), ["local_notice", "user"])
        XCTAssertEqual(chat.model.messages.map(\.content),
                       ["⊙ Goal set (20-turn budget): write three haiku", "write three haiku"])
        XCTAssertNotNil(chat.model.activeStreamID, "the message started the turn")
    }

    func testGoalExecShowsItsOutputAndSubmitsNothing() async {
        let chat = await openChat()
        chat.host.always("command.dispatch", .init(result: .object([
            "type": .string("exec"), "output": .string("⏸ Goal paused: write three haiku")
        ])))

        let submitted = await chat.model.submitGoal(args: "pause")
        XCTAssertTrue(submitted)
        XCTAssertEqual(chat.writes("command.dispatch").map { $0["arg"] }, [.string("pause")])
        XCTAssertEqual(chat.writes("prompt.submit"), [])
        XCTAssertEqual(chat.model.messages.map(\.content), ["⏸ Goal paused: write three haiku"])
        XCTAssertEqual(chat.model.messages.map(\.role), ["local_notice"])
    }

    func testGoalControlsRunMidTurnButANewGoalWaits() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        chat.host.next("command.dispatch", .init(result: .object([
            "type": .string("exec"), "output": .string("⏸ Goal paused: write three haiku")
        ])))
        chat.host.next("command.dispatch", .init(result: .object([
            "type": .string("send"), "notice": .string("▶ Goal resumed: write three haiku"),
            "message": .string("[Continuing toward your standing goal]"), "display": .string("/goal resume")
        ])))

        let paused = await chat.model.submitGoal(args: "pause")
        let resumed = await chat.model.submitGoal(args: "resume")
        XCTAssertTrue(paused)
        XCTAssertTrue(resumed)
        XCTAssertEqual(chat.writes("command.dispatch").map { $0["arg"] }, [.string("pause"), .string("resume")])
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [.string("[Continuing toward your standing goal]")])
        XCTAssertEqual(chat.model.queuedPromptMessages.first?.content, "[Continuing toward your standing goal]",
                       "the host holds the resume for the next turn")
        XCTAssertEqual(chat.model.pinnedLocalNotices,
                       ["⏸ Goal paused: write three haiku", "▶ Goal resumed: write three haiku"], "pinned until the turn ends")

        let setGoal = await chat.model.submitGoal(args: "write a sonnet")
        XCTAssertFalse(setGoal)
        XCTAssertEqual(chat.model.goalErrorMessage, "Wait for the current response to finish before changing goals.")
        XCTAssertEqual(chat.writes("command.dispatch").count, 2)
    }

    func testAFailedGoalCommandKeepsItsDraft() async {
        let chat = await openChat()
        chat.host.next("command.dispatch", .init(error: 4004))

        let refused = await chat.model.executeSlashCommand(Self.command("goal"), args: "wait abc")
        XCTAssertEqual(refused, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "refused", "the fixture host's message")

        chat.receive(event(1, "message.start"))
        let midTurn = await chat.model.executeSlashCommand(Self.command("goal"), args: "write a sonnet")
        XCTAssertEqual(midTurn, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "Wait for the current response to finish before changing goals.")
        XCTAssertEqual(chat.writes("command.dispatch").map { $0["arg"] }, [.string("wait abc")])
    }

    func testAGoalCommandOnAReapedRuntimeReattaches() async {
        let chat = await openChat()
        chat.host.next("command.dispatch", .init(error: 4001))
        let attached = chat.host.requests.count

        let submitted = await chat.model.submitGoal(args: "pause")
        XCTAssertFalse(submitted)
        XCTAssertEqual(chat.model.goalErrorMessage, "Reconnect to the server to manage goals.")
        await chat.turn.activate()
        let methods = chat.host.requests.dropFirst(attached).compactMap { $0["method"].text }
        XCTAssertEqual(methods.filter { !["session.control.read", "model.options", "profiles.list", "commands.catalog",
                                          "subagent.list"].contains($0) },
                       ["command.dispatch", "session.resume", "session.events.since", "session.resume"],
                       "reattaching only reads")
    }

    func testGoalStateFollowsTheSessionsControlSnapshots() async {
        let chat = await openChat(control: Self.control(goal: "write three haiku", status: "active"))
        await waitUntil("read") { chat.model.currentGoal?.status == "active" }
        XCTAssertEqual(chat.model.currentGoal?.goal, "write three haiku")
        XCTAssertEqual(chat.model.currentGoal?.maxTurns, 20)
        XCTAssertTrue(chat.model.hasActivatedGoalCommand, "the goal menu shows")
        XCTAssertEqual(chat.writes("session.control.read"), [["session_id": .string("runtime"), "profile": .string("default")]])

        chat.receive(event(1, "session.control.update", ["control": Self.control(goal: "write three haiku", status: "paused")]))
        XCTAssertEqual(chat.model.currentGoal?.status, "paused")

        chat.receive(event(2, "session.control.update", ["control": .object(["goal": .null, "revision": .string("")])]))
        XCTAssertNil(chat.model.currentGoal)
        XCTAssertTrue(chat.model.hasActivatedGoalCommand)
    }

    func testLoopAndHeartbeatFollowTheSessionsControlSnapshots() async {
        let chat = await openChat(control: Self.control(goal: "ship it", status: "active", loop: "active", heartbeat: "paused"))
        await waitUntil("read") { !chat.sideTasks.automations.isEmpty }
        XCTAssertEqual(chat.sideTasks.automations.map(\.kind), [.loop, .heartbeat])
        XCTAssertEqual(chat.sideTasks.automations.map(\.action), ["loop.pause", "heartbeat.resume"])
        XCTAssertEqual(chat.model.currentGoal?.goal, "ship it")

        chat.receive(event(1, "session.control.update", ["control": Self.control(heartbeat: "active")]))
        XCTAssertEqual(chat.sideTasks.automations.map(\.kind), [.heartbeat])
        XCTAssertEqual(chat.sideTasks.automations.map(\.status), ["active"])
        XCTAssertNil(chat.model.currentGoal)
        XCTAssertTrue(chat.model.showsGoalControls, "the menu shows for a heartbeat alone")

        chat.receive(event(2, "session.control.update", ["control": Self.control(heartbeat: "future")]))
        XCTAssertEqual(chat.sideTasks.automations.map(\.action), [nil], "an unknown state offers nothing")
    }

    func testAHeartbeatPausesAfterOneConfirmation() async throws {
        let chat = await openChat(control: Self.control(heartbeat: "active"))
        await waitUntil("read") { !chat.sideTasks.automations.isEmpty }
        let heartbeat = try XCTUnwrap(chat.sideTasks.automations.first)
        chat.host.always("session.control", .init(result: .object(["control": Self.control(heartbeat: "paused")])))

        chat.sideTasks.ask(heartbeat)
        XCTAssertEqual(chat.sideTasks.pendingAutomation, heartbeat)
        chat.sideTasks.cancelAutomation()
        XCTAssertNil(chat.sideTasks.pendingAutomation)
        XCTAssertEqual(chat.writes("session.control"), [], "nothing goes out before the confirmation")

        chat.sideTasks.ask(heartbeat)
        await chat.model.confirmHermesAutomation(heartbeat)
        XCTAssertNil(chat.sideTasks.pendingAutomation)
        XCTAssertEqual(chat.writes("session.control"), [[
            "session_id": .string("runtime"), "profile": .string("default"), "action": .string("heartbeat.pause")
        ]])
        XCTAssertEqual(chat.sideTasks.automations.map(\.status), ["paused"])
        XCTAssertNil(chat.model.sendErrorMessage)
    }

    func testAStaleControlSnapshotNeverReplacesANewerUpdate() async throws {
        let chat = await openChat(control: Self.control(loop: "active"), controlFirst: [
            event(1, "session.control.update", ["control": Self.control(loop: "active", heartbeat: "active")])
        ])
        await waitUntil("update") { chat.sideTasks.automations.count == 2 }
        _ = try? await chat.turn.engine.request(.sessionControlRead(sessionID: "runtime", profile: "default"),
                                                attempt: chat.turn.engine.generation)
        XCTAssertEqual(chat.sideTasks.automations.map(\.kind), [.loop, .heartbeat])

        let loop = try XCTUnwrap(chat.sideTasks.automations.first)
        chat.host.next("session.control", .init(
            result: .object(["control": Self.control(loop: "paused")]),
            before: [event(2, "session.control.update", ["control": Self.control(loop: "paused", heartbeat: "paused")])]
        ))
        chat.sideTasks.ask(loop)
        await chat.model.confirmHermesAutomation(loop)
        XCTAssertEqual(chat.sideTasks.automations.map(\.status), ["paused", "paused"])
    }

    func testAPauseStopsAtDispatchWhenItsHeartbeatIsReplaced() async throws {
        let chat = await openChat(control: Self.control(heartbeat: "active"))
        await waitUntil("read") { !chat.sideTasks.automations.isEmpty }
        let heartbeat = try XCTUnwrap(chat.sideTasks.automations.first)
        chat.host.always("session.control", .init(result: .object(["control": Self.control(heartbeat: "paused")])))
        let replacement = Self.control(heartbeat: "active", heartbeatPrompt: "summarize the news")
        withObservationTracking { _ = chat.sideTasks.isChangingAutomation } onChange: {
            MainActor.assumeIsolated { chat.receive(self.event(1, "session.control.update", ["control": replacement])) }
        }

        chat.sideTasks.ask(heartbeat)
        await chat.model.confirmHermesAutomation(heartbeat)
        XCTAssertEqual(chat.writes("session.control"), [])
        XCTAssertEqual(chat.sideTasks.automations.map(\.title), ["summarize the news"])
        XCTAssertEqual(chat.sideTasks.automations.map(\.status), ["active"])
        XCTAssertEqual(chat.model.sendErrorMessage, BotFailure.stale.localizedDescription)
    }

    func testAReattachDiscardsAPendingPause() async throws {
        let chat = await openChat(control: Self.control(loop: "active"))
        await waitUntil("read") { !chat.sideTasks.automations.isEmpty }
        let loop = try XCTUnwrap(chat.sideTasks.automations.first)
        chat.sideTasks.ask(loop)

        chat.model.suspendStreamForNavigation()
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertNil(chat.sideTasks.pendingAutomation, "the confirmation closes")
        await chat.model.confirmHermesAutomation(loop)
        XCTAssertEqual(chat.writes("session.control"), [])
        XCTAssertEqual(chat.model.sendErrorMessage, BotFailure.stale.localizedDescription)
    }

    func testAReattachHoldsPauseUntilItsControlReadLands() async throws {
        let chat = await openChat(control: Self.control(loop: "active"))
        await waitUntil("read") { !chat.sideTasks.automations.isEmpty }
        let loop = try XCTUnwrap(chat.sideTasks.automations.first)
        chat.host.always("session.control", .init(result: .object(["control": Self.control(loop: "paused")])))
        chat.host.next("session.control.read", .init(error: 5000, message: "busy"))
        let readSent = expectation(description: "this attach's read went out")
        chat.host.expect(readSent, onNext: "session.control.read")

        chat.model.suspendStreamForNavigation()
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.sideTasks.automations, [loop], "the menu keeps showing the loop")
        chat.sideTasks.ask(loop)
        XCTAssertNil(chat.sideTasks.pendingAutomation, "nothing to confirm before this attach's read")
        await chat.model.confirmHermesAutomation(loop)
        XCTAssertEqual(chat.writes("session.control"), [])
        XCTAssertEqual(chat.model.sendErrorMessage, BotFailure.stale.localizedDescription)
        await fulfillment(of: [readSent], timeout: 5)

        chat.host.always("session.control.read", .init(result: .object([
            "control": Self.control(loop: "active", heartbeat: "active")
        ])))
        chat.model.suspendStreamForNavigation()
        await chat.model.reconnectStreamIfNeeded()
        await waitUntil("this attach's read") { chat.sideTasks.automations.count == 2 }
        chat.sideTasks.ask(loop)
        await chat.model.confirmHermesAutomation(loop)
        XCTAssertEqual(chat.writes("session.control"), [[
            "session_id": .string("runtime"), "profile": .string("default"), "action": .string("loop.pause")
        ]])
    }

    func testARefusedPauseShowsTheHostsReason() async throws {
        let chat = await openChat(control: Self.control(loop: "active"))
        await waitUntil("read") { !chat.sideTasks.automations.isEmpty }
        chat.host.next("session.control", .init(error: 4004, message: "loop.pause failed: no loop"))

        let loop = try XCTUnwrap(chat.sideTasks.automations.first)
        chat.sideTasks.ask(loop)
        await chat.model.confirmHermesAutomation(loop)
        XCTAssertEqual(chat.model.sendErrorMessage, "loop.pause failed: no loop")
        XCTAssertEqual(chat.sideTasks.automations.map(\.status), ["active"])
        XCTAssertEqual(chat.writes("session.control").count, 1)
    }

    func testBtwDuringARunningTurnLeavesTheTurnIntact() async {
        let chat = await openChat()
        chat.host.always("prompt.btw", .init(result: .object(["task_id": .string("btw_1")])))
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Working")]))

        let result = await chat.model.executeSlashCommand(Self.command("btw"), args: "what are you doing?")
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("prompt.btw"), [["session_id": .string("runtime"), "text": .string("what are you doing?")]])

        XCTAssertEqual(chat.sideTasks.btw?.question, "what are you doing?")
        XCTAssertEqual(chat.sideTasks.btw?.state, .waiting)

        chat.receive(event(3, "btw.complete", ["task_id": .string("btw_1"), "question": .string("what are you doing?"),
                                               "text": .string("Checking the logs.")]))
        chat.receive(event(4, "message.delta", ["text": .string(" on it")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.sideTasks.btw?.state, .answered("Checking the logs."))
        XCTAssertEqual(chat.model.messages.map(\.content), ["Working on it"])
        XCTAssertNotNil(chat.model.activeStreamID, "the turn keeps running")

        chat.sideTasks.closeBtw()
        XCTAssertNil(chat.sideTasks.btw)
    }

    func testUnknownTaskIDsAreIgnored() async {
        let chat = await openChat()
        chat.host.always("prompt.btw", .init(result: .object(["task_id": .string("btw_1")])))
        _ = await chat.model.executeSlashCommand(Self.command("btw"), args: "what are you doing?")

        chat.receive(event(1, "btw.complete", ["task_id": .string("btw_9"), "text": .string("Someone else's answer")]))
        chat.receive(event(2, "background.complete", ["task_id": .string("bg_9"), "text": .string("Someone else's result")]))
        XCTAssertEqual(chat.sideTasks.btw?.state, .waiting)
        XCTAssertEqual(chat.model.messages, [])
    }

    func testASecondBtwWaitsForTheFirst() async {
        let chat = await openChat()
        chat.host.always("prompt.btw", .init(result: .object(["task_id": .string("btw_1")])))
        _ = await chat.model.executeSlashCommand(Self.command("btw"), args: "what are you doing?")

        let second = await chat.model.executeSlashCommand(Self.command("btw"), args: "and then?")
        XCTAssertEqual(second, .notDelivered, "the draft stays")
        XCTAssertEqual(chat.model.sendErrorMessage, "Wait for the current /btw answer to finish first.")
        XCTAssertEqual(chat.writes("prompt.btw").count, 1)
        XCTAssertEqual(chat.sideTasks.btw?.question, "what are you doing?")
    }

    func testAnAnswerThatBeatsTheAsksReplyStillLands() async {
        let chat = await openChat()
        chat.host.next("prompt.btw", .init(result: .object(["task_id": .string("btw_1")]), before: [
            event(1, "btw.complete", ["task_id": .string("btw_1"), "text": .string("error: no model")])
        ]))
        _ = await chat.model.executeSlashCommand(Self.command("btw"), args: "what are you doing?")
        XCTAssertEqual(chat.sideTasks.btw?.state, .answered("error: no model"))
    }

    func testABtwAnswerInTheReplayFillsThePanel() async {
        let chat = await openChat()
        chat.host.always("prompt.btw", .init(result: .object(["task_id": .string("btw_1")])))
        _ = await chat.model.executeSlashCommand(Self.command("btw"), args: "what are you doing?")
        chat.model.suspendStreamForNavigation()
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 1, events: [
            event(1, "btw.complete", ["task_id": .string("btw_1"), "text": .string("Checking the logs.")])
        ])))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.sideTasks.btw?.state, .answered("Checking the logs."))
    }

    func testABtwAnswerLostToATruncatedReplayIsUnavailable() async {
        let chat = await openChat()
        chat.host.always("prompt.btw", .init(result: .object(["task_id": .string("btw_1")])))
        _ = await chat.model.executeSlashCommand(Self.command("btw"), args: "what are you doing?")
        await reattachAfterTruncatedReplay(chat)
        XCTAssertEqual(chat.sideTasks.btw?.state, .unavailable)
    }

    func testBackgroundCompleteFillsTheCard() async {
        let chat = await openChat()
        chat.host.always("prompt.background", .init(result: .object(["task_id": .string("bg_1")])))

        let result = await chat.model.executeSlashCommand(Self.command("background"), args: "summarize this chat")
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("prompt.background"),
                       [["session_id": .string("runtime"), "text": .string("summarize this chat")]])
        XCTAssertEqual(chat.model.messages.map(\.content), [Self.card("Running in the background…")])

        chat.receive(event(1, "background.complete", ["task_id": .string("bg_1"), "text": .string("Three topics.")]))
        XCTAssertEqual(chat.model.messages.map(\.content), [Self.card("Three topics.")])
    }

    func testBackgroundCompletionArrivesInTheReplay() async {
        let chat = await startBackground()
        chat.model.suspendStreamForNavigation()
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 1, events: [
            event(1, "background.complete", ["task_id": .string("bg_1"), "text": .string("Three topics.")])
        ])))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.model.messages.map(\.content), [Self.card("Three topics.")])
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/bg_1/messages"), 0, "the replay needs no read")
    }

    func testATruncatedReplayReadsTheResultFromTheSideSession() async {
        let chat = await startBackground()
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/sessions/bg_1/messages" else { return nil }
            return .json(200, .object(["session_id": .string("bg_1"), "messages": .array([
                .object(["role": .string("user"), "content": .string("summarize this chat")]),
                .object(["role": .string("assistant"), "content": .string("Let me check."),
                         "tool_calls": .array([.object(["id": .string("call_1")])])]),
                .object(["role": .string("tool"), "content": .string("{}")]),
                .object(["role": .string("assistant"), "content": .string("Three topics.")])
            ])]))
        }
        await reattachAfterTruncatedReplay(chat)
        await waitUntil("filled") { chat.model.messages.map(\.content) == [Self.card("Three topics.")] }
        let read = HermesHostFixture.requests.first { $0.url?.path == "/api/sessions/bg_1/messages" }
        XCTAssertEqual(read?.url?.query, "profile=default")
        XCTAssertEqual(read?.httpMethod, "GET")
        XCTAssertEqual(chat.sideTasks.backgroundTasks.map(\.state), [.finished("Three topics.")])
    }

    func testAMissingSideSessionShowsTheResultUnavailable() async {
        let chat = await startBackground()
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/sessions/bg_1/messages" else { return nil }
            return .json(404, .object(["detail": .string("Session not found")]))
        }
        await reattachAfterTruncatedReplay(chat)
        await waitUntil("unavailable") { chat.model.messages.map(\.content) == [Self.card("Result unavailable.")] }
    }

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private static func command(_ name: String) -> SlashCommand {
        SlashCommandCatalog.command(named: name)!
    }

    private static func card(_ body: String, prompt: String = "summarize this chat") -> String {
        "**Background** \(prompt)\n\n\(body)"
    }

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient

        @MainActor var sideTasks: HermesChatSideTasks { turn.sideTasks }

        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private static func control(goal: String, status: String) -> BotJSON {
        .object(["goal": .object(["title": .string(goal), "status": .string(status), "turns_used": .number(0),
                                  "max_turns": .number(20), "subgoals": .array([])]),
                 "loop": .null, "heartbeat": .null, "revision": .string("r1")])
    }

    private static func control(goal: String? = nil, status: String = "active", loop: String? = nil,
                                heartbeat: String? = nil, heartbeatPrompt: String = "tidy the inbox") -> BotJSON {
        let goalRow: BotJSON = goal.map {
            .object(["title": .string($0), "status": .string(status), "turns_used": .number(0), "max_turns": .number(20)])
        } ?? .null
        let loopRow: BotJSON = loop.map {
            .object(["prompt": .string("check CI"), "status": .string($0), "mode": .string("interval"),
                     "interval_seconds": .number(600), "ticks_fired": .number(2), "deferred_by_goal": .bool(false)])
        } ?? .null
        let heartbeatRow: BotJSON = heartbeat.map {
            .object(["prompt": .string(heartbeatPrompt), "status": .string($0), "interval_seconds": .number(1800),
                     "fire_count": .number(4)])
        } ?? .null
        return .object(["goal": goalRow, "loop": loopRow, "heartbeat": heartbeatRow, "revision": .string("r2")])
    }

    private func openChat(control: BotJSON? = nil, controlFirst: [BotJSON] = []) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        if let control {
            host.always("session.control.read", .init(result: .object(["control": control]), before: controlFirst))
        }
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let client = BotClient(http: host.connection(Self.connection))
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: .session(profile: "default", key: "tip"), wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, turn: turn, host: host, client: client)
    }

    private func startBackground() async -> Chat {
        let chat = await openChat()
        chat.host.always("prompt.background", .init(result: .object(["task_id": .string("bg_1")])))
        _ = await chat.model.executeSlashCommand(Self.command("background"), args: "summarize this chat")
        return chat
    }

    private func reattachAfterTruncatedReplay(_ chat: Chat) async {
        chat.model.suspendStreamForNavigation()
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 600, truncated: true)))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:]) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }
}
