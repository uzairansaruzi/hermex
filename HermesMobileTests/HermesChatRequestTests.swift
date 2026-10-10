import XCTest
@testable import HermesMobile

/// A Hermes session's host requests in the main chat (#1011): approvals, questions, and sudo
/// and secret prompts, over #901's socket-level host and the approval recorded at the
/// `HERMES_AGENT_TESTED_SHA` pin.
@MainActor final class HermesChatRequestTests: XCTestCase {
    // MARK: Approvals

    /// The recorded approval offers exactly the host's four choices, and the answer names the
    /// approval queue's `request_id`, not the envelope id.
    func testARecordedApprovalOffersTheHostsChoicesAndAnswersByItsRequestID() async throws {
        let approval = try XCTUnwrap(try recorded("turn-tool-approval-frames").first { $0["method"].text == "approval" })
        let chat = await openChat(runtime: "7dd4dff2")
        chat.host.always("approval.respond", .init(result: .object(["resolved": .number(1)])))
        chat.receive(approval)
        guard case .approval(let shown)? = chat.requests.onScreen else { return XCTFail("Expected the approval on screen") }
        let content = shown.overlayContent(pendingCount: chat.requests.approvalCount)
        XCTAssertEqual(content.choices, [.once, .session, .always, .deny])
        XCTAssertEqual(content.pendingCount, 1)
        XCTAssertEqual(content.command, "python3 -c \"print(1)\"")
        XCTAssertTrue(chat.model.isWaitingForUser)

        let taken = await chat.requests.respond(try action(chat), choice: .session)
        XCTAssertTrue(taken)
        XCTAssertEqual(chat.writes("approval.respond"), [[
            "session_id": .string("7dd4dff2"), "request_id": .string("850a0a9d32c448c2b4b9bc34503f5812"),
            "choice": .string("session")
        ]])
        XCTAssertNil(chat.requests.onScreen, "an answered card leaves at once")
        XCTAssertFalse(chat.model.isWaitingForUser)
    }

    /// A smart-denied approval offers only Allow once and Deny, and a choice it did not offer
    /// is never sent.
    func testAnApprovalOffersOnlyTheChoicesTheHostComputed() async throws {
        let chat = await openChat()
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1", choices: ["once", "deny"]))
        guard case .approval(let shown)? = chat.requests.onScreen else { return XCTFail("Expected the approval on screen") }
        XCTAssertEqual(shown.overlayContent(pendingCount: 1).choices, [.once, .deny])

        let taken = await chat.requests.respond(try action(chat), choice: .always)
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.writes("approval.respond"), [])
    }

    /// `resolved: 0`: the host no longer held it, answered elsewhere or expired. The card goes
    /// quietly, and the answer is not sent again.
    func testAnApprovalTheHostNoLongerHeldLeavesQuietly() async throws {
        let chat = await openChat()
        chat.host.always("approval.respond", .init(result: .object(["resolved": .number(0)])))
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))
        let taken = await chat.requests.respond(try action(chat), choice: .once)
        XCTAssertFalse(taken)
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertNil(chat.requests.errorMessage)
        XCTAssertNil(chat.requests.withdrawal)
        XCTAssertEqual(chat.writes("approval.respond").count, 1)
    }

    /// A refused answer leaves the card answerable with the reason; nothing is retried.
    func testARefusedAnswerKeepsTheCardAndIsNotRetried() async throws {
        let chat = await openChat()
        chat.host.always("request.answer", .init(error: 4002))
        chat.receive(request("sudo", id: "srq-s1"))
        let taken = await chat.requests.answerCredential(try action(chat), value: "hunter2")
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.requests.onScreen?.requestID, "srq-s1")
        XCTAssertTrue(chat.requests.mayAnswer)
        XCTAssertEqual(chat.requests.errorMessage, "The server did not accept that response. The request is still waiting.")
        XCTAssertEqual(chat.model.sendErrorMessage, "The server did not accept that response. The request is still waiting.")
        XCTAssertEqual(chat.writes("request.answer").count, 1)
    }

    // MARK: Approval bypass

    /// The pill reads the session's `yolo` from `session.info`.
    func testTheBypassFollowsSessionInfo() async {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["yolo": .bool(true)]))
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
        chat.receive(event(2, "session.info", ["yolo": .bool(false)]))
        XCTAssertFalse(chat.model.isSessionApprovalBypassEnabled)
    }

    /// Skip all turns the session's bypass on, then releases the card with `once`, each sent
    /// once and in that order; the pill turns it off again.
    func testSkipAllTurnsTheBypassOnAndReleasesTheCardAndThePillTurnsItOff() async throws {
        let chat = await openChat()
        chat.host.next("config.set", .init(result: .object(["key": .string("yolo"), "value": .string("1"), "scope": .string("session")])))
        chat.host.next("config.set", .init(result: .object(["key": .string("yolo"), "value": .string("0"), "scope": .string("session")])))
        chat.host.always("approval.respond", .init(result: .object(["resolved": .number(1)])))
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))

        let skipped = await chat.requests.skipApprovals(try action(chat))
        XCTAssertTrue(skipped)
        XCTAssertEqual(chat.host.requests.compactMap { $0["method"].text }.filter { ["config.set", "approval.respond"].contains($0) },
                       ["config.set", "approval.respond"])
        XCTAssertEqual(chat.writes("config.set"), [[
            "session_id": .string("runtime"), "profile": .string("default"), "key": .string("yolo"),
            "value": .string("on"), "scope": .string("session")
        ]])
        XCTAssertEqual(chat.writes("approval.respond"), [[
            "session_id": .string("runtime"), "request_id": .string("q-1"), "choice": .string("once")
        ]])
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)

        await chat.requests.turnOffApprovalBypass()
        XCTAssertEqual(chat.writes("config.set").last?["value"], .string("off"))
        XCTAssertFalse(chat.model.isSessionApprovalBypassEnabled)
    }

    /// Skip all whose release the host refuses is not a skip: the bypass is on, but the card
    /// stays answerable with the reason, and the release is not sent again.
    func testSkipAllWhoseReleaseIsRefusedKeepsTheCard() async throws {
        let chat = await openChat()
        chat.host.next("config.set", .init(result: yoloReply("1")))
        chat.host.always("approval.respond", .init(error: 4002))
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))

        let skipped = await chat.requests.skipApprovals(try action(chat))
        XCTAssertFalse(skipped)
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
        XCTAssertEqual(chat.requests.onScreen?.requestID, "q-1")
        XCTAssertTrue(chat.requests.mayAnswer)
        XCTAssertEqual(chat.requests.errorMessage, "The server did not accept that response. The request is still waiting.")
        XCTAssertEqual(chat.writes("approval.respond").count, 1)
    }

    /// Turn off clears only the session's flag. A bypass the host sets itself (a `--yolo`
    /// launch) stays on in the `session.info` written ahead of the reply, so the pill keeps
    /// reporting it and offers no second Turn off.
    func testTurnOffNeverClaimsApprovalsAreBackWhileTheHostStillBypassesThem() async {
        let chat = await openChat(info: ["yolo": .bool(true), "approval_mode": .string("manual")])
        chat.host.next("config.set", .init(result: yoloReply("0"), before: [
            event(1, "session.info", ["yolo": .bool(true), "approval_mode": .string("manual")])
        ]))
        await chat.requests.turnOffApprovalBypass()
        XCTAssertEqual(chat.writes("config.set").map { $0["value"] }, [.string("off")])
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled, "the host still bypasses approvals")

        await chat.requests.turnOffApprovalBypass()
        XCTAssertEqual(chat.writes("config.set").count, 1, "a session flag already off cannot clear the host's bypass")
    }

    /// A host that approves everything itself (`approvals.mode: off`) shows the bypass, and the
    /// pill never sends a session-scoped off that cannot clear it.
    func testAHostWideBypassIsReportedButNotTurnedOff() async {
        let chat = await openChat(info: ["yolo": .bool(true), "approval_mode": .string("off")])
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
        await chat.requests.turnOffApprovalBypass()
        XCTAssertEqual(chat.writes("config.set"), [])
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
    }

    // MARK: Questions

    /// A batch locks each outstanding question by its `qid`, skipping the one the host already
    /// holds, and never sends a bare answer. Skipping a batch locks each one empty.
    func testABatchLocksEachQuestionByItsIDAndSkipNeverSendsABareAnswer() async throws {
        let restored = request("clarify", id: "srq-b1", [
            "questions": .array([question("q1", "Which repo?"), question("q2", "Which branch?"), question("q3", "Run tests?")]),
            "answers": .object(["q1": .string("hermex")])
        ])
        let chat = await openChat(openRequests: [restored])
        chat.host.next("clarify.lock", .init(result: .object(["status": .string("ok"), "remaining": .array([.string("q3")])])))
        chat.host.next("clarify.lock", .init(result: .object(["status": .string("ok"), "remaining": .array([])])))
        guard case .question(let shown)? = chat.requests.onScreen else { return XCTFail("Expected the batch on screen") }
        XCTAssertEqual(shown.questions.map(\.isAnswered), [true, false, false], "the restore keeps the host's lock")

        let partial = await chat.requests.answerQuestion(try action(chat), [BotQuestionAnswer(questionID: "q2", text: "main")])
        XCTAssertFalse(partial, "every outstanding question is answered in one tap")
        let taken = await chat.requests.answerQuestion(try action(chat), [
            BotQuestionAnswer(questionID: "q2", text: "main"), BotQuestionAnswer(questionID: "q3", text: "yes")
        ])
        XCTAssertTrue(taken)
        XCTAssertEqual(chat.writes("clarify.lock"), [
            ["request_id": .string("srq-b1"), "question_id": .string("q2"), "answer": .string("main")],
            ["request_id": .string("srq-b1"), "question_id": .string("q3"), "answer": .string("yes")]
        ])
        XCTAssertNil(chat.requests.onScreen)

        chat.host.next("clarify.lock", .init(result: .object(["status": .string("ok"), "remaining": .array([.string("q2")])])))
        chat.host.next("clarify.lock", .init(result: .object(["status": .string("ok"), "remaining": .array([])])))
        chat.receive(request("clarify", id: "srq-b2", ["questions": .array([question("q1", "Deploy?"), question("q2", "Notify?")])]))
        let skipped = await chat.requests.skipQuestion(try action(chat))
        XCTAssertTrue(skipped)
        XCTAssertEqual(chat.writes("clarify.lock").suffix(2).map { $0["question_id"] }, [.string("q1"), .string("q2")])
        XCTAssertEqual(chat.writes("clarify.lock").suffix(2).map { $0["answer"] }, [.string(""), .string("")])
        XCTAssertEqual(chat.writes("request.answer"), [], "a batch never gets a bare answer")
    }

    /// A single question is answered, and skipped, with one `request.answer`.
    func testASingleQuestionIsAnsweredAndSkippedWithRequestAnswer() async throws {
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which mailbox first?"),
                                                       "choices": .array([.string("Primary (Recommended)"), .string("Follow-ups")])]))
        let taken = await chat.requests.answerQuestion(try action(chat), [BotQuestionAnswer(questionID: nil, text: "Primary (Recommended)")])
        XCTAssertTrue(taken)

        chat.receive(request("clarify", id: "srq-c2", ["question": .string("Anything else?")]))
        let skipped = await chat.requests.skipQuestion(try action(chat))
        XCTAssertTrue(skipped)
        XCTAssertEqual(chat.writes("request.answer"), [
            ["id": .string("srq-c1"), "result": .object(["answer": .string("Primary (Recommended)")])],
            ["id": .string("srq-c2"), "result": .object(["answer": .string("")])]
        ])
        XCTAssertEqual(chat.writes("clarify.lock"), [])
    }

    // MARK: Credentials

    /// Sudo and secret are answered and skipped with `request.answer {value}`, and the value is
    /// kept nowhere on the request model once it is sent.
    func testSudoAndSecretAreAnsweredAndSkippedAndTheValueIsNotKept() async throws {
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        chat.receive(request("sudo", id: "srq-s1"))
        let answered = await chat.requests.answerCredential(try action(chat), value: "hunter2")
        XCTAssertTrue(answered)

        chat.receive(request("secret", id: "srq-k1", ["env_var": .string("TAVILY_API_KEY")]))
        let skipped = await chat.requests.answerCredential(try action(chat), value: "")
        XCTAssertTrue(skipped)
        XCTAssertEqual(chat.writes("request.answer"), [
            ["id": .string("srq-s1"), "result": .object(["value": .string("hunter2")])],
            ["id": .string("srq-k1"), "result": .object(["value": .string("")])]
        ])
        var kept = ""
        dump(chat.requests, to: &kept, maxDepth: 4)
        XCTAssertFalse(kept.contains("hunter2"), kept)
    }

    /// An answer tapped for one prompt never answers the one that replaced it.
    func testAnActionForAReplacedPromptIsNeverDispatched() async throws {
        let chat = await openChat()
        chat.receive(request("sudo", id: "srq-s5"))
        let stale = try action(chat)
        chat.receive(event(1, "request.cancel", ["id": .string("srq-s5"), "method": .string("sudo"), "reason": .string("timeout")]))
        chat.receive(request("sudo", id: "srq-s6"))
        let taken = await chat.requests.answerCredential(stale, value: "hunter2")
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.writes("request.answer"), [])
        XCTAssertTrue(chat.requests.mayAnswer, "the live prompt is still answerable")
    }

    /// Vault prompts (#943) and unknown methods get no card and no answer here, though the
    /// session still waits on them.
    func testRequestsThisChatMustNotAnswerGetNoCardButStillWait() async {
        let chat = await openChat()
        chat.receive(request("vault.unlock_prompt", id: "srq-v1", ["display_name": .string("1Password")]))
        chat.receive(request("display.install.sudo", id: "srq-d1"))
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertNil(chat.requests.prepareAnswer())
        XCTAssertTrue(chat.model.isWaitingForUser)
        XCTAssertTrue(chat.model.stopNeedsConfirmation)
        XCTAssertEqual(ChatActiveRunStatusPolicy.presentation(
            isStartingChat: false, hasActiveStream: true, activeStreamRecoveryState: .idle, isCancellingStream: false,
            isScrolledNearBottom: false, activeRunStartedAt: nil, isWaitingForUser: chat.model.isWaitingForUser
        )?.label(now: Date()), "Waiting for you")
    }

    // MARK: Desktop tasks and connections (#1141)

    /// A Desktop task shows its card with Stop and is never answered from here: the card is
    /// inert, stopping loses nothing, and its withdrawal leaves no note.
    func testADesktopTaskShowsItsCardAndIsNeverAnswered() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(request("terminal.read", id: "srq-t1"))
        guard case .desktopTask(let task)? = chat.requests.onScreen else { return XCTFail("Expected the Desktop task on screen") }
        XCTAssertEqual(task.kind, .terminalRead)
        XCTAssertNil(chat.requests.prepareAnswer())
        XCTAssertFalse(chat.requests.mayAnswer)
        XCTAssertTrue(chat.model.isWaitingForUser)
        XCTAssertFalse(chat.model.stopNeedsConfirmation, "stopping loses nothing Desktop's own task holds")

        chat.receive(event(2, "request.cancel", ["id": .string("srq-t1"), "method": .string("terminal.read"),
                                                 "reason": .string("timeout")]))
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertNil(chat.requests.withdrawal, "Desktop's own task leaves silently")
        XCTAssertEqual(chat.writes("request.answer"), [])
    }

    /// `connection.request` shows one row per app in the host's order, duplicates dropped; an
    /// update moves the rows only when its `seq` is newer; the settled frame closes the card,
    /// and a late request for that operation cannot bring it back.
    func testAConnectionOperationOpensMovesForwardAndSettles() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1, targets: [
            BotConnectionFixture.gmail(), BotConnectionFixture.github(), BotConnectionFixture.gmail(state: "connected")
        ])))
        XCTAssertEqual(connectionOnScreen(chat)?.targets.map(\.name), ["gmail", "github"])
        XCTAssertEqual(connectionOnScreen(chat)?.targets.first?.state, .pending)
        XCTAssertTrue(chat.model.isWaitingForUser)

        chat.receive(event(3, "connection.update", operation(seq: 3, targets: [
            BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github()
        ])))
        chat.receive(event(4, "connection.update", operation(seq: 2, targets: [
            BotConnectionFixture.gmail(state: "failed"), BotConnectionFixture.github()
        ])))
        XCTAssertEqual(connectionOnScreen(chat)?.targets.first?.state, .connected, "an older seq moves nothing")

        chat.receive(event(5, "connection.update", operation(seq: 4, settled: true)))
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertFalse(chat.model.isWaitingForUser)
        chat.receive(event(6, "connection.request", operation(seq: 5)))
        XCTAssertNil(chat.requests.onScreen, "a settled operation never comes back")
    }

    /// An attach restores the operation from `pending_connection`; one this build cannot read
    /// still waits, with no card; a resume that omits it clears it.
    func testPendingConnectionRestoresOnAttachAndClearsWhenOmitted() async {
        let chat = await openChat(pendingConnection: .object(operation(seq: 2)))
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1")
        XCTAssertTrue(chat.model.isWaitingForUser)

        chat.model.suspendStreamForBackground()
        chat.host.always("session.resume", .init(result: resume(pendingConnection: .object(["op_id": .string("op-2")]))))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertTrue(chat.model.isWaitingForUser, "an operation with no readable row still waits")

        chat.model.suspendStreamForBackground()
        chat.host.always("session.resume", .init(result: resume()))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertFalse(chat.model.isWaitingForUser)
    }

    /// A row's answer goes out once as `connection.respond` by the session's owner and `op_id`;
    /// the card stays until the host says the operation settled. A move the card does not
    /// offer is never sent.
    func testConnectionAnswersAreSentOnceAndTheCardStaysUntilSettled() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.host.next("connection.respond", .init(result: .object(["status": .string("ok"), "settled": .bool(false)])))
        chat.host.next("connection.respond", .init(result: .object(["status": .string("ok"), "settled": .bool(true)])))

        let notOffered = await chat.requests.respondToConnection(try action(chat), .connect(target: "github", env: [:]))
        XCTAssertFalse(notOffered, "a required value is missing")
        let skipped = await chat.requests.respondToConnection(try action(chat), .skip(target: "gmail"))
        XCTAssertTrue(skipped)
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1", "other rows are still open")
        let released = await chat.requests.respondToConnection(try action(chat), .continueWithout)
        XCTAssertTrue(released)
        XCTAssertEqual(chat.writes("connection.respond"), [
            ["owner": .object(["type": .string("session"), "session_id": .string("runtime")]), "op_id": .string("op-1"),
             "result": .object(["targets": .array([.object(["name": .string("gmail"), "status": .string("skipped")])])])],
            ["owner": .object(["type": .string("session"), "session_id": .string("runtime")]), "op_id": .string("op-1"),
             "result": .object(["settled_by": .string("continue")])]
        ])
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertFalse(chat.model.isWaitingForUser)
    }

    /// A row the host moves between the tap and the socket write is not answered: the write
    /// checks the card still offers that move, and the rows still open stay answerable.
    func testAMoveTheCardStopsOfferingBeforeTheWriteIsNeverSent() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        let moved = event(3, "connection.update", operation(seq: 2, targets: [
            BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github()
        ]))
        // Fires as the answer begins, after its tap checks and before the socket write.
        withObservationTracking { _ = chat.requests.answeringRequestID } onChange: {
            MainActor.assumeIsolated { chat.receive(moved) }
        }

        let taken = await chat.requests.respondToConnection(try action(chat), .skip(target: "gmail"))
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.writes("connection.respond"), [])
        XCTAssertEqual(connectionOnScreen(chat)?.targets.first?.state, .connected)
        XCTAssertTrue(chat.requests.mayAnswer, "the card still answers its open rows")
    }

    /// 4004: the host no longer holds the operation. The chat reads the session again, and a
    /// card that read still lists stays inert; nothing is sent again.
    func testAnOperationTheHostNoLongerHoldsGoesInertAndIsReadAgain() async throws {
        let chat = await openChat(pendingConnection: .object(operation(seq: 1)))
        chat.host.next("connection.respond", .init(error: 4004))
        let resumes = chat.writes("session.resume").count

        let taken = await chat.requests.respondToConnection(try action(chat), .skip(target: "gmail"))
        XCTAssertFalse(taken)
        XCTAssertFalse(chat.requests.mayAnswer)
        await chat.turn.activate()
        XCTAssertGreaterThan(chat.writes("session.resume").count, resumes, "the chat read the session again")
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1")
        XCTAssertEqual(chat.requests.onScreenResolution?.outcome, .alreadyResolved)
        XCTAssertFalse(chat.requests.mayAnswer)
        XCTAssertNil(chat.requests.prepareAnswer())
        XCTAssertEqual(chat.writes("connection.respond").count, 1)
    }

    /// A lost reply warns on the card the reconnect restores, and is never resent.
    func testALostConnectionAnswerWarnsAndIsNeverResent() async throws {
        let chat = await openChat(pendingConnection: .object(operation(seq: 1)), rpcDeadline: .milliseconds(50))
        chat.host.withhold("connection.respond")
        let taken = await chat.requests.respondToConnection(try action(chat), .skip(target: "gmail"))
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.turn.engine.connectionState, .disconnected)
        XCTAssertNil(chat.requests.onScreen, "the card leaves with the socket")
        XCTAssertFalse(chat.model.isWaitingForUser)

        // Reattach now rather than on the backoff.
        await chat.model.networkPathDidChange()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1", "the host still holds it")
        XCTAssertEqual(chat.requests.onScreenResolution?.outcome, .uncertain)
        XCTAssertTrue(chat.requests.mayAnswer, "a deliberate second answer is the user's call")
        XCTAssertEqual(chat.writes("connection.respond").count, 1)
    }

    /// An operation this build cannot read stops holding the chat once the socket drops.
    func testADisconnectClearsAnUnreadableOperationsWait() async {
        let chat = await openChat(pendingConnection: .object(["op_id": .string("op-2")]))
        XCTAssertTrue(chat.model.isWaitingForUser)

        chat.turn.engine.disconnect(BotFailure.rejected(403))
        XCTAssertFalse(chat.model.isWaitingForUser)
    }

    /// A readable settled frame ends the wait of an operation this build could not read, by
    /// its `op_id`: another operation's settling leaves it waiting, and the settled one never
    /// comes back.
    func testASettledFrameEndsAnUnreadableOperationsWait() async {
        let chat = await openChat(pendingConnection: .object(["op_id": .string("op-1")]))
        XCTAssertTrue(chat.model.isWaitingForUser)

        chat.receive(event(1, "connection.update", operation("op-2", seq: 2, settled: true)))
        XCTAssertTrue(chat.model.isWaitingForUser, "another operation settled")
        chat.receive(event(2, "connection.update", operation(seq: 2, settled: true)))
        XCTAssertFalse(chat.model.isWaitingForUser)
        XCTAssertFalse(chat.requests.stopWithdrawsAnswers)

        chat.receive(event(3, "connection.request", operation(seq: 3)))
        XCTAssertNil(chat.requests.onScreen, "a settled operation never comes back")
    }

    /// A new operation this build cannot read replaces the live card, as a readable one would:
    /// the old card leaves rather than staying answerable, and the chat still waits.
    func testAnUnreadableRequestReplacesTheLiveCard() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1")

        chat.receive(event(3, "connection.request", ["op_id": .string("op-2")]))
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertFalse(chat.requests.mayAnswer)
        XCTAssertTrue(chat.model.isWaitingForUser)
    }

    /// Another operation's settled frame leaves the live card as it was.
    func testAnotherOperationSettlingLeavesTheLiveCardOpen() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.receive(event(3, "connection.update", operation("op-2", seq: 4, settled: true)))
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1")
        XCTAssertEqual(connectionOnScreen(chat)?.seq, 1)
        XCTAssertTrue(chat.model.isWaitingForUser)
    }

    /// Back on a session whose operation opened before the replay cursor, a `connection.update`
    /// the engine holds while the snapshot is read moves the restored card instead of losing
    /// it, and the snapshot's `open_requests` still apply.
    func testAnUpdateDuringTheSnapshotReadMovesTheRestoredOperation() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.model.suspendStreamForBackground()

        let question = request("clarify", id: "srq-c1", ["question": .string("Which file?")])
        chat.host.always("session.events.since", .init(result: replay(latest: 2)))
        chat.host.next("session.resume", .init(result: resume(pendingConnection: .object(operation(seq: 1)))))
        chat.host.next("session.resume", .init(
            result: resume(openRequests: [question], pendingConnection: .object(operation(seq: 1))),
            before: [event(3, "connection.update", operation(seq: 2, targets: [
                BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github()
            ]))]
        ))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(chat.requests.open.map(\.id), ["srq-c1"], "a connection frame never holds back open_requests")
        XCTAssertEqual(chat.requests.connection?.seq, 2)
        XCTAssertEqual(chat.requests.connection?.targets.first?.state, .connected)

        chat.receive(event(4, "connection.update", operation(seq: 3, targets: [
            BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github(state: "connected")
        ])))
        XCTAssertEqual(chat.requests.connection?.targets.map(\.state), [.connected, .connected], "later updates still land")
    }

    /// An operation that settles while the snapshot is read closes, though the snapshot still
    /// lists it, and a late frame for it cannot bring it back.
    func testAnOperationSettledDuringTheSnapshotReadStaysClosed() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.model.suspendStreamForBackground()

        chat.host.always("session.events.since", .init(result: replay(latest: 2)))
        chat.host.next("session.resume", .init(result: resume(pendingConnection: .object(operation(seq: 1)))))
        chat.host.next("session.resume", .init(result: resume(pendingConnection: .object(operation(seq: 1))),
                                               before: [event(3, "connection.update", operation(seq: 2, settled: true))]))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertFalse(chat.model.isWaitingForUser)

        chat.receive(event(4, "connection.request", operation(seq: 3)))
        XCTAssertNil(chat.requests.onScreen, "a settled operation never comes back")
    }

    /// An operation that settles while the snapshot is read stays closed when the snapshot,
    /// read after it settled, no longer lists it.
    func testAnOperationSettledDuringASnapshotThatOmitsItStaysClosed() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.model.suspendStreamForBackground()

        chat.host.always("session.events.since", .init(result: replay(latest: 2)))
        chat.host.next("session.resume", .init(result: resume(pendingConnection: .object(operation(seq: 1)))))
        chat.host.next("session.resume", .init(result: resume(),
                                               before: [event(3, "connection.update", operation(seq: 2, settled: true))]))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertFalse(chat.model.isWaitingForUser)

        chat.receive(event(4, "connection.request", operation(seq: 3)))
        XCTAssertNil(chat.requests.onScreen, "a settled operation never comes back")
    }

    /// Steer and Queue release an open operation with `settled_by: "continue"` before their
    /// message, as Desktop does; a refused Continue still sends it; Interrupt sends no Continue.
    func testGuideAndQueueContinueFirstAndInterruptDoesNot() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.host.next("connection.respond", .init(result: .object(["status": .string("ok"), "settled": .bool(true)])))
        chat.host.next("session.steer", .init(result: .object(["status": .string("queued")])))
        _ = try await chat.turn.submit("Use the work account", mode: .steer)
        XCTAssertEqual(chat.host.requests.compactMap { $0["method"].text }.filter { ["connection.respond", "session.steer"].contains($0) },
                       ["connection.respond", "session.steer"])
        XCTAssertEqual(chat.writes("connection.respond").first?["result"], .object(["settled_by": .string("continue")]))
        XCTAssertNil(chat.requests.onScreen)

        chat.receive(event(3, "connection.request", operation("op-2", seq: 1)))
        chat.host.next("connection.respond", .init(error: 4004))
        chat.host.next("prompt.submit", .init(result: .object(["status": .string("queued")])))
        let queued = try await chat.turn.submit("Then the docs", mode: .queue)
        XCTAssertEqual(queued, .followUpQueued, "a refused Continue still sends the message")
        XCTAssertEqual(chat.writes("connection.respond").count, 2)

        chat.receive(event(4, "connection.request", operation("op-3", seq: 1)))
        chat.host.next("session.redirect", .init(result: .object(["status": .string("redirected")])))
        _ = try await chat.turn.submit("Stop and summarize", mode: .redirect)
        XCTAssertEqual(chat.writes("connection.respond").count, 2, "Interrupt sends no Continue")
    }

    /// A row's answer and a Steer or Queue's Continue never compete for one operation: while a
    /// row's answer is out, a Queue sends no Continue and its message is held; while a Continue
    /// is out, the card can't be answered.
    func testARowAnswerAndContinueNeverCompete() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.host.withhold("connection.respond")
        let answering = expectation(description: "the row's answer is out")
        chat.host.expect(answering, onNext: "connection.respond")
        let skip = try action(chat)
        let answer = Task { await chat.requests.respondToConnection(skip, .skip(target: "gmail")) }
        await fulfillment(of: [answering], timeout: 5)
        do {
            _ = try await chat.turn.submit("Then the docs", mode: .queue)
            XCTFail("A Queue must not release the operation while a row's answer is out")
        } catch {
            XCTAssertTrue(error is HermesChatTurnCoordinator.NotSent, "\(error)")
        }
        XCTAssertEqual(chat.writes("connection.respond").count, 1, "no competing Continue")
        XCTAssertEqual(chat.writes("prompt.submit"), [])
        chat.turn.engine.disconnect(BotFailure.transport)
        _ = await answer.value

        let other = await openChat()
        other.receive(event(1, "message.start"))
        other.receive(event(2, "connection.request", operation(seq: 1)))
        other.host.withhold("connection.respond")
        let releasing = expectation(description: "Continue is out")
        other.host.expect(releasing, onNext: "connection.respond")
        let queued = Task { try await other.turn.submit("Then the docs", mode: .queue) }
        await fulfillment(of: [releasing], timeout: 5)
        XCTAssertFalse(other.requests.mayAnswer, "the card waits for Continue")
        XCTAssertNil(other.requests.prepareAnswer())
        other.turn.engine.disconnect(BotFailure.transport)
        _ = try? await queued.value
        XCTAssertEqual(other.writes("connection.respond").count, 1)
    }

    /// A Continue whose reply is lost holds the message: it is never sent, and nothing is retried.
    func testALostContinueHoldsTheMessage() async {
        let chat = await openChat(rpcDeadline: .milliseconds(50))
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.host.withhold("connection.respond")
        do {
            _ = try await chat.turn.submit("Then the docs", mode: .queue)
            XCTFail("A lost Continue must not send the message")
        } catch {
            XCTAssertTrue(error is HermesChatTurnCoordinator.NotSent, "\(error)")
        }
        XCTAssertEqual(chat.writes("connection.respond").count, 1)
        XCTAssertEqual(chat.writes("prompt.submit"), [])
    }

    /// A lost Continue warns on the card the reconnect restores, as a lost row answer does,
    /// and is never resent.
    func testALostContinueWarnsOnTheRestoredCard() async {
        let chat = await openChat(pendingConnection: .object(operation(seq: 1)), rpcDeadline: .milliseconds(50))
        chat.host.withhold("connection.respond")
        do {
            _ = try await chat.turn.submit("Then the docs", mode: .queue)
            XCTFail("A lost Continue must not send the message")
        } catch {
            XCTAssertTrue(error is HermesChatTurnCoordinator.NotSent, "\(error)")
        }
        XCTAssertEqual(chat.turn.engine.connectionState, .disconnected)

        // Reattach now rather than on the backoff.
        await chat.model.networkPathDidChange()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1", "the host still holds it")
        XCTAssertEqual(chat.requests.onScreenResolution?.outcome, .uncertain)
        XCTAssertEqual(chat.writes("connection.respond").count, 1)
        XCTAssertEqual(chat.writes("prompt.submit"), [])
    }

    // MARK: Withdrawal

    /// The host withdrawing the card on screen leaves one note; a new request takes its slot,
    /// and a request answered elsewhere (`resolved`) goes silently.
    func testAWithdrawnCardLeavesItsNoteAndAResolvedOneGoesSilently() async {
        let chat = await openChat()
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))
        chat.receive(event(1, "request.cancel", ["id": .string("srq-a1"), "method": .string("approval"), "reason": .string("timeout")]))
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertEqual(chat.requests.withdrawal?.message, "Approval timed out, so it didn't run.")

        chat.receive(request("sudo", id: "srq-s1"))
        XCTAssertNil(chat.requests.withdrawal, "a new request takes the note's slot")
        chat.receive(event(2, "request.cancel", ["id": .string("srq-s1"), "method": .string("sudo"), "reason": .string("resolved")]))
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertNil(chat.requests.withdrawal)
    }

    /// This phone's Stop withdrawing the card is the user's own doing: no note. Another
    /// client's stop leaves one.
    func testThisPhonesStopWithdrawsTheCardSilently() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))
        chat.host.next("session.interrupt", .init(result: .object(["status": .string("interrupted")]), before: [
            event(2, "request.cancel", ["id": .string("srq-a1"), "method": .string("approval"), "reason": .string("interrupted")])
        ]))
        let stopped = await chat.model.cancelActiveStream()
        XCTAssertTrue(stopped)
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertNil(chat.requests.withdrawal)

        chat.receive(event(3, "message.complete", ["status": .string("interrupted")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        chat.receive(event(5, "message.start"))
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which file?")]))
        chat.receive(event(6, "request.cancel", ["id": .string("srq-c1"), "method": .string("clarify"), "reason": .string("interrupted")]))
        XCTAssertEqual(chat.requests.withdrawal?.message, "Question withdrawn because the work stopped.")
    }

    /// Stop & send while a card is open only steers: a redirect while a tool waits on the
    /// request cancels nothing, so the card stays answerable and the session still waits.
    func testStopAndSendLeavesAnOpenCardAnswerable() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which file?")]))
        chat.host.next("session.redirect", .init(result: .object(["status": .string("redirected"), "text": .string("Use main")])))
        let outcome = try await chat.turn.submit("Use main", mode: .redirect)
        XCTAssertEqual(outcome, .redirected)
        XCTAssertEqual(chat.requests.onScreen?.requestID, "srq-c1")
        XCTAssertTrue(chat.requests.mayAnswer)
        XCTAssertTrue(chat.model.isWaitingForUser)
        XCTAssertTrue(chat.model.stopNeedsConfirmation)
    }

    // MARK: Restore

    /// Back from the background, the replay's `open_requests` replaces the cards, one per
    /// envelope id; one answered on Desktop meanwhile is gone without a note, and nothing is
    /// answered on return.
    func testReattachRestoresOpenRequestsDedupedBySrqID() async {
        let chat = await openChat()
        chat.receive(request("sudo", id: "srq-s1"))
        chat.model.suspendStreamForBackground()

        let question = request("clarify", id: "srq-c1", ["question": .string("Which file?")])
        let approval = approvalRequest(id: "srq-a2", requestID: "q-2")
        chat.host.always("session.events.since", .init(result: replay(openRequests: [question, question, approval])))
        chat.host.always("session.resume", .init(result: resume(openRequests: [question, question, approval])))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.requests.open.map(\.id), ["srq-c1", "srq-a2"])
        XCTAssertEqual(chat.requests.onScreen?.requestID, "srq-c1", "a question comes first")
        XCTAssertEqual(chat.requests.approvalCount, 1)
        XCTAssertNil(chat.requests.withdrawal)
        XCTAssertEqual(chat.writes("request.answer") + chat.writes("approval.respond"), [])
    }

    /// A card withdrawn while the phone was away leaves its note on return, from the replay.
    func testACardWithdrawnWhileAwayLeavesItsNoteOnReturn() async {
        let chat = await openChat()
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))
        chat.model.suspendStreamForBackground()

        chat.host.always("session.events.since", .init(result: replay(latest: 1, events: [
            event(1, "request.cancel", ["id": .string("srq-a1"), "method": .string("approval"), "reason": .string("timeout")])
        ])))
        chat.host.always("session.resume", .init(result: resume()))
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertEqual(chat.requests.withdrawal?.message, "Approval timed out, so it didn't run.")
    }

    /// The snapshot restores the bypass a reattach finds.
    func testTheSnapshotRestoresTheBypass() async {
        let chat = await openChat(info: ["yolo": .bool(true)])
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
    }

    // MARK: Fixture

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/HermesAgent")

    /// A Hermes chat attached to an idle session on `runtime`, whose frames the test feeds.
    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient

        /// One recorded line: an event's params, or a host request envelope as is.
        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }

        @MainActor var requests: HermesChatRequests { turn.requests }

        /// The params of every `method` call the chat sent.
        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private func openChat(runtime: String = "runtime", openRequests: [BotJSON] = [], info: [String: BotJSON] = [:],
                          pendingConnection: BotJSON? = nil, rpcDeadline: Duration = .seconds(30)) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: resume(runtime: runtime, openRequests: openRequests, info: info,
                                                           pendingConnection: pendingConnection)))
        host.always("session.events.since", .init(result: replay(runtime: runtime, openRequests: openRequests)))
        let client = BotClient(http: host.connection(Self.connection, rpcDeadline: rpcDeadline))
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

    /// The answer the card on screen would capture on a tap.
    private func action(_ chat: Chat, file: StaticString = #filePath, line: UInt = #line) throws -> HermesAnswerAction {
        try XCTUnwrap(chat.requests.prepareAnswer(), "Nothing on screen to answer", file: file, line: line)
    }

    private func recorded(_ name: String) throws -> [BotJSON] {
        guard let data = try? Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".json")) else {
            throw XCTSkip("The source tree is not present (physical device or remote runner).")
        }
        return try XCTUnwrap(try JSONDecoder().decode(BotJSON.self, from: data)["frames"].list)
    }

    private func approvalRequest(id: String, requestID: String,
                                 choices: [String] = ["once", "session", "always", "deny"]) -> BotJSON {
        request("approval", id: id, ["request_id": .string(requestID), "command": .string("rm -rf build"),
                                     "description": .string("recursive delete"), "choices": .array(choices.map(BotJSON.string))])
    }

    /// The host's `config.set yolo` reply for the session scope.
    private func yoloReply(_ value: String) -> BotJSON {
        .object(["key": .string("yolo"), "value": .string(value), "scope": .string("session")])
    }

    private func question(_ qid: String, _ text: String) -> BotJSON {
        .object(["qid": .string(qid), "question": .string(text), "choices": .array([]), "multi_select": .bool(false)])
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:], runtime: String = "runtime") -> BotJSON {
        .object(["session_id": .string(runtime), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }

    /// A host request envelope on `runtime`.
    private func request(_ method: String, id: String, _ params: [String: BotJSON] = [:], runtime: String = "runtime") -> BotJSON {
        var params = params
        params["session_id"] = .string(runtime)
        return .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)])
    }

    private func replay(runtime: String = "runtime", latest: Int = 0, events: [BotJSON] = [],
                        openRequests: [BotJSON] = []) -> BotJSON {
        var reply = BotFixtureWire.replay(latest: latest, events: events).fields ?? [:]
        reply["open_requests"] = .array(openRequests)
        return .object(reply)
    }

    private func resume(runtime: String = "runtime", running: Bool = true, openRequests: [BotJSON] = [],
                        info: [String: BotJSON] = [:], pendingConnection: BotJSON? = nil) -> BotJSON {
        var info = info
        info["profile_name"] = .string("default")
        var reply: [String: BotJSON] = [
            "session_id": .string(runtime), "session_key": .string("tip"), "running": .bool(running),
            "messages": .array([]), "info": .object(info)
        ]
        if running { reply["turn_started_at"] = .number(1_790_000_000) }
        if !openRequests.isEmpty { reply["open_requests"] = .array(openRequests) }
        if let pendingConnection { reply["pending_connection"] = pendingConnection }
        return .object(reply)
    }

    /// A `manage_connections` frame's payload for this session (`BotConnectionFixture`'s shape).
    private func operation(_ id: String = "op-1", seq: Int, settled: Bool? = nil,
                           targets: [BotJSON] = [BotConnectionFixture.gmail(), BotConnectionFixture.github()]) -> [String: BotJSON] {
        var payload = BotConnectionFixture.operation(id, seq: seq, settled: settled, targets: targets).fields ?? [:]
        payload["owner"] = .object(["type": .string("session"), "session_id": .string("runtime")])
        return payload
    }

    private func connectionOnScreen(_ chat: Chat) -> BotConnectionOperation? {
        if case .connection(let operation)? = chat.requests.onScreen { return operation }
        return nil
    }
}
