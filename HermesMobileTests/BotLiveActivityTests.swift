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

    func start(sessionID: String, sessionTitle: String, streamID: String?, startedAt: Date) {}
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
