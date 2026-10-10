import XCTest
@testable import HermesMobile

/// #489: a bot's Live Activity. The feed and its snapshots are tested at their own seams
/// (a Hermes chat's turn is `HermesChatLiveActivityTests`); ActivityKit is unreachable here.
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

    /// A bot activity's tap (#1146) opens the bot's canonical chat in the regular chat, under the
    /// root the activity named, through the selection every bot route ends at.
    func testATapOpensTheBotsCanonicalChat() throws {
        let connection = BotConnection(id: UUID(), name: "Mac", address: server, username: "user", password: "fixture")
        let bot = try XCTUnwrap(AgentRunActivityBot(destination(connection.id)))
        let attributes = AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Inbox Triage", startedAt: .now, bot: bot)
        let tap = try XCTUnwrap(AgentRunTapTarget.url(attributes: attributes, sessionID: bot.key, activityID: "activity-1"))

        var selection = BotInboxSelection()
        selection.open(try XCTUnwrap(HermesDeepLink.botDestination(from: tap)), connection: connection, profiles: [profile])
        let chat = try XCTUnwrap(selection.chat(server: server, connection: connection))
        XCTAssertEqual(chat.target, .canonicalChat(profile: "inbox-triage"))
        XCTAssertEqual(chat.linkedRoot, "root")
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

    func testRepeatedSnapshotsAreCoalesced() {
        let spy = BotLiveActivitySpy()
        let feed = feed(spy)
        let same = snapshot(destination(), turn, work: .thinking, chips: ["3 tools"])
        feed.sync(same, profile: profile)
        feed.sync(same, profile: profile)
        XCTAssertEqual(spy.started.count, 1)
        XCTAssertEqual(spy.events, [.reasoning(""), .workSummary(["3 tools"])])
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

    // MARK: Stale waiting presentation (#813)

    func testStaleBotPresentationSelectsOnlyPendingInput() {
        let counts = ["Plan 2 of 5", "2 workers"]
        let unrelated = "Sketching a diagram"
        let answer = String(localized: "Open to answer")
        let disconnected = String(localized: "Not connected")
        let reconnect = String(localized: "Open to reconnect")

        for status in AgentRunActivityStatus.allCases {
            for isStale in [false, true] {
                for isBot in [false, true] {
                    let state = activityState(status: status, isStale: isStale, currentActivity: unrelated, chips: counts)
                    let stale = AgentRunStaleBotPresentation.presentation(state: state, isBot: isBot)
                    let pending = isBot && isStale
                        && (status == .waitingForApproval || status == .waitingForClarification)
                    let where_ = "\(status) stale=\(isStale) bot=\(isBot)"

                    if pending {
                        XCTAssertEqual(stale?.lead, status.title, where_)
                        XCTAssertNotEqual(stale?.lead, state.currentActivity, where_)
                        XCTAssertEqual(stale?.action, answer, where_)
                        XCTAssertEqual(stale?.isPendingInput, true, where_)
                    } else if isBot && isStale {
                        XCTAssertEqual(stale?.lead, disconnected, where_)
                        XCTAssertEqual(stale?.action, reconnect, where_)
                        XCTAssertEqual(stale?.isPendingInput, false, where_)
                    } else {
                        XCTAssertNil(stale, where_)
                    }

                    let chips = AgentRunStaleBotPresentation.lockScreenChips(state: state, isBot: isBot)
                    if isBot && isStale, let action = stale?.action {
                        XCTAssertEqual(chips, counts + [action], where_)
                        XCTAssertEqual(chips.filter { $0 == action }.count, 1, where_)
                    } else {
                        XCTAssertEqual(chips, counts, where_)
                    }

                    let line = AgentRunStaleBotPresentation.expandedCountsLine(state: state, isBot: isBot)
                    if pending {
                        XCTAssertEqual(line, ([status.title] + counts + [answer]).joined(separator: " · "), where_)
                    } else if isBot && isStale {
                        XCTAssertEqual(line, ([disconnected] + counts).joined(separator: " · "), where_)
                    } else {
                        XCTAssertEqual(line, ([unrelated] + counts).joined(separator: " · "), where_)
                    }
                    XCTAssertEqual(AgentRunStaleBotPresentation.prefersWaitingAnswer(state: state, isBot: isBot), pending, where_)
                }
            }
        }
    }

    func testStalePendingInputKeepsItsAskBesideCountsErrorsAndExcerpts() {
        let answer = String(localized: "Open to answer")
        for status in [AgentRunActivityStatus.waitingForApproval, .waitingForClarification] {
            for currentActivity in ["", "not the ask"] {
                for counts: [String]? in [nil, [], ["Plan 2 of 5"]] {
                    var state = activityState(
                        status: status, isStale: true, currentActivity: currentActivity, chips: counts,
                        excerpt: "hidden reply", errorSummary: "boom")
                    let stale = AgentRunStaleBotPresentation.presentation(state: state, isBot: true)
                    XCTAssertEqual(stale?.lead, status.title)
                    XCTAssertNotEqual(stale?.lead, state.currentActivity)
                    XCTAssertNotEqual(stale?.lead, state.errorSummary)
                    let shownCounts = counts ?? []
                    let chips = AgentRunStaleBotPresentation.lockScreenChips(state: state, isBot: true)
                    XCTAssertEqual(chips, shownCounts + [answer])
                    XCTAssertEqual(chips.filter { $0 == answer }.count, 1)
                    XCTAssertFalse(chips.contains("hidden reply"))
                    let line = AgentRunStaleBotPresentation.expandedCountsLine(state: state, isBot: true)
                    XCTAssertEqual(line, ([status.title] + shownCounts + [answer]).joined(separator: " · "))
                    XCTAssertFalse(line.contains("hidden reply"))
                    XCTAssertTrue(AgentRunStaleBotPresentation.prefersWaitingAnswer(state: state, isBot: true))

                    state.isStale = false
                    XCTAssertNil(AgentRunStaleBotPresentation.presentation(state: state, isBot: true))
                    XCTAssertEqual(AgentRunStaleBotPresentation.lockScreenChips(state: state, isBot: true), shownCounts)
                    XCTAssertFalse(AgentRunStaleBotPresentation.prefersWaitingAnswer(state: state, isBot: true))
                    XCTAssertEqual(
                        AgentRunStaleBotPresentation.expandedCountsLine(state: state, isBot: true),
                        ([state.currentActivity] + shownCounts).joined(separator: " · "))
                }
            }
        }
    }

    /// Generic waiting, in-flight work, and final or failed runs stay on the
    /// disconnected card. Stopping is a conversation turn, not an activity status:
    /// the card keeps the mapped command line and does not become an ask.
    func testOrdinaryStaleBotsStayDisconnected() {
        let disconnected = String(localized: "Not connected")
        let reconnect = String(localized: "Open to reconnect")
        let counts = ["1 tool"]
        let cases: [(AgentRunActivityStatus, String, String?, Bool)] = [
            (.waiting, String(localized: "Waiting for you"), nil, false),
            (.runningCommand, String(localized: "Running command"), nil, false),
            (.usingTool, String(localized: "Using tool"), nil, false),
            (.thinking, String(localized: "Thinking"), nil, false),
            (.searchingFiles, String(localized: "Searching files"), nil, false),
            (.complete, String(localized: "Response complete"), nil, true),
            (.failed, String(localized: "Response failed"), "boom", true),
            (.cancelled, String(localized: "Response cancelled"), nil, true),
        ]
        for (status, activity, error, isFinal) in cases {
            let state = activityState(
                status: status, isStale: true, currentActivity: activity, chips: counts,
                excerpt: "hidden reply", errorSummary: error, isFinal: isFinal)
            let stale = AgentRunStaleBotPresentation.presentation(state: state, isBot: true)
            XCTAssertEqual(stale?.lead, disconnected, "\(status)")
            XCTAssertEqual(stale?.action, reconnect, "\(status)")
            XCTAssertEqual(stale?.isPendingInput, false, "\(status)")
            XCTAssertEqual(AgentRunStaleBotPresentation.lockScreenChips(state: state, isBot: true), counts + [reconnect])
            XCTAssertEqual(
                AgentRunStaleBotPresentation.expandedCountsLine(state: state, isBot: true),
                ([disconnected] + counts).joined(separator: " · "), "\(status)")
            XCTAssertFalse(AgentRunStaleBotPresentation.prefersWaitingAnswer(state: state, isBot: true), "\(status)")
        }

        let freshFailure = activityState(
            status: .failed, isStale: false, currentActivity: String(localized: "Response failed"),
            errorSummary: "boom", isFinal: true)
        XCTAssertNil(AgentRunStaleBotPresentation.presentation(state: freshFailure, isBot: true))
        XCTAssertNil(AgentRunStaleBotPresentation.presentation(state: freshFailure, isBot: false))
        let staleWebuiAsk = activityState(
            status: .waitingForApproval, isStale: true, currentActivity: "Sketching a diagram", chips: counts)
        XCTAssertNil(AgentRunStaleBotPresentation.presentation(state: staleWebuiAsk, isBot: false))
        XCTAssertEqual(
            AgentRunStaleBotPresentation.expandedCountsLine(state: staleWebuiAsk, isBot: false),
            (["Sketching a diagram"] + counts).joined(separator: " · "))
        XCTAssertFalse(AgentRunStaleBotPresentation.prefersWaitingAnswer(state: staleWebuiAsk, isBot: false))
    }

    func testStalePresentationDoesNotMutateActivityState() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = Date(timeIntervalSince1970: 1_800_000_042)
        var state = activityState(
            status: .waitingForClarification, isStale: true, currentActivity: "unrelated",
            chips: ["2 workers"], excerpt: "Ask which inbox", errorSummary: "boom",
            started: started, updated: updated)
        let encoded = try JSONEncoder().encode(state)
        let snapshot = state
        _ = AgentRunStaleBotPresentation.presentation(state: state, isBot: true)
        _ = AgentRunStaleBotPresentation.lockScreenChips(state: state, isBot: true)
        _ = AgentRunStaleBotPresentation.expandedCountsLine(state: state, isBot: true)
        _ = AgentRunStaleBotPresentation.prefersWaitingAnswer(state: state, isBot: true)
        XCTAssertEqual(state, snapshot)
        XCTAssertTrue(state.isStale)
        XCTAssertEqual(state.startedAt, started)
        XCTAssertEqual(state.updatedAt, updated)
        XCTAssertEqual(state.status, .waitingForClarification)
        XCTAssertEqual(state.responseExcerpt, "Ask which inbox")
        XCTAssertEqual(state.chips, ["2 workers"])
        XCTAssertEqual(try decodedActivity(JSONEncoder().encode(state)), try decodedActivity(encoded))

        // The widget reads presented state: ActivityKit staleness counts, the stored value does not change.
        var stored = state
        stored.isStale = false
        let storedEncoded = try JSONEncoder().encode(stored)
        let attributes = AgentRunActivityAttributes(
            sessionID: stored.sessionID, sessionTitle: stored.sessionTitle, startedAt: started)
        let presented = stored.presented(attributes: attributes, systemIsStale: true)
        XCTAssertEqual(try decodedActivity(JSONEncoder().encode(stored)), try decodedActivity(storedEncoded))
        XCTAssertFalse(stored.isStale)
        XCTAssertEqual(stored.status, .waitingForClarification)
        XCTAssertEqual(stored.responseExcerpt, state.responseExcerpt)
        XCTAssertTrue(presented.isStale)
        XCTAssertEqual(
            AgentRunStaleBotPresentation.presentation(state: presented, isBot: true)?.lead,
            AgentRunActivityStatus.waitingForClarification.title)
        XCTAssertNil(AgentRunStaleBotPresentation.presentation(state: stored, isBot: true))
        XCTAssertNil(AgentRunStaleBotPresentation.presentation(state: presented, isBot: false))
    }

    private func activityState(
        status: AgentRunActivityStatus,
        isStale: Bool,
        currentActivity: String,
        chips: [String]? = nil,
        excerpt: String = "",
        errorSummary: String? = nil,
        isFinal: Bool = false,
        started: Date = Date(timeIntervalSince1970: 100),
        updated: Date = Date(timeIntervalSince1970: 140)
    ) -> AgentRunActivityAttributes.ContentState {
        var state = AgentRunActivityAttributes.ContentState(
            sessionID: "bot-key",
            sessionTitle: "Inbox Triage",
            status: status,
            currentActivity: currentActivity,
            responseExcerpt: excerpt,
            startedAt: started,
            updatedAt: updated,
            isStale: isStale,
            isFinal: isFinal,
            errorSummary: errorSummary
        )
        state.chips = chips
        return state
    }

    private func decodedActivity(_ data: Data) throws -> AgentRunActivityAttributes.ContentState {
        try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self, from: data)
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
