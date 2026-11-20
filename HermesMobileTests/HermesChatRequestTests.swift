import XCTest
@testable import HermesMobile

@MainActor final class HermesChatRequestTests: XCTestCase {
    func testApprovalStillAnswersWhileItsSummaryIsLoading() async throws {
        let chat = await openChat()
        defer { chat.model.suspendStreamForBackground() }
        chat.receive(approvalRequest(id: "summary-envelope", requestID: "summary-loading"))
        guard case .approval(let approval)? = chat.requests.onScreen else { return XCTFail("Expected approval") }
        let presentation = try XCTUnwrap(chat.requests.summaryPresentation(for: approval, workingDirectory: nil))
        defer { presentation.summaries.retain([], in: presentation.key.scope) }
        chat.host.withhold("llm.oneshot")
        let sent = expectation(description: "summary model request on the wire")
        chat.host.expect(sent, onNext: "llm.oneshot")
        let summary = Task { await presentation.summaries.show(presentation.key, load: presentation.load) }
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(presentation.summaries.states[presentation.key], .loading)
        XCTAssertTrue(chat.requests.mayAnswer, "summary work never disables approval choices")
        chat.host.always("approval.respond", .init(result: .object(["resolved": .number(1)])))
        let taken = await chat.requests.respond(try action(chat), choice: .once)
        XCTAssertTrue(taken)
        await summary.value
        XCTAssertEqual(chat.writes("approval.respond").last?["choice"], .string("once"))
        XCTAssertEqual(chat.turn.engine.connectionState, .connected, "cancelling the optional read must not disconnect chat")
        XCTAssertNil(presentation.summaries.states[presentation.key], "the accepted answer ended the approval")
    }

    func testARefusedAnswerKeepsTheStillPendingApprovalsSummary() async throws {
        let chat = await openChat()
        defer { chat.model.suspendStreamForBackground() }
        chat.receive(approvalRequest(id: "refused-envelope", requestID: "refused-approval"))
        guard case .approval(let approval)? = chat.requests.onScreen else { return XCTFail("Expected approval") }
        let presentation = try XCTUnwrap(chat.requests.summaryPresentation(for: approval, workingDirectory: nil))
        chat.host.withhold("llm.oneshot")
        let sent = expectation(description: "summary model request on the wire")
        chat.host.expect(sent, onNext: "llm.oneshot")
        let summary = Task { await presentation.summaries.show(presentation.key, load: presentation.load) }
        await fulfillment(of: [sent], timeout: 2)
        chat.host.always("approval.respond", .init(error: 4002))
        let taken = await chat.requests.respond(try action(chat), choice: .once)
        XCTAssertFalse(taken)
        XCTAssertEqual(presentation.summaries.states[presentation.key], .loading, "the approval is still waiting")
        XCTAssertEqual(chat.requests.summaryPresentation(for: approval, workingDirectory: nil)?.key, presentation.key)
        presentation.summaries.retain([], in: presentation.key.scope)
        await summary.value
    }

    func testAnsweringAnotherApprovalKeepsThePendingSummaryAvailable() async throws {
        let chat = await openChat()
        defer { chat.model.suspendStreamForBackground() }
        chat.receive(approvalRequest(id: "answer-envelope", requestID: "answered-approval"))
        chat.receive(approvalRequest(id: "summary-envelope", requestID: "pending-summary"))
        let approval = try XCTUnwrap(chat.requests.open.compactMap { row -> BotApprovalRequest? in
            guard case .approval(let approval)? = row.pending, approval.requestID == "pending-summary" else { return nil }
            return approval
        }.first)
        let presentation = try XCTUnwrap(chat.requests.summaryPresentation(for: approval, workingDirectory: nil))
        defer { presentation.summaries.retain([], in: presentation.key.scope) }
        chat.host.always("llm.oneshot", .init(result: .object(["text": .string("Explains the pending command.")])))
        let queued = expectation(description: "summary waiting to dispatch")
        var dispatch: CheckedContinuation<Void, Never>?
        let summary = Task {
            await presentation.summaries.show(presentation.key) {
                await withCheckedContinuation { dispatch = $0; queued.fulfill() }
                return try await presentation.load()
            }
        }
        await fulfillment(of: [queued], timeout: 3)
        chat.host.withhold("approval.respond")
        let answering = expectation(description: "other approval response pending")
        chat.host.expect(answering, onNext: "approval.respond")
        let answerAction = try action(chat)
        let answer = Task { await chat.requests.respond(answerAction, choice: .once) }
        await fulfillment(of: [answering], timeout: 3)
        XCTAssertEqual(chat.requests.answeringRequestID, "answered-approval")
        XCTAssertFalse(chat.requests.mayAnswer)
        XCTAssertEqual(chat.requests.summaryPresentation(for: approval, workingDirectory: nil)?.key, presentation.key,
                       "another request's answer must not remove this summary")
        XCTAssertEqual(presentation.summaries.states[presentation.key], .loading)
        dispatch?.resume(); await summary.value
        XCTAssertEqual(presentation.summaries.states[presentation.key], .ready("Explains the pending command."),
                       "a different in-flight answer must not reject this summary's dispatch")
        XCTAssertEqual(chat.writes("llm.oneshot").count, 1)
        chat.model.suspendStreamForBackground()
        _ = await answer.value
    }

    func testLeavingAChatCancelsOnlyItsUnfinishedSummary() async throws {
        let chat = await openChat()
        chat.receive(approvalRequest(id: "summary-envelope", requestID: "summary-leave"))
        guard case .approval(let approval)? = chat.requests.onScreen else { return XCTFail("Expected approval") }
        let presentation = try XCTUnwrap(chat.requests.summaryPresentation(for: approval, workingDirectory: nil))
        defer { presentation.summaries.retain([], in: presentation.key.scope) }
        let sent = expectation(description: "summary request started")
        chat.host.withhold("llm.oneshot")
        chat.host.expect(sent, onNext: "llm.oneshot")
        let summary = Task { await presentation.summaries.show(presentation.key, load: presentation.load) }
        await fulfillment(of: [sent], timeout: 2)
        chat.model.suspendStreamForBackground()
        await summary.value
        XCTAssertEqual(presentation.summaries.states[presentation.key], .unavailable,
                       "leaving cancels work but retains a terminal state for that pending approval")
        XCTAssertNil(chat.requests.summaryPresentation(for: approval, workingDirectory: nil), "no direct connection means no summary slot")
    }

    func testARecordedApprovalOffersTheHostsChoicesAndAnswersByItsRequestID() async throws {
        let approval = try XCTUnwrap(try recorded("turn-tool-approval-frames").first { $0["method"].text == "approval" })
        let runtime = try XCTUnwrap(approval["params"]["session_id"].text)
        let requestID = try XCTUnwrap(approval["params"]["request_id"].text)
        let chat = await openChat(runtime: runtime)
        chat.host.always("approval.respond", .init(result: .object(["resolved": .number(1)])))
        chat.receive(approval)
        guard case .approval(let shown)? = chat.requests.onScreen else { return XCTFail("Expected the approval on screen") }
        let content = shown.requestContent(pendingCount: chat.requests.approvalCount)
        XCTAssertEqual(content.choices, [.once, .session, .always, .deny])
        XCTAssertEqual(content.pendingCount, 1)
        XCTAssertEqual(content.command, "python3 -c \"print(1)\"")
        XCTAssertTrue(chat.model.isWaitingForUser)

        let taken = await chat.requests.respond(try action(chat), choice: .session)
        XCTAssertTrue(taken)
        XCTAssertEqual(chat.writes("approval.respond"), [[
            "session_id": .string(runtime), "request_id": .string(requestID),
            "choice": .string("session")
        ]])
        XCTAssertNil(chat.requests.onScreen, "an answered card leaves at once")
        XCTAssertFalse(chat.model.isWaitingForUser)
    }

    func testAnApprovalOffersOnlyTheChoicesTheHostComputed() async throws {
        let chat = await openChat()
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1", choices: ["once", "deny"]))
        guard case .approval(let shown)? = chat.requests.onScreen else { return XCTFail("Expected the approval on screen") }
        XCTAssertEqual(shown.requestContent(pendingCount: 1).choices, [.once, .deny])

        let taken = await chat.requests.respond(try action(chat), choice: .always)
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.writes("approval.respond"), [])
    }

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

    func testAMalformedResolvedKeepsTheCardWarnsAndIsNotResent() async throws {
        for reply: BotJSON in [.object([:]), .object(["resolved": .string("1")]), .object(["resolved": .number(1.5)]),
                               .object(["resolved": .number(-1)]), .object(["resolved": .null])] {
            let chat = await openChat()
            chat.host.always("approval.respond", .init(result: reply))
            chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))
            let taken = await chat.requests.respond(try action(chat), choice: .once)
            XCTAssertFalse(taken, "\(reply)")
            XCTAssertEqual(chat.requests.onScreen?.requestID, "q-1", "card kept for \(reply)")
            XCTAssertEqual(chat.requests.errorMessage,
                           "Answer outcome unknown. Check Hermes Desktop before answering again.", "\(reply)")
            XCTAssertEqual(chat.writes("approval.respond").count, 1, "never resent for \(reply)")
            XCTAssertTrue(chat.requests.mayAnswer, "a deliberate second tap stays possible")
            chat.receive(event(2, "request.cancel", ["id": .string("srq-a1"), "method": .string("approval"),
                                                    "reason": .string("resolved")]))
            XCTAssertNil(chat.requests.onScreen, "reconciled by the host's cancel for \(reply)")
        }
    }

    func testTheUncertainWarningLeavesWithItsRequestAndNeverReachesTheNextCard() async throws {
        let chat = await openChat()
        chat.host.always("approval.respond", .init(result: .object([:])))
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))
        _ = await chat.requests.respond(try action(chat), choice: .once)
        XCTAssertNotNil(chat.requests.errorMessage)
        chat.receive(event(1, "request.cancel", ["id": .string("srq-a1"), "method": .string("approval"),
                                                "reason": .string("resolved")]))
        XCTAssertNil(chat.requests.errorMessage, "the warning left with its card")
        chat.receive(approvalRequest(id: "srq-a2", requestID: "q-2"))
        XCTAssertEqual(chat.requests.onScreen?.requestID, "q-2")
        XCTAssertNil(chat.requests.errorMessage, "a fresh card carries no warning")
    }

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

    func testSkipAllTurnsTheBypassOnAndReleasesTheCardAndTheSwitchTurnsItOff() async throws {
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

        await chat.requests.setApprovalBypass(false)
        XCTAssertEqual(chat.writes("config.set").last?["value"], .string("off"))
        XCTAssertFalse(chat.model.isSessionApprovalBypassEnabled)
    }

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

    func testTurnOffNeverClaimsApprovalsAreBackWhileTheHostStillBypassesThem() async {
        let chat = await openChat(info: ["yolo": .bool(true), "approval_mode": .string("manual")])
        chat.host.next("config.set", .init(result: yoloReply("0"), before: [
            event(1, "session.info", ["yolo": .bool(true), "approval_mode": .string("manual")])
        ]))
        await chat.requests.setApprovalBypass(false)
        XCTAssertEqual(chat.writes("config.set").map { $0["value"] }, [.string("off")])
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled, "the host still bypasses approvals")

        await chat.requests.setApprovalBypass(false)
        XCTAssertEqual(chat.writes("config.set").count, 1, "a session flag already off cannot clear the host's bypass")
    }

    func testAHostWideBypassIsReportedButNotTurnedOff() async {
        let chat = await openChat(info: ["yolo": .bool(true), "approval_mode": .string("off")])
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
        await chat.requests.setApprovalBypass(false)
        XCTAssertEqual(chat.writes("config.set"), [])
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
    }

    func testAnApprovalModeWritesTheProfilesConfigAndOffLocksTheBypass() async {
        let chat = await openChat(info: ["yolo": .bool(false), "approval_mode": .string("manual")])
        chat.host.next("config.set", .init(result: modeReply("off"), before: [
            event(1, "session.info", ["yolo": .bool(true), "approval_mode": .string("off")])
        ]))
        chat.host.next("config.set", .init(result: modeReply("smart")))

        let changed = await chat.requests.setApprovalMode(.off)
        XCTAssertTrue(changed)
        XCTAssertEqual(chat.writes("config.set"), [[
            "session_id": .string("runtime"), "profile": .string("default"),
            "key": .string("approvals.mode"), "value": .string("off")
        ]])
        XCTAssertEqual(chat.model.composerApprovals.value, "Off")
        XCTAssertTrue(chat.model.composerApprovals.isYoloLocked)

        await chat.requests.setApprovalMode(.smart)
        XCTAssertEqual(chat.model.composerApprovals.value, "YOLO")
        XCTAssertTrue(chat.model.isSessionApprovalBypassEnabled)
        XCTAssertFalse(chat.model.composerApprovals.isYoloLocked)

        chat.requests.applyBypass(.object(["yolo": .bool(false), "approval_mode": .string("smart")]))
        XCTAssertEqual(chat.model.composerApprovals.value, "Smart")
    }

    func testTheYoloSwitchSendsTheValueAskedFor() async {
        let chat = await openChat(info: ["yolo": .bool(true), "approval_mode": .string("manual")])
        chat.requests.applyBypass(.object(["yolo": .bool(false), "approval_mode": .string("manual")]))
        await chat.model.setSessionApprovalBypass(false)
        XCTAssertEqual(chat.writes("config.set"), [], "already off, so nothing goes out")

        chat.requests.applyBypass(.object(["yolo": .bool(true), "approval_mode": .string("off")]))
        await chat.model.setSessionApprovalBypass(false)
        XCTAssertEqual(chat.writes("config.set"), [], "the mode holds this bypass")
    }

    func testARefusedApprovalModeKeepsTheModeInEffect() async {
        let chat = await openChat(info: ["yolo": .bool(false), "approval_mode": .string("manual")])
        chat.host.next("config.set", .init(error: 4002))

        let changed = await chat.requests.setApprovalMode(.smart)

        XCTAssertFalse(changed)
        XCTAssertEqual(chat.model.composerApprovals.value, "Manual")
        XCTAssertNotNil(chat.model.composerApprovals.errorMessage)
        XCTAssertFalse(chat.model.composerApprovals.isChanging)
    }

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

    func testARestoredCanonicalApprovalAnswersWithItsOwnPromptAndGeneration() async throws {
        let prompt = try XCTUnwrap(try canonical("canonical-resume-running")["prompts"].list?.first)
        let chat = await openChat(canonical: [prompt])
        chat.host.always("approval.respond", .init(result: .object(["status": .string("resolved"), "prompt_id": prompt["prompt_id"]])))
        guard case .approval? = chat.requests.onScreen else { return XCTFail("Expected the restored approval on screen") }
        let taken = await chat.requests.respond(try action(chat), choice: .once)
        XCTAssertTrue(taken)
        XCTAssertEqual(chat.writes("approval.respond"), [[
            "profile": .string("default"), "session_id": .string("tip"), "execution_generation": prompt["execution_generation"],
            "prompt_id": prompt["prompt_id"], "choice": .string("once")
        ]], "the host refuses any other key")
        XCTAssertNil(chat.requests.onScreen)
    }

    func testALiveCanonicalQuestionAnswersByItsPromptAndGeneration() async throws {
        let lifecycle = try XCTUnwrap(try canonical("canonical-clarify-lifecycle").list)
        var asked = try XCTUnwrap(lifecycle[0].fields)
        asked["session_id"] = .string("tip"); asked["seq"] = .number(1)
        let chat = await openChat(canonical: [])
        chat.host.always("clarify.respond", .init(result: lifecycle[1]))
        chat.receive(.object(asked))
        guard case .question(let question)? = chat.requests.onScreen else { return XCTFail("Expected the question on screen") }
        XCTAssertEqual(question.questions.first?.prompt, "Which check should I run?")
        let answered = await chat.requests.answerQuestion(try action(chat), [BotQuestionAnswer(questionID: nil, text: "Lint")])
        XCTAssertTrue(answered)
        XCTAssertEqual(chat.writes("clarify.respond"), [[
            "profile": .string("default"), "session_id": .string("tip"), "execution_generation": asked["payload"]?["execution_generation"] ?? .null,
            "prompt_id": asked["payload"]?["prompt_id"] ?? .null, "answer": .string("Lint")
        ]], "the host refuses any other key")
        XCTAssertNil(chat.requests.onScreen)
    }

    func testACanonicalSudoValueGoesAsTheResponseFrame() async throws {
        let chat = await openChat(canonical: [])
        chat.receive(request("sudo", id: "srq-s1", runtime: "tip"))
        let answered = await chat.requests.answerCredential(try action(chat), value: "hunter2")
        XCTAssertTrue(answered)
        let response = try XCTUnwrap(chat.host.requests.first { $0["id"].text == "srq-s1" })
        XCTAssertEqual(response["result"], .object(["value": .string("hunter2")]))
        XCTAssertEqual(response["method"], .null)
        XCTAssertEqual(chat.writes("request.answer"), [])
    }

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

    func testABatchSendsOnlyTheQuestionsTheHostStillAsks() async throws {
        let restored = request("clarify", id: "srq-b1", [
            "questions": .array([question("q1", "First?"), question("q2", "Second?")]),
            "answers": .object(["q1": .string("already")])
        ])
        let chat = await openChat(openRequests: [restored])
        chat.host.always("clarify.lock", .init(result: .object(["status": .string("ok"), "remaining": .array([])])))
        let foreign = await chat.requests.answerQuestion(try action(chat), [BotQuestionAnswer(questionID: "q9", text: "nope")])
        XCTAssertFalse(foreign)
        XCTAssertEqual(chat.writes("clarify.lock"), [])

        let taken = await chat.requests.answerQuestion(try action(chat), [BotQuestionAnswer(questionID: "q2", text: "b")])
        XCTAssertTrue(taken)
        XCTAssertEqual(chat.writes("clarify.lock").map { $0["question_id"] }, [.string("q2")])
    }

    func testABatchStopsOnceTheHostSaysNothingRemains() async throws {
        for status in ["expired", "ok"] {
            let chat = await openChat()
            chat.host.always("clarify.lock", .init(result: .object(["status": .string(status), "remaining": .array([])])))
            chat.receive(request("clarify", id: "srq-b1", ["questions": .array([question("q1", "First?"), question("q2", "Second?")])]))
            let taken = await chat.requests.answerQuestion(try action(chat), [
                BotQuestionAnswer(questionID: "q1", text: "a"), BotQuestionAnswer(questionID: "q2", text: "b")
            ])
            XCTAssertEqual(taken, status == "ok", status)
            XCTAssertEqual(chat.writes("clarify.lock").count, 1, status)
            XCTAssertNil(chat.requests.onScreen, status)
            XCTAssertNil(chat.requests.errorMessage, status)
        }
    }

    func testAnExpiredCredentialPromptLeavesQuietly() async throws {
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("expired")])))
        chat.receive(request("secret", id: "srq-k1", ["env_var": .string("TAVILY_API_KEY")]))
        let taken = await chat.requests.answerCredential(try action(chat), value: "late")
        XCTAssertFalse(taken)
        XCTAssertNil(chat.requests.onScreen)
        XCTAssertNil(chat.requests.errorMessage)
        XCTAssertEqual(chat.writes("request.answer").count, 1)
    }

    func testAQuestionOutranksAnApprovalAndACredentialPrompt() async {
        let chat = await openChat()
        chat.receive(request("sudo", id: "srq-s1"))
        chat.receive(approvalRequest(id: "srq-a1", requestID: "q-1"))
        XCTAssertEqual(chat.requests.onScreen?.requestID, "q-1", "an approval outranks a credential prompt")
        chat.receive(request("clarify", id: "srq-c1", ["question": .string("Which mailbox?")]))
        XCTAssertEqual(chat.requests.onScreen?.requestID, "srq-c1")
    }

    func testALostAnswerIsNeverResent() async throws {
        let approval = approvalRequest(id: "srq-a1", requestID: "q-1")
        let chat = await openChat(openRequests: [approval], rpcDeadline: .milliseconds(50))
        chat.host.withhold("approval.respond")
        let taken = await chat.requests.respond(try action(chat), choice: .deny)
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.turn.engine.connectionState, .disconnected)

        await chat.model.networkPathDidChange()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(chat.requests.onScreen?.requestID, "q-1", "the host still holds it")
        XCTAssertTrue(chat.requests.mayAnswer)
        XCTAssertEqual(chat.writes("approval.respond").count, 1)
    }

    func testAnAnswerCapturedBeforeAReattachIsNeverSent() async throws {
        let sudo = request("sudo", id: "srq-s1")
        let chat = await openChat(openRequests: [sudo])
        let captured = try action(chat)
        chat.model.suspendStreamForBackground()
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertEqual(chat.requests.onScreen?.requestID, "srq-s1")
        let taken = await chat.requests.answerCredential(captured, value: "never sent")
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.writes("request.answer"), [])
        XCTAssertTrue(chat.requests.mayAnswer, "the restored prompt takes a fresh tap")
    }

    func testACancelMustNameTheEnvelopesIDAndMethod() async {
        let chat = await openChat()
        chat.receive(request("sudo", id: "srq-s1"))
        for (seq, id, method) in [(1, "other", "sudo"), (2, "srq-s1", "secret"), (3, "srq-s1", "sudo")] {
            chat.receive(event(seq, "request.cancel", ["id": .string(id), "method": .string(method), "reason": .string("timeout")]))
            XCTAssertEqual(chat.requests.onScreen == nil, seq == 3, "\(id) \(method)")
        }
    }

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

    func testAMoveTheCardStopsOfferingBeforeTheWriteIsNeverSent() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        let moved = event(3, "connection.update", operation(seq: 2, targets: [
            BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github()
        ]))
        withObservationTracking { _ = chat.requests.answeringRequestID } onChange: {
            MainActor.assumeIsolated { chat.receive(moved) }
        }

        let taken = await chat.requests.respondToConnection(try action(chat), .skip(target: "gmail"))
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.writes("connection.respond"), [])
        XCTAssertEqual(connectionOnScreen(chat)?.targets.first?.state, .connected)
        XCTAssertTrue(chat.requests.mayAnswer, "the card still answers its open rows")
    }

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

    func testALostConnectionAnswerWarnsAndIsNeverResent() async throws {
        let chat = await openChat(pendingConnection: .object(operation(seq: 1)), rpcDeadline: .milliseconds(50))
        chat.host.withhold("connection.respond")
        let taken = await chat.requests.respondToConnection(try action(chat), .skip(target: "gmail"))
        XCTAssertFalse(taken)
        XCTAssertEqual(chat.turn.engine.connectionState, .disconnected)
        XCTAssertNil(chat.requests.onScreen, "the card leaves with the socket")
        XCTAssertFalse(chat.model.isWaitingForUser)

        await chat.model.networkPathDidChange()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1", "the host still holds it")
        XCTAssertEqual(chat.requests.onScreenResolution?.outcome, .uncertain)
        XCTAssertTrue(chat.requests.mayAnswer, "a deliberate second answer is the user's call")
        XCTAssertEqual(chat.writes("connection.respond").count, 1)
    }

    func testADisconnectClearsAnUnreadableOperationsWait() async {
        let chat = await openChat(pendingConnection: .object(["op_id": .string("op-2")]))
        XCTAssertTrue(chat.model.isWaitingForUser)

        chat.turn.engine.disconnect(BotFailure.rejected(403))
        XCTAssertFalse(chat.model.isWaitingForUser)
    }

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

    func testAnotherOperationSettlingLeavesTheLiveCardOpen() async {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.receive(event(3, "connection.update", operation("op-2", seq: 4, settled: true)))
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1")
        XCTAssertEqual(connectionOnScreen(chat)?.seq, 1)
        XCTAssertTrue(chat.model.isWaitingForUser)
    }

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

    func testAContinueForAReplacedOperationIsNeverSent() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "connection.request", operation(seq: 1)))
        chat.host.next("connection.respond", .init(error: 4004))
        chat.host.next("prompt.submit", .init(result: .object(["status": .string("queued")])))
        let replaced = event(3, "connection.request", operation("op-2", seq: 1))
        withObservationTracking { _ = chat.requests.answeringRequestID } onChange: {
            MainActor.assumeIsolated { chat.receive(replaced) }
        }

        do {
            _ = try await chat.turn.submit("Then the docs", mode: .queue)
            XCTFail("A Queue must not go out behind the operation that replaced the card")
        } catch {
            XCTAssertTrue(error is HermesChatTurnCoordinator.NotSent, "\(error)")
        }
        XCTAssertEqual(chat.writes("connection.respond"), [])
        XCTAssertEqual(chat.writes("prompt.submit"), [])
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-2")
    }

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

        await chat.model.networkPathDidChange()
        XCTAssertEqual(chat.turn.engine.connectionState, .connected)
        XCTAssertEqual(connectionOnScreen(chat)?.opID, "op-1", "the host still holds it")
        XCTAssertEqual(chat.requests.onScreenResolution?.outcome, .uncertain)
        XCTAssertEqual(chat.writes("connection.respond").count, 1)
        XCTAssertEqual(chat.writes("prompt.submit"), [])
    }

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

    func testAThemeApplyTurnsTheAppDarkAndAnswersWhatItApplied() async throws {
        keepAppearance()
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        let answered = expectation(description: "theme.apply answered")
        chat.host.expect(answered, onNext: "request.answer")
        chat.receive(request("theme.apply", id: "srq-t1", ["mode": .string("dark")]))
        XCTAssertTrue(chat.requests.open.isEmpty)
        XCTAssertFalse(chat.model.isWaitingForUser)
        await fulfillment(of: [answered], timeout: 2)
        let sent = try XCTUnwrap(chat.writes("request.answer").first)
        XCTAssertEqual(chat.writes("request.answer").count, 1)
        XCTAssertEqual(sent["id"], .string("srq-t1"))
        let value = try themeAnswer(sent)
        XCTAssertEqual(value["success"], .bool(true))
        XCTAssertEqual(value["applied"]["mode"], .string("dark"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.storageKey), AppTheme.dark.rawValue)
    }

    func testAThemeApplyStoresTheAccentSwatch() async throws {
        keepAppearance()
        UserDefaults.standard.removeObject(forKey: AppAppearanceSettings.accentHexKey)
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        let answered = expectation(description: "theme.apply answered")
        chat.host.expect(answered, onNext: "request.answer")
        chat.receive(request("theme.apply", id: "srq-t3", ["accent": .string("green")]))
        await fulfillment(of: [answered], timeout: 2)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppAppearanceSettings.accentHexKey), "#4CC96B")
    }

    func testAThemeApplyWithALayoutIsRefusedAndChangesNothing() async throws {
        keepAppearance()
        UserDefaults.standard.set(AppTheme.light.rawValue, forKey: AppTheme.storageKey)
        UserDefaults.standard.set("#FF5C5C", forKey: AppAppearanceSettings.accentHexKey)
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        let answered = expectation(description: "theme.apply answered")
        chat.host.expect(answered, onNext: "request.answer")
        chat.receive(request("theme.apply", id: "srq-t2", ["mode": .string("dark"), "accent": .string("green"),
                                                           "layout": .string("focus")]))
        await fulfillment(of: [answered], timeout: 2)
        let value = try themeAnswer(try XCTUnwrap(chat.writes("request.answer").first))
        XCTAssertEqual(value["success"], .bool(false))
        XCTAssertNotNil(value["error"].text)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.storageKey), AppTheme.light.rawValue)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppAppearanceSettings.accentHexKey), "#FF5C5C")
    }

    func testAThemePickIsAnsweredAtOnceWithSaid() async throws {
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        let answered = expectation(description: "theme.pick answered")
        chat.host.expect(answered, onNext: "request.answer")
        chat.receive(request("theme.pick", id: "srq-p1", ["picker": .string("accent")]))
        XCTAssertFalse(chat.model.isWaitingForUser)
        await fulfillment(of: [answered], timeout: 2)
        let sent = try XCTUnwrap(chat.writes("request.answer").first)
        XCTAssertEqual(sent["id"], .string("srq-p1"))
        XCTAssertEqual(sent["result"]?.fields?.keys.sorted(), ["said"])
        XCTAssertFalse(sent["result"]?["said"].text?.isEmpty ?? true)
    }

    func testACanonicalThemePickGoesAsTheResponseFrame() async throws {
        let chat = await openChat(canonical: [])
        let answered = expectation(description: "theme.pick response frame")
        chat.host.expect(answered, onNext: "")
        chat.receive(request("theme.pick", id: "srq-p6", ["picker": .string("accent")], runtime: "tip"))
        await fulfillment(of: [answered], timeout: 2)
        let response = try XCTUnwrap(chat.host.requests.first { $0["id"].text == "srq-p6" })
        XCTAssertEqual(response["result"].fields?.keys.sorted(), ["said"])
        XCTAssertEqual(chat.writes("request.answer"), [])
    }

    func testTheSameThemeRequestIsAnsweredOnce() async throws {
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        let first = expectation(description: "first answer")
        chat.host.expect(first, onNext: "request.answer")
        let pick = request("theme.pick", id: "srq-p2", ["picker": .string("layout")])
        chat.receive(pick)
        chat.receive(pick)
        await fulfillment(of: [first], timeout: 2)
        chat.receive(pick)
        let next = expectation(description: "the next request's answer")
        chat.host.expect(next, onNext: "request.answer")
        chat.receive(request("theme.pick", id: "srq-p3", ["picker": .string("accent")]))
        await fulfillment(of: [next], timeout: 2)
        XCTAssertEqual(chat.writes("request.answer").map { $0["id"] }, [.string("srq-p2"), .string("srq-p3")])
    }

    func testARestoredThemeRequestIsAnsweredOnceAndNeverWaits() async throws {
        let chat = await openChat()
        chat.host.always("request.answer", .init(result: .object(["status": .string("ok")])))
        chat.model.suspendStreamForBackground()
        let pick = request("theme.pick", id: "srq-p4", ["picker": .string("accent")])
        chat.host.always("session.events.since", .init(result: replay(openRequests: [pick])))
        chat.host.always("session.resume", .init(result: resume(openRequests: [pick])))
        let answered = expectation(description: "restored theme.pick answered")
        chat.host.expect(answered, onNext: "request.answer")
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertTrue(chat.requests.open.isEmpty)
        XCTAssertFalse(chat.model.isWaitingForUser)
        await fulfillment(of: [answered], timeout: 2)

        chat.model.suspendStreamForBackground()
        await chat.model.reconnectStreamIfNeeded()
        let next = expectation(description: "the next request's answer")
        chat.host.expect(next, onNext: "request.answer")
        chat.receive(request("theme.pick", id: "srq-p5", ["picker": .string("accent")]))
        await fulfillment(of: [next], timeout: 2)
        XCTAssertEqual(chat.writes("request.answer").map { $0["id"] }, [.string("srq-p4"), .string("srq-p5")])
    }

    private func keepAppearance() {
        let defaults = UserDefaults.standard
        let keys = [AppTheme.storageKey, AppAppearanceSettings.accentHexKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        addTeardownBlock { @MainActor in
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            AppAppearanceSettings.applyStoredToConnectedScenes()
        }
    }

    private func themeAnswer(_ sent: [String: BotJSON]) throws -> BotJSON {
        let text = try XCTUnwrap(sent["result"]?["value"].text)
        return try JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))
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

        @MainActor func receive(_ frame: BotJSON) {
            client.onEvent?(frame["method"].text == "event" ? frame["params"] : frame)
        }

        @MainActor var requests: HermesChatRequests { turn.requests }

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private func openChat(runtime: String = "runtime", openRequests: [BotJSON] = [], info: [String: BotJSON] = [:],
                          pendingConnection: BotJSON? = nil, rpcDeadline: Duration = .seconds(30),
                          canonical prompts: [BotJSON]? = nil) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        let runtime = prompts == nil ? runtime : "tip"
        var snapshot = resume(runtime: runtime, openRequests: openRequests, info: info, pendingConnection: pendingConnection)
        if let prompts, var fields = snapshot.fields {
            fields["session_key"] = nil
            fields["stored_session_id"] = .string("tip"); fields["replay_epoch"] = .string("epoch")
            fields["execution_generation"] = .number(1); fields["prompts"] = .array(prompts)
            snapshot = .object(fields)
        }
        host.always("session.resume", .init(result: snapshot))
        host.always("session.events.since", .init(result: replay(runtime: runtime, openRequests: openRequests)))
        let client = BotClient(http: host.connection(Self.connection, rpcDeadline: rpcDeadline, canonical: prompts != nil))
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

    private func action(_ chat: Chat, file: StaticString = #filePath, line: UInt = #line) throws -> HermesAnswerAction {
        try XCTUnwrap(chat.requests.prepareAnswer(), "Nothing on screen to answer", file: file, line: line)
    }

    private func canonical(_ name: String) throws -> BotJSON {
        guard let data = try? Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".json")) else {
            throw XCTSkip("The source tree is not present (physical device or remote runner).")
        }
        return try JSONDecoder().decode(BotJSON.self, from: data)["reply"]
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

    private func modeReply(_ value: String) -> BotJSON {
        .object(["key": .string("approvals.mode"), "value": .string(value)])
    }

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
