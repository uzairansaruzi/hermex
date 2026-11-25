import XCTest
import Observation
import SwiftUI
@testable import HermesMobile

@MainActor final class HermesChatTurnTests: XCTestCase {
    func testAnApprovalSummaryUsesTheSameChatsRuntimeAndSurvivesReattach() async throws {
        let chat = await openChat()
        defer { chat.model.suspendStreamForBackground() }
        let frame = BotJSON.object(["id": .string("summary-envelope"), "method": .string("approval"),
            "params": .object(["session_id": .string("runtime"), "request_id": .string("summary-approval"),
                               "description": .string("Deletes files"), "command": .string("rm ./draft.txt")])])
        chat.receive(frame)
        let requests = chat.turn.requests
        guard case .approval(let approval)? = requests.onScreen else { return XCTFail("approval must be shown") }
        let presentation = try XCTUnwrap(requests.summaryPresentation(for: approval, workingDirectory: "/workspace"))
        defer { presentation.summaries.retain([], in: presentation.key.scope) }
        chat.host.always("llm.oneshot", .init(result: .object(["text": .string("Removes the draft file.")])))
        await presentation.summaries.show(presentation.key, load: presentation.load)
        XCTAssertEqual(presentation.summaries.states[presentation.key], .ready("Removes the draft file."))
        XCTAssertEqual(chat.writes("llm.oneshot").last?["session_id"]?.text, "runtime")
        let input = try XCTUnwrap(chat.writes("llm.oneshot").last?["input"]?.text)
        XCTAssertTrue(input.contains("Deletes files") && input.contains("rm ./draft.txt") && input.contains("/workspace"))

        let snapshot = resume(running: false).replacing("open_requests", with: .array([frame]))
        chat.model.suspendStreamForBackground()
        chat.host.always("session.events.since", .init(result: BotFixtureWire.replay().replacing("open_requests", with: .array([frame]))))
        chat.host.always("session.resume", .init(result: snapshot))
        await chat.model.reconnectStreamIfNeeded()
        let returned = try XCTUnwrap(requests.summaryPresentation(for: approval, workingDirectory: "/workspace"))
        XCTAssertEqual(returned.key, presentation.key)
        await returned.summaries.show(returned.key, load: returned.load)
        XCTAssertEqual(chat.writes("llm.oneshot").count, 1)
        XCTAssertEqual(returned.summaries.states[returned.key], .ready("Removes the draft file."))
        chat.receive(event(1, "request.cancel", ["id": .string("summary-envelope"), "method": .string("approval")]))
        XCTAssertNil(returned.summaries.states[returned.key], "only the host withdrawing it drops the result")
    }

    func testRecordedTurnStreamsTextAndTitleAndEndsOnSessionInfo() async throws {
        let frames = try recorded("turn-frames")
        let first = frames[0]["params"]
        let runtime = try XCTUnwrap(first["session_id"].text)
        let key = try XCTUnwrap(first["payload"]["stored_session_id"].text)
        let startedAt = Date(timeIntervalSince1970: try XCTUnwrap(first["payload"]["turn_started_at"].number))
        let chat = await openChat(runtime: runtime, key: key, profile: "hermex-fixtures")
        chat.receive(frames[0])
        chat.receive(frames[1])
        XCTAssertNotNil(chat.model.activeStreamID, "an unprompted message.start starts a turn")
        XCTAssertEqual(chat.model.activeRunStartedAt, startedAt, "the run counts from the host's turn_started_at")

        frames[2..<(frames.count - 1)].forEach(chat.receive)
        chat.model.flushPendingStreamingContent()
        let complete = try XCTUnwrap(frames.first { $0["params"]["type"].text == "message.complete" })["params"]["payload"]
        XCTAssertEqual(chat.model.messages.map(\.role), ["assistant"])
        XCTAssertEqual(chat.model.messages.map(\.content), [try XCTUnwrap(complete["text"].text)],
                       "reasoning.available repeats the answer and is never shown again")
        XCTAssertEqual(chat.model.liveReasoningText, "", "thinking.delta is spinner text, not reasoning")
        XCTAssertEqual(chat.model.displayTitle, "fixture-redacted")
        XCTAssertNotNil(chat.model.activeStreamID, "message.complete alone does not make the chat idle")
        XCTAssertEqual(chat.model.contextWindowSnapshot?.contextLength, try XCTUnwrap(complete["usage"]["context_max"].integer))
        XCTAssertEqual(chat.model.contextWindowSnapshot?.tokensUsed, try XCTUnwrap(complete["usage"]["context_used"].integer))

        chat.receive(frames[frames.count - 1])
        XCTAssertNil(chat.model.activeStreamID)
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .completed)
        XCTAssertNotNil(chat.model.latestRunOutcome?.endedAt, "a live end counts from when the chat saw it")
        XCTAssertEqual(chat.model.runEndTrigger, 1)
        XCTAssertEqual(chat.liveActivity.titles, [], "a Hermes title never reaches a webui Live Activity")

        chat.receive(event(frames.count + 1, "message.start", runtime: runtime))
        XCTAssertNotEqual(chat.model.activeRunStartedAt, startedAt, "a later turn never counts from the last one's start")
    }

    func testRecordedToolTurnKeysToolsByIDAndAppendsTheFinalAnswer() async throws {
        let frames = try recorded("turn-tool-approval-frames")
        let key = try XCTUnwrap(frames[0]["params"]["payload"]["stored_session_id"].text)
        let runtime = try XCTUnwrap(frames[0]["params"]["session_id"].text)
        let chat = await openChat(runtime: runtime, key: key, profile: "default")
        let approval = try XCTUnwrap(frames.firstIndex { $0["method"].text == "approval" })
        let withdrawal = try XCTUnwrap(frames.firstIndex { $0["params"]["type"].text == "request.cancel" })
        frames[..<approval].forEach(chat.receive)
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.liveToolCalls.map(\.id), ["fixture-redacted"])
        XCTAssertEqual(chat.model.liveToolCalls.map(\.name), ["terminal"])
        XCTAssertEqual(chat.model.liveToolCalls.map(\.isCompleted), [false])

        chat.receive(frames[approval])
        XCTAssertTrue(chat.model.stopNeedsConfirmation, "the approval is an open request")
        frames[(approval + 1)...withdrawal].forEach(chat.receive)
        XCTAssertFalse(chat.model.stopNeedsConfirmation, "request.cancel withdrew it")

        frames[(withdrawal + 1)...].forEach(chat.receive)
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

    func testAnAttachmentOnlyTitleShowsTheAttachmentsName() async {
        let chat = await openChat()
        chat.receive(event(1, "session.title", ["title": .string(Self.photoReference)]))
        XCTAssertEqual(chat.model.displayTitle, "IMG_2041.jpg")
    }

    func testATitleCutBeforeTheAttachmentsNameShowsTheFirstPromptsAttachment() async {
        let chat = await openChat(history: [userRow(Self.photoReference)])
        chat.receive(event(1, "session.title", ["title": .string("[The user attached an image…")]))
        XCTAssertEqual(chat.model.displayTitle, "IMG_2041.jpg")
    }

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

    func testACompactionMidTurnShowsFromCompactingUntilCompacted() async throws {
        let frames = try recorded("turn-compaction-frames")
        let chat = await openChat(runtime: try XCTUnwrap(frames[0]["params"]["session_id"].text))
        let kinds = frames.map { $0["params"]["payload"]["kind"].text }
        let start = try XCTUnwrap(kinds.firstIndex(of: "compacting"))
        let end = try XCTUnwrap(kinds.firstIndex(of: "compacted"))
        frames[...start].forEach(chat.receive)
        XCTAssertTrue(chat.model.isCompacting)
        frames[(start + 1)..<end].forEach(chat.receive)
        XCTAssertTrue(chat.model.isCompacting, "a second compacting line keeps it")
        chat.receive(frames[end])
        XCTAssertFalse(chat.model.isCompacting)
        XCTAssertNotNil(chat.model.activeStreamID, "the turn goes on")
    }

    func testTheTurnsEndClearsACompactionWhoseEndNeverCame() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "status.update", ["kind": .string("compacting"), "text": .string("Compacting context")]))
        XCTAssertTrue(chat.model.isCompacting)
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        XCTAssertFalse(chat.model.isCompacting)
    }

    func testTheTurnsNextOutputClearsACompactionThatSentNoEnd() async throws {
        let frames = try recorded("turn-compaction-frames", key: "unended")
        let chat = await openChat(runtime: try XCTUnwrap(frames[0]["params"]["session_id"].text))
        let output = try XCTUnwrap(frames.firstIndex { $0["params"]["type"].text == "thinking.delta" })
        frames[..<output].forEach(chat.receive)
        XCTAssertTrue(chat.model.isCompacting)
        chat.receive(frames[output])
        XCTAssertFalse(chat.model.isCompacting)
    }

    func testAReattachDropsACompactionItCannotSeeEnd() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "status.update", ["kind": .string("compacting"), "text": .string("Compacting context")]))
        XCTAssertTrue(chat.model.isCompacting)
        await reattach(chat, resume(running: true), latest: 2)
        XCTAssertFalse(chat.model.isCompacting)
        XCTAssertNotNil(chat.model.activeStreamID, "the running turn is still shown")
    }

    func testACompressPinnedStatusEndsWithItsReady() async {
        let chat = await openChat()
        chat.receive(event(1, "status.update", ["kind": .string("compressing"), "text": .string("compressing 10 messages")]))
        XCTAssertTrue(chat.model.isCompacting)
        chat.receive(event(2, "status.update", ["kind": .string("status"), "text": .string("ready")]))
        XCTAssertFalse(chat.model.isCompacting)
    }

    func testALiveTTLNoticeShowsUntilItsTimeIsUp() async throws {
        let frames = try recorded("turn-notice-frames")
        let payload = frames[1]["params"]["payload"]
        let timer = ManualNoticeTimer()
        let chat = await openChat(runtime: try XCTUnwrap(frames[0]["params"]["session_id"].text), noticeTimer: timer.timer)
        let notices = chat.turn.hostNotices
        frames.forEach(chat.receive)
        XCTAssertEqual(notices.shown?.text, payload["text"].text)
        XCTAssertEqual(notices.shown?.level, .warning)
        XCTAssertEqual(timer.delays, [.milliseconds(try XCTUnwrap(payload["ttl_ms"].integer))])
        XCTAssertNil(chat.model.sendErrorMessage, "a notice never takes the error line")
        XCTAssertTrue(chat.model.messages.isEmpty, "a notice is not a transcript row")

        chat.receive(event(3, "notification.show", ["text": .string("Could not switch model: still unknown"), "level": .string("warn"),
                                                    "kind": .string("ttl"), "ttl_ms": .number(12000),
                                                    "key": .string("model_switch.dropped")], runtime: "fixture-runtime"))
        XCTAssertEqual(notices.notices.map(\.text), ["Could not switch model: still unknown"], "the same key replaces it")
        timer.fire(0)
        XCTAssertEqual(notices.shown?.text, "Could not switch model: still unknown", "the replaced notice's timer hides nothing")
        timer.fire(1)
        XCTAssertNil(notices.shown)
    }

    func testOpeningAChatRestoresStandingNoticesButNoExpiredOne() async throws {
        let timer = ManualNoticeTimer()
        let chat = await openChat(replay: try standingNoticeReplay(latest: 4), noticeTimer: timer.timer)
        XCTAssertEqual(chat.turn.hostNotices.notices.map(\.text), ["Sign in at https://example.com/device"])
        XCTAssertTrue(timer.delays.isEmpty)
    }

    func testAReattachWithATruncatedReplayStillRestoresStandingNotices() async throws {
        let timer = ManualNoticeTimer()
        let chat = await openChat(noticeTimer: timer.timer)
        chat.model.suspendStreamForBackground()
        chat.host.next("session.events.since", .init(result: try standingNoticeReplay(latest: 4, truncated: true)))
        chat.host.always("session.resume", .init(result: resume(running: false)))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.hostNotices.notices.map(\.text), ["Sign in at https://example.com/device"])
        XCTAssertTrue(timer.delays.isEmpty)
    }

    func testAClearArrivingAfterAGapStillWithdrawsItsNotice() async {
        let chat = await openChat()
        chat.receive(event(1, "notification.show", ["text": .string("Credit access paused"), "level": .string("error"),
                                                    "kind": .string("sticky"), "key": .string("credits.depleted")]))
        XCTAssertNotNil(chat.turn.hostNotices.shown)
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 3)))
        chat.receive(event(3, "notification.clear", ["key": .string("credits.depleted")]))
        await waitUntil("rebuilt") { chat.turn.engine.connectionState == .connected }
        XCTAssertNil(chat.turn.hostNotices.shown)
    }

    func testANewRuntimeDropsTheOldRuntimesNoticesAndTimers() async {
        let timer = ManualNoticeTimer()
        let chat = await openChat(noticeTimer: timer.timer)
        let notices = chat.turn.hostNotices
        chat.receive(event(1, "notification.show", ["text": .string("Still starting the agent"), "level": .string("info"),
                                                    "kind": .string("agent"), "key": .string("agent.build_slow")]))
        chat.receive(event(2, "notification.show", ["text": .string("Large model"), "level": .string("warn"), "kind": .string("ttl"),
                                                    "ttl_ms": .number(8000), "key": .string("model.large_notice")]))
        await reattach(chat, resume(running: false, runtime: "runtime-2"))
        XCTAssertTrue(notices.notices.isEmpty)
        XCTAssertTrue(timer.tasks[0].isCancelled)

        chat.receive(event(1, "notification.show", ["text": .string("Large model again"), "level": .string("warn"), "kind": .string("ttl"),
                                                    "ttl_ms": .number(8000), "key": .string("model.large_notice")], runtime: "runtime-2"))
        timer.fire(0)
        XCTAssertEqual(notices.shown?.text, "Large model again", "the old runtime's timer hides nothing")
    }

    func testAShowWithAKnownKeyReplacesThatNoticeInPlace() async {
        let chat = await openChat()
        let notices = chat.turn.hostNotices
        chat.receive(event(1, "notification.show", ["text": .string("You've used 50% of your cap"), "level": .string("info"),
                                                    "kind": .string("sticky"), "key": .string("credits.usage")]))
        chat.receive(event(2, "notification.show", ["text": .string("⚠ Low disk"), "level": .string("warn"), "kind": .string("sticky"),
                                                    "key": .string("sessions.auto_prune"), "detail": .string("Turn on auto-prune?")]))
        chat.receive(event(3, "notification.show", ["text": .string("You've used 75% of your cap"), "level": .string("warn"),
                                                    "kind": .string("sticky"), "key": .string("credits.usage")]))
        XCTAssertEqual(notices.notices.map(\.text), ["You've used 75% of your cap", "⚠ Low disk"])
        XCTAssertEqual(notices.shown?.detail, "Turn on auto-prune?")
        XCTAssertEqual(notices.waitingCount, 1)
    }

    func testAClearWithdrawsANoticeAndADismissHidesItUntilNewText() async throws {
        let chat = await openChat()
        let notices = chat.turn.hostNotices
        chat.receive(event(1, "notification.show", ["text": .string("Credit access paused"), "level": .string("error"),
                                                    "kind": .string("sticky"), "key": .string("credits.depleted")]))
        chat.receive(event(2, "notification.show", ["text": .string("A plugin says hi"), "level": .string("info"),
                                                    "kind": .string("sticky"), "key": .string("plugin-message:p:1")]))
        chat.receive(event(3, "notification.clear", ["key": .string("credits.depleted")]))
        XCTAssertEqual(notices.notices.map(\.text), ["A plugin says hi"])

        notices.dismiss(try XCTUnwrap(notices.shown))
        XCTAssertNil(notices.shown)
        chat.receive(event(4, "notification.show", ["text": .string("A plugin says hi"), "level": .string("info"),
                                                    "kind": .string("sticky"), "key": .string("plugin-message:p:1")]))
        XCTAssertNil(notices.shown, "the same text stays dismissed")
        chat.receive(event(5, "notification.show", ["text": .string("A plugin says bye"), "level": .string("info"),
                                                    "kind": .string("sticky"), "key": .string("plugin-message:p:1")]))
        XCTAssertEqual(notices.shown?.text, "A plugin says bye")
    }

    func testACanonicalSessionUnderANewEpochDropsTheOldNoticesAndTimers() async {
        let timer = ManualNoticeTimer()
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(), canonical: true, noticeTimer: timer.timer)
        let notices = chat.turn.hostNotices
        chat.receive(event(1, "notification.show", ["text": .string("Sign in at https://example.com/device"), "level": .string("info"),
                                                    "kind": .string("sticky"), "key": .string("login:1")], runtime: "tip"))
        chat.receive(event(2, "notification.show", ["text": .string("Large model"), "level": .string("warn"), "kind": .string("ttl"),
                                                    "ttl_ms": .number(8000), "key": .string("model.large_notice")], runtime: "tip"))
        chat.model.suspendStreamForBackground()
        chat.host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0, truncated: true, epoch: "epoch-2")))
        chat.host.always("session.resume", .init(result: canonicalSnapshot(epoch: "epoch-2")))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertTrue(notices.notices.isEmpty)
        XCTAssertTrue(timer.tasks[0].isCancelled)
    }

    func testAGapInTheSameLifetimeKeepsTheNotices() async {
        let chat = await openChat()
        chat.receive(event(1, "notification.show", ["text": .string("Credit access paused"), "level": .string("error"),
                                                    "kind": .string("sticky"), "key": .string("credits.depleted")]))
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 3)))
        chat.receive(event(3, "message.start"))
        await waitUntil("rebuilt") { chat.turn.engine.connectionState == .connected }
        XCTAssertEqual(chat.turn.hostNotices.shown?.text, "Credit access paused")
    }

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

    func testADirectSendReadsHeadBeforeItsPromptAndOnlyItsTurnKeepsTheBase() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/git/review/rev-parse" ? .park : HermesGitHost.repositoryReply(request, root: "/work/app")
        }
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        let parked = expectation(description: "The HEAD read waits")
        HermesHostFixture.onPark = { parked.fulfill() }

        let send = Task { await chat.model.sendMessage("Edit and commit") }
        await fulfillment(of: [parked], timeout: 5)
        XCTAssertEqual(chat.writes("prompt.submit").count, 0, "the prompt waits for the HEAD read")
        HermesHostFixture.releaseParked(.json(200, .object(["sha": .string(HermesGitHost.headSHA)])))
        let sent = await send.value

        XCTAssertTrue(sent)
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
        let read = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/git/review/rev-parse" })
        XCTAssertEqual(HermesGitHost.query(read, "path"), "/work/app")
        chat.receive(event(2, "message.start"))
        chat.receive(event(3, "message.complete", ["status": .string("complete")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.model.hermesTurnBase?.sha, HermesGitHost.headSHA)

        chat.receive(event(5, "message.start"))
        XCTAssertNil(chat.model.hermesTurnBase, "a turn this chat did not send has no base")
    }

    func testOnlyACompletedTurnCountsAsACompletedReply() async throws {
        let rating = isolatedRatingState()
        let chat = await openChat(ratingPromptState: rating)
        var seq = 0
        for status in ["complete", "interrupted", "error", "complete"] {
            chat.receive(event(seq + 1, "message.start"))
            chat.receive(event(seq + 2, "message.complete", ["status": .string(status)]))
            chat.receive(event(seq + 3, "session.info", ["running": .bool(false)]))
            chat.receive(event(seq + 4, "session.info", ["running": .bool(false)]))
            seq += 4
        }
        XCTAssertEqual(rating.policy.completedResponses, 2)
    }

    func testARunningTurnHoldsTheRatingRequestBack() async throws {
        let rating = isolatedRatingState()
        let chat = await openChat(ratingPromptState: rating)
        let server = try XCTUnwrap(URL(string: "https://hermes.example"))
        chat.receive(event(1, "message.start"))
        XCTAssertTrue(rating.hasActiveStream(on: server))
        XCTAssertFalse(rating.hasActiveStream(on: try XCTUnwrap(URL(string: "https://other.example"))))
        chat.receive(event(2, "message.complete", ["status": .string("complete")]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        XCTAssertFalse(rating.hasActiveStream(on: server))
    }

    func testAFailedHeadReadStillSendsAndACancelledOneSendsNothing() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        nonisolated(unsafe) var head: HermesHostFixture.Reply = .json(500, .object(["detail": .string("boom")]))
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/git/review/rev-parse" ? head : HermesGitHost.repositoryReply(request, root: "/work/app")
        }
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

        let sent = await chat.model.sendMessage("Edit it")
        XCTAssertTrue(sent)
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
        XCTAssertEqual(HermesHostFixture.count("/api/git/review/rev-parse"), 1)
        chat.receive(event(2, "message.start"))
        chat.receive(event(3, "message.complete", ["status": .string("complete")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertNil(chat.model.hermesTurnBase)

        HermesHostFixture.script { head = .park }
        let parked = expectation(description: "The HEAD read waits")
        HermesHostFixture.onPark = { parked.fulfill() }
        let send = Task { await chat.model.sendMessage("Edit it again") }
        await fulfillment(of: [parked], timeout: 5)
        send.cancel()
        HermesHostFixture.releaseParked(.json(200, .object(["sha": .string(HermesGitHost.headSHA)])))
        let cancelled = await send.value

        XCTAssertFalse(cancelled)
        XCTAssertEqual(chat.writes("prompt.submit").count, 1, "a cancelled send never reaches the host")
    }

    func testATurnsBaseSurvivesItsReattachButNotAFolderMove() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/sessions/tip/messages"
                ? .json(200, .object(["session_id": .string("tip"), "messages": .array([])]))
                : HermesGitHost.repositoryReply(request, root: "/work/app")
        }
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Edit and commit")
        chat.receive(event(2, "message.start"))

        await reattach(chat, resume(running: true), latest: 2)
        XCTAssertNotNil(chat.model.activeStreamID)
        XCTAssertEqual(chat.model.hermesTurnBase?.sha, HermesGitHost.headSHA, "the same turn keeps its base")

        chat.receive(event(3, "session.info", ["cwd": .string("/work/moved"), "terminal_backend": .string("local")]))
        XCTAssertNil(chat.model.hermesTurnBase)
    }

    func testATurnStartedAheadOfAQueuedSendsReplyKeepsNoBase() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        _ = HermesHostFixture.configuration { HermesGitHost.repositoryReply($0, root: "/work/app") }
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")]),
                                                before: [event(2, "message.start")]))

        _ = await chat.model.sendMessage("Edit and commit")
        XCTAssertNotNil(chat.model.activeStreamID)
        XCTAssertNil(chat.model.hermesTurnBase, "the turn ahead of the queued send is not its own")

        chat.receive(event(3, "message.complete", ["status": .string("complete")]))
        chat.receive(event(4, "message.start"))
        XCTAssertNil(chat.model.hermesTurnBase, "the queued turn began without its send alone")
    }

    func testAReattachThatLostFramesDropsABaseItCannotMatchToTheRunningTurn() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/sessions/tip/messages"
                ? .json(200, .object(["session_id": .string("tip"), "messages": .array([])]))
                : HermesGitHost.repositoryReply(request, root: "/work/app")
        }
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Edit and commit")
        XCTAssertEqual(chat.model.hermesTurnBase?.sha, HermesGitHost.headSHA)

        chat.model.suspendStreamForBackground()
        chat.host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 40, truncated: true)))
        chat.host.always("session.resume", .init(result: resume(running: true)))
        await chat.model.reconnectStreamIfNeeded()

        XCTAssertNotNil(chat.model.activeStreamID)
        XCTAssertNil(chat.model.hermesTurnBase)
    }

    func testEachPromptModeReadsOnlyItsOwnAcknowledgment() {
        let reply = { (status: String) in BotJSON.object(["status": .string(status), "future": .bool(true)]) }
        XCTAssertEqual(BotPromptMode.steer.outcome(reply("queued")), .guidanceQueued)
        XCTAssertEqual(BotPromptMode.redirect.outcome(reply("redirected")), .redirected)
        XCTAssertEqual(BotPromptMode.redirect.outcome(reply("queued")), .redirectQueued)
        XCTAssertEqual(BotPromptMode.queue.outcome(reply("queued")), .followUpQueued)
        XCTAssertEqual(BotPromptMode.send.outcome(reply("streaming")), .started)
        XCTAssertEqual(BotPromptMode.steer.outcome(reply("rejected")), .rejected)
        XCTAssertEqual(BotPromptMode.steer.outcome(reply("streaming")), .unknown)
        XCTAssertEqual(BotPromptMode.send.outcome(reply("redirected")), .unknown)
        XCTAssertEqual(BotPromptMode.send.outcome(.object(["voice_stopped": .bool(true)])), .voiceStopped)
        XCTAssertEqual(BotPromptMode.send.outcome(.object(["status": .string("queued")]), canonical: true), .unknown)
        XCTAssertEqual(BotPromptMode.send.outcome(.object(["status": .string("terminal"), "admission_id": .string("a1")]),
                                                  canonical: true), .unknown)
        XCTAssertEqual(BotPromptMode.steer.outcome(.object(["voice_stopped": .bool(true)])), .unknown)

        XCTAssertTrue(BotPromptMode.send.definitelyRejected(BotFailure.rejected(4001)))
        XCTAssertTrue(BotPromptMode.steer.definitelyRejected(BotFailure.rejected(4002)))
        XCTAssertFalse(BotPromptMode.send.definitelyRejected(BotFailure.rejected(4002)), "a send may have been taken")
        XCTAssertFalse(BotPromptMode.send.definitelyRejected(BotFailure.transport))
    }

    func testAnUnknownAcknowledgmentKeepsTheDraftAndSendsOnce() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("something new")])))
        let sent = await chat.model.sendMessage("Deploy it")
        XCTAssertFalse(sent, "false keeps the draft in the composer")
        XCTAssertEqual(chat.model.sendErrorMessage, "Hermes did not confirm this message. Your draft is still here.")
        XCTAssertEqual(chat.model.messages, [])
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
    }

    func testAcceptedNewSessionClosesOnConfirmedArchiveOrDelete() async throws {
        for archived in [false, true] {
            let key = archived ? "new-archived" : "new-deleted"
            let chat = await openChat(key: key, target: .new(profile: "default"))
            defer { chat.model.suspendStreamForNavigation() }
            let opened = HermesSessionChat(server: URL(string: "https://hermes.example")!,
                                           connection: Self.connection, target: .new(profile: "default"))
            var covers = HermesSessionListCovers()
            covers.chat = opened
            var identified: ChatDraftKey?
            chat.model.onHermesDraftKeyChange = { identity in
                identified = identity
                covers.identifyChat(opened.id, draftKey: identity)
            }
            chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
            let sent = await chat.model.sendMessage("Plan the release")
            XCTAssertTrue(sent)
            XCTAssertEqual(identified, chat.model.hermesDraftKey, "Accepted identity must reach the parent")
            XCTAssertEqual(covers.chat?.id, opened.id, "Identifying the session must not replace its live chat")
            covers.closeChat(for: SessionSummary(sessionId: key, archived: archived, profile: "default",
                hermes: .init(lineageRoot: key, unread: false, preview: nil)))
            XCTAssertNil(covers.chat, "Both confirmed sidebar mutations must close a chat that opened as New Session")
        }
    }

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
        await chat.model.reconnectStreamIfNeeded()

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

    func testEverySegmentOfACompressionChainSharesOneDraft() async {
        let drafts = ChatDraftStore(persistence: InMemoryDraftPersistence(), debounceDuration: .seconds(60))
        let server = URL(string: "https://hermes.example")!
        func draftKey(_ key: String) -> ChatDraftKey {
            .hermesSession(server: server, connectionID: Self.connection.id, profile: "default", key: key)
        }
        drafts.setDraft("Ship the notes", for: draftKey("tip"))

        var expected = "Ship the notes"
        for segment in ["tip", "middle", "root"] {
            let chat = await openChat(key: segment, drafts: drafts, lineageRoot: "root")
            await chat.model.adoptHermesSegmentDraft()
            XCTAssertEqual(chat.model.hermesDraftKey, draftKey("root"), segment)
            let restored = await drafts.draft(for: draftKey("root"))
            XCTAssertEqual(restored?.text, expected, segment)
            XCTAssertEqual(Set(chat.writes("session.resume").compactMap { $0["session_id"]?.text }), [segment])
            expected = "Ship the notes from \(segment)"
            drafts.setDraft(expected, for: draftKey("root"))
            chat.model.suspendStreamForNavigation()
        }
        let tip = await drafts.draft(for: draftKey("tip"))
        XCTAssertNil(tip, "moved, not copied")
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

    func testQueueHoldsThePromptOnTheHostUntilItsTurnStarts() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        let result = await chat.model.submitStreamingMessage("Then the tests", behavior: .queue)
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("prompt.submit").first?["queued"], .bool(true))
        _ = await chat.model.submitStreamingMessage("And the docs", behavior: .queue)
        XCTAssertEqual(chat.model.queuedPromptMessages.first?.content, "Then the tests\n\nAnd the docs")
        XCTAssertNil(chat.model.queuedMessagesReceipt, "the bubble replaces the receipt")
        XCTAssertEqual(chat.model.messages, [], "the bubble is not a transcript row")

        chat.receive(event(2, "message.complete", ["status": .string("complete")]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        XCTAssertFalse(chat.model.queuedPromptMessages.isEmpty, "it stays between the turns")
        chat.receive(event(4, "message.start"))
        XCTAssertEqual(chat.model.messages.map(\.content), ["Then the tests\n\nAnd the docs"])
        XCTAssertTrue(chat.model.queuedPromptMessages.isEmpty)
    }

    func testAReattachRestoresTheQueuedPromptAsOneBubble() async {
        let chat = await openChat(snapshot: resume(running: true)
            .replacing("queued", with: .object(["user": .string("Then the tests\n\n@file:/a/notes.txt")])))
        XCTAssertEqual(chat.model.queuedPromptMessages.first?.content, "Then the tests")
        XCTAssertEqual(chat.model.queuedPromptMessages.first?.attachments?.map(\.name), ["notes.txt"])

        chat.receive(event(1, "message.start"))
        XCTAssertEqual(chat.model.messages.filter { $0.role == "user" }.map(\.content), ["Then the tests"])
        XCTAssertTrue(chat.model.queuedPromptMessages.isEmpty)
    }

    func testAStopFromAnotherClientClearsTheQueuedPrompt() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        _ = await chat.model.submitStreamingMessage("Then the tests", behavior: .queue)
        XCTAssertTrue(chat.model.stopNeedsConfirmation)

        chat.receive(event(2, "message.complete", ["status": .string("interrupted")]))
        XCTAssertTrue(chat.model.queuedPromptMessages.isEmpty)
        XCTAssertFalse(chat.model.stopNeedsConfirmation)
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        chat.receive(event(4, "message.start"))
        XCTAssertEqual(chat.model.messages, [], "the next turn is not the discarded prompt")
        XCTAssertEqual(chat.writes("session.interrupt"), [], "this chat sent no stop")
    }

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
        XCTAssertEqual(chat.model.queuedPromptMessages.first?.content, "Afterwards")
        chat.host.always("session.interrupt", .init(result: .object(["status": .string("interrupted")])))
        _ = await chat.model.cancelActiveStream()
        XCTAssertFalse(chat.model.stopNeedsConfirmation, "the host discarded the queue")
        XCTAssertTrue(chat.model.queuedPromptMessages.isEmpty)
    }

    func testACanonicalReceiptForTheRunningOrABlockedAdmissionShowsNoPhantomTurn() async throws {
        var receipt = try XCTUnwrap(try canonical("canonical-receipts")["idle"].fields)
        receipt["admission_id"] = .string("a1")
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(), canonical: true)
        chat.host.next("prompt.submit", .init(result: .object(receipt), before: [
            canonicalEvent(1, "session.info", ["pending": .array([admission("a1", "queued", "Run the quick check.")])],
                           admission: "a1", generation: nil),
            canonicalEvent(2, "message.start", admission: "a1", generation: 1)
        ]))
        let sent = await chat.model.sendMessage("Run the quick check.")
        XCTAssertTrue(sent, "true clears the draft")
        let params = try XCTUnwrap(chat.writes("prompt.submit").first)
        XCTAssertEqual(params["profile"]?.text, "default")
        XCTAssertEqual(params["submission_id"]?.text?.isEmpty, false)
        XCTAssertNotNil(chat.model.activeStreamID)
        XCTAssertTrue(chat.model.queuedPromptMessages.isEmpty, "the running admission is no follow-up")
        XCTAssertEqual(chat.model.messages.filter { $0.role == "user" }.map(\.content), ["Run the quick check."],
                       "the send's prompt shows once")

        let blocked = await openChat(runtime: "tip", snapshot: canonicalSnapshot(pending: [
            admission("lost", "unknown", "Run the quick check.", generation: 2)
        ]), canonical: true)
        receipt["admission_id"] = .string("behind")
        blocked.host.always("prompt.submit", .init(result: .object(receipt)))
        let queued = await blocked.model.sendMessage("Then the tests")
        XCTAssertTrue(queued)
        XCTAssertNil(blocked.model.activeStreamID, "nothing runs until Discard")
        XCTAssertEqual(blocked.model.queuedPromptMessages.map(\.content), ["Then the tests"])
    }

    func testAnOlderAdmissionStartingDuringASendShowsItsOwnPrompt() async throws {
        var receipt = try XCTUnwrap(try canonical("canonical-receipts")["idle"].fields)
        receipt["admission_id"] = .string("a3")
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(pending: [
            admission("lost", "unknown", "Earlier", generation: 1), admission("a2", "queued", "Then the tests")
        ]), canonical: true)
        chat.host.next("prompt.submit", .init(result: .object(receipt), before: [
            canonicalEvent(1, "session.info", ["pending": .array([admission("a2", "queued", "Then the tests")])],
                           admission: "a2", generation: nil),
            canonicalEvent(2, "message.start", admission: "a2", generation: 2)
        ]))
        let sent = await chat.model.sendMessage("Run the quick check.")
        XCTAssertTrue(sent)
        XCTAssertEqual(chat.model.messages.filter { $0.role == "user" }.map(\.content), ["Then the tests"])
        XCTAssertEqual(chat.model.queuedPromptMessages.map(\.content), ["Run the quick check."])
    }

    func testCanonicalQueuedSendsStaySeparateAdmissions() async throws {
        let rows = try XCTUnwrap(try canonical("canonical-resume-queued")["pending"].list)
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(running: true, pending: rows), canonical: true)
        XCTAssertEqual(chat.model.queuedPromptMessages.map(\.content), ["Then the tests", "And the docs"])
        XCTAssertTrue(chat.model.stopNeedsConfirmation)

        let next = try XCTUnwrap(rows[1]["admission_id"].text)
        chat.receive(canonicalEvent(1, "message.start", admission: next, generation: 2))
        XCTAssertEqual(chat.model.queuedPromptMessages.map(\.content), ["And the docs"])
        XCTAssertEqual(chat.model.messages.filter { $0.role == "user" }.map(\.content), ["Then the tests"])
    }

    func testAWithdrawnCanonicalAdmissionIsNotTheRunningTurnsCompletion() async throws {
        let withdrawn = try canonical("canonical-withdrawn-complete")
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(), canonical: true)
        chat.receive(canonicalEvent(1, "message.start", admission: "running", generation: 1))
        var params = try XCTUnwrap(withdrawn.fields)
        params["session_id"] = .string("tip"); params["seq"] = .number(2)
        chat.receive(.object(params))
        XCTAssertNotNil(chat.model.activeStreamID, "the running turn goes on")

        chat.receive(canonicalEvent(3, "error", ["message": .string("Provider unavailable")], admission: "running", generation: 1))
        chat.receive(canonicalEvent(4, "session.info", ["running": .bool(false)], admission: "running", generation: 1))
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .failed)
    }

    func testCanonicalStopWithdrawsTheQueueThenInterruptsItsGeneration() async throws {
        let stale = try canonical("canonical-stale-generation")
        var next = try XCTUnwrap(try canonical("canonical-second-turn-start").fields)
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(running: true, generation: 1, pending: [
            admission("a1", "started", "Run the quick check.", generation: 1), admission("a2", "queued", "Then the tests")
        ]), canonical: true)
        next["session_id"] = .string("tip"); next["seq"] = .number(1)
        chat.receive(.object(next))
        XCTAssertNotNil(chat.model.activeStreamID)
        chat.host.next("prompt.cancel", .init(result: .object(["status": .string("terminal"), "outcome": .string("cancelled")]),
                                              before: [canonicalEvent(2, "session.usage", admission: "a3", generation: 3)]))
        chat.host.next("session.interrupt", .init(error: stale["code"].integer, message: stale["message"].text ?? "", data: stale["data"]))
        chat.host.next("session.interrupt", .init(result: .object(["execution_state": .string("running")])))
        let refused = await chat.model.cancelActiveStream()
        XCTAssertFalse(refused)
        XCTAssertEqual(chat.writes("prompt.cancel").map { $0["admission_id"]?.text }, ["a2"])
        XCTAssertEqual(chat.writes("session.interrupt").map { $0["execution_generation"]?.integer }, [2])

        let stopped = await chat.model.cancelActiveStream()
        XCTAssertTrue(stopped)
        XCTAssertEqual(chat.writes("session.interrupt").count, 2, "only the second tap sent a second stop")
    }

    func testALostCanonicalTurnIsDiscardedWithItsOwnGeneration() async throws {
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(generation: 4, pending: [
            admission("lost", "unknown", "Run the quick check.", generation: 2), admission("next", "queued", "Then the tests")
        ]), canonical: true)
        XCTAssertNotNil(chat.model.lostTurn)
        chat.host.always("prompt.resolve_unknown", .init(result: .object(["status": .string("terminal")])))
        await chat.model.discardLostTurn()
        XCTAssertEqual(chat.writes("prompt.resolve_unknown"), [[
            "profile": .string("default"), "session_id": .string("tip"), "admission_id": .string("lost"),
            "execution_generation": .number(2)
        ]], "the host refuses any other key")
        XCTAssertNil(chat.model.lostTurn)
        XCTAssertEqual(chat.writes("prompt.submit"), [])
    }

    func testACanonicalBranchKeepsTheRowsThroughTheSelectedRowsID() async throws {
        let branch = try canonical("canonical-mutations")["branch"]["result"]
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(), canonical: true)
        chat.host.always("session.mutate", .init(result: branch))
        let key = try await chat.turn.branch(through: 81, name: "Branched")
        XCTAssertEqual(key, branch["branched_session_id"].text)
        let sent = try XCTUnwrap(chat.writes("session.mutate").first)
        XCTAssertEqual(sent["operation"], .string("branch"))
        XCTAssertEqual(sent["payload"], .object(["title": .string("Branched"), "through_message_id": .number(81)]))
        XCTAssertEqual(sent["expected_revision"], .number(2))
        XCTAssertEqual(sent["expected_generation"], .number(1))
    }

    func testALostCanonicalUndoIsSentAgainIdentical() async throws {
        let chat = await openChat(runtime: "tip", history: [userRow("First", id: 1), assistantRow("One", id: 2),
                                                             userRow("Second", id: 3), assistantRow("Two", id: 4)],
                                  snapshot: canonicalSnapshot(), rpcDeadline: .milliseconds(300), canonical: true)
        chat.host.withhold("session.mutate")
        do { try await chat.turn.undo(); XCTFail("The undo's answer was lost") } catch {}

        chat.host.allow("session.mutate")
        chat.host.always("session.mutate", .init(result: .object(["rewound_count": .number(0)])))
        serveHistory([userRow("First", id: 1), assistantRow("One", id: 2)])
        await waitUntil("reattached") { chat.turn.engine.connectionState == .connected }
        try await chat.turn.undo()
        let tries = chat.writes("session.mutate")
        XCTAssertEqual(tries.count, 2)
        XCTAssertEqual(tries.map { $0["payload"] }, Array(repeating: .object(["target_message_id": .number(3)]), count: 2))
        XCTAssertEqual(tries[0]["request_id"], tries[1]["request_id"])
    }

    func testACanonicalCompressIsAFencedEdit() async throws {
        let noop = try canonical("canonical-mutations")["compress"]["result"]
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(), canonical: true)
        chat.host.always("session.mutate", .init(result: noop))
        let compression = try await chat.turn.compress(focus: nil)
        XCTAssertEqual(compression, .unchanged(noop["summary"]["headline"].text))
        XCTAssertEqual(chat.writes("session.mutate").map { $0["operation"] }, [.string("compress")])
        XCTAssertEqual(chat.writes("session.compress"), [])
    }

    func testACanonicalCompressReplyWithoutARevisionFails() async throws {
        let chat = await openChat(runtime: "tip", snapshot: canonicalSnapshot(), canonical: true)
        chat.host.always("session.mutate", .init(result: .object(["session_id": .string("tip"), "operation": .string("compress"),
                                                                  "status": .string("unexpected")])))
        do { _ = try await chat.turn.compress(focus: nil); XCTFail("an unreadable compaction reply was refused") }
        catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
    }

    func testARefusedSignInIsNeverSentAgainUnasked() async {
        let chat = await openChat()
        let before = chat.host.requests.count
        chat.turn.engine.disconnect(BotFailure.rejected(401))
        XCTAssertTrue(chat.model.hermesNeedsSignIn)

        chat.model.suspendStreamForBackground()
        await chat.model.reconnectStreamIfNeeded()
        await chat.model.networkPathDidChange()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        let sent = await chat.model.sendMessage("Are you there?")
        XCTAssertFalse(sent)
        let methods = chat.host.requests.dropFirst(before).compactMap { $0["method"].text }
        XCTAssertEqual(methods.filter { !["session.control.read", "model.options", "profiles.list", "commands.catalog",
                                          "subagent.list"].contains($0) }, [], "nothing reattached or sent")
        XCTAssertEqual(chat.turn.engine.connectionState, .disconnected)
    }

    func testTheAtPanelCompletesPathsOnTheCurrentRuntimeOfALocalBackend() async {
        let chat = await openChat()
        XCTAssertFalse(chat.model.offersFilePathSearch, "no session.info has named a folder")
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("docker")]))
        XCTAssertFalse(chat.model.offersFilePathSearch, "a docker folder is not on the host")
        await chat.model.searchFilePaths("Sou")
        XCTAssertEqual(chat.writes("complete.path").count, 0, "a closed panel asks nothing")

        chat.receive(event(2, "session.info", ["terminal_backend": .string("local")]))
        XCTAssertTrue(chat.model.offersFilePathSearch)
        chat.host.next("complete.path", .init(result: completions([
            "@folder:Sources/": "dir", "@file:Tools/Sourcery.yml": "Tools"
        ])))
        await chat.model.searchFilePaths("Sou")
        XCTAssertEqual(chat.model.filePathSearch.matches.map(\.path), ["Sources", "Tools/Sourcery.yml"])
        XCTAssertEqual(chat.model.filePathSearch.matches.map(\.isDirectory), [true, false])

        chat.host.next("complete.path", .init(result: completions(["Sources/App.swift": ""])))
        await chat.model.searchFilePaths("Sources/")
        XCTAssertEqual(chat.model.filePathSearch.matches.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(chat.writes("complete.path"), [
            ["word": .string("@file:Sou"), "session_id": .string("runtime"), "profile": .string("default")],
            ["word": .string("Sources/"), "session_id": .string("runtime"), "profile": .string("default")]
        ])
    }

    func testAPanelReplyThatLandsAfterTheFolderMovedIsDropped() async {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        chat.host.next("complete.path", .init(result: completions(["Sources/": "dir"]), before: [
            event(2, "session.info", ["cwd": .string("/work/moved")])
        ]))

        await chat.model.searchFilePaths("Sou")

        XCTAssertEqual(chat.writes("complete.path").count, 1)
        XCTAssertEqual(chat.model.filePathSearch.matches, [])
        XCTAssertFalse(chat.model.filePathSearch.isLoading)
    }

    func testFilesSearchesTheWholeFolderAfterTheChatDetachesForIt() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("docker")]))
        XCTAssertNil(chat.model.workspaceFileSearch, "a docker folder is not on the host")

        chat.receive(event(2, "session.info", ["terminal_backend": .string("local")]))
        let search = try XCTUnwrap(chat.model.workspaceFileSearch)
        chat.model.suspendStreamForNavigation()
        chat.host.next("complete.path", .init(result: completions([
            "@file:Sources/Git Diff.swift": "Sources", "@file:Tools/GitDiff.yml": "Tools"
        ])))
        let rows = try await search("Git Diff")

        XCTAssertEqual(rows.map(\.path), ["Sources/Git Diff.swift", "Tools/GitDiff.yml"])
        let requests = chat.writes("complete.path")
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request["word"], .string("@file:Git Diff"))
        XCTAssertEqual(request["cwd"], .string("/work/app"))
        XCTAssertEqual(request["profile"], .string("default"))
        XCTAssertTrue(chat.turn.isConnectionSuspended, "the search reattached the chat")
    }

    func testAFilesSearchCancelledWhileTheSocketOpensEndsAtOnce() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        let search = try XCTUnwrap(chat.model.workspaceFileSearch)
        chat.model.suspendStreamForNavigation()
        let opened = expectation(description: "the search's socket opened")
        chat.host.stallReady(opened)
        let searching = Task { try await search("GitDiff") }
        await fulfillment(of: [opened], timeout: 2)

        searching.cancel()
        do {
            _ = try await searching.value
            XCTFail("a cancelled search returned rows")
        } catch {
            XCTAssertEqual(error as? BotFailure, .stale, "the search waited out the stalled handshake")
        }
    }

    func testAFilesSearchReplyAfterTheFolderMovedIsStale() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        let search = try XCTUnwrap(chat.model.workspaceFileSearch)
        chat.host.next("complete.path", .init(result: completions(["@file:Sources/App.swift": "Sources"]), before: [
            event(2, "session.info", ["cwd": .string("/work/moved")])
        ]))

        do {
            _ = try await search("App")
            XCTFail("the old folder's rows were returned")
        } catch {
            XCTAssertEqual(error as? BotFailure, .stale)
        }
    }

    func testAnAtPathBecomesAChipOnlyWhenTheHostListsIt() async {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        chat.host.next("complete.path", .init(result: completions(["Sources/App.swift": "", "Sources/App.swift.orig": ""])))
        chat.host.next("complete.path", .init(result: completions([:])))

        await chat.model.loadFileChipReferences(draft: "read @Sources/App.swift and @nope.md")

        XCTAssertEqual(chat.model.fileChipPaths, ["Sources/App.swift"])
        XCTAssertEqual(chat.writes("complete.path").map { $0["word"]?.text }, ["Sources/App.swift", "nope.md"])
        await chat.model.loadFileChipReferences(draft: "read @Sources/App.swift and @nope.md")
        XCTAssertEqual(chat.writes("complete.path").count, 2, "a settled candidate is not asked again")
    }

    func testAFailedLookupKeepsItsSiblingsAnswers() async {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        chat.host.next("complete.path", .init(result: completions(["a.md": ""])))
        chat.host.next("complete.path", .init(error: -32000))

        await chat.model.loadFileChipReferences(draft: "see @a.md and @b.md")

        XCTAssertEqual(chat.model.fileChipPaths, ["a.md"])
        chat.host.next("complete.path", .init(result: completions(["b.md": ""])))
        await chat.model.loadFileChipReferences(draft: "see @a.md and @b.md")
        XCTAssertEqual(chat.writes("complete.path").map { $0["word"]?.text }, ["a.md", "b.md", "b.md"])
        XCTAssertEqual(chat.model.fileChipPaths, ["a.md", "b.md"])
    }

    func testAFolderMoveDropsChipsAndAStaleConfirmation() async {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        chat.model.recordFileChipReference("picked.md")
        XCTAssertEqual(chat.model.fileChipPaths, ["picked.md"])

        let revision = chat.model.fileChipScopeRevision
        chat.receive(event(2, "session.info", ["cwd": .string("/work/moved")]))
        XCTAssertEqual(chat.model.fileChipPaths, [])
        XCTAssertNotEqual(chat.model.fileChipScopeRevision, revision, "the chat re-checks in the new folder")

        chat.host.next("complete.path", .init(result: completions(["README.md": ""]), before: [
            event(3, "session.info", ["cwd": .string("/work/elsewhere")])
        ]))
        await chat.model.loadFileChipReferences(draft: "see @README.md")
        XCTAssertEqual(chat.model.fileChipPaths, [], "the reply described the folder before the move")

        chat.host.next("complete.path", .init(result: completions(["README.md": ""])))
        await chat.model.loadFileChipReferences(draft: "see @README.md")
        XCTAssertEqual(chat.model.fileChipPaths, ["README.md"])
        XCTAssertEqual(chat.writes("complete.path").count, 2)
    }

    func testAnUnansweredCompletionFailsOnlyItself() async throws {
        let chat = await openChat(rpcDeadline: .milliseconds(50))
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        let resumes = chat.writes("session.resume").count
        chat.host.withhold("complete.path")

        await chat.model.searchFilePaths("Sou")
        await chat.model.loadFileChipReferences(draft: "see @README.md")

        XCTAssertEqual(chat.writes("complete.path").count, 2)
        XCTAssertEqual(chat.model.filePathSearch.matches, [])
        XCTAssertFalse(chat.model.filePathSearch.isLoading)
        XCTAssertEqual(chat.model.fileChipPaths, [])
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        let reply = try await chat.turn.engine.request(.subagentList(sessionID: "runtime"), attempt: chat.turn.engine.generation)
        XCTAssertEqual(reply["subagents"].list, [])
        XCTAssertEqual(chat.writes("session.resume").count, resumes, "the chat never reattached")
    }

    func testAWaitingChipPassRechecksTheBackend() async {
        let chat = await openChat(rpcDeadline: .seconds(5))
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        chat.host.withhold("complete.path")
        let asked = expectation(description: "the first pass asks")
        chat.host.expect(asked, onNext: "complete.path")
        let first = Task { await chat.model.loadFileChipReferences(draft: "see @README.md") }
        await fulfillment(of: [asked], timeout: 2)
        let secondStarted = expectation(description: "the second pass starts behind the first")
        let second = Task {
            secondStarted.fulfill()
            await chat.model.loadFileChipReferences(draft: "see @README.md")
        }
        await fulfillment(of: [secondStarted], timeout: 2)

        chat.receive(event(2, "session.info", ["terminal_backend": .string("docker")]))
        await first.value
        await second.value

        XCTAssertFalse(chat.model.offersFilePathSearch)
        XCTAssertEqual(chat.writes("complete.path").count, 1)
        XCTAssertEqual(chat.model.fileChipPaths, [])
    }

    func testAnOpenPanelReloadsInTheNewFolder() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        chat.host.next("complete.path", .init(result: completions(["Sources/": "dir"]), before: [
            event(2, "session.info", ["cwd": .string("/work/moved")])
        ]))
        chat.host.next("complete.path", .init(result: completions(["Sourdough.md": ""])))
        let reloaded = expectation(description: "the panel loads its query again")
        var loads = 0
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: FilePathAutocompleteView(
            query: "Sou", search: chat.model.filePathSearch, load: { query in
                loads += 1
                if loads == 2 { reloaded.fulfill() }
                await chat.model.searchFilePaths(query)
            }, onSelect: { _ in }
        ))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        await fulfillment(of: [reloaded], timeout: 5)
        guard loads == 2 else { return }
        await waitUntil("the new folder's rows") { chat.model.filePathSearch.matches.map(\.path) == ["Sourdough.md"] }
        XCTAssertEqual(chat.writes("complete.path").map { $0["word"]?.text }, ["@file:Sou", "@file:Sou"])
    }

    func testALiveComputerUseRaisesTheScreenCardUntilTheNextTurn() async {
        let chat = await openChat()
        defer { chat.model.suspendStreamForBackground() }
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "tool.start", ["tool_id": .string("t1"), "name": .string("browser_click")]))
        XCTAssertNil(chat.turn.screenUse, "a browser tool doesn't mean the screen is in use")
        chat.receive(event(3, "tool.start", ["tool_id": .string("t2"), "name": .string("computer_use")]))
        XCTAssertEqual(chat.turn.screenUse, .active)
        chat.receive(event(4, "message.complete", ["text": .string("Stuck at a login.")]))
        chat.receive(event(5, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.turn.screenUse, .ended)

        chat.model.suspendStreamForBackground()
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 7, events: [
            event(6, "message.start"),
            event(7, "tool.start", ["tool_id": .string("t3"), "name": .string("computer_use")])
        ])))
        chat.host.always("session.resume", .init(result: resume(running: true)))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertNil(chat.turn.screenUse, "a replayed call is history, not the bot at work now")
    }

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
        let methods = chat.host.requests.dropFirst(leaving).compactMap { $0["method"].text }
        XCTAssertEqual(methods.filter { !["session.control.read", "model.options", "profiles.list", "commands.catalog",
                                          "subagent.list"].contains($0) },
                       ["session.resume", "session.events.since", "session.resume"], "reattaching only reads")
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
        XCTAssertNotNil(chat.model.activeStreamID)
    }

    func testAGapRebuildsFromTheSnapshot() async {
        await assertRebuild(after: event(5, "message.delta", ["text": .string("lost the middle")]))
    }

    func testARebuildKeepsNewDeltasThatRepeatTheReply() async {
        await assertRebuild(after: event(5, "message.delta", ["text": .string("lost the middle")]),
                            reply: "I checked the logs.\n",
                            held: [event(7, "message.delta", ["text": .string("I")]),
                                   event(8, "message.delta", ["text": .string("\nNext")])],
                            shows: "I checked the logs.\nI\nNext")
    }

    func testARebuildDropsOnlyTheDeltasAfterTheReplayedText() async {
        await assertRebuild(after: event(5, "message.delta", ["text": .string("lost the middle")]),
                            replayed: [event(6, "message.delta", ["text": .string(". ha")])],
                            reply: "Hello there. ha ha",
                            held: [event(7, "message.delta", ["text": .string(" ha")]),
                                   event(8, "message.delta", ["text": .string(" ha")])],
                            shows: "Hello there. ha ha ha")
    }

    func testAReclaimedRuntimeReattachesAndTheNextSendGoesOut() async {
        let chat = await openChat()
        let leaving = chat.host.requests.count
        await reclaim(chat, reclaimed(runtime: "runtime", key: "tip"))
        XCTAssertEqual(socketReads(chat, since: leaving), ["session.resume", "session.events.since", "session.resume"],
                       "one reattach, which only reads")

        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        let sent = await chat.model.sendMessage("Check the deploy")
        XCTAssertTrue(sent)
        XCTAssertNil(chat.model.sendErrorMessage)
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["session_id"] }, [.string("runtime-2")])
    }

    func testAReclaimOfTheStoredKeyReattaches() async {
        let chat = await openChat()
        let leaving = chat.host.requests.count
        await reclaim(chat, reclaimed(runtime: "another-runtime", key: "tip"))
        XCTAssertEqual(socketReads(chat, since: leaving), ["session.resume", "session.events.since", "session.resume"])
    }

    func testAnotherSessionsReclaimIsIgnored() async {
        let chat = await openChat()
        let leaving = chat.host.requests.count
        chat.receive(reclaimed(runtime: "another-runtime", key: "another-key"))
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(chat.turn.engine.runtime, "runtime")
        XCTAssertEqual(chat.host.requests.count, leaving, "nothing read or sent")
    }

    func testAReclaimMidTurnEndsInTheRecoveryState() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Working on")]))
        XCTAssertNotNil(chat.model.activeStreamID)
        await reclaim(chat, reclaimed(runtime: "runtime", key: "tip"))
        XCTAssertNil(chat.model.activeStreamID, "the idle snapshot ends the turn")
        XCTAssertNotNil(chat.model.latestRunOutcome)
        XCTAssertNil(chat.model.latestRunOutcome?.endedAt, "the chat never saw when the turn ended")
        XCTAssertEqual(chat.turn.recoveryState, .idle)
        XCTAssertEqual(chat.writes("prompt.submit").count, 0, "nothing resends")
    }

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

    func testABotChatTheHostReplacedIsFollowedAndASendAcrossTheSwapIsHeld() async {
        let chat = await openChat(target: .canonicalChat(profile: "default"), history: [userRow("Old question")])
        XCTAssertEqual(chat.model.messages.map(\.content), ["Old question"])

        chat.model.suspendStreamForBackground()
        chat.host.always("session.list", .init(result: .object(["sessions": .array([
            .object(["id": .string("new-root"), "resolved_id": .string("new-tip")])
        ])])))
        chat.host.always("session.resume", .init(result: resume(running: false, runtime: "runtime-2", key: "new-tip")))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        serveHistory([assistantRow("Fresh start", id: 1)], key: "new-tip")

        let held = await chat.model.sendMessage("Continue")
        XCTAssertFalse(held)
        XCTAssertNotNil(chat.model.sendErrorMessage)
        XCTAssertEqual(chat.writes("prompt.submit").count, 0, "nothing goes to a chat the user has not seen")
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(chat.turn.engine.root, "new-root")
        XCTAssertEqual(chat.model.messages.map(\.role), ["assistant", "local_notice"])
        XCTAssertEqual(chat.model.messages.first?.content, "Fresh start")

        let sent = await chat.model.sendMessage("Continue")
        XCTAssertTrue(sent)
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["session_id"] }, [.string("runtime-2")])
    }

    func testAPlanParsesTolerantlyAndSkipsMalformedItems() {
        let plan = HermesPlan(.object([
            "revision": .number(3),
            "todos": .array([
                .object(["id": .string("a"), "content": .string("Archive newsletters"), "status": .string("completed")]),
                .object(["content": .string("Draft replies"), "status": .string("in_progress")]),
                .object(["id": .string("c"), "content": .string(" "), "status": .string("pending")]),
                .string("garbage"),
                .object(["id": .string("d"), "content": .string("Report"), "status": .string("weird")])
            ])
        ]))
        XCTAssertEqual(plan?.revision, 3)
        XCTAssertEqual(plan?.items.map(\.content), ["Archive newsletters", "Draft replies", "Report"])
        XCTAssertEqual(plan?.items[1].id, "plan-1")
        XCTAssertEqual(plan?.completedCount, 1)
        XCTAssertEqual(plan?.current?.content, "Draft replies")
        XCTAssertFalse(plan?.isFinished ?? true)
        XCTAssertNil(HermesPlan(.object(["revision": .number(1), "todos": .array([])])))
        XCTAssertNil(HermesPlan(.object(["todos": .string("nope")])))
        XCTAssertNil(HermesPlan(.null))
    }

    func testAPlanPinsWhileItsTurnRunsAndSettlesIntoThatTurn() async throws {
        let chat = await openChat()
        let activity = chat.turn.activity
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Plan it")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "todo.updated", todos(revision: 1, ["completed", "completed", "in_progress", "pending", "pending"])))
        let pinned = try XCTUnwrap(activity.pinnedPlan, "an open plan pins while its turn runs")
        XCTAssertEqual(pinned.completedCount, 2)
        XCTAssertEqual(pinned.items.count, 5)
        XCTAssertEqual(pinned.current?.content, "Step 3")
        XCTAssertNil(activity.settledPlan, "a pinned plan is not also in the transcript")

        chat.receive(event(3, "todo.updated", todos(revision: 2, ["completed", "completed", "completed", "cancelled", "completed"])))
        XCTAssertNil(activity.pinnedPlan, "a finished plan leaves the strip while the turn still runs")
        XCTAssertEqual(activity.settledPlan?.plan.revision, 2)
        XCTAssertEqual(activity.settledPlan?.followsLastPrompt, true, "under the prompt this chat sent")

        chat.receive(event(4, "message.complete", ["status": .string("complete"), "text": .string("Done."),
                                                   "persisted_turn": .object(["row_ids": .array([.number(7), .number(8)]),
                                                                              "complete": .bool(false), "user_row_id": .number(7)])]))
        chat.receive(event(5, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(activity.settledPlan?.rowID, 7, "the plan keeps its turn's saved prompt")

        chat.receive(event(6, "message.start"))
        XCTAssertNil(activity.pinnedPlan)
        XCTAssertEqual(activity.settledPlan?.rowID, 7)
        XCTAssertEqual(activity.settledPlan?.followsLastPrompt, false, "the new turn did not touch the plan")
    }

    func testAnOpenPlanSettlesWhenItsTurnEnds() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Plan it")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "todo.updated", todos(revision: 1, ["completed", "in_progress", "pending"])))
        chat.receive(event(3, "message.complete", ["status": .string("complete"), "text": .string("Stopping here.")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertNil(chat.turn.activity.pinnedPlan)
        XCTAssertEqual(chat.turn.activity.settledPlan?.plan.current?.content, "Step 2")
        XCTAssertEqual(chat.turn.activity.settledPlan?.followsLastPrompt, true)
    }

    func testAnUnseenTurnEndsAnEarlierPlansClaimOnTheLastPrompt() async {
        let chat = await openChat()
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Plan it")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "todo.updated", todos(revision: 1, ["completed"])))
        chat.receive(event(3, "message.complete", ["status": .string("complete"), "text": .string("Done.")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.turn.activity.settledPlan?.followsLastPrompt, true)

        chat.receive(event(5, "message.complete", ["status": .string("error"), "error": .string("HTTP 500")]))
        XCTAssertNil(chat.turn.activity.settledPlan, "no saved row, and the last prompt may be the unseen turn's")
    }

    func testAnOlderPlanRevisionNeverReplacesANewerOneAndAHostClearRemovesIt() async {
        let chat = await openChat()
        let activity = chat.turn.activity
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "todo.updated", todos(revision: 2, ["in_progress", "pending"])))
        chat.receive(event(3, "todo.updated", todos(revision: 1, ["pending"], prefix: "Stale")))
        XCTAssertEqual(activity.pinnedPlan?.items.map(\.content), ["Step 1", "Step 2"])

        chat.receive(event(4, "todo.updated", todos(revision: 3, [])))
        XCTAssertNil(activity.pinnedPlan, "a host clear removes the strip")
        XCTAssertNil(activity.settledPlan, "and the row")

        chat.receive(event(5, "todo.updated", todos(revision: 2, ["pending"], prefix: "Stale")))
        XCTAssertNil(activity.pinnedPlan, "an older revision never undoes the clear")
    }

    func testTheAttachSnapshotRestoresThePlanAndANewRuntimeDropsIt() async {
        let chat = await openChat()
        let activity = chat.turn.activity
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "todo.updated", todos(revision: 1, ["in_progress", "pending"])))
        await reattach(chat, resume(running: true).replacing("todo_state", with: .object(todos(revision: 4, ["completed", "in_progress"]))))
        XCTAssertEqual(activity.pinnedPlan?.revision, 4, "the followed turn's plan pins after a reattach")
        XCTAssertEqual(activity.pinnedPlan?.current?.content, "Step 2")

        await reattach(chat, resume(running: true).replacing("todo_state", with: .object(todos(revision: 3, ["pending"], prefix: "Stale"))))
        XCTAssertEqual(activity.pinnedPlan?.revision, 4, "an older snapshot never replaces it")

        await reattach(chat, resume(running: true, runtime: "runtime-2")
            .replacing("todo_state", with: .object(todos(revision: 1, ["in_progress"], prefix: "Restored"))))
        XCTAssertNil(activity.pinnedPlan, "a new runtime drops the old one's plan, and can't place the one it restored")
        XCTAssertNil(activity.settledPlan)

        chat.receive(event(1, "todo.updated", todos(revision: 2, ["in_progress"], prefix: "Fresh"), runtime: "runtime-2"))
        XCTAssertEqual(activity.pinnedPlan?.items.map(\.content), ["Fresh 1"], "its revisions count from the start again")
    }

    func testAPlanRestoredOnOpenIsNotDrawnUnderTheNewestPrompt() async {
        let chat = await openChat(snapshot: resume(running: false)
            .replacing("todo_state", with: .object(todos(revision: 2, ["completed", "completed"]))))
        XCTAssertNil(chat.turn.activity.settledPlan, "no turn is known to own the restored plan")
        XCTAssertNil(chat.turn.activity.pinnedPlan)
    }

    func testARunningTurnPinsOnlyAPlanItRevised() async {
        let chat = await openChat(snapshot: resume(running: true)
            .replacing("todo_state", with: .object(todos(revision: 2, ["completed", "in_progress"], prefix: "Earlier"))))
        let activity = chat.turn.activity
        XCTAssertNotNil(chat.model.activeStreamID)
        XCTAssertNil(activity.pinnedPlan, "the running turn may not own the restored plan")
        XCTAssertNil(activity.settledPlan)

        chat.receive(event(1, "todo.updated", todos(revision: 3, ["in_progress", "pending"])))
        XCTAssertEqual(activity.pinnedPlan?.revision, 3, "its own revision pins")
    }

    func testAFollowedTurnsFinalPlanSettlesUnderItsPromptAfterAReattach() async {
        let activity = await followTurnThatEndsAway(saving: [userRow("Plan it", id: 5, at: 1_790_000_001)])
        XCTAssertNil(activity.pinnedPlan)
        XCTAssertEqual(activity.settledPlan?.plan.revision, 2, "the turn's final plan settles")
        XCTAssertEqual(activity.settledPlan?.rowID, 5, "at the top of its own turn")
    }

    func testAFollowedTurnsUnchangedPlanSettlesUnderItsPromptAfterAReattach() async {
        let activity = await followTurnThatEndsAway(saving: [userRow("Plan it", id: 5, at: 1_790_000_001)],
                                                    finalPlan: todos(revision: 1, ["in_progress", "pending"]))
        XCTAssertNil(activity.pinnedPlan)
        XCTAssertEqual(activity.settledPlan?.plan.revision, 1, "the turn's plan settles")
        XCTAssertEqual(activity.settledPlan?.rowID, 5, "at the top of its own turn")
    }

    func testAFollowedTurnKeepsNoPlanALaterTurnMayHaveRevised() async {
        let activity = await followTurnThatEndsAway(saving: [userRow("Plan it", id: 5, at: 1_790_000_001),
                                                             userRow("Another client", id: 6, at: 1_790_000_050)])
        XCTAssertNil(activity.pinnedPlan)
        XCTAssertNil(activity.settledPlan)
    }

    func testAnotherClientsPlanIsNeverDrawnUnderAnEarlierPrompt() async {
        let chat = await openChat(history: [userRow("Mine", id: 7)])
        let activity = chat.turn.activity
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "todo.updated", todos(revision: 1, ["completed", "completed"])))
        chat.receive(event(3, "message.complete", ["status": .string("complete"), "text": .string("Done.")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertNil(activity.settledPlan, "no row and no prompt shown for its turn")

        chat.receive(event(5, "message.start"))
        chat.receive(event(6, "todo.updated", todos(revision: 2, ["completed"])))
        chat.receive(event(7, "message.complete", ["status": .string("complete"), "text": .string("Done."),
                                                   "persisted_turn": .object(["complete": .bool(false), "user_row_id": .number(9)])]))
        chat.receive(event(8, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(activity.settledPlan?.rowID, 9)
        XCTAssertEqual(activity.settledPlan?.followsLastPrompt, false, "only its saved row places it")
    }

    func testASettledPlanWhoseSavedPromptIsGoneIsNotDrawn() throws {
        let plan = try XCTUnwrap(HermesPlan(.object(todos(revision: 1, ["completed"]))))
        let rows = [promptRow("Earlier", rowID: 5), promptRow("Its prompt", rowID: 7)]
        let saved = HermesChatActivity.SettledPlan(plan: plan, rowID: 7, followsLastPrompt: true)
        XCTAssertEqual(saved.afterRenderID(in: rows), "row-7")
        XCTAssertNil(saved.afterRenderID(in: Array(rows.prefix(1))), "never under the earlier prompt")
        let unsaved = HermesChatActivity.SettledPlan(plan: plan, rowID: nil, followsLastPrompt: true)
        XCTAssertEqual(unsaved.afterRenderID(in: rows), "row-7", "until its row is known, the prompt this chat showed")
        let shown = TranscriptMessage(loadedIndex: 8, renderID: "local", anchorID: "anchor-local",
                                      message: ChatMessage(role: "user", content: "Its prompt", timestamp: 1, messageId: "local"))
        XCTAssertEqual(saved.afterRenderID(in: [rows[0], shown]), "local", "the shown prompt stands in until the read saves it")
    }

    func testAnEmptyChatShowsAFailedTurnsOutcomeOrAQueuedPrompt() {
        typealias Placeholder = ChatTranscriptView.Placeholder
        XCTAssertNil(Placeholder(isLoading: false, errorMessage: nil, isEmpty: true, showsTurnOutcome: true,
                                 showsQueuedPrompt: false))
        XCTAssertNil(Placeholder(isLoading: false, errorMessage: nil, isEmpty: true, showsTurnOutcome: false,
                                 showsQueuedPrompt: true))
        XCTAssertEqual(Placeholder(isLoading: false, errorMessage: nil, isEmpty: true, showsTurnOutcome: false,
                                   showsQueuedPrompt: false), .startPrompt)
        XCTAssertEqual(Placeholder(isLoading: true, errorMessage: nil, isEmpty: true, showsTurnOutcome: true,
                                   showsQueuedPrompt: true), .loading)
        XCTAssertEqual(Placeholder(isLoading: false, errorMessage: "Offline", isEmpty: true, showsTurnOutcome: true,
                                   showsQueuedPrompt: true), .loadFailed("Offline"))
        XCTAssertNil(Placeholder(isLoading: false, errorMessage: nil, isEmpty: false, showsTurnOutcome: false,
                                 showsQueuedPrompt: false))
    }

    func testAFailedTurnShowsItsOutcomeAndNeverRetriesOnItsOwn() async throws {
        let chat = await openChat()
        let activity = chat.turn.activity
        serveHistory([userRow("Summarize the logs", id: 7)])
        chat.receive(event(1, "message.start"))
        chat.host.next("session.resume", .init(result: resume(running: false, inflight: Self.failedInflight)))
        chat.receive(event(2, "message.complete", Self.rateLimitedCompletion))
        XCTAssertNotNil(chat.model.activeStreamID, "the turn waits for session.info")
        chat.receive(event(3, "session.info", ["running": .bool(false)]))

        let failure = try XCTUnwrap(activity.failure)
        XCTAssertEqual(HermesTurnOutcomeRow.title(for: failure), "The model provider is rate-limiting requests")
        XCTAssertEqual(failure.error, "HTTP 429: Number of request tokens has exceeded your per-minute rate limit")
        XCTAssertEqual(failure.surface?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertTrue(failure.offersRetry)
        XCTAssertNil(chat.model.sendErrorMessage, "the outcome row says it, not an error line")
        XCTAssertEqual(chat.model.latestRunOutcome?.ending, .failed)

        await waitUntil("the retained prompt read") { activity.retryTarget != nil }
        XCTAssertEqual(activity.retryTarget, .init(rowID: 7, text: "Summarize the logs\n\n@file:/a/notes.txt", showsPrompt: false))
        XCTAssertEqual(chat.writes("prompt.submit").count, 0, "nothing resends on its own")

        chat.receive(event(4, "message.start"))
        XCTAssertNil(activity.failure, "the next turn clears the row")
        XCTAssertNil(activity.retryTarget)
    }

    func testRetryCutsAtThePromptOfTheTurnTheFailureReadNames() async {
        let chat = await openChat()
        let activity = chat.turn.activity
        serveHistory([userRow("First", id: 7), userRow("Second", id: 9, at: 1_790_000_100)])
        var later = Self.failedInflight
        later["user"] = .string("Second"); later["started_at"] = .number(1_790_000_100)
        chat.host.next("session.resume", .init(result: resume(running: false, inflight: later)))
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", Self.rateLimitedCompletion))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))

        await waitUntil("the retained prompt read") { activity.retryTarget != nil }
        XCTAssertEqual(activity.retryTarget, .init(rowID: 9, text: "Second", showsPrompt: false), "the named turn's prompt, at its own row")
    }

    func testAnUnseenFailedTurnReplacesTheEarlierRetry() async {
        let chat = await openChat()
        let activity = chat.turn.activity
        serveHistory([userRow("First", id: 7)])
        var first = Self.failedInflight
        first["user"] = .string("First")
        chat.host.next("session.resume", .init(result: resume(running: false, inflight: first)))
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", Self.rateLimitedCompletion))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        await waitUntil("the first failure read") { activity.retryTarget != nil }
        XCTAssertEqual(activity.retryTarget?.rowID, 7)

        serveHistory([userRow("First", id: 7), userRow("Second", id: 9, at: 1_790_000_100)])
        var second = Self.failedInflight
        second["user"] = .string("Second"); second["started_at"] = .number(1_790_000_100)
        chat.host.next("session.resume", .init(result: resume(running: false, inflight: second)))
        var unseen = Self.rateLimitedCompletion
        unseen["persisted_turn"] = nil
        chat.receive(event(4, "message.complete", unseen))
        XCTAssertNil(activity.retryTarget, "the earlier prompt's cut would take the newer turn")

        await waitUntil("the second failure read") { activity.retryTarget != nil }
        XCTAssertEqual(activity.retryTarget, .init(rowID: 9, text: "Second", showsPrompt: false))
    }

    func testRetryIsNotOfferedWhenAPromptFollowsTheFailedOne() async {
        let chat = await openChat()
        let activity = chat.turn.activity
        serveHistory([userRow("First", id: 7, at: 1_790_000_001), userRow("Second", id: 9, at: 1_790_000_100)])
        var retained = Self.failedInflight
        retained["user"] = .string("First"); retained["error"] = .string("HTTP 429: retained")
        chat.host.next("session.resume", .init(result: resume(running: false, inflight: retained)))
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", Self.rateLimitedCompletion))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))

        await waitUntil("the failure read") { activity.failure?.error == "HTTP 429: retained" }
        XCTAssertNil(activity.retryTarget, "no prompt row is provably the failed turn's")
    }

    func testAWarningShowsTheHostsWordsUntilTheNextTurn() async {
        let chat = await openChat()
        let activity = chat.turn.activity
        let warning = "The session database was locked; this reply exists only in this view."
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", ["status": .string("complete"), "text": .string("Done."),
                                                   "warning": .string(warning)]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(activity.notice?.warning, warning)
        XCTAssertNil(activity.failure)

        await reattach(chat, resume(running: false), latest: 3)
        XCTAssertEqual(activity.notice?.warning, warning, "a continuous reattach keeps it")

        chat.receive(event(4, "message.start"))
        XCTAssertNil(activity.notice)
    }

    func testAFailureTheHostRetainedShowsOnAttach() async {
        let chat = await openChat(history: [userRow("Summarize the logs")])
        await reattach(chat, resume(running: false, inflight: Self.failedInflight))
        XCTAssertEqual(chat.turn.activity.failure?.surface?.code, "rate_limit")
        XCTAssertNil(chat.model.sendErrorMessage)
        XCTAssertEqual(chat.turn.activity.retryTarget, .init(rowID: 1, text: "Summarize the logs\n\n@file:/a/notes.txt", showsPrompt: false))
    }

    func testLiveWorkersReplaceTheEmptyConversationPlaceholder() {
        typealias Placeholder = ChatTranscriptView.Placeholder
        XCTAssertNil(Placeholder(isLoading: false, errorMessage: nil, isEmpty: true,
                                 showsTurnOutcome: false, showsQueuedPrompt: false, showsDelegatedWork: true))
        XCTAssertEqual(Placeholder(isLoading: false, errorMessage: nil, isEmpty: true,
                                   showsTurnOutcome: false, showsQueuedPrompt: false, showsDelegatedWork: false), .startPrompt)
    }

    func testDelegatedWorkListsOnConnectAndOnLifecycleFramesOnly() async {
        let chat = await openChat(subagents: [worker("tests"), worker("docs")])
        let work = chat.turn.activity.delegatedWork
        await waitUntil("listed on connect") { work.activeCount == 2 }
        XCTAssertEqual(chat.writes("subagent.list").map { $0["session_id"]?.text }, ["runtime"])

        chat.host.always("subagent.list", .init(result: .object(["subagents": .array([worker("docs")])])))
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "subagent.complete", ["subagent_id": .string("tests"), "status": .string("completed")]))
        chat.receive(event(3, "subagent.progress", ["subagent_id": .string("docs")]))
        await waitUntil("listed after the lifecycle frames") { work.activeCount == 1 }
        XCTAssertEqual(work.workers.map(\.subagentID), ["docs"])
        XCTAssertEqual(chat.writes("subagent.list").count, 2, "two lifecycle frames are one read")

        chat.model.suspendStreamForBackground()
        XCTAssertEqual(work.activeCount, 0, "a chat that left shows no workers")
    }

    func testALiveDelegationDeliveryDrawsItsCompletionCardWhenItsTurnEnds() async throws {
        let report = "[ASYNC DELEGATION BATCH COMPLETE]\n--- RESULT ---\nTests rewritten; docs updated."
        let earlier = [userRow("Split the work"), assistantRow("Started two workers.", id: 2)]
        let chat = await openChat(history: earlier)
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Both workers finished.")]))
        chat.receive(event(3, "message.complete", ["status": .string("complete"), "text": .string("Both workers finished."),
                                                   "persisted_turn": .object([
                                                       "row_ids": .array([.number(3), .number(4)]), "complete": .bool(true),
                                                       "user_row_id": .number(3), "final_assistant_row_id": .number(4)
                                                   ])]))
        serveHistory(earlier + [
            .object(["id": .number(3), "role": .string("user"), "timestamp": .number(1_790_000_100),
                     "content": .string(report), "display_kind": .string("async_delegation_complete"),
                     "display_metadata": .object(["task_count": .number(2), "completed_count": .number(2),
                                                  "failed_count": .number(0), "duration_seconds": .number(41),
                                                  "delegation_id": .string("dlg_7f3a")])]),
            assistantRow("Both workers finished.", id: 4, at: 1_790_000_140)
        ])
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        await waitUntil("the turn's saved rows") { chat.model.messages.last?.rowID == 4 }

        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4])
        let completion = try XCTUnwrap(HermesDelegationCompletion(chat.model.messages[2]), "the delivery is its card")
        XCTAssertEqual(completion.report, report, "the card carries the full report")
        XCTAssertEqual(completion.taskCount, 2)
        XCTAssertEqual(completion.completedCount, 2)
        XCTAssertEqual(completion.delegationID, "dlg_7f3a")
        XCTAssertEqual(chat.model.messages.last?.content, "Both workers finished.")
    }

    func testARefusedResumeShowsTheHostsReasonAndIsNotRetriedUnasked() async {
        let chat = await openChat()
        chat.model.suspendStreamForNavigation()
        chat.host.always("session.resume", .init(error: 4001, data: .object(["reason": .string("runtime_coordination_required")])))
        let before = chat.host.requests.count
        func resumes() -> Int { chat.host.requests.dropFirst(before).filter { $0["method"].text == "session.resume" }.count }
        await chat.model.reconnectStreamIfNeeded()
        await chat.model.loadMessages(usesInitialPrefetch: true)
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(resumes(), 1, "appearing, the first load and its follow-up share one attach")
        XCTAssertEqual(chat.model.errorMessage, BotFailure.resumeRefused("runtime_coordination_required").localizedDescription)
        chat.host.always("session.resume", .init(error: 4001, message: "session not found"))
        await chat.model.loadMessages()
        XCTAssertEqual(resumes(), 2, "Try Again asks once more")
        XCTAssertEqual(chat.model.errorMessage, BotFailure.resumeRefused("session not found").localizedDescription)
        chat.model.suspendStreamForNavigation()
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(resumes(), 3, "coming back to the chat asks again")
        XCTAssertFalse(BotConnectionAdvice.isRetryable(BotFailure.rejected(4001)))
    }

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/HermesAgent")

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient
        let liveActivity: TitleRecordingLiveActivity

        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private static let photoReference = "[The user attached an image: dashboard_20261005_120000_0123abcd_IMG_2041.jpg]\n"
        + "[Examine it with the vision_analyze tool using image_url: /home/u/.hermes/images/dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"

    private func openChat(runtime: String = "runtime", key: String = "tip", profile: String = "default",
                          target: ConversationTarget? = nil, drafts: ChatDraftStore? = nil, lineageRoot: String? = nil,
                          history: [BotJSON] = [], snapshot: BotJSON? = nil, subagents: [BotJSON] = [],
                          rpcDeadline: Duration = .seconds(30), canonical: Bool = false,
                          botChatRoot: String? = nil, ratingPromptState: RatingPromptState? = nil,
                          replay: BotJSON? = nil, noticeTimer: HermesHostNotices.Timer? = nil) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("subagent.list", .init(result: .object(["subagents": .array(subagents), "delegations": .array([])])))
        host.always("session.resume", .init(result: snapshot ?? resume(running: false, runtime: runtime, key: key, profile: profile)))
        host.always("session.events.since", .init(result: replay ?? BotFixtureWire.replay(latest: 0)))
        host.always("session.create", .init(result: .object([
            "session_id": .string(runtime), "stored_session_id": .string(key), "message_count": .number(0),
            "messages": .array([]), "info": .object(["profile_name": .string(profile)])
        ])))
        let client = BotClient(http: host.connection(Self.connection, rpcDeadline: rpcDeadline, canonical: canonical))
        serveHistory(history, key: key)
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: target ?? .session(profile: profile, key: key), wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, botChatRoot: botChatRoot, lineageRoot: lineageRoot,
                                             isNetworkAvailable: { true },
                                             ratingPromptState: ratingPromptState ?? isolatedRatingState(),
                                             noticeTimer: noticeTimer)
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

    private func isolatedRatingState() -> RatingPromptState {
        let suite = "HermesChatTurnTests.rating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return RatingPromptState(defaults: defaults)
    }

    private static let failedInflight: [String: BotJSON] = [
        "user": .string("Summarize the logs\n\n@file:/a/notes.txt"), "assistant": .string(""),
        "error": .string("HTTP 429: Number of request tokens has exceeded your per-minute rate limit"),
        "status": .string("error"), "recoverable": .bool(true),
        "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"),
                                  "retryable": .bool(true), "resets_at": .number(1_900_000_000)])
    ]

    private static let rateLimitedCompletion: [String: BotJSON] = [
        "status": .string("error"), "text": .string("HTTP 429: Number of request tokens has exceeded your per-minute rate limit"),
        "error": .string("HTTP 429: Number of request tokens has exceeded your per-minute rate limit"),
        "recoverable": .bool(true),
        "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"),
                                  "retryable": .bool(true), "resets_at": .number(1_900_000_000)]),
        "persisted_turn": .object(["row_ids": .array([.number(7)]), "complete": .bool(false), "user_row_id": .number(7)])
    ]

    private func todos(revision: Int, _ statuses: [String], prefix: String = "Step") -> [String: BotJSON] {
        ["revision": .number(Double(revision)), "todos": .array(statuses.enumerated().map { index, status in
            .object(["id": .string("\(prefix)-\(index)"), "content": .string("\(prefix) \(index + 1)"), "status": .string(status)])
        })]
    }

    private func standingNoticeReplay(latest: Int, truncated: Bool = false) throws -> BotJSON {
        var expired = try recorded("turn-notice-frames")[1]["params"].fields ?? [:]
        expired["session_id"] = .string("runtime"); expired["seq"] = .number(Double(latest - 3))
        return BotFixtureWire.replay(latest: latest, truncated: truncated, events: [
            .object(expired),
            event(latest - 2, "notification.show", ["text": .string("Sign in at https://example.com/device"), "level": .string("info"),
                                                    "kind": .string("sticky"), "key": .string("login:1")]),
            event(latest - 1, "notification.show", ["text": .string("Still starting the agent"), "level": .string("info"),
                                                    "kind": .string("agent"), "key": .string("agent.build_slow")]),
            event(latest, "notification.clear", ["key": .string("agent.build_slow")])
        ])
    }

    private func reattach(_ chat: Chat, _ snapshot: BotJSON, latest: Int = 0) async {
        chat.model.suspendStreamForBackground()
        chat.host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: latest)))
        chat.host.always("session.resume", .init(result: snapshot))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
    }

    private func reclaimed(runtime: String, key: String) -> BotJSON {
        .object(["type": .string("session.reclaimed"), "session_id": .string(""),
                 "payload": .object(["session_id": .string(runtime), "stored_session_id": .string(key),
                                     "reason": .string("idle_timeout")])])
    }

    private func reclaim(_ chat: Chat, _ frame: BotJSON) async {
        chat.host.always("session.resume", .init(result: resume(running: false, runtime: "runtime-2")))
        chat.receive(frame)
        await waitUntil("reattached") {
            chat.turn.engine.connectionState == .connected && chat.turn.engine.runtime == "runtime-2"
        }
    }

    private func socketReads(_ chat: Chat, since index: Int) -> [String] {
        chat.host.requests.dropFirst(index).compactMap { $0["method"].text }
            .filter { !["session.control.read", "model.options", "profiles.list", "commands.catalog", "subagent.list"].contains($0) }
    }

    private func assertRebuild(after frame: BotJSON, replayed: [BotJSON] = [], reply: String = "Hello there, friend",
                               held: [BotJSON]? = nil, shows: String = "Hello there, friend.",
                               file: StaticString = #filePath, line: UInt = #line) async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Hello")]))
        chat.receive(event(3, "message.delta", ["text": .string(" there")]))
        let held = held ?? [event(7, "message.delta", ["text": .string(", fri")]),
                            event(8, "message.delta", ["text": .string("end")]),
                            event(9, "message.delta", ["text": .string(".")])]
        serveHistory([userRow("Hi")])
        let snapshot = resume(running: true, inflight: ["user": .string("Hi"), "assistant": .string(reply)])
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 6, events: replayed)))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.host.next("session.resume", .init(result: snapshot, before: held))
        let leaving = chat.host.requests.count
        chat.receive(frame)
        await waitUntil("rebuilt") { chat.turn.engine.connectionState == .connected }
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.host.transcriptReads(since: leaving), [false, false], "the snapshot carries no transcript",
                       file: file, line: line)
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/tip/messages"), 2, "the gap re-read the newest page",
                       file: file, line: line)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", shows], file: file, line: line)

        let next = (held.compactMap { $0["seq"].integer }.max() ?? 6) + 1
        chat.receive(event(next, "message.delta", ["text": .string(" Done")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", shows + " Done"], file: file, line: line)
        XCTAssertNotNil(chat.model.activeStreamID, file: file, line: line)
    }

    private func followTurnThatEndsAway(saving rows: [BotJSON], finalPlan: [String: BotJSON]? = nil) async -> HermesChatActivity {
        let earlier = userRow("Earlier", id: 3, at: 1_789_999_000)
        let chat = await openChat(history: [earlier])
        let activity = chat.turn.activity
        chat.receive(event(1, "session.info", ["running": .bool(true), "turn_started_at": .number(1_790_000_000)]))
        chat.receive(event(2, "message.start"))
        chat.receive(event(3, "todo.updated", todos(revision: 1, ["in_progress", "pending"])))
        XCTAssertEqual(activity.pinnedPlan?.revision, 1)
        serveHistory([earlier] + rows)
        await reattach(chat, resume(running: false)
            .replacing("todo_state", with: .object(finalPlan ?? todos(revision: 2, ["completed", "completed"]))))
        XCTAssertNil(chat.model.activeStreamID, "the idle snapshot ends the followed turn")
        return activity
    }

    private func canonical(_ name: String) throws -> BotJSON {
        guard let data = try? Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".json")) else {
            throw XCTSkip("The source tree is not present (physical device or remote runner).")
        }
        return try JSONDecoder().decode(BotJSON.self, from: data)["reply"]
    }

    private func canonicalSnapshot(running: Bool = false, generation: Int = 1, pending: [BotJSON] = [],
                                   prompts: [BotJSON] = [], epoch: String = "epoch") -> BotJSON {
        .object(["session_id": .string("tip"), "stored_session_id": .string("tip"), "replay_epoch": .string(epoch),
                 "subscription_id": .string("sub-1"), "execution_generation": .number(Double(generation)), "revision": .number(2),
                 "running": .bool(running), "messages": .array([]), "pending": .array(pending), "prompts": .array(prompts),
                 "info": .object(["profile_name": .string("default")])])
    }

    private func admission(_ id: String, _ status: String, _ text: String, generation: Int? = nil) -> BotJSON {
        .object(["admission_id": .string(id), "status": .string(status), "text": .string(text),
                 "execution_generation": generation.map { .number(Double($0)) } ?? .null])
    }

    private func canonicalEvent(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:],
                                admission: String, generation: Int?) -> BotJSON {
        var params = event(seq, type, payload, runtime: "tip").fields ?? [:]
        params["admission_id"] = .string(admission)
        params["execution_generation"] = generation.map { .number(Double($0)) } ?? .null
        return .object(params)
    }

    private func recorded(_ name: String, key: String = "frames") throws -> [BotJSON] {
        guard let data = try? Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".json")) else {
            throw XCTSkip("The source tree is not present (physical device or remote runner).")
        }
        let capture = try JSONDecoder().decode(BotJSON.self, from: data)
        return try XCTUnwrap(capture.list ?? capture[key].list)
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:], runtime: String = "runtime") -> BotJSON {
        .object(["session_id": .string(runtime), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }

    private func completions(_ rows: KeyValuePairs<String, String>) -> BotJSON {
        .object(["items": .array(rows.map { text, meta in
            .object(["text": .string(text), "display": .string(text), "meta": .string(meta)])
        })])
    }

    private func worker(_ id: String) -> BotJSON {
        .object(["subagent_id": .string(id), "goal": .string("Work on \(id)"), "depth": .number(0),
                 "started_at": .number(1_790_000_010), "status": .string("running")])
    }

    private func userRow(_ text: String, id: Int = 1, at timestamp: Double = 1_790_000_000) -> BotJSON {
        .object(["id": .number(Double(id)), "role": .string("user"), "content": .string(text), "timestamp": .number(timestamp)])
    }

    private func promptRow(_ text: String, rowID: Int) -> TranscriptMessage {
        TranscriptMessage(loadedIndex: rowID, renderID: "row-\(rowID)", anchorID: "anchor-\(rowID)",
                          message: ChatMessage(role: "user", content: text, timestamp: 1, messageId: "m\(rowID)", rowID: rowID))
    }

    private func assistantRow(_ text: String, id: Int, at timestamp: Double = 1_790_000_010) -> BotJSON {
        .object(["id": .number(Double(id)), "role": .string("assistant"), "content": .string(text), "timestamp": .number(timestamp)])
    }

    private func serveHistory(_ rows: [BotJSON], key: String = "tip") {
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/sessions/\(key)/messages" else { return nil }
            return .json(200, .object(["session_id": .string(key), "messages": .array(rows)]))
        }
    }

    private func resume(running: Bool, runtime: String = "runtime", key: String = "tip", profile: String = "default",
                        history: [BotJSON] = [], inflight: [String: BotJSON]? = nil) -> BotJSON {
        var reply: [String: BotJSON] = [
            "session_id": .string(runtime), "session_key": .string(key), "running": .bool(running),
            "messages": .array(history), "info": .object(["profile_name": .string(profile)])
        ]
        if running { reply["turn_started_at"] = .number(1_790_000_000) }
        if var inflight {
            inflight["started_at"] = inflight["started_at"] ?? .number(1_790_000_000)
            reply["inflight"] = .object(inflight)
        }
        return .object(reply)
    }
}

@MainActor private final class ManualNoticeTimer {
    private(set) var delays: [Duration] = []
    private(set) var tasks: [Task<Void, Never>] = []
    private var expiries: [@MainActor () -> Void] = []
    private var streams: [AsyncStream<Void>.Continuation] = []

    var timer: HermesHostNotices.Timer {
        { [self] delay, expire in
            delays.append(delay)
            expiries.append(expire)
            let (never, open) = AsyncStream<Void>.makeStream()
            streams.append(open)
            let task = Task { for await _ in never {} }
            tasks.append(task)
            return task
        }
    }

    func fire(_ index: Int) { expiries[index]() }
}

private final class TitleRecordingLiveActivity: AgentLiveActivityManaging {
    private(set) var titles: [String] = []
    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date) {}
    func update(_ event: AgentLiveActivityEvent) {
        if case .sessionTitle(let title) = event { titles.append(title) }
    }
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}

private actor InMemoryDraftPersistence: ChatDraftPersisting {
    private var values: [ChatDraftKey: ChatDraft] = [:]
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) { values = drafts }
}

private extension BotJSON {
    func replacing(_ key: String, with value: BotJSON) -> BotJSON {
        var fields = self.fields ?? [:]
        fields[key] = value
        return .object(fields)
    }
}
