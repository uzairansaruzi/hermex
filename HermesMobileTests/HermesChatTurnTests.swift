import XCTest
import Observation
@testable import HermesMobile

/// A Hermes session in the main chat (#1010): `HermesChatTurnCoordinator` reducing the
/// engine's frames onto `ChatViewModel`, over #901's socket-level host and the frames
/// recorded at the `HERMES_AGENT_TESTED_SHA` pin.
@MainActor final class HermesChatTurnTests: XCTestCase {
    // MARK: Reducer

    /// The recorded canned turn starts with no prompt from this phone, streams its text
    /// and title, and goes idle only once `session.info` says so after `message.complete`.
    func testRecordedTurnStreamsTextAndTitleAndEndsOnSessionInfo() async throws {
        let frames = try recorded("turn-frames")
        let chat = await openChat(runtime: "e7d1ef0d", key: "20260925_023517_59d8c3", profile: "inbox-triage")
        chat.receive(frames[0])
        chat.receive(frames[1])
        XCTAssertNotNil(chat.model.activeStreamID, "an unprompted message.start starts a turn")
        XCTAssertEqual(chat.model.activeRunStartedAt, Date(timeIntervalSince1970: 1790318117.362543),
                       "the run counts from the host's turn_started_at")

        frames[2...8].forEach(chat.receive)
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.map(\.role), ["assistant"])
        XCTAssertEqual(chat.model.messages.map(\.content), ["ok"],
                       "reasoning.available repeats the answer and is never shown again")
        XCTAssertEqual(chat.model.liveReasoningText, "", "thinking.delta is spinner text, not reasoning")
        XCTAssertEqual(chat.model.displayTitle, "fixture-redacted")
        XCTAssertNotNil(chat.model.activeStreamID, "message.complete alone does not make the chat idle")
        XCTAssertEqual(chat.model.contextWindowSnapshot?.contextLength, 1_048_576)
        XCTAssertEqual(chat.model.contextWindowSnapshot?.tokensUsed, 14_215)

        chat.receive(frames[9])
        XCTAssertNil(chat.model.activeStreamID)
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .completed)
        XCTAssertEqual(chat.model.runEndTrigger, 1)
        XCTAssertEqual(chat.liveActivity.titles, [], "a Hermes title never reaches a webui Live Activity")

        // The host sends no `session.info {running: true}` before a later turn's start.
        chat.receive(event(11, "message.start", runtime: "e7d1ef0d"))
        XCTAssertNotEqual(chat.model.activeRunStartedAt, Date(timeIntervalSince1970: 1790318117.362543),
                          "a later turn never counts from the last one's start")
    }

    /// The recorded tool turn: the interim reply, one tool row keyed by `tool_id` from start
    /// to completion, the approval as an open request until it is withdrawn, and the final
    /// answer that only `message.complete` carries.
    func testRecordedToolTurnKeysToolsByIDAndAppendsTheFinalAnswer() async throws {
        let frames = try recorded("turn-tool-approval-frames")
        let key = try XCTUnwrap(frames[0]["params"]["payload"]["stored_session_id"].text)
        let chat = await openChat(runtime: "7dd4dff2", key: key, profile: "default")
        frames[0...7].forEach(chat.receive)
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.liveToolCalls.map(\.id), ["fixture-redacted"])
        XCTAssertEqual(chat.model.liveToolCalls.map(\.name), ["terminal"])
        XCTAssertEqual(chat.model.liveToolCalls.map(\.isCompleted), [false])

        chat.receive(frames[8])
        XCTAssertTrue(chat.model.stopNeedsConfirmation, "the approval is an open request")
        chat.receive(frames[9])
        XCTAssertFalse(chat.model.stopNeedsConfirmation, "request.cancel withdrew it")

        frames[10...].forEach(chat.receive)
        XCTAssertEqual(chat.model.liveToolCalls.map(\.id), ["fixture-redacted"], "the completion found its start")
        XCTAssertEqual(chat.model.liveToolCalls.map(\.isCompleted), [true])
        XCTAssertEqual(chat.model.messages.map(\.content), ["Let me run a quick check.\n\nThe command returned: 1."])
        XCTAssertEqual(chat.model.latestTurnToolCalls.map(\.name), ["terminal"])
        XCTAssertNil(chat.model.activeStreamID)
    }

    func testReasoningDeltaIsReasoningAndThinkingDeltaIsNot() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "thinking.delta", ["text": .string("pondering...")]))
        chat.receive(event(3, "reasoning.delta", ["text": .string("Check the config first.")]))
        chat.receive(event(4, "message.delta", ["text": .string("Done.")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.liveReasoningText, "Check the config first.")
        XCTAssertEqual(chat.model.messages.map(\.content), ["Done."])
    }

    /// An error after the turn's `message.start` with no completion after it: the turn ends
    /// failed when the host settles it.
    func testALoneErrorEndsTheTurnAsFailedWhenTheHostSettles() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Part")]))
        chat.receive(event(3, "error", ["message": .string("Provider unavailable")]))
        XCTAssertEqual(chat.model.sendErrorMessage, "Provider unavailable")
        XCTAssertNotNil(chat.model.activeStreamID, "session.info settles the turn")

        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertNil(chat.model.activeStreamID)
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .failed)
        XCTAssertEqual(chat.model.runEndOutcome, .failed)
        XCTAssertEqual(chat.model.runEndTrigger, 1)
    }

    /// A warning the turn goes on past, such as a model switch that failed at its start, is
    /// an `error` too: the reply stays one row, and the turn ends once, completed.
    func testAnErrorTheTurnGoesOnPastKeepsOneTurn() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Checking")]))
        chat.receive(event(3, "error", ["message": .string("Could not switch model: unknown model")]))
        chat.receive(event(4, "message.delta", ["text": .string(" done.")]))
        chat.receive(event(5, "message.complete", ["status": .string("complete"), "text": .string("Checking done.")]))
        chat.receive(event(6, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.model.messages.map(\.content), ["Checking done."])
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .completed)
        XCTAssertEqual(chat.model.runEndTrigger, 1)
    }

    /// A turn the host refuses before starting it sends only an `error`: it ends at once.
    func testAnErrorBeforeTheTurnStartsEndsItAtOnce() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Summarize the logs")
        XCTAssertNotNil(chat.model.activeStreamID)
        chat.receive(event(1, "error", ["message": .string("This session is active on another machine")]))
        XCTAssertNil(chat.model.activeStreamID)
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .failed)
        XCTAssertEqual(chat.model.runEndTrigger, 1)
    }

    /// Stop is one `session.interrupt`; the run ends stopped only from its own frames, and a
    /// stopped run raises no completion alert.
    func testStopInterruptsOnceAndEndsOnTheInterruptedCompletion() async {
        let chat = await openChat()
        chat.host.always("session.interrupt", .init(result: .object(["status": .string("interrupted")])))
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Working on")]))

        let stopped = await chat.model.cancelActiveStream()
        XCTAssertTrue(stopped)
        XCTAssertNotNil(chat.model.activeStreamID, "an accepted stop is not idle yet")
        _ = await chat.model.cancelActiveStream()
        XCTAssertEqual(chat.writes("session.interrupt"), [["session_id": .string("runtime")]], "a stop goes out once")

        chat.receive(event(3, "message.complete", ["status": .string("interrupted"), "text": .string("Working on")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertNil(chat.model.activeStreamID)
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .cancelled)
        XCTAssertEqual(chat.model.runEndTrigger, 0)
    }

    // MARK: Sending

    func testSendSubmitsAQueuedPromptOnceAndShowsIt() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        let sent = await chat.model.sendMessage("Summarize the logs")
        XCTAssertTrue(sent)
        XCTAssertEqual(chat.writes("prompt.submit"), [[
            "session_id": .string("runtime"), "text": .string("Summarize the logs"), "queued": .bool(true)
        ]], "no config.set or session.cwd.set, and one submit")
        XCTAssertEqual(chat.model.messages.map(\.content), ["Summarize the logs"])
        XCTAssertNotNil(chat.model.activeStreamID, "streaming starts the turn")

        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Two errors.")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.map(\.role), ["user", "assistant"], "its own message.start is the same turn")
    }

    /// A reply that is neither a start nor a queue might have been taken: the draft stays,
    /// and nothing is sent again.
    func testAnUnknownAcknowledgmentKeepsTheDraftAndSendsOnce() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("something new")])))
        let sent = await chat.model.sendMessage("Deploy it")
        XCTAssertFalse(sent, "false keeps the draft in the composer")
        XCTAssertEqual(chat.model.sendErrorMessage, "Hermes did not confirm this message. Your draft is still here.")
        XCTAssertEqual(chat.model.messages, [])
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
    }

    /// A new session's draft keeps the new-session key until the host accepts its first
    /// prompt, so leaving before sending leaves it for the next New Session. Then it moves
    /// to the session's own key.
    func testANewSessionKeepsItsDraftUntilItsFirstPromptIsAccepted() async throws {
        let drafts = ChatDraftStore(persistence: InMemoryDraftPersistence(), debounceDuration: .seconds(60))
        let server = URL(string: "https://hermes.example")!
        let newKey = ChatDraftKey.hermesSession(server: server, connectionID: Self.connection.id, profile: "default", key: nil)
        drafts.setDraft("Plan the release", for: newKey)
        let chat = await openChat(key: "fresh", target: .new(profile: "default"), drafts: drafts)
        XCTAssertEqual(chat.model.hermesDraftKey, newKey, "created, but nothing sent")
        chat.model.suspendStreamForNavigation()
        let kept = await drafts.draft(for: newKey)
        XCTAssertEqual(kept?.text, "Plan the release", "leaving keeps it for the next New Session")

        await chat.model.reconnectStreamIfNeeded()
        chat.host.next("prompt.submit", .init(result: .object(["status": .string("something new")])))
        _ = await chat.model.sendMessage("Plan the release")
        XCTAssertEqual(chat.model.hermesDraftKey, newKey, "an unconfirmed prompt moves nothing")

        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Plan the release")
        let sessionKey = ChatDraftKey.hermesSession(server: server, connectionID: Self.connection.id, profile: "default", key: "fresh")
        XCTAssertEqual(chat.model.hermesDraftKey, sessionKey)
        let moved = await drafts.draft(for: sessionKey)
        XCTAssertEqual(moved?.text, "Plan the release")
        let left = await drafts.draft(for: newKey)
        XCTAssertNil(left)
        XCTAssertEqual(chat.host.requests.filter { $0["method"].text == "session.create" }.count, 1,
                       "returning resumed the created session")
    }

    func testAcceptedSteerShowsItsEchoAndARefusedOneKeepsTheDraftAndTheRun() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.next("session.steer", .init(result: .object(["status": .string("queued")])))
        let accepted = await chat.model.submitStreamingMessage("Use tabs", behavior: .steer)
        XCTAssertEqual(accepted, .executed(message: nil))
        XCTAssertEqual(chat.model.messages.last?.isSteerMessage, true)
        XCTAssertEqual(chat.model.steeringConfirmationNotice, "Steering hint delivered.")

        chat.host.next("session.steer", .init(result: .object(["status": .string("rejected")])))
        let refused = await chat.model.submitStreamingMessage("Use spaces", behavior: .steer)
        XCTAssertEqual(refused, .notDelivered, "the draft stays")
        XCTAssertEqual(chat.model.steerFailureMessage, "Couldn't steer")
        XCTAssertNotNil(chat.model.activeStreamID, "a refused steer does not stop the run (#856)")
        XCTAssertEqual(chat.writes("session.steer").map { $0["text"] }, [.string("Use tabs"), .string("Use spaces")])
        XCTAssertEqual(chat.writes("session.interrupt"), [])
    }

    /// Stop & send is `session.redirect`: the new prompt takes a row, and the reply after it a new one.
    func testStopAndSendRedirectsTheTurn() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Reading every file")]))
        chat.host.always("session.redirect", .init(result: .object(["status": .string("redirected")])))
        let result = await chat.model.submitStreamingMessage("Only the README", behavior: .interrupt)
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("session.redirect"), [["session_id": .string("runtime"), "text": .string("Only the README")]])

        chat.receive(event(3, "message.delta", ["text": .string("README says hi.")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.map(\.content), ["Reading every file", "Only the README", "README says hi."])
    }

    /// Queue holds the prompt on the host behind a receipt; when the host runs it, its turn
    /// shows it.
    func testQueueHoldsThePromptOnTheHostUntilItsTurnStarts() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        let result = await chat.model.submitStreamingMessage("Then the tests", behavior: .queue)
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("prompt.submit").first?["queued"], .bool(true))
        XCTAssertEqual(chat.model.queuedMessagesReceipt, "Queued, sends when this run finishes")
        XCTAssertEqual(chat.model.messages, [], "nothing shows until the host runs it")

        chat.receive(event(2, "message.complete", ["status": .string("complete")]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        chat.receive(event(4, "message.start"))
        XCTAssertEqual(chat.model.messages.map(\.content), ["Then the tests"])
        XCTAssertNil(chat.model.queuedMessagesReceipt)
    }

    /// Another client's Stop discards the host's queue too: the receipt goes, Stop no longer
    /// asks, and the next turn does not show the discarded prompt.
    func testAStopFromAnotherClientClearsTheQueuedReceipt() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        _ = await chat.model.submitStreamingMessage("Then the tests", behavior: .queue)
        XCTAssertTrue(chat.model.stopNeedsConfirmation)

        chat.receive(event(2, "message.complete", ["status": .string("interrupted")]))
        XCTAssertNil(chat.model.queuedMessagesReceipt)
        XCTAssertFalse(chat.model.stopNeedsConfirmation)
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        chat.receive(event(4, "message.start"))
        XCTAssertEqual(chat.model.messages, [], "the next turn is not the discarded prompt")
        XCTAssertEqual(chat.writes("session.interrupt"), [], "this chat sent no stop")
    }

    /// Stop asks first only when it would lose something: a queued prompt or an open request.
    func testStopConfirmsOnlyWithAQueuedPromptOrAnOpenRequest() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        XCTAssertFalse(chat.model.stopNeedsConfirmation)

        let approval = try XCTUnwrap(try recorded("turn-tool-approval-frames").first { $0["method"].text == "approval" })
        var envelope = try XCTUnwrap(approval.fields)
        envelope["params"] = approval["params"].replacing("session_id", with: .string("runtime"))
        chat.client.onEvent?(.object(envelope))
        XCTAssertTrue(chat.model.stopNeedsConfirmation)
        chat.receive(event(2, "request.cancel", ["id": approval["id"], "method": .string("approval")]))
        XCTAssertFalse(chat.model.stopNeedsConfirmation)

        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        _ = await chat.model.submitStreamingMessage("Afterwards", behavior: .queue)
        XCTAssertTrue(chat.model.stopNeedsConfirmation)
        chat.host.always("session.interrupt", .init(result: .object(["status": .string("interrupted")])))
        _ = await chat.model.cancelActiveStream()
        XCTAssertFalse(chat.model.stopNeedsConfirmation, "the host discarded the queue")
        XCTAssertNil(chat.model.queuedMessagesReceipt)
    }

    // MARK: Reattach

    /// Back from the background mid-turn: the replay carries what was missed, the reply
    /// continues without repeating, and nothing is sent again.
    func testReattachContinuesFromTheReplayWithoutDuplicatingOrResending() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Write a haiku")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Autumn ")]))
        chat.model.suspendStreamForBackground()

        let leaving = chat.host.requests.count
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 3, events: [
            event(3, "message.delta", ["text": .string("moonlight")])
        ])))
        chat.host.always("session.resume", .init(result: resume(running: true, history: [userRow("Write a haiku")],
                                                               inflight: ["user": .string("Write a haiku"),
                                                                          "assistant": .string("Autumn moonlight")])))
        await chat.model.reconnectStreamIfNeeded()
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.map(\.content), ["Write a haiku", "Autumn moonlight"])
        XCTAssertEqual(chat.host.requests.dropFirst(leaving).compactMap { $0["method"].text },
                       ["session.resume", "session.events.since", "session.resume"], "reattaching only reads")
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
        XCTAssertNotNil(chat.model.activeStreamID)
    }

    /// A hole in the live stream rebuilds the transcript from a full snapshot. The two deltas
    /// emitted while it was read are in its reply already and are dropped; the next one
    /// continues it.
    func testAGapRebuildsFromTheSnapshot() async {
        await assertRebuild(after: event(5, "message.delta", ["text": .string("lost the middle")]))
    }

    func testABackwardsSeqRebuildsFromTheSnapshot() async {
        await assertRebuild(after: event(1, "message.delta", ["text": .string("from before")]))
    }

    /// Only deltas the rebuilt reply holds are dropped: a new one that repeats the reply's
    /// start, or its last character, is new text.
    func testARebuildKeepsNewDeltasThatRepeatTheReply() async {
        await assertRebuild(after: event(5, "message.delta", ["text": .string("lost the middle")]),
                            reply: "I checked the logs.\n",
                            held: [event(7, "message.delta", ["text": .string("I")]),
                                   event(8, "message.delta", ["text": .string("\nNext")])],
                            shows: "I checked the logs.\nI\nNext")
    }

    /// The replay places the raced deltas: of two held " ha"s after a replayed ". ha", only
    /// the first is in the reply "Hello there. ha ha", so the second still shows.
    func testARebuildDropsOnlyTheDeltasAfterTheReplayedText() async {
        await assertRebuild(after: event(5, "message.delta", ["text": .string("lost the middle")]),
                            replayed: [event(6, "message.delta", ["text": .string(". ha")])],
                            reply: "Hello there. ha ha",
                            held: [event(7, "message.delta", ["text": .string(" ha")]),
                                   event(8, "message.delta", ["text": .string(" ha")])],
                            shows: "Hello there. ha ha ha")
    }

    // MARK: Entry

    func testNewSessionIsOfferedOnlyOnAHermesHomeInDebugOrBranchBuilds() {
        XCTAssertTrue(HermesSessionEntry.isOffered(isHermesHome: true, isDebugBuild: true,
                                                   bundleIdentifier: "com.uzairansar.hermesmobile"))
        XCTAssertTrue(HermesSessionEntry.isOffered(isHermesHome: true, isDebugBuild: false,
                                                   bundleIdentifier: "com.uzairansar.hermesmobile.branch"))
        XCTAssertFalse(HermesSessionEntry.isOffered(isHermesHome: true, isDebugBuild: false,
                                                    bundleIdentifier: "com.uzairansar.hermesmobile"), "Release")
        XCTAssertFalse(HermesSessionEntry.isOffered(isHermesHome: false, isDebugBuild: true,
                                                    bundleIdentifier: "com.uzairansar.hermesmobile"), "a webui server")
    }

    /// The new session runs under the Profile the dashboard is scoped to (`current`), not the
    /// CLI's sticky default (`active`).
    func testCurrentProfileIsTheDashboardsScopedProfile() async throws {
        let host = BotSocketHost()
        let client = BotClient(http: host.connection(Self.connection))
        addTeardownBlock { HermesHostFixture.reset() }
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/profiles/active" else { return nil }
            return .json(200, .object(["active": .string("work"), "current": .string("inbox-triage")]))
        }
        try await client.connect()
        let profile = try await client.currentProfile()
        XCTAssertEqual(profile, "inbox-triage")
        XCTAssertEqual(HermesHostFixture.requests.last { $0.url?.path == "/api/profiles/active" }?.httpMethod, "GET")
    }

    func testHermesSessionHidesHistoryActions() throws {
        let reply = ChatMessage(role: "assistant", content: "Hi", timestamp: nil, messageId: "a")
        let context = try XCTUnwrap(MessageActionContext(message: reply, visibleIndex: 0, messagesOffset: 0,
                                                         offersHistoryActions: false))
        let menu = ChatMessageActionMenu(
            context: context, listeningMessageID: nil, isViewingCachedData: false, hasActiveStream: false,
            isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
            onToggleListening: { _ in }, onRegenerate: { _ in }, onEdit: { _ in }, onFork: { _ in }, onCopy: { _ in }
        )
        XCTAssertEqual(menu.items.map(\.kind), [.listen])
    }

    // MARK: Fixture

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/HermesAgent")

    /// A Hermes chat attached to an idle session on `runtime`, whose events the test feeds.
    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient
        let liveActivity: TitleRecordingLiveActivity

        /// One recorded line: an event's params, or a host request envelope as is.
        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }

        /// The params of every `method` call the chat sent.
        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private func openChat(runtime: String = "runtime", key: String = "tip", profile: String = "default",
                          target: ConversationTarget? = nil, drafts: ChatDraftStore? = nil) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: resume(running: false, runtime: runtime, key: key, profile: profile)))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        // The reduced reply `session.create` gives a session that has not started.
        host.always("session.create", .init(result: .object([
            "session_id": .string(runtime), "stored_session_id": .string(key), "message_count": .number(0),
            "messages": .array([]), "info": .object(["profile_name": .string(profile)])
        ])))
        let client = BotClient(http: host.connection(Self.connection))
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: target ?? .session(profile: profile, key: key), wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let liveActivity = TitleRecordingLiveActivity()
        let model = ChatViewModel(
            session: SessionSummary(profile: profile), server: URL(string: "https://hermes.example")!,
            liveActivityManager: liveActivity, streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: drafts ?? ChatDraftStore(persistence: InMemoryDraftPersistence(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, turn: turn, host: host, client: client, liveActivity: liveActivity)
    }

    /// Feeds a turn through seq 3, then `frame`, which breaks the order: the chat reattaches,
    /// the replay carries `replayed` up to seq 6, and the snapshot, whose reply is `reply`,
    /// replaces the transcript. `held` lands while that snapshot is read; the reply then
    /// reads `shows`, and a live delta appends as it is.
    private func assertRebuild(after frame: BotJSON, replayed: [BotJSON] = [], reply: String = "Hello there, friend",
                               held: [BotJSON]? = nil, shows: String = "Hello there, friend.",
                               file: StaticString = #filePath, line: UInt = #line) async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Hello")]))
        chat.receive(event(3, "message.delta", ["text": .string(" there")]))
        // Deltas 7 and 8 were emitted while the host read the snapshot, so its reply holds
        // them; 9 came after.
        let held = held ?? [event(7, "message.delta", ["text": .string(", fri")]),
                            event(8, "message.delta", ["text": .string("end")]),
                            event(9, "message.delta", ["text": .string(".")])]
        let snapshot = resume(running: true, history: [userRow("Hi")],
                              inflight: ["user": .string("Hi"), "assistant": .string(reply)])
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 6, events: replayed)))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.host.next("session.resume", .init(result: snapshot, before: held))
        let leaving = chat.host.requests.count
        chat.receive(frame)
        await waitUntil("rebuilt") { chat.turn.engine.connectionState == .connected }
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.host.transcriptReads(since: leaving), [false, true], "one full read", file: file, line: line)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", shows], file: file, line: line)

        let next = (held.compactMap { $0["seq"].integer }.max() ?? 6) + 1
        chat.receive(event(next, "message.delta", ["text": .string(" Done")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", shows + " Done"], file: file, line: line)
        XCTAssertNotNil(chat.model.activeStreamID, file: file, line: line)
    }

    /// Waits on observation, never a clock, until `condition` holds.
    private func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            let changed = expectation(description: description)
            withObservationTracking { _ = condition() } onChange: { changed.fulfill() }
            await fulfillment(of: [changed], timeout: 5)
        }
    }

    private func recorded(_ name: String) throws -> [BotJSON] {
        guard let data = try? Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".json")) else {
            throw XCTSkip("The source tree is not present (physical device or remote runner).")
        }
        let capture = try JSONDecoder().decode(BotJSON.self, from: data)
        return try XCTUnwrap(capture.list ?? capture["frames"].list)
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:], runtime: String = "runtime") -> BotJSON {
        .object(["session_id": .string(runtime), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }

    private func userRow(_ text: String) -> BotJSON {
        .object(["role": .string("user"), "text": .string(text), "timestamp": .number(1_790_000_000)])
    }

    private func resume(running: Bool, runtime: String = "runtime", key: String = "tip", profile: String = "default",
                        history: [BotJSON] = [], inflight: [String: BotJSON]? = nil) -> BotJSON {
        var reply: [String: BotJSON] = [
            "session_id": .string(runtime), "session_key": .string(key), "running": .bool(running),
            "messages": .array(history), "info": .object(["profile_name": .string(profile)])
        ]
        if running { reply["turn_started_at"] = .number(1_790_000_000) }
        if var inflight {
            inflight["started_at"] = .number(1_790_000_000)
            reply["inflight"] = .object(inflight)
        }
        return .object(reply)
    }
}

/// Records the session titles a chat pushes to the Live Activity.
private final class TitleRecordingLiveActivity: AgentLiveActivityManaging {
    private(set) var titles: [String] = []
    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {}
    func update(_ event: AgentLiveActivityEvent) {
        if case .sessionTitle(let title) = event { titles.append(title) }
    }
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}

/// Drafts kept in memory for the test's life.
private actor InMemoryDraftPersistence: ChatDraftPersisting {
    private var values: [ChatDraftKey: ChatDraft] = [:]
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) { values = drafts }
}

private extension BotJSON {
    /// This object with `key` set to `value`.
    func replacing(_ key: String, with value: BotJSON) -> BotJSON {
        var fields = self.fields ?? [:]
        fields[key] = value
        return .object(fields)
    }
}
