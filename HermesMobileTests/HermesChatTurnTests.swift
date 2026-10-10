import XCTest
import Observation
import SwiftUI
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

    /// A title that is only the reference line a photo-only send appends shows the photo's
    /// name, never the raw line (#1046).
    func testAnAttachmentOnlyTitleShowsTheAttachmentsName() async {
        let chat = await openChat()
        chat.receive(event(1, "session.title", ["title": .string(Self.photoReference)]))
        XCTAssertEqual(chat.model.displayTitle, "IMG_2041.jpg")
    }

    /// The host's instant title cuts a photo's reference line at 48 characters, before the
    /// photo's name. The header names the chat after the first prompt's photo instead (#1046).
    func testATitleCutBeforeTheAttachmentsNameShowsTheFirstPromptsAttachment() async {
        let chat = await openChat(history: [userRow(Self.photoReference)])
        chat.receive(event(1, "session.title", ["title": .string("[The user attached an image…")]))
        XCTAssertEqual(chat.model.displayTitle, "IMG_2041.jpg")
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
        // Its lost answer holds Send until the reattach it started has read the session (#508).
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

    // MARK: `@` file references (#1113)

    /// The `@` panel opens only once `session.info` names a folder on a `local` backend, then
    /// asks `complete.path` on the attached runtime under the session's Profile; a picked folder
    /// asks again for what is inside it.
    func testTheAtPanelCompletesPathsOnTheCurrentRuntimeOfALocalBackend() async {
        let chat = await openChat()
        XCTAssertFalse(chat.model.offersFilePathSearch, "no session.info has named a folder")
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("docker")]))
        XCTAssertFalse(chat.model.offersFilePathSearch, "a docker folder is not on the host")
        await chat.model.searchFilePaths("Sou")
        XCTAssertEqual(chat.writes("complete.path").count, 0, "a closed panel asks nothing")

        chat.receive(event(2, "session.info", ["terminal_backend": .string("local")]))
        XCTAssertTrue(chat.model.offersFilePathSearch)
        chat.host.next("complete.path", .init(result: completions(["Sources/": "dir", "Sourcery.yml": ""])))
        await chat.model.searchFilePaths("Sou")
        XCTAssertEqual(chat.model.filePathSearch.matches.map(\.path), ["Sources", "Sourcery.yml"])
        XCTAssertEqual(chat.model.filePathSearch.matches.map(\.isDirectory), [true, false])

        chat.host.next("complete.path", .init(result: completions(["Sources/App.swift": ""])))
        await chat.model.searchFilePaths("Sources/")
        XCTAssertEqual(chat.model.filePathSearch.matches.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(chat.writes("complete.path"), [
            ["word": .string("Sou"), "session_id": .string("runtime"), "profile": .string("default")],
            ["word": .string("Sources/"), "session_id": .string("runtime"), "profile": .string("default")]
        ])
    }

    /// Rows for a folder the chat has moved away from never show: a reply that lands after
    /// `session.info` names a new folder is dropped.
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

    /// An `@path` in the draft or a sent message becomes a chip when `complete.path` lists it;
    /// one it doesn't list stays text and is not asked about again.
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

    /// A failed lookup leaves only its own candidate open: a sibling the host confirmed in the
    /// same folder still becomes a chip and is not asked about again.
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

    /// Move to Project takes the old folder's chips with it, and a confirmation that lands after
    /// the move counts for nothing: the next pass asks again in the new folder.
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

    /// A `complete.path` the host never answers empties the panel and leaves the candidate
    /// open; the chat keeps its connection and its next call is answered.
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

    /// A chip pass that waited behind another starts against the backend it finds: once
    /// `session.info` moves the folder off `local`, it asks nothing.
    func testAWaitingChipPassRechecksTheBackend() async {
        let chat = await openChat(rpcDeadline: .seconds(5))
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        chat.host.withhold("complete.path")
        let asked = expectation(description: "the first pass asks")
        chat.host.expect(asked, onNext: "complete.path")
        let first = Task { await chat.model.loadFileChipReferences(draft: "see @README.md") }
        await fulfillment(of: [asked], timeout: 2)
        let second = Task { await chat.model.loadFileChipReferences(draft: "see @README.md") }
        await Task.yield() // the second caller reaches its wait behind the first pass

        chat.receive(event(2, "session.info", ["terminal_backend": .string("docker")]))
        await first.value
        await second.value

        XCTAssertFalse(chat.model.offersFilePathSearch)
        XCTAssertEqual(chat.writes("complete.path").count, 1)
        XCTAssertEqual(chat.model.fileChipPaths, [])
    }

    /// An open `@` panel asks again when the folder moves under the same query, even while
    /// the old folder's reply is still on its way.
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
        XCTAssertEqual(chat.writes("complete.path").map { $0["word"]?.text }, ["Sou", "Sou"])
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
        // Each attach's goal, model-catalog, Profile (#1015) and command-catalog (#1036) reads
        // run off its path and can land anywhere in this; they are not the reattach.
        let methods = chat.host.requests.dropFirst(leaving).compactMap { $0["method"].text }
        XCTAssertEqual(methods.filter { !["session.control.read", "model.options", "profiles.list", "commands.catalog"].contains($0) },
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

    // MARK: Plan and outcome (#1139)

    /// The host's plan reads tolerantly: blank and malformed items drop, an item with no id
    /// gets its position, and an unknown status reads as pending.
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

    /// A turn that calls `todo` pins its plan while it runs. Once every step is done, or the turn
    /// ends, the plan settles at the top of that turn: under the prompt the chat sent, then by the
    /// row the host saved it as. A later turn that leaves the plan alone does not take it.
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

    /// A plan whose turn ends with steps still open settles too, showing where it stopped.
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

    /// An older revision never replaces a newer one, and an empty list at revision 1 or later is
    /// the host clearing the plan: it goes from the strip and the transcript, and an older
    /// revision does not bring it back.
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

    /// A reattach to the turn the chat was following restores that turn's plan from the
    /// snapshot's `todo_state`, revision-monotonic; a new runtime starts its revisions again, so
    /// the plan the old one had is dropped, and the new one's own revision pins.
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

    /// Reopening a chat restores the session's plan, which the host keeps across turns, so it may
    /// be any earlier turn's: it is not drawn under the newest prompt.
    func testAPlanRestoredOnOpenIsNotDrawnUnderTheNewestPrompt() async {
        let chat = await openChat(snapshot: resume(running: false)
            .replacing("todo_state", with: .object(todos(revision: 2, ["completed", "completed"]))))
        XCTAssertNil(chat.turn.activity.settledPlan, "no turn is known to own the restored plan")
        XCTAssertNil(chat.turn.activity.pinnedPlan)
    }

    /// Opening a chat while a turn runs does not pin a restored plan the turn never revised; the
    /// turn's own revision does.
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

    /// The chat followed a turn's plan, then left; the turn finished its plan and ended while the
    /// replay lost its frames. The idle snapshot's newer revision is still that turn's, since its
    /// prompt is the only one saved since it began: it settles at the top of that turn.
    func testAFollowedTurnsFinalPlanSettlesUnderItsPromptAfterAReattach() async {
        let activity = await followTurnThatEndsAway(saving: [userRow("Plan it", id: 5, at: 1_790_000_001)])
        XCTAssertNil(activity.pinnedPlan)
        XCTAssertEqual(activity.settledPlan?.plan.revision, 2, "the turn's final plan settles")
        XCTAssertEqual(activity.settledPlan?.rowID, 5, "at the top of its own turn")
    }

    /// As above, but the turn did not revise its plan again: the plan it already owned settles at
    /// the top of that turn all the same.
    func testAFollowedTurnsUnchangedPlanSettlesUnderItsPromptAfterAReattach() async {
        let activity = await followTurnThatEndsAway(saving: [userRow("Plan it", id: 5, at: 1_790_000_001)],
                                                    finalPlan: todos(revision: 1, ["in_progress", "pending"]))
        XCTAssertNil(activity.pinnedPlan)
        XCTAssertEqual(activity.settledPlan?.plan.revision, 1, "the turn's plan settles")
        XCTAssertEqual(activity.settledPlan?.rowID, 5, "at the top of its own turn")
    }

    /// As above, but another turn also ran while the chat was away: the newer revision may be
    /// that turn's, so it is not drawn under either.
    func testAFollowedTurnKeepsNoPlanALaterTurnMayHaveRevised() async {
        let activity = await followTurnThatEndsAway(saving: [userRow("Plan it", id: 5, at: 1_790_000_001),
                                                             userRow("Another client", id: 6, at: 1_790_000_050)])
        XCTAssertNil(activity.pinnedPlan)
        XCTAssertNil(activity.settledPlan)
    }

    /// A turn another client started shows no prompt in this chat, so its plan never settles
    /// under the last prompt shown, an earlier turn's: without a saved row it is not drawn, and
    /// with one only that row places it.
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

    /// A failed turn says why in its outcome row, not as error text: the host's surface, its
    /// reset time and raw error. Once the turn settles, one live-state read takes the prompt the
    /// host kept for Retry, which nothing sends on its own. The next turn clears the row.
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
        XCTAssertEqual(activity.retryTarget, .init(rowID: 7, text: "Summarize the logs\n\n@file:/a/notes.txt"))
        XCTAssertEqual(chat.writes("prompt.submit").count, 0, "nothing resends on its own")

        chat.receive(event(4, "message.start"))
        XCTAssertNil(activity.failure, "the next turn clears the row")
        XCTAssertNil(activity.retryTarget)
    }

    /// The failure read can name a later turn than the one this chat saw fail, such as one another
    /// client started that the host failed before it began. Retry then offers that turn's prompt,
    /// dated from its start, never the earlier prompt's row, whose cut would take both turns.
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
        XCTAssertEqual(activity.retryTarget, .init(rowID: 9, text: "Second"), "the named turn's prompt, at its own row")
    }

    /// The failure read takes the snapshot, then the newest rows. A turn another client submitted
    /// in between, which the host failed before it began, saved its prompt after the failed one's,
    /// so the rows can't say which prompt the snapshot's turn is: Retry is not offered, rather than
    /// cutting at the later prompt's row with the earlier prompt's text.
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

    /// A warning on a turn that succeeded shows the host's words. It survives a reattach and
    /// goes when the next turn starts.
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

    /// A failure the host retained while the chat was away shows on attach, with the host's raw
    /// prompt and the saved row dated from the turn's start for Retry.
    func testAFailureTheHostRetainedShowsOnAttach() async {
        let chat = await openChat(history: [userRow("Summarize the logs")])
        await reattach(chat, resume(running: false, inflight: Self.failedInflight))
        XCTAssertEqual(chat.turn.activity.failure?.surface?.code, "rate_limit")
        XCTAssertNil(chat.model.sendErrorMessage)
        XCTAssertEqual(chat.turn.activity.retryTarget, .init(rowID: 1, text: "Summarize the logs\n\n@file:/a/notes.txt"))
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

    /// The two reference lines a photo-only send appends, for an upload the host named
    /// `dashboard_<date>_<time>_<hex>_IMG_2041.jpg`.
    private static let photoReference = "[The user attached an image: dashboard_20261005_120000_0123abcd_IMG_2041.jpg]\n"
        + "[Examine it with the vision_analyze tool using image_url: /home/u/.hermes/images/dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"

    private func openChat(runtime: String = "runtime", key: String = "tip", profile: String = "default",
                          target: ConversationTarget? = nil, drafts: ChatDraftStore? = nil,
                          history: [BotJSON] = [], snapshot: BotJSON? = nil, rpcDeadline: Duration = .seconds(30)) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: snapshot ?? resume(running: false, runtime: runtime, key: key, profile: profile)))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        // The reduced reply `session.create` gives a session that has not started.
        host.always("session.create", .init(result: .object([
            "session_id": .string(runtime), "stored_session_id": .string(key), "message_count": .number(0),
            "messages": .array([]), "info": .object(["profile_name": .string(profile)])
        ])))
        let client = BotClient(http: host.connection(Self.connection, rpcDeadline: rpcDeadline))
        serveHistory(history, key: key)
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

    /// A failed turn's retained `inflight`, as `session.resume` carries it (`_fail_inflight_turn`).
    private static let failedInflight: [String: BotJSON] = [
        "user": .string("Summarize the logs\n\n@file:/a/notes.txt"), "assistant": .string(""),
        "error": .string("HTTP 429: Number of request tokens has exceeded your per-minute rate limit"),
        "status": .string("error"), "recoverable": .bool(true),
        "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"),
                                  "retryable": .bool(true), "resets_at": .number(1_900_000_000)])
    ]

    /// A rate-limited turn's `message.complete` (`_complete_turn_payload`), whose prompt row the host saved as 7.
    private static let rateLimitedCompletion: [String: BotJSON] = [
        "status": .string("error"), "text": .string("HTTP 429: Number of request tokens has exceeded your per-minute rate limit"),
        "error": .string("HTTP 429: Number of request tokens has exceeded your per-minute rate limit"),
        "recoverable": .bool(true),
        "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"),
                                  "retryable": .bool(true), "resets_at": .number(1_900_000_000)]),
        "persisted_turn": .object(["row_ids": .array([.number(7)]), "complete": .bool(false), "user_row_id": .number(7)])
    ]

    /// A `todo.updated` payload or `todo_state` at `revision`: one item per status, named
    /// `<prefix> <n>`.
    private func todos(revision: Int, _ statuses: [String], prefix: String = "Step") -> [String: BotJSON] {
        ["revision": .number(Double(revision)), "todos": .array(statuses.enumerated().map { index, status in
            .object(["id": .string("\(prefix)-\(index)"), "content": .string("\(prefix) \(index + 1)"), "status": .string(status)])
        })]
    }

    /// Leaves and comes back: the replay holds nothing past `latest`, and every snapshot is `snapshot`.
    private func reattach(_ chat: Chat, _ snapshot: BotJSON, latest: Int = 0) async {
        chat.model.suspendStreamForBackground()
        chat.host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: latest)))
        chat.host.always("session.resume", .init(result: snapshot))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
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

    /// Follows a turn that began at the fixtures' start time and revised its plan to revision 1,
    /// then leaves. While away the turn ends with `finalPlan` (by default finished at revision 2),
    /// the host saves `rows` after an earlier prompt, and the replay comes back truncated.
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

    /// A `complete.path` reply listing `rows`, path to `meta`, in order.
    private func completions(_ rows: KeyValuePairs<String, String>) -> BotJSON {
        .object(["items": .array(rows.map { text, meta in
            .object(["text": .string(text), "display": .string(text), "meta": .string(meta)])
        })])
    }

    /// A saved prompt as a transcript page carries it (#1047), saved at `at`.
    private func userRow(_ text: String, id: Int = 1, at timestamp: Double = 1_790_000_000) -> BotJSON {
        .object(["id": .number(Double(id)), "role": .string("user"), "content": .string(text), "timestamp": .number(timestamp)])
    }

    /// Serves `rows` as session `key`'s settled history, every page the same.
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
