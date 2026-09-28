import XCTest
@testable import HermesMobile

/// #489: a bot's Live Activity. The feed and the conversation's snapshot are tested
/// at their own seams; ActivityKit itself is unreachable in unit tests.
@MainActor final class BotLiveActivityTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private let profile = BotProfile(.object(["name": .string("inbox-triage")]))!

    private func destination(_ connectionID: UUID = UUID()) -> BotDestination {
        BotDestination(server: server, connectionID: connectionID, profile: "inbox-triage", conversation: "root")
    }

    private func snapshot(_ destination: BotDestination, _ phase: BotLiveActivitySnapshot.Phase,
                          work: BotLiveActivitySnapshot.Work = .starting, chips: [String] = []) -> BotLiveActivitySnapshot {
        BotLiveActivitySnapshot(destination: destination, title: "Inbox Triage", phase: phase, work: work, chips: chips)
    }

    private func feed(_ spy: BotLiveActivitySpy, showsExcerpts: Bool = false) -> BotLiveActivityFeed {
        BotLiveActivityFeed(manager: spy, showsExcerpts: { showsExcerpts }, writeAvatar: { _, _ in "avatar.png" })
    }

    private let turn = BotLiveActivitySnapshot.Phase.working(turn: "100.0", startedAt: Date(timeIntervalSince1970: 100))

    // MARK: Feed

    func testWorkingTurnStartsABotActivityThatTapsBackToThatBot() throws {
        let spy = BotLiveActivitySpy()
        let target = destination()
        feed(spy).sync(snapshot(target, turn, work: .tool("search_mail"), chips: ["Plan 2 of 5"]), profile: profile)

        let started = try XCTUnwrap(spy.started.first)
        XCTAssertEqual(spy.started.count, 1)
        XCTAssertEqual(started.title, "Inbox Triage")
        XCTAssertEqual(started.bot.avatarFile, "avatar.png")
        XCTAssertEqual(HermesDeepLink.botDestination(from: started.bot.destinationURL), target)
        XCTAssertEqual(spy.events, [.toolStarted(name: "search_mail"), .workSummary(["Plan 2 of 5"])])
    }

    func testEqualProfileNamesOnTwoConnectionsNeverShareAnActivity() throws {
        let first = try XCTUnwrap(AgentRunActivityBot(destination()))
        let second = try XCTUnwrap(AgentRunActivityBot(destination()))
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertFalse(AgentLiveActivityReusePolicy.canReuseActivity(
            existingSessionID: first.key, existingStreamID: first.streamID(turn: "100.0"),
            requestedSessionID: second.key, requestedStreamID: second.streamID(turn: "100.0")))
        // The same bot's next turn is a new activity; a reconnect inside a turn is not.
        XCTAssertNotEqual(first.streamID(turn: "100.0"), first.streamID(turn: "200.0"))
    }

    func testDisconnectMarksStaleAndReconnectInsideTheTurnReadoptsIt() {
        let spy = BotLiveActivitySpy()
        let feed = feed(spy)
        let target = destination()
        feed.sync(snapshot(target, turn), profile: profile)
        feed.sync(snapshot(target, .disconnected), profile: profile)
        XCTAssertEqual(spy.staleCount, 1)

        feed.sync(snapshot(target, turn), profile: profile)
        XCTAssertEqual(spy.started.map(\.turn), ["100.0", "100.0"])
    }

    func testCompletionEndsOnlyTheActivityThisBotStillOwns() {
        let spy = BotLiveActivitySpy()
        let feed = feed(spy)
        let target = destination()
        feed.sync(snapshot(target, turn), profile: profile)
        // A webui run took the one activity over before the bot finished.
        spy.drivenSessionID = "webui-session"
        feed.sync(snapshot(target, .disconnected), profile: profile)
        feed.sync(snapshot(target, .finished(.complete)), profile: profile)
        XCTAssertEqual(spy.staleCount, 0)
        XCTAssertTrue(spy.ended.isEmpty)

        spy.drivenSessionID = AgentRunActivityBot(target)?.key
        feed.sync(snapshot(target, .finished(.cancelled)), profile: profile)
        XCTAssertEqual(spy.ended, [.cancelled])
    }

    func testColdLaunchRestoresCompactPushOwnershipSoCompletedBotCanEndIt() throws {
        let target = destination()
        let bot = try XCTUnwrap(AgentRunActivityBot(target))
        let attributes = AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Inbox Triage",
                                                    streamID: bot.streamID(turn: "100.0"),
                                                    startedAt: Date(timeIntervalSince1970: 100), bot: bot)
        let state = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self,
                                            from: Data(#"{"v":1,"status":"running","tool_calls":5}"#.utf8))
        let manager = AgentLiveActivityManager()
        XCTAssertTrue(manager.restoreBotOwnership(attributes: attributes, state: state))
        XCTAssertEqual(manager.drivenSessionID, bot.key)
        XCTAssertEqual(manager.currentStateForTesting()?.sessionTitle, "Inbox Triage")
        XCTAssertNil(manager.activeConnectedStreamID, "A restored push activity does not own a foreground stream")

        let feed = BotLiveActivityFeed(manager: manager, showsExcerpts: { false }, writeAvatar: { _, _ in nil })
        feed.sync(snapshot(target, .finished(.complete)), profile: profile)
        XCTAssertTrue(try XCTUnwrap(manager.currentStateForTesting()).isFinal)
        XCTAssertNil(manager.drivenSessionID)
    }

    func testColdLaunchRejectsFinalActivitiesAndDoesNotReplaceAnAdoptedOwner() throws {
        let bot = try XCTUnwrap(AgentRunActivityBot(destination()))
        let attributes = AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Inbox Triage",
                                                    streamID: bot.streamID(turn: "100.0"),
                                                    startedAt: Date(timeIntervalSince1970: 100), bot: bot)
        let running = AgentRunActivityStateReducer.initialState(sessionID: bot.key, sessionTitle: "Inbox Triage")
        let final = AgentRunActivityStateReducer.final(status: .complete, activity: "Done", state: running)
        let manager = AgentLiveActivityManager()
        XCTAssertFalse(manager.restoreBotOwnership(attributes: attributes, state: final))
        XCTAssertNil(manager.drivenSessionID)
        XCTAssertTrue(manager.restoreBotOwnership(attributes: attributes, state: running))
        var duplicate = attributes
        duplicate.sessionID = "another-bot"
        XCTAssertFalse(manager.restoreBotOwnership(attributes: duplicate, state: running))
        XCTAssertEqual(manager.drivenSessionID, bot.key)
    }

    /// The relay route for each kind of activity (#566): a webui run pushes under its
    /// own server and session ID, a bot under its destination's server and stored
    /// agent session, and an activity that names neither cannot be pushed.
    func testPushTargetRoutesWebuiRunsAndBotsToTheirOwnServerAndAgentSession() throws {
        let webui = AgentRunActivityAttributes(sessionID: "webui-session", sessionTitle: "Plan",
                                               startedAt: .now, server: server)
        XCTAssertEqual(webui.pushTarget, AgentRunActivityPushTarget(server: server, sessionID: "webui-session"))

        var bot = try XCTUnwrap(AgentRunActivityBot(destination()))
        let unsettled = AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Inbox Triage",
                                                   startedAt: .now, bot: bot)
        XCTAssertNil(unsettled.pushTarget, "A bot without its agent session ID has no route yet")
        bot.pushSessionID = "tip"
        let settled = AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Inbox Triage",
                                                 startedAt: .now, bot: bot)
        XCTAssertEqual(settled.pushTarget, AgentRunActivityPushTarget(server: server, sessionID: "tip"))

        let legacy = AgentRunActivityAttributes(sessionID: "webui-session", sessionTitle: "Plan", startedAt: .now)
        XCTAssertNil(legacy.pushTarget)
    }

    func testAnIdleBotNeverStartsAnActivityAndUnknownStateSaysNothing() {
        let spy = BotLiveActivitySpy()
        let feed = feed(spy)
        feed.sync(snapshot(destination(), .finished(.complete)), profile: profile)
        feed.sync(snapshot(destination(), .unknown), profile: profile)
        XCTAssertTrue(spy.started.isEmpty)
        XCTAssertTrue(spy.ended.isEmpty)
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testReplyTextReachesTheActivityOnlyWhenPreviewsAreOn() {
        let hidden = BotLiveActivitySpy()
        feed(hidden).sync(snapshot(destination(), turn, work: .responding("private words")), profile: profile)
        XCTAssertEqual(hidden.events, [.responding, .workSummary([])])

        let shown = BotLiveActivitySpy()
        feed(shown, showsExcerpts: true).sync(snapshot(destination(), turn, work: .responding("private words")), profile: profile)
        XCTAssertEqual(shown.events, [.interimAssistant("private words"), .workSummary([])])
    }

    func testTurningPreviewsOffClearsTextAlreadyOnTheActivity() {
        let spy = BotLiveActivitySpy()
        var shows = true
        let feed = BotLiveActivityFeed(manager: spy, showsExcerpts: { shows }, writeAvatar: { _, _ in nil })
        let target = destination()
        feed.sync(snapshot(target, turn, work: .responding("private words")), profile: profile)
        shows = false
        feed.sync(snapshot(target, turn, work: .tool("search_mail")), profile: profile)
        XCTAssertEqual(spy.events, [.interimAssistant("private words"), .workSummary([]),
                                    .clearResponseExcerpt, .toolStarted(name: "search_mail"), .workSummary([])])
    }

    func testAHostErrorEndsAsFailedAndAStopAsCancelled() async {
        let failed = BotFixtureWire(); failed.inflight = .object(["error": .string("boom")])
        let broken = conversation(failed)
        await broken.recover()
        XCTAssertEqual(broken.liveActivitySnapshot.phase, .finished(.failed))
        broken.suspend()

        let stopped = BotFixtureWire()
        stopped.transformResume = { snapshot in
            guard case .object(var fields) = snapshot else { return snapshot }
            fields["status"] = .string("interrupted")
            return .object(fields)
        }
        let halted = conversation(stopped)
        await halted.recover()
        XCTAssertEqual(halted.liveActivitySnapshot.phase, .finished(.cancelled))
        halted.suspend()
    }

    func testRepeatedSnapshotsAreCoalesced() {
        let spy = BotLiveActivitySpy()
        let feed = feed(spy)
        let same = snapshot(destination(), turn, work: .thinking, chips: ["3 tools"])
        feed.sync(same, profile: profile)
        feed.sync(same, profile: profile)
        XCTAssertEqual(spy.started.count, 1)
        XCTAssertEqual(spy.events, [.reasoning(""), .workSummary(["3 tools"])])
    }

    // MARK: Conversation snapshot

    private func conversation(_ wire: BotFixtureWire, feed: BotLiveActivityFeed? = nil) -> BotConversation {
        BotConversation(server: server,
                        connection: BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture"),
                        profile: profile, wire: wire,
                        drafts: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
                        liveActivityFeed: feed, reconnectDelay: { _ in })
    }

    // #676: the snapshot reads a bounded head of the reply, but leading whitespace
    // does not use up that head.
    func testReplyExcerptSkipsLeadingWhitespaceBeforeTheBoundedHead() async {
        let wire = BotFixtureWire(); wire.running = true
        let reply = String(repeating: " \n", count: 3_000) + "Hello"
        wire.inflight = .object(["started_at": .number(100), "assistant": .string(reply)])
        let model = conversation(wire)
        await model.recover()

        XCTAssertEqual(model.liveActivitySnapshot.work, .responding("Hello"))
    }

    func testRunningTurnProjectsBoundedCountsAndSuspendGoesStale() async {
        let wire = BotFixtureWire(); wire.running = true
        wire.inflight = .object(["started_at": .number(100), "assistant": .string("secret reply")])
        wire.todoState = .object(["revision": .number(1), "todos": .array([
            .object(["id": .string("a"), "content": .string("Read mail"), "status": .string("completed")]),
            .object(["id": .string("b"), "content": .string("Sort mail"), "status": .string("in_progress")])
        ])])
        let spy = BotLiveActivitySpy()
        let model = conversation(wire, feed: feed(spy))
        await model.recover()

        let live = model.liveActivitySnapshot
        XCTAssertEqual(live.phase, .working(turn: "100.0", startedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(live.chips, ["Plan 2 of 2"])
        XCTAssertEqual(live.destination.conversation, "root")
        XCTAssertEqual(live.agentSessionID, "tip")
        XCTAssertEqual(spy.started.first?.bot.pushSessionID, "tip")
        XCTAssertEqual(spy.started.map(\.turn), ["100.0"])
        // Previews are off in this feed, so the reply never left the conversation.
        XCTAssertFalse(spy.events.contains { if case .interimAssistant = $0 { true } else { false } })

        model.suspend()
        XCTAssertEqual(model.liveActivitySnapshot.phase, .disconnected)
        XCTAssertEqual(spy.staleCount, 1)

        // A callback from the closed socket changes nothing.
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1), "type": .string("message.delta")]))
        XCTAssertEqual(spy.staleCount, 1)
        XCTAssertEqual(spy.started.count, 1)
    }

    func testPushUsesTheStoredAgentSessionInsteadOfTheGatewayRuntimeOrRoot() async {
        let wire = BotFixtureWire()
        wire.root = "canonical-chat"
        wire.tip = "agent-session-after-compression"
        wire.runtimeID = "gateway-runtime"
        wire.running = true
        wire.inflight = .object(["started_at": .number(100)])
        let spy = BotLiveActivitySpy()
        let model = conversation(wire, feed: feed(spy))
        await model.recover()

        // Hermes constructs the agent with session_id=session_key. Its plugin
        // hooks use that stored ID, whereas RPC replies identify the runtime.
        XCTAssertEqual(spy.started.first?.bot.pushSessionID, wire.tip)
        XCTAssertNotEqual(spy.started.first?.bot.pushSessionID, model.runtime)
        XCTAssertEqual(model.liveActivitySnapshot.destination.conversation, wire.root)
        model.suspend()
    }

    func testPushSessionFollowsTheResolvedAgentSessionOnReconnect() async {
        let wire = BotFixtureWire()
        wire.running = true
        wire.inflight = .object(["started_at": .number(100)])
        let spy = BotLiveActivitySpy()
        let model = conversation(wire, feed: feed(spy))
        await model.recover()
        model.suspend()

        wire.tip = "next-agent-session"
        wire.runtimeID = "next-gateway-runtime"
        await model.recover()
        XCTAssertEqual(spy.started.map { $0.bot.pushSessionID }, ["tip", "next-agent-session"])
        model.suspend()
    }

    func testWorkThatFinishedWhileAwayEndsTheActivityOnReturn() async {
        let wire = BotFixtureWire(); wire.running = true
        wire.inflight = .object(["started_at": .number(100)])
        let spy = BotLiveActivitySpy()
        let model = conversation(wire, feed: feed(spy))
        await model.recover()
        model.suspend()

        wire.running = false; wire.inflight = .null
        await model.recover()
        XCTAssertEqual(spy.ended, [.complete])
        model.suspend()
    }

    func testABlockedBotSaysWhatItIsWaitingFor() async {
        let wire = BotFixtureWire(); wire.running = true; wire.attention = true
        let model = conversation(wire)
        await model.recover()
        XCTAssertEqual(model.liveActivitySnapshot.work, .waitingForApproval)
        model.suspend()
    }

    func testPureDecisionCoversStartUpdateWaitEndAndOwnership() throws {
        let target = destination()
        let key = try XCTUnwrap(AgentRunActivityBot(target)?.key)
        let running = snapshot(target, turn)
        XCTAssertEqual(BotLiveActivityFeed.decision(running, previous: nil, drivenSessionID: nil), .start)
        XCTAssertEqual(BotLiveActivityFeed.decision(running, previous: running, drivenSessionID: key), .update)
        XCTAssertEqual(BotLiveActivityFeed.decision(snapshot(target, .unknown), previous: running, drivenSessionID: key), .wait)
        XCTAssertEqual(BotLiveActivityFeed.decision(snapshot(target, .disconnected), previous: running, drivenSessionID: key), .stale)
        XCTAssertEqual(BotLiveActivityFeed.decision(snapshot(target, .finished(.failed)), previous: running, drivenSessionID: key), .end(.failed))
        XCTAssertEqual(BotLiveActivityFeed.decision(snapshot(target, .finished(.complete)), previous: running, drivenSessionID: "other"), .wait)
        var changedAgentSession = running
        changedAgentSession.agentSessionID = "compressed-agent-session"
        XCTAssertEqual(BotLiveActivityFeed.decision(changedAgentSession, previous: running, drivenSessionID: key), .start)
    }

    func testRelayContentDecodesWithoutLocalFieldsAndUsesAttributeIdentity() throws {
        let data = Data(#"{"v":1,"status":"running","tool":"terminal","tool_calls":3,"started_at":1800000000}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded.rawStatus, "running")
        XCTAssertEqual(decoded.status, .runningCommand)
        XCTAssertEqual(decoded.startedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(decoded.chips, ["3 tools"])
        let attributes = AgentRunActivityAttributes(sessionID: "bot-key", sessionTitle: "Triage", startedAt: .now)
        let shown = decoded.presented(attributes: attributes, systemIsStale: true)
        XCTAssertEqual(shown.sessionID, "bot-key")
        XCTAssertEqual(shown.sessionTitle, "Triage")
        XCTAssertTrue(shown.isStale)
    }

    func testUnknownVersionAndStatusSurviveRoundTripWithoutClaimingCompletion() throws {
        for json in [#"{"v":99,"status":"done"}"#, #"{"v":1,"status":"future-status"}"#] {
            let state = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: Data(json.utf8))
            XCTAssertEqual(state.status, .starting)
            XCTAssertFalse(state.isFinal)
            XCTAssertFalse(state.currentActivity.isEmpty)
            let copy = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(copy, state)
        }
    }

    func testRelayWaitAndFinalStatuses() throws {
        for (raw, expected, final) in [("waiting", AgentRunActivityStatus.waiting, false),
                                       ("done", .complete, true), ("failed", .failed, true)] {
            let beforeReceipt = Date()
            let data = try JSONSerialization.data(withJSONObject: ["v": 1, "status": raw])
            let state = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: data)
            XCTAssertEqual(state.status, expected)
            XCTAssertEqual(state.isFinal, final)
            XCTAssertGreaterThanOrEqual(state.updatedAt, beforeReceipt)
        }
    }

    // MARK: Detail chips (#644)

    func testOnlyARealUpdateTimeIsShownAsFreshness() throws {
        let stamped = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: Data(
            #"{"v":1,"status":"running","tool_calls":3,"started_at":1800000000,"updated_at":1800000042}"#.utf8))
        let sentAt = Date(timeIntervalSince1970: 1_800_000_042)
        XCTAssertEqual(stamped.updatedAt, sentAt)
        XCTAssertEqual(stamped.detailChips, [.text("3 tools"), .updated(sentAt)])

        let unstamped = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: Data(
            #"{"v":1,"status":"running","tool_calls":3,"started_at":1800000000}"#.utf8))
        XCTAssertFalse(unstamped.updateTimeIsKnown)
        XCTAssertEqual(unstamped.detailChips, [.text("3 tools")], "A decode time is never presented as an update time")

        var local = AgentRunActivityStateReducer.initialState(sessionID: "s", sessionTitle: "Plan",
                                                               startedAt: Date().addingTimeInterval(-60))
        local.updatedAt = Date()
        let written = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: JSONEncoder().encode(local))
        XCTAssertTrue(written.updateTimeIsKnown)
        XCTAssertEqual(written.detailChips, [.updated(local.updatedAt)])
    }

    /// A turn without tools sends nothing between its start and its end, so its last
    /// update is the start: "Updated … ago" would tick in step with the elapsed timer.
    func testAnUpdateFromTheRunsFirstMomentsDoesNotRepeatTheTimer() throws {
        let early = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: Data(
            #"{"v":1,"status":"running","started_at":1800000000,"updated_at":1800000002}"#.utf8))
        XCTAssertEqual(early.detailChips, [])
        let local = AgentRunActivityStateReducer.initialState(sessionID: "s", sessionTitle: "Plan")
        XCTAssertEqual(local.detailChips, [], "The app's own first write is the start too")
    }

    func testFinishedDetailPointsToTheReplyOnlyAfterCompletion() throws {
        func relay(_ status: String) throws -> AgentRunActivityAttributes.ContentState {
            try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: Data(
                #"{"v":1,"status":"\#(status)","tool_calls":5,"updated_at":1800000042}"#.utf8))
        }
        XCTAssertEqual(try relay("done").detailChips, [.text("5 tools"), .openReply])
        XCTAssertEqual(try relay("failed").detailChips, [.text("5 tools")])
        let silent = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self,
                                              from: Data(#"{"v":1,"status":"running"}"#.utf8))
        XCTAssertEqual(silent.detailChips, [], "Nothing to say leaves the row out")
    }

    func testLocalWritesKeepTheCountTheRelayShowed() throws {
        let shown = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self,
                                             from: Data(#"{"v":1,"status":"running","tool_calls":3}"#.utf8))
        let local = AgentRunActivityStateReducer.initialState(sessionID: "s", sessionTitle: "Plan")
        XCTAssertEqual(local.keepingCounts(from: shown).chips, ["3 tools"])
        var counted = local
        counted.chips = ["Plan 2 of 5"]
        XCTAssertEqual(counted.keepingCounts(from: shown).chips, ["Plan 2 of 5"], "A state's own chips win")
    }

    // MARK: Shared model

    func testAnActivityPersistedByAnOlderBuildStillDecodes() throws {
        let state = Data(#"{"sessionID":"s","sessionTitle":"T","status":"thinking","currentActivity":"Thinking","responseExcerpt":"","startedAt":0,"updatedAt":0,"isStale":false,"isFinal":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: state).chips)
        let attributes = Data(#"{"sessionID":"s","sessionTitle":"T","startedAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AgentRunActivityAttributes.self, from: attributes).bot)
    }

    func testChipsAreBoundedAndAvatarNamesCannotLeaveTheirDirectory() {
        let chips = AgentRunActivitySanitizer.chips(["a", " ", "b\nc", "d", String(repeating: "x", count: 80)])
        XCTAssertEqual(chips, ["a", "b c", "d"])
        XCTAssertNil(AgentRunActivityAvatarFile.url(named: "../escape.png"))
        XCTAssertNil(AgentRunActivityAvatarFile.url(named: nil))
    }
}

@MainActor private final class BotLiveActivitySpy: AgentLiveActivityManaging {
    struct Start { let bot: AgentRunActivityBot; let title: String; let turn: String }
    var started: [Start] = []
    var events: [AgentLiveActivityEvent] = []
    var ended: [AgentRunActivityStatus] = []
    var staleCount = 0
    var drivenSessionID: String?

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {}
    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date) {
        started.append(Start(bot: bot, title: title, turn: turn))
        drivenSessionID = bot.key
    }
    func update(_ event: AgentLiveActivityEvent) { events.append(event) }
    func markStale() { staleCount += 1 }
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ended.append(status); drivenSessionID = nil
    }
}
