import XCTest
@testable import HermesMobile

/// #489: a bot's Live Activity: its identity, tap target, cold-launch ownership and relay
/// content. A bot's chat driving it is `HermesChatLiveActivityTests`; ActivityKit is
/// unreachable here.
@MainActor final class BotLiveActivityTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private let profile = BotProfile(.object(["name": .string("inbox-triage")]))!

    private func destination(_ connectionID: UUID = UUID()) -> BotDestination {
        BotDestination(server: server, connectionID: connectionID, profile: "inbox-triage", conversation: "root")
    }

    // MARK: Identity and ownership

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

    func testColdLaunchRestoresCompactPushOwnershipSoCompletedBotCanEndIt() throws {
        let bot = try XCTUnwrap(AgentRunActivityBot(destination()))
        let attributes = AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Inbox Triage",
                                                    streamID: bot.streamID(turn: "100.0"),
                                                    startedAt: Date(timeIntervalSince1970: 100), bot: bot)
        let state = try JSONDecoder().decode(AgentRunActivityAttributes.ContentState.self,
                                            from: Data(#"{"v":1,"status":"running","tool_calls":5}"#.utf8))
        let manager = AgentLiveActivityManager()
        XCTAssertTrue(manager.restoreOwnership(attributes: attributes, state: state))
        XCTAssertEqual(manager.drivenSessionID, bot.key)
        XCTAssertEqual(manager.currentStateForTesting()?.sessionTitle, "Inbox Triage")
        XCTAssertNil(manager.activeConnectedStreamID, "A restored push activity does not own a foreground stream")

        manager.end(status: .complete, activity: "Done", errorSummary: nil)
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
        XCTAssertFalse(manager.restoreOwnership(attributes: attributes, state: final))
        XCTAssertNil(manager.drivenSessionID)
        XCTAssertTrue(manager.restoreOwnership(attributes: attributes, state: running))
        var duplicate = attributes
        duplicate.sessionID = "another-bot"
        XCTAssertFalse(manager.restoreOwnership(attributes: duplicate, state: running))
        XCTAssertEqual(manager.drivenSessionID, bot.key)
    }

    /// A legacy compression moves a bot's stored key mid-turn (#1179): the adopted activity's
    /// pushes move to the new key, and a blank key moves nothing.
    func testABotsPushesFollowAKeyMove() throws {
        var bot = try XCTUnwrap(AgentRunActivityBot(destination()))
        bot.pushSessionID = "tip"
        let attributes = AgentRunActivityAttributes(sessionID: bot.key, sessionTitle: "Inbox Triage",
                                                    streamID: bot.streamID(turn: "100.0"),
                                                    startedAt: Date(timeIntervalSince1970: 100), bot: bot)
        let running = AgentRunActivityStateReducer.initialState(sessionID: bot.key, sessionTitle: "Inbox Triage")
        let manager = AgentLiveActivityManager()
        XCTAssertTrue(manager.restoreOwnership(attributes: attributes, state: running))
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip")
        manager.movePushSession(to: "tip-2")
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip-2")
        manager.movePushSession(to: "")
        XCTAssertEqual(manager.drivenPushSessionIDForTesting, "tip-2")
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

    private func activityState(
        status: AgentRunActivityStatus,
        isStale: Bool,
        currentActivity: String,
        chips: [String]? = nil,
        excerpt: String = "",
        errorSummary: String? = nil
    ) -> AgentRunActivityAttributes.ContentState {
        var state = AgentRunActivityAttributes.ContentState(
            sessionID: "bot-key",
            sessionTitle: "Inbox Triage",
            status: status,
            currentActivity: currentActivity,
            responseExcerpt: excerpt,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 140),
            isStale: isStale,
            isFinal: false,
            errorSummary: errorSummary
        )
        state.chips = chips
        return state
    }
}
