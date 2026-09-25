import XCTest
@testable import HermesMobile

/// Parsing the host's blocking-request payloads. Everything here is pure, so it
/// pins the wire contract without a socket.
@MainActor final class BotPendingRequestParsingTests: XCTestCase {
    func testApprovalKeepsTheHostsOwnChoiceSet() {
        let request = BotApprovalRequest(BotFixtureWire.approval())
        XCTAssertEqual(request?.requestID, "req-1")
        XCTAssertEqual(request?.command, "rm -rf build")
        XCTAssertEqual(request?.consequence, "recursive delete")
        XCTAssertEqual(request?.choices, [.once, .session, .always, .deny])
    }

    func testApprovalDropsUnknownChoicesAndAlwaysOffersDeny() {
        let request = BotApprovalRequest(.object([
            "request_id": .string("req-2"),
            "choices": .array([.string("once"), .string("teleport")])
        ]))
        XCTAssertEqual(request?.choices, [.once, .deny])
    }

    /// A host old enough to omit `choices` still gets the gateway's own rules.
    func testApprovalRebuildsOmittedChoicesFromTheHostsFlags() {
        XCTAssertEqual(
            BotApprovalRequest(.object(["request_id": .string("a")]))?.choices,
            [.once, .session, .always, .deny]
        )
        XCTAssertEqual(
            BotApprovalRequest(.object(["request_id": .string("a"), "allow_permanent": .bool(false)]))?.choices,
            [.once, .session, .deny]
        )
        XCTAssertEqual(
            BotApprovalRequest(.object(["request_id": .string("a"), "smart_denied": .bool(true)]))?.choices,
            [.once, .deny]
        )
    }

    /// A host that renames every choice must not have a permission invented for
    /// it. Deny is the only thing safe to offer when none of the list parses.
    func testAnApprovalWhoseChoicesAreAllUnknownOffersOnlyDeny() {
        let request = BotApprovalRequest(.object([
            "request_id": .string("req-9"), "command": .string("rm -rf /"),
            "choices": .array([.string("allow_forever"), .string("nope")]),
            "allow_permanent": .bool(true)
        ]))
        XCTAssertEqual(request?.choices, [.deny])
        // An explicitly empty list is the host offering nothing, not an old host.
        XCTAssertEqual(
            BotApprovalRequest(.object(["request_id": .string("req-10"), "choices": .array([])]))?.choices,
            [.deny]
        )
    }

    func testApprovalWithoutARequestIDIsNotShown() {
        XCTAssertNil(BotApprovalRequest(.object(["command": .string("rm -rf /")])))
        XCTAssertNil(BotApprovalRequest(.object(["request_id": .string("")])))
        XCTAssertNil(BotApprovalRequest(.null))
    }

    func testSingleQuestionCarriesNoQuestionIDAndStripsTheRecommendationLabel() {
        let request = BotQuestionRequest(BotFixtureWire.clarify())
        XCTAssertEqual(request?.requestID, "clr-1")
        XCTAssertEqual(request?.isBatch, false)
        XCTAssertNil(request?.questions.first?.wireID)
        XCTAssertEqual(request?.questions.first?.prompt, "Which mailbox first?")
        XCTAssertEqual(request?.questions.first?.choices.map(\.label), ["Primary", "Follow-ups"])
        // The answer echoes the host's own label back; only presentation is stripped.
        XCTAssertEqual(request?.questions.first?.choices.map(\.wireLabel), ["Primary (Recommended)", "Follow-ups"])
        XCTAssertEqual(request?.questions.first?.choices.map(\.isRecommended), [true, false])
    }

    func testOpenEndedQuestionHasNoChoices() {
        let request = BotQuestionRequest(.object([
            "request_id": .string("clr-2"), "question": .string("What should I name it?"), "choices": .null
        ]))
        XCTAssertEqual(request?.questions.first?.choices, [])
        XCTAssertEqual(request?.questions.first?.allowsMultipleChoices, false)
    }

    func testBatchQuestionsKeepWireIDsOrderAndLockedAnswers() {
        let request = BotQuestionRequest(.object([
            "request_id": .string("clr-3"),
            "questions": .array([
                .object(["qid": .string("q0"), "question": .string("Which mailbox?"),
                         "choices": .array([.string("Primary")]), "multi_select": .bool(false)]),
                .object(["qid": .string("q1"), "question": .string("Newsletters?"),
                         "choices": .array([.string("Archive"), .string("Unsubscribe")]), "multi_select": .bool(true)])
            ]),
            "answers": .object(["q0": .string("Primary")])
        ]))
        XCTAssertEqual(request?.isBatch, true)
        XCTAssertEqual(request?.questions.map(\.wireID), ["q0", "q1"])
        XCTAssertEqual(request?.questions.map(\.isAnswered), [true, false])
        XCTAssertEqual(request?.unansweredCount, 1)
        XCTAssertEqual(request?.questions.last?.allowsMultipleChoices, true)
    }

    func testQuestionWithNoReadableContentIsNotShown() {
        XCTAssertNil(BotQuestionRequest(.object(["request_id": .string("clr-4")])))
        XCTAssertNil(BotQuestionRequest(.object(["request_id": .string("clr-4"), "question": .string("   ")])))
        XCTAssertNil(BotQuestionRequest(.object(["question": .string("orphan")])))
        XCTAssertNil(BotQuestionRequest(.null))
    }

    func testMultiSelectAnswerIsAJSONArrayString() {
        let answer = BotQuestionAnswer(questionID: "q1", selections: ["Archive", "Unsubscribe"])
        XCTAssertEqual(answer.text, #"["Archive","Unsubscribe"]"#)
    }

    private func frame(_ method: String, id: String = "srq-1", params: [String: BotJSON] = [:]) -> BotJSON {
        .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method),
                 "params": .object(params.merging(["session_id": .string("runtime")]) { _, new in new })])
    }

    func testCredentialKindsMapFromTheirServerRequests() {
        for kind in BotCredentialRequest.Kind.allCases {
            let request = BotServerRequest(frame(kind.rawValue, params: [
                "env_var": .string("OPENAI_API_KEY"), "prompt": .string("Paste the key")
            ]))
            XCTAssertEqual(request?.pending, .credential(BotCredentialRequest(
                kind: kind, requestID: "srq-1", envVar: "OPENAI_API_KEY", prompt: "Paste the key"
            )))
        }
    }

    /// `request.answer` is addressed by the envelope id, and a request belongs to
    /// one session, so a frame missing either is nobody's request.
    func testARequestWithoutAnIDOrSessionIsDropped() {
        let params = BotJSON.object(["session_id": .string("runtime")])
        XCTAssertNil(BotServerRequest(.object(["method": .string("sudo"), "params": params])))
        XCTAssertNil(BotServerRequest(.object(["id": .string(""), "method": .string("sudo"), "params": params])))
        XCTAssertNil(BotServerRequest(.object(["id": .string("srq-1"), "method": .string("sudo"), "params": .object([:])])))
    }

    /// A sudo request carries only the redacted command; a secret's fields are read tolerantly.
    func testACredentialRequestReadsWithoutOptionalFields() {
        guard case .credential(let request)? = BotServerRequest(frame("sudo", params: ["command": .string("sudo ls")]))?.pending
        else { return XCTFail("Expected a credential request") }
        XCTAssertNil(request.envVar)
        XCTAssertNil(request.prompt)
        XCTAssertFalse(request.detail.isEmpty)
        XCTAssertFalse(request.handling.isEmpty)
    }

    func testDesktopTaskKindsMapFromTheirServerRequests() {
        let expected: [String: BotDesktopTaskRequest.Kind] = [
            "terminal.read": .terminalRead, "window.read": .windowRead, "preview.read": .previewRead,
            "preview.act": .previewAct, "tour": .tour, "vault.unlock_prompt": .vaultUnlock,
            "vault.save_login": .vaultSaveLogin, "vault.code": .vaultCode
        ]
        XCTAssertEqual(Set(expected.values), Set(BotDesktopTaskRequest.Kind.allCases))
        for (method, kind) in expected {
            XCTAssertEqual(BotServerRequest(frame(method))?.pending,
                           .desktopTask(BotDesktopTaskRequest(kind: kind, requestID: "srq-1")))
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.detail.isEmpty)
        }
        // Only the password-manager prompts wait for someone at the Mac, and
        // they are the only ones there is anything to skip.
        XCTAssertEqual(Set(BotDesktopTaskRequest.Kind.allCases.filter(\.needsSomeoneAtTheMac)),
                       [.vaultUnlock, .vaultSaveLogin, .vaultCode])
    }

    /// `mcp.setup` no longer exists at the pin; it and any future method still
    /// block the bot, but have no card the phone could answer.
    func testUnknownMethodsBlockWithoutACard() {
        for method in ["mcp.setup", "future.prompt"] {
            let request = BotServerRequest(frame(method))
            XCTAssertEqual(request?.method, method)
            XCTAssertNil(request?.pending)
        }
    }
}

/// Answering from the phone: dispatch, revalidation, and every way an answer can
/// fail to take effect.
@MainActor final class BotAnsweringTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private func connection(_ address: String = "http://hermes.local:9120") -> BotConnection {
        BotConnection(id: UUID(), name: "Mac", address: URL(string: address)!, username: "user", password: "fixture")
    }
    private var profile: BotProfile { BotProfile(.object(["name": .string("inbox-triage")]))! }

    private func make(_ wire: BotFixtureWire, connection override: BotConnection? = nil) -> BotConversation {
        BotConversation(server: server, connection: override ?? connection(), profile: profile, wire: wire,
                        drafts: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)))
    }

    /// A connected conversation whose bot is mid-turn, so a request can block it.
    private func blocked(on wire: BotFixtureWire) async -> BotConversation {
        wire.running = true
        let model = make(wire)
        await model.recover()
        return model
    }

    /// The action `prepareAnswer()` must have produced. Fails rather than aborting,
    /// so these non-throwing async tests stay readable.
    private func action(_ model: BotConversation,
                        file: StaticString = #filePath, line: UInt = #line) -> BotConversation.AnswerAction {
        guard let action = model.prepareAnswer() else {
            XCTFail("Expected an answerable request", file: file, line: line)
            return BotConversation.AnswerAction(generation: -1, runtime: "", requestID: "")
        }
        return action
    }

    /// Waits for the conversation's coalesced snapshot read to land. Every
    /// `applySnapshot` republishes the turn state, so it is the arrival signal.
    private func awaitSnapshot(_ model: BotConversation) async {
        let applied = expectation(description: "Snapshot applied")
        withObservationTracking { _ = String(describing: model.turn) } onChange: { applied.fulfill() }
        await fulfillment(of: [applied], timeout: 5)
    }

    // MARK: approvals

    func testApprovalFromTheSnapshotIsAnswerableAndDispatchesTheHostsChoice() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        XCTAssertEqual(model.turn, .needsAttention)
        XCTAssertFalse(model.maySend)
        XCTAssertTrue(model.mayAnswer)
        guard case .approval(let request)? = model.pendingRequest else { return XCTFail("Expected an approval") }
        XCTAssertEqual(request.command, "rm -rf build")

        await model.respond(action(model), choice: .session)
        let sent = wire.calls.last { $0.0 == "approval.respond" }
        XCTAssertEqual(sent?.1["session_id"], .string("runtime"))
        XCTAssertEqual(sent?.1["request_id"], .string("req-1"))
        XCTAssertEqual(sent?.1["choice"], .string("session"))
        XCTAssertEqual(model.requestResolution, BotRequestResolution(requestID: "req-1", outcome: .answered))
        XCTAssertFalse(model.mayAnswer)
        model.suspend()
    }

    /// The host unblocked nothing: Desktop answered first, or it timed out. That is
    /// an action failure, not a delivery failure, and the card must go inert.
    func testResolvedZeroReportsAlreadyAnsweredAndDisablesTheCard() async {
        let wire = BotFixtureWire(); wire.attention = true; wire.approvalResolved = 0
        let model = await blocked(on: wire)
        await model.respond(action(model), choice: .once)
        XCTAssertEqual(model.requestResolution?.outcome, .alreadyResolved)
        XCTAssertFalse(model.mayAnswer)
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertNil(model.errorMessage)
        model.suspend()
    }

    func testAChoiceTheHostNeverOfferedIsNeverSent() async {
        let wire = BotFixtureWire()
        wire.pendingApproval = BotFixtureWire.approval(choices: ["once", "deny"])
        let model = await blocked(on: wire)
        await model.respond(action(model), choice: .always)
        XCTAssertTrue(wire.calls.filter { $0.0 == "approval.respond" }.isEmpty)
        XCTAssertNil(model.requestResolution)
        model.suspend()
    }

    func testAnActionForADifferentRequestIsNeverDispatched() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        let current = action(model)
        let foreign = BotConversation.AnswerAction(
            generation: current.generation, runtime: current.runtime, requestID: "req-elsewhere")
        await model.respond(foreign, choice: .once)
        XCTAssertTrue(wire.calls.filter { $0.0 == "approval.respond" }.isEmpty)
        XCTAssertNil(model.requestResolution)
        model.suspend()
    }

    /// The connection was replaced between the tap and the socket write. The
    /// dispatch guard fails closed, and nothing is left in doubt.
    func testTheDispatchGuardRejectsAnActionThatWentStaleBeforeTheWrite() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        let captured = action(model)
        wire.beforeDispatch = { [weak model] method in
            if method == "approval.respond" { model?.suspend() }
        }
        await model.respond(captured, choice: .once)
        XCTAssertTrue(wire.calls.filter { $0.0 == "approval.respond" }.isEmpty)
        XCTAssertNil(model.requestResolution)
        model.suspend()
    }

    /// A lost socket mid-answer cannot tell sent from not sent. The phone says so
    /// and never resends by itself; reconnecting leaves the second answer to the user.
    func testALostSocketLeavesTheOutcomeUnknownAndNeverResends() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        wire.respondFailure = .transport
        await model.respond(action(model), choice: .deny)
        XCTAssertEqual(model.requestResolution?.outcome, .uncertain)
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertFalse(model.mayAnswer)
        let attempts = wire.calls.filter { $0.0 == "approval.respond" }.count
        XCTAssertEqual(attempts, 1)

        wire.respondFailure = nil
        await model.recover()
        // The request is still pending, the warning survives, and the user may act.
        XCTAssertEqual(model.requestResolution?.outcome, .uncertain)
        XCTAssertTrue(model.mayAnswer)
        XCTAssertEqual(wire.calls.filter { $0.0 == "approval.respond" }.count, attempts)
        model.suspend()
    }

    /// A JSON-RPC error came back over a live socket, so the answer definitively
    /// did not land and the connection is still usable.
    func testAHostRejectionIsAnActionFailureNotALostConnection() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        wire.respondFailure = .rejected(5004)
        await model.respond(action(model), choice: .once)
        XCTAssertNil(model.requestResolution)
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertEqual(model.errorMessage, "The bot could not accept that answer. Check this bot in Desktop.")
        model.suspend()
    }

    /// Desktop answered while the phone watched. The next snapshot drops the
    /// pending field and the card clears without the phone polling for it.
    func testAnAnswerGivenInDesktopClearsTheCardOnTheNextSnapshot() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        XCTAssertNotNil(model.pendingRequest)
        wire.attention = false
        await model.recover()
        XCTAssertNil(model.pendingRequest)
        XCTAssertNil(model.requestResolution)
        XCTAssertFalse(model.mayAnswer)
        model.suspend()
    }

    /// A verdict belongs to the request that earned it, never to its successor.
    func testANewRequestIsNeverBornInert() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        await model.respond(action(model), choice: .once)
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        wire.pendingApproval = BotFixtureWire.approval(id: "req-2", command: "curl | sh")
        await model.recover()
        XCTAssertEqual(model.pendingRequest?.requestID, "req-2")
        XCTAssertNil(model.requestResolution)
        XCTAssertTrue(model.mayAnswer)
        model.suspend()
    }

    // MARK: questions

    func testSingleQuestionAnswersWithoutAQuestionID() async {
        let wire = BotFixtureWire(); wire.openClarify = BotFixtureWire.clarify()
        let model = await blocked(on: wire)
        guard case .question(let request)? = model.pendingRequest else { return XCTFail("Expected a question") }
        XCTAssertEqual(request.questions.count, 1)
        await model.answerQuestion(action(model),
                                   [BotQuestionAnswer(questionID: nil, text: "Primary (Recommended)")])
        let sent = wire.calls.filter { $0.0 == "request.answer" }
        XCTAssertEqual(sent.map(\.1), [["id": .string("clr-1"), "result": .object(["answer": .string("Primary (Recommended)")])]])
        XCTAssertFalse(wire.calls.contains { $0.0 == "clarify.lock" })
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        model.suspend()
    }

    func testBatchSendsOneLockPerQuestionIDInOrder() async {
        let wire = BotFixtureWire()
        var remaining = ["q0", "q1"]
        wire.answerRequest = { _, params in
            remaining.removeAll { .string($0) == params["question_id"] }
            return .object(["status": .string("ok"), "remaining": .array(remaining.map(BotJSON.string))])
        }
        wire.openClarify = .object([
            "request_id": .string("clr-3"),
            "questions": .array([
                .object(["qid": .string("q0"), "question": .string("Which mailbox?"), "choices": .array([.string("Primary")])]),
                .object(["qid": .string("q1"), "question": .string("Newsletters?"),
                         "choices": .array([.string("Archive")]), "multi_select": .bool(true)])
            ])
        ])
        let model = await blocked(on: wire)
        await model.answerQuestion(action(model), [
            BotQuestionAnswer(questionID: "q0", text: "Primary"),
            BotQuestionAnswer(questionID: "q1", selections: ["Archive"])
        ])
        let sent = wire.calls.filter { $0.0 == "clarify.lock" }
        XCTAssertEqual(sent.map { $0.1["question_id"] }, [.string("q0"), .string("q1")])
        XCTAssertEqual(sent.first?.1["request_id"], .string("clr-3"))
        XCTAssertEqual(sent.last?.1["answer"], .string(#"["Archive"]"#))
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        model.suspend()
    }

    func testAnswersForQuestionsTheHostNeverAskedAreNeverSent() async {
        let wire = BotFixtureWire()
        wire.openClarify = .object([
            "request_id": .string("clr-3"),
            "questions": .array([.object(["qid": .string("q0"), "question": .string("Which mailbox?")])])
        ])
        let model = await blocked(on: wire)
        await model.answerQuestion(action(model), [BotQuestionAnswer(questionID: "q9", text: "nope")])
        XCTAssertFalse(wire.calls.contains { ["clarify.lock", "request.answer"].contains($0.0) })
        model.suspend()
    }

    /// The host dropped the prompt before the answer arrived. It kept nothing, so
    /// the remaining questions have nothing left to lock either.
    /// The host locks every answer it is handed, and an empty one is a skip, so
    /// a partial batch would silently skip whatever the user never touched.
    func testAPartialBatchAnswerIsNeverSent() async {
        let wire = BotFixtureWire()
        wire.openClarify = .object([
            "request_id": .string("clr-5"),
            "questions": .array([
                .object(["qid": .string("q0"), "question": .string("First?")]),
                .object(["qid": .string("q1"), "question": .string("Second?")])
            ])
        ])
        let model = await blocked(on: wire)
        await model.answerQuestion(action(model), [BotQuestionAnswer(questionID: "q0", text: "a")])
        XCTAssertFalse(wire.calls.contains { ["clarify.lock", "request.answer"].contains($0.0) })
        XCTAssertNil(model.requestResolution)
        // Declining the whole request is still one deliberate unkeyed answer.
        await model.skipQuestion(action(model))
        XCTAssertEqual(wire.calls.filter { $0.0 == "request.answer" }.count, 1)
        XCTAssertFalse(wire.calls.contains { $0.0 == "clarify.lock" })
        model.suspend()
    }

    /// A question the host already locked is not outstanding, so the rest of the
    /// batch completes without re-answering it.
    func testABatchIgnoresQuestionsTheHostHasAlreadyLocked() async {
        let wire = BotFixtureWire()
        wire.openClarify = .object([
            "request_id": .string("clr-6"),
            "questions": .array([
                .object(["qid": .string("q0"), "question": .string("First?")]),
                .object(["qid": .string("q1"), "question": .string("Second?")])
            ]),
            "answers": .object(["q0": .string("already")])
        ])
        let model = await blocked(on: wire)
        await model.answerQuestion(action(model), [BotQuestionAnswer(questionID: "q1", text: "b")])
        XCTAssertEqual(wire.calls.filter { $0.0 == "clarify.lock" }.map { $0.1["question_id"] },
                       [.string("q1")])
        model.suspend()
    }

    func testAnExpiredQuestionStopsTheBatchAndReportsItAsAlreadyResolved() async {
        let wire = BotFixtureWire(); wire.answerStatus = "expired"
        wire.openClarify = .object([
            "request_id": .string("clr-3"),
            "questions": .array([
                .object(["qid": .string("q0"), "question": .string("First?")]),
                .object(["qid": .string("q1"), "question": .string("Second?")])
            ])
        ])
        let model = await blocked(on: wire)
        await model.answerQuestion(action(model), [
            BotQuestionAnswer(questionID: "q0", text: "a"), BotQuestionAnswer(questionID: "q1", text: "b")
        ])
        XCTAssertEqual(wire.calls.filter { $0.0 == "clarify.lock" }.count, 1)
        XCTAssertEqual(model.requestResolution?.outcome, .alreadyResolved)
        XCTAssertFalse(model.mayAnswer)
        model.suspend()
    }

    func testSkipSendsOneUnkeyedEmptyAnswer() async {
        let wire = BotFixtureWire()
        wire.openClarify = .object([
            "request_id": .string("clr-3"),
            "questions": .array([.object(["qid": .string("q0"), "question": .string("First?")])])
        ])
        let model = await blocked(on: wire)
        await model.skipQuestion(action(model))
        let sent = wire.calls.filter { $0.0 == "request.answer" }
        XCTAssertEqual(sent.map(\.1), [["id": .string("clr-3"), "result": .object(["answer": .string("")])]])
        model.suspend()
    }

    /// Both present: the clarify is the outer blocker, so it owns the card.
    func testAQuestionOutranksAnApproval() async {
        let wire = BotFixtureWire(); wire.attention = true; wire.openClarify = BotFixtureWire.clarify()
        let model = await blocked(on: wire)
        guard case .question? = model.pendingRequest else { return XCTFail("Expected the question to win") }
        model.suspend()
    }

    // MARK: credential prompts

    /// `request.answer` takes the envelope id from any client, so the phone answers
    /// a sudo prompt rather than sending someone to a Mac they are not sitting at.
    func testASudoPromptIsAnsweredFromThePhone() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        XCTAssertEqual(model.turn, .running)
        let prompt = serverRequest("sudo", id: "sudo-1")
        wire.openRequests = .array([prompt])
        wire.onEvent?(prompt)
        guard case .credential(let request)? = model.pendingRequest else { return XCTFail("Expected a credential prompt") }
        XCTAssertEqual(request.kind, .sudo)
        XCTAssertTrue(model.pendingRequest?.isAnswerable ?? false)
        // The request alone stops the app claiming the bot is working, and a
        // fresh snapshot restores it from `open_requests` rather than undoing that.
        XCTAssertEqual(model.turn, .needsAttention)
        await model.recover()
        XCTAssertEqual(model.turn, .needsAttention)
        XCTAssertEqual(model.pendingRequest?.requestID, "sudo-1")
        XCTAssertTrue(model.mayAnswer)

        await model.answerCredential(action(model), value: "hunter2")
        let sent = wire.calls.last { $0.0 == "request.answer" }
        XCTAssertEqual(sent?.1, ["id": .string("sudo-1"), "result": .object(["value": .string("hunter2")])])
        XCTAssertEqual(model.requestResolution, BotRequestResolution(requestID: "sudo-1", outcome: .answered))
        // An answered request is retired here, so the card never outlives the
        // thing it was blocking while the next snapshot is in flight.
        XCTAssertNil(model.pendingRequest)
        model.suspend()
    }

    /// The secret prompt carries the host's own wording and the name it will be
    /// saved under.
    func testASecretPromptShowsTheHostsWordingAndSendsItsValue() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("secret", id: "sec-1", params: [
            "env_var": .string("TAVILY_API_KEY"), "prompt": .string("Paste your Tavily key")
        ]))
        guard case .credential(let request)? = model.pendingRequest else { return XCTFail("Expected a credential prompt") }
        XCTAssertEqual(request.detail, "Paste your Tavily key")
        XCTAssertTrue(request.handling.contains("TAVILY_API_KEY"))

        await model.answerCredential(action(model), value: "tvly-123")
        let sent = wire.calls.last { $0.0 == "request.answer" }
        XCTAssertEqual(sent?.1, ["id": .string("sec-1"), "result": .object(["value": .string("tvly-123")])])
        model.suspend()
    }

    /// Skipping is the host's own decline: an empty value releases the bot now
    /// instead of parking it until the prompt times out.
    func testSkippingACredentialSendsAnEmptyValue() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("secret", id: "sec-2"))
        await model.skipCredential(action(model))
        let sent = wire.calls.last { $0.0 == "request.answer" }
        XCTAssertEqual(sent?.1["result"], .object(["value": .string("")]))
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        model.suspend()
    }

    /// A prompt the host already dropped answers `expired`: an action failure over
    /// a live socket, so the card goes inert and the connection stays up.
    func testAnExpiredCredentialPromptReportsAlreadyResolved() async {
        let wire = BotFixtureWire(); wire.answerStatus = "expired"
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("sudo", id: "sudo-3"))
        await model.answerCredential(action(model), value: "hunter2")
        XCTAssertEqual(model.requestResolution?.outcome, .alreadyResolved)
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.mayAnswer)
        model.suspend()
    }

    /// An answer captured for one prompt must never satisfy the next one.
    func testAnActionForAReplacedCredentialPromptIsNeverDispatched() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("sudo", id: "sudo-5"))
        let stale = action(model)
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1), "type": .string("request.cancel"),
                               "payload": .object(["id": .string("sudo-5"), "method": .string("sudo"), "reason": .string("timeout")])]))
        wire.onEvent?(serverRequest("sudo", id: "sudo-6"))
        XCTAssertEqual(model.pendingRequest?.requestID, "sudo-6")
        await model.answerCredential(stale, value: "hunter2")
        XCTAssertFalse(wire.calls.contains { $0.0 == "request.answer" })
        XCTAssertNil(model.requestResolution)
        // The live prompt is still answerable; only the stale action was refused.
        XCTAssertTrue(model.mayAnswer)
        model.suspend()
    }

    /// A clarify is the outer blocker, so it wins the card even while a
    /// credential prompt sits underneath it.
    func testAQuestionOutranksACredentialPrompt() async {
        let wire = BotFixtureWire(); wire.openClarify = BotFixtureWire.clarify()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("sudo", id: "sudo-7"))
        guard case .question? = model.pendingRequest else { return XCTFail("Expected the question to win") }
        model.suspend()
    }

    // MARK: Desktop-task kinds

    func testADesktopTaskBlocksTheTurnAndIsNeverAnswerable() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        XCTAssertEqual(model.turn, .running)
        let task = serverRequest("terminal.read", id: "term-1")
        wire.openRequests = .array([task])
        wire.onEvent?(task)
        XCTAssertEqual(model.pendingRequest,
                       .desktopTask(BotDesktopTaskRequest(kind: .terminalRead, requestID: "term-1")))
        guard case .desktopTask(let request)? = model.pendingRequest else { return XCTFail("Expected a Desktop task") }
        XCTAssertFalse(request.kind.title.isEmpty)
        // Not because the phone is withheld: the answer is the renderer's buffer.
        XCTAssertFalse(model.pendingRequest?.isAnswerable ?? true)
        XCTAssertFalse(model.mayAnswer)
        XCTAssertNil(model.prepareAnswer())
        // The request alone stops the app claiming the bot is working, and a
        // fresh snapshot restores it from `open_requests` rather than undoing that.
        XCTAssertEqual(model.turn, .needsAttention)
        await model.recover()
        XCTAssertEqual(model.turn, .needsAttention)
        XCTAssertEqual(model.pendingRequest?.requestID, "term-1")
        // Answering is off the table, but stopping the blocked work is not.
        XCTAssertTrue(model.mayStop)
        // Nothing reaches the host: a reply from here would pre-empt Desktop.
        XCTAssertFalse(wire.calls.contains { ["request.answer", "clarify.lock", "approval.respond"].contains($0.0) })
        model.suspend()
    }

    /// A password-manager prompt waits for someone at the Mac. The phone cannot
    /// answer it, but Skip releases the bot now with the host's empty value.
    func testAVaultPromptIsSkippedFromThePhone() async {
        for method in ["vault.unlock_prompt", "vault.save_login", "vault.code"] {
            let wire = BotFixtureWire()
            let model = await blocked(on: wire)
            wire.onEvent?(serverRequest(method, id: "vault-1", params: ["site": .string("example.com")]))
            // Skipping is not answering: the password or code only goes in at the Mac.
            XCTAssertFalse(model.pendingRequest?.isAnswerable ?? true)
            XCTAssertFalse(model.mayAnswer)
            XCTAssertTrue(model.mayDecline)

            await model.declineDesktopTask(action(model))
            XCTAssertEqual(wire.calls.last { $0.0 == "request.answer" }?.1,
                           ["id": .string("vault-1"), "result": .object(["value": .string("")])])
            XCTAssertEqual(model.requestResolution?.outcome, .answered)
            XCTAssertNil(model.pendingRequest)
            model.suspend()
        }
    }

    /// Every other Desktop task has nothing to decline, and a decline aimed at
    /// one must never reach the wire.
    func testADesktopTaskThatCannotBeDeclinedNeverDispatches() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("preview.read", id: "prev-1"))
        XCTAssertFalse(model.mayDecline)
        XCTAssertNil(model.prepareAnswer())
        await model.declineDesktopTask(
            BotConversation.AnswerAction(generation: 0, runtime: "runtime", requestID: "prev-1")
        )
        XCTAssertFalse(wire.calls.contains { $0.0 == "request.answer" })
        XCTAssertNil(model.requestResolution)
        model.suspend()
    }

    /// A gap or a lost socket may hide a `request.cancel`. Dropping the card
    /// beats showing a stale one until the next snapshot restores the real list.
    func testASequenceGapAndADisconnectBothDropTheRequest() async {
        for breakStream in [true, false] {
            let wire = BotFixtureWire()
            let model = await blocked(on: wire)
            wire.onEvent?(serverRequest("tour", id: "tour-1"))
            XCTAssertEqual(model.pendingRequest?.requestID, "tour-1")
            if breakStream {
                wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(9),
                                       "type": .string("tool.start"), "payload": .object([:])]))
            } else {
                wire.onDisconnect?(BotFailure.transport)
            }
            XCTAssertNil(model.pendingRequest)
            model.suspend()
        }
    }

    // MARK: isolation

    /// Two connections whose Profile names match must not share request state.
    func testTwoConnectionsWithTheSameProfileNameKeepTheirOwnRequests() async {
        let first = BotFixtureWire(); first.attention = true; first.running = true
        let second = BotFixtureWire(); second.running = true
        second.pendingApproval = BotFixtureWire.approval(id: "req-other", command: "shutdown -h now")
        let left = make(first, connection: connection("http://one.local:9120"))
        let right = make(second, connection: connection("http://two.local:9120"))
        await left.recover(); await right.recover()
        XCTAssertEqual(left.pendingRequest?.requestID, "req-1")
        XCTAssertEqual(right.pendingRequest?.requestID, "req-other")
        await left.respond(action(left), choice: .deny)
        XCTAssertEqual(left.requestResolution?.outcome, .answered)
        XCTAssertNil(right.requestResolution)
        XCTAssertTrue(second.calls.filter { $0.0 == "approval.respond" }.isEmpty)
        left.suspend(); right.suspend()
    }

    /// A callback that outlived its connection must never answer on the new one.
    func testAnActionCapturedBeforeSuspendNeverAnswersAfterRecovery() async {
        let wire = BotFixtureWire(); wire.attention = true
        let model = await blocked(on: wire)
        let stale = action(model)
        model.suspend()
        await model.recover()
        await model.respond(stale, choice: .once)
        XCTAssertTrue(wire.calls.filter { $0.0 == "approval.respond" }.isEmpty)
        XCTAssertNil(model.requestResolution)
        model.suspend()
    }

    /// Unknown and missing server fields never produce a card the phone cannot
    /// address. The bot is still blocked, so the turn still says so.
    func testAnUnaddressableRequestShowsAttentionWithoutACard() async {
        let wire = BotFixtureWire()
        wire.pendingApproval = .object(["future_field": .string("?"), "choices": .string("not-a-list")])
        wire.openClarify = .object(["request_id": .string("clr-9"), "questions": .array([])])
        let model = await blocked(on: wire)
        XCTAssertNil(model.pendingRequest)
        XCTAssertFalse(model.mayAnswer)
        XCTAssertEqual(model.turn, .needsAttention)
        model.suspend()
    }

    /// A connector operation (`connection.request`) is Desktop's card, not the
    /// phone's, but the bot is parked on it all the same. The snapshot's
    /// `pending_connection` says so, and the turn must not claim it is working.
    func testAnOpenConnectionOperationShowsAttentionWithoutACard() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        XCTAssertEqual(model.turn, .running)
        wire.transformResume = { snapshot in
            var fields = snapshot.fields ?? [:]
            fields["pending_connection"] = .object([
                "op_id": .string("op-1"), "seq": .number(1), "deadline_at": .number(1_900_000_000),
                "timeout_seconds": .number(600), "targets": .array([]), "future_field": .bool(true)
            ])
            return .object(fields)
        }
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                               "type": .string("connection.request"), "payload": .object(["op_id": .string("op-1")])]))
        await awaitSnapshot(model)
        XCTAssertNil(model.pendingRequest)
        XCTAssertFalse(model.mayAnswer)
        XCTAssertEqual(model.turn, .needsAttention)
        model.suspend()
    }
}

extension BotAnsweringTests {
    private func serverRequest(_ method: String, id: String = "srq-1", session: String = "runtime",
                               params: [String: BotJSON] = [:]) -> BotJSON {
        .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method),
                 "params": .object(params.merging(["session_id": .string(session)]) { _, new in new })])
    }

    func testModernLiveAndRestoredCredentialsUseAcknowledgedAnswerProxy() async {
        for kind in ["sudo", "secret"] {
            for live in [true, false] {
                let wire = BotFixtureWire()
                let frame = serverRequest(kind)
                wire.openRequests = .array(live ? [] : [frame])
                let model = await blocked(on: wire)
                if live { wire.onEvent?(frame) }
                XCTAssertEqual(model.pendingRequest?.requestID, "srq-1")
                XCTAssertEqual(model.turn, .needsAttention)
                await model.answerCredential(action(model), value: "fixture-value")
                let sent = wire.calls.last { $0.0 == "request.answer" }
                XCTAssertEqual(sent?.1, ["id": .string("srq-1"),
                                         "result": .object(["value": .string("fixture-value")])])
                XCTAssertEqual(model.requestResolution?.outcome, .answered)
                XCTAssertNil(model.pendingRequest)
                XCTAssertFalse(wire.calls.contains { $0.0 == kind + ".respond" })
                model.suspend()
            }
        }
    }

    func testModernSingleQuestionAndBatchSkipUseAnswerProxy() async {
        for batch in [false, true] {
            let wire = BotFixtureWire()
            let params: [String: BotJSON] = batch
                ? ["questions": .array([.object(["qid": .string("q1"), "question": .string("Where?")])])]
                : ["question": .string("Where?")]
            wire.openRequests = .array([serverRequest("clarify", params: params)])
            let model = await blocked(on: wire)
            if batch { await model.skipQuestion(action(model)) }
            else { await model.answerQuestion(action(model), [.init(questionID: nil, text: "Here")]) }
            XCTAssertEqual(wire.calls.last { $0.0 == "request.answer" }?.1,
                           ["id": .string("srq-1"), "result": .object(["answer": .string(batch ? "" : "Here")])])
            XCTAssertEqual(model.requestResolution?.outcome, .answered)
            model.suspend()
        }
    }

    func testModernBatchLocksRespectRemainingAndExpiration() async {
        for status in ["ok", "expired", "completedElsewhere", "partial"] {
            let wire = BotFixtureWire()
            wire.openRequests = .array([serverRequest("clarify", params: [
                "questions": .array((0...2).map { .object(["qid": .string("q\($0)"), "question": .string("Question \($0)?")]) }),
                "answers": .object(["q0": .string("Locked before reconnect")])
            ])])
            var locks = 0
            wire.answerRequest = { method, params in
                XCTAssertEqual(method, "clarify.lock")
                XCTAssertEqual(params["request_id"], .string("srq-1"))
                locks += 1
                let remaining: [BotJSON] = (status == "partial" || (status == "ok" && locks == 1)) ? [.string("q2")] : []
                return .object(["status": .string(status == "expired" ? "expired" : "ok"), "remaining": .array(remaining)])
            }
            let model = await blocked(on: wire)
            guard case .question(let question)? = model.pendingRequest else { return XCTFail("Missing restored batch") }
            XCTAssertEqual(question.questions.first?.lockedAnswer, "Locked before reconnect")
            await model.answerQuestion(action(model), [.init(questionID: "q1", text: "One"), .init(questionID: "q2", text: "Two")])
            XCTAssertEqual(locks, ["ok", "partial"].contains(status) ? 2 : 1)
            if status == "partial" {
                XCTAssertNil(model.requestResolution)
                XCTAssertNotNil(model.pendingRequest)
            } else {
                XCTAssertEqual(model.requestResolution?.outcome, status == "expired" ? .alreadyResolved : .answered)
            }
            model.suspend()
        }
    }

    func testModernVaultSkipAndApprovalKeepDistinctResultVocabulary() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([serverRequest("vault.code")])
        let model = await blocked(on: wire)
        await model.declineDesktopTask(action(model))
        XCTAssertEqual(wire.calls.last { $0.0 == "request.answer" }?.1["result"],
                       .object(["value": .string("")]))
        model.suspend()

        wire.openRequests = .array([serverRequest("approval", params: BotFixtureWire.approval(id: "queue-id").fields!)])
        await model.recover()
        await model.respond(action(model), choice: .deny)
        XCTAssertEqual(wire.calls.last { $0.0 == "approval.respond" }?.1["request_id"], .string("queue-id"))
        model.suspend()
    }

    func testModernCancelMatchesEnvelopeIDAndMethodAndRejectsCapturedAnswer() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([serverRequest("sudo")])
        let model = await blocked(on: wire)
        let captured = action(model)
        for (seq, id, method) in [(1, "other", "sudo"), (2, "srq-1", "secret"), (3, "srq-1", "sudo")] {
            wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(Double(seq)),
                                  "type": .string("request.cancel"),
                                  "payload": .object(["id": .string(id), "method": .string(method), "reason": .string("timeout")])]))
            XCTAssertEqual(model.pendingRequest == nil, seq == 3)
        }
        await model.answerCredential(captured, value: "never sent")
        XCTAssertFalse(wire.calls.contains { $0.0 == "request.answer" })
        model.suspend()
    }

    func testModernRequestsRejectForeignRuntimeAndStaleGenerationAtDispatch() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([serverRequest("sudo", session: "foreign")])
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("sudo", session: "foreign"))
        XCTAssertNil(model.pendingRequest)
        wire.onEvent?(serverRequest("sudo"))
        let captured = action(model)
        wire.beforeDispatch = { method in
            if method == "request.answer" { model.suspend() }
        }
        await model.answerCredential(captured, value: "never sent")
        XCTAssertFalse(wire.calls.contains { $0.0 == "request.answer" })
        wire.beforeDispatch = nil
        wire.openRequests = .array([serverRequest("sudo")])
        wire.runtimeID = "replacement"
        await model.recover()
        await model.answerCredential(captured, value: "never sent")
        XCTAssertFalse(wire.calls.contains { $0.0 == "request.answer" })
        model.suspend()
    }

    func testModernLostAnswerIsUncertainAndRecoveryNeverResends() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([serverRequest("secret")])
        wire.respondFailure = .transport
        let model = await blocked(on: wire)
        await model.answerCredential(action(model), value: "fixture")
        XCTAssertEqual(model.requestResolution?.outcome, .uncertain)
        XCTAssertEqual(model.connectionState, .disconnected)
        wire.respondFailure = nil
        await model.recover()
        XCTAssertEqual(wire.calls.filter { $0.0 == "request.answer" }.count, 1)
        XCTAssertEqual(model.pendingRequest?.requestID, "srq-1")
        model.suspend()
    }

    func testModernEmptySnapshotClearsRequestAndUnknownMethodStillBlocks() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([serverRequest("future.prompt")])
        let model = await blocked(on: wire)
        XCTAssertNil(model.pendingRequest)
        XCTAssertEqual(model.turn, .needsAttention)
        wire.openRequests = .array([])
        model.suspend()
        await model.recover()
        XCTAssertNil(model.pendingRequest)
        XCTAssertEqual(model.turn, .running)
        model.suspend()
    }
    func testModernRequestsRestoreEvenWhenReplayIsTruncated() async {
        let wire = BotFixtureWire()
        var replay = BotFixtureWire.replay(latest: 9, truncated: true).fields!
        replay["open_requests"] = .array([serverRequest("secret")])
        wire.replay = .object(replay)
        wire.openRequests = .array([serverRequest("secret")])
        let model = await blocked(on: wire)
        XCTAssertTrue(model.replayWasReset)
        XCTAssertEqual(model.pendingRequest?.requestID, "srq-1")
        XCTAssertEqual(model.turn, .needsAttention)
        model.suspend()
    }

    func testSnapshotCannotOverwriteANewerLiveRequestOrCancellation() async {
        for cancel in [false, true] {
            let wire = BotFixtureWire()
            let frame = serverRequest("secret")
            wire.openRequests = .array(cancel ? [frame] : [])
            let model = await blocked(on: wire)
            wire.transformResume = { snapshot in
                wire.transformResume = nil
                if cancel {
                    wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(2),
                                          "type": .string("request.cancel"),
                                          "payload": .object(["id": .string("srq-1"), "method": .string("secret")])]))
                } else { wire.onEvent?(frame) }
                wire.openRequests = .array(cancel ? [] : [frame])
                return snapshot
            }
            wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                                  "type": .string("session.info"), "payload": .object([:])]))
            await awaitSnapshot(model)
            XCTAssertEqual(model.pendingRequest?.requestID, cancel ? nil : "srq-1")
            model.suspend()
        }
    }

    func testModernReplacedRequestIsRejectedAtActualDispatch() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([serverRequest("sudo")])
        let model = await blocked(on: wire)
        wire.beforeDispatch = { method in
            guard method == "request.answer" else { return }
            wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                                  "type": .string("request.cancel"),
                                  "payload": .object(["id": .string("srq-1"), "method": .string("sudo")])]))
            wire.onEvent?(self.serverRequest("sudo", id: "srq-2"))
        }
        await model.answerCredential(action(model), value: "never sent")
        XCTAssertFalse(wire.calls.contains { $0.0 == "request.answer" })
        XCTAssertEqual(model.pendingRequest?.requestID, "srq-2")
        model.suspend()
    }

    func testModernResumeOmittingOpenRequestsClearsAnsweredElsewhere() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([serverRequest("secret")])
        let model = await blocked(on: wire)
        wire.openRequests = .null
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                              "type": .string("session.info"), "payload": .object([:])]))
        await awaitSnapshot(model)
        XCTAssertNil(model.pendingRequest)
        XCTAssertEqual(model.turn, .running)
        model.suspend()
    }

    func testCancellationOfUnseenRequestInvalidatesAnOlderSnapshot() async {
        let wire = BotFixtureWire()
        wire.openRequests = .array([])
        let model = await blocked(on: wire)
        wire.transformResume = { snapshot in
            wire.transformResume = nil
            var stale = snapshot.fields!
            stale["open_requests"] = .array([self.serverRequest("secret")])
            wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(2),
                                  "type": .string("request.cancel"),
                                  "payload": .object(["id": .string("srq-1"), "method": .string("secret")])]))
            return .object(stale)
        }
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                              "type": .string("session.info"), "payload": .object([:])]))
        await awaitSnapshot(model)
        XCTAssertNil(model.pendingRequest)
        model.suspend()
    }

}
