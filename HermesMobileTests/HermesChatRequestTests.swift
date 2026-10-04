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

    /// Vault prompts (#943), Desktop's own tasks and unknown methods get no card and no answer
    /// here, though the session still waits on them.
    func testRequestsThisChatMustNotAnswerGetNoCardButStillWait() async {
        let chat = await openChat()
        chat.receive(request("vault.unlock_prompt", id: "srq-v1", ["display_name": .string("1Password")]))
        chat.receive(request("terminal.read", id: "srq-t1"))
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

    private func openChat(runtime: String = "runtime", openRequests: [BotJSON] = [],
                          info: [String: BotJSON] = [:]) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: resume(runtime: runtime, openRequests: openRequests, info: info)))
        host.always("session.events.since", .init(result: replay(runtime: runtime, openRequests: openRequests)))
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
                        info: [String: BotJSON] = [:]) -> BotJSON {
        var info = info
        info["profile_name"] = .string("default")
        var reply: [String: BotJSON] = [
            "session_id": .string(runtime), "session_key": .string("tip"), "running": .bool(running),
            "messages": .array([]), "info": .object(info)
        ]
        if running { reply["turn_started_at"] = .number(1_790_000_000) }
        if !openRequests.isEmpty { reply["open_requests"] = .array(openRequests) }
        return .object(reply)
    }
}
