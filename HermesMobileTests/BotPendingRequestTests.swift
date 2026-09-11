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

    func testDesktopOnlyKindsMapFromTheirRequestAndExpireEvents() {
        let expected: [String: BotDesktopOnlyRequest.Kind] = [
            "sudo": .sudo, "secret": .secret, "terminal.read": .terminalRead,
            "window.read": .windowRead, "mcp.setup": .mcpSetup,
            "preview.read": .previewRead, "preview.act": .previewAct, "tour": .tour
        ]
        for (prefix, kind) in expected {
            XCTAssertEqual(
                BotDesktopOnlyRequest.requested(eventType: "\(prefix).request",
                                                payload: .object(["request_id": .string("r")])),
                BotDesktopOnlyRequest(kind: kind, requestID: "r")
            )
            XCTAssertEqual(BotDesktopOnlyRequest.expired(eventType: "\(prefix).expire"), kind)
            XCTAssertFalse(kind.title.isEmpty)
        }
        XCTAssertNil(BotDesktopOnlyRequest.requested(eventType: "clarify.request", payload: .null))
        XCTAssertNil(BotDesktopOnlyRequest.requested(eventType: "tool.start", payload: .null))
        XCTAssertNil(BotDesktopOnlyRequest.expired(eventType: "clarify.expire"))
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
        let wire = BotFixtureWire(); wire.pendingClarify = BotFixtureWire.clarify()
        let model = await blocked(on: wire)
        guard case .question(let request)? = model.pendingRequest else { return XCTFail("Expected a question") }
        XCTAssertEqual(request.questions.count, 1)
        await model.answerQuestion(action(model),
                                   [BotQuestionAnswer(questionID: nil, text: "Primary (Recommended)")])
        let sent = wire.calls.filter { $0.0 == "clarify.respond" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.1["request_id"], .string("clr-1"))
        XCTAssertEqual(sent.first?.1["answer"], .string("Primary (Recommended)"))
        XCTAssertNil(sent.first?.1["question_id"])
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        model.suspend()
    }

    func testBatchSendsOneRespondPerQuestionIDInOrder() async {
        let wire = BotFixtureWire()
        wire.pendingClarify = .object([
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
        let sent = wire.calls.filter { $0.0 == "clarify.respond" }
        XCTAssertEqual(sent.map { $0.1["question_id"] }, [.string("q0"), .string("q1")])
        XCTAssertEqual(sent.last?.1["answer"], .string(#"["Archive"]"#))
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        model.suspend()
    }

    func testAnswersForQuestionsTheHostNeverAskedAreNeverSent() async {
        let wire = BotFixtureWire()
        wire.pendingClarify = .object([
            "request_id": .string("clr-3"),
            "questions": .array([.object(["qid": .string("q0"), "question": .string("Which mailbox?")])])
        ])
        let model = await blocked(on: wire)
        await model.answerQuestion(action(model), [BotQuestionAnswer(questionID: "q9", text: "nope")])
        XCTAssertTrue(wire.calls.filter { $0.0 == "clarify.respond" }.isEmpty)
        model.suspend()
    }

    /// The host dropped the prompt before the answer arrived. It kept nothing, so
    /// the remaining questions have nothing left to lock either.
    func testAnExpiredQuestionStopsTheBatchAndReportsItAsAlreadyResolved() async {
        let wire = BotFixtureWire(); wire.clarifyStatus = "expired"
        wire.pendingClarify = .object([
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
        XCTAssertEqual(wire.calls.filter { $0.0 == "clarify.respond" }.count, 1)
        XCTAssertEqual(model.requestResolution?.outcome, .alreadyResolved)
        XCTAssertFalse(model.mayAnswer)
        model.suspend()
    }

    func testSkipSendsOneUnkeyedEmptyAnswer() async {
        let wire = BotFixtureWire()
        wire.pendingClarify = .object([
            "request_id": .string("clr-3"),
            "questions": .array([.object(["qid": .string("q0"), "question": .string("First?")])])
        ])
        let model = await blocked(on: wire)
        await model.skipQuestion(action(model))
        let sent = wire.calls.filter { $0.0 == "clarify.respond" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.1["answer"], .string(""))
        XCTAssertNil(sent.first?.1["question_id"])
        model.suspend()
    }

    /// Both keys present: the clarify is the outer blocker, so it owns the card.
    func testAQuestionOutranksAnApproval() async {
        let wire = BotFixtureWire(); wire.attention = true; wire.pendingClarify = BotFixtureWire.clarify()
        let model = await blocked(on: wire)
        guard case .question? = model.pendingRequest else { return XCTFail("Expected the question to win") }
        model.suspend()
    }

    // MARK: Desktop-only kinds

    func testADesktopOnlyRequestBlocksTheTurnAndIsNeverAnswerable() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        XCTAssertEqual(model.turn, .running)
        wire.onEvent?(.object([
            "session_id": .string("runtime"), "seq": .number(1), "type": .string("sudo.request"),
            "payload": .object(["request_id": .string("sudo-1"), "prompt": .string("Password:")])
        ]))
        XCTAssertEqual(model.desktopOnlyRequest, BotDesktopOnlyRequest(kind: .sudo, requestID: "sudo-1"))
        guard case .desktopOnly(let request)? = model.pendingRequest else { return XCTFail("Expected a Desktop-only request") }
        XCTAssertFalse(request.kind.title.isEmpty)
        XCTAssertFalse(model.pendingRequest?.isAnswerable ?? true)
        XCTAssertFalse(model.mayAnswer)
        XCTAssertNil(model.prepareAnswer())
        // The snapshot read it triggers must stop the app claiming the bot is working.
        await awaitSnapshot(model)
        XCTAssertEqual(model.turn, .needsAttention)
        // Answering is off the table, but stopping the blocked work is not.
        XCTAssertTrue(model.mayStop)
        model.suspend()
    }

    func testTheMatchingExpireEventClearsTheDesktopOnlyRequest() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                               "type": .string("secret.request"), "payload": .object([:])]))
        XCTAssertEqual(model.desktopOnlyRequest?.kind, .secret)
        // A different kind's expiry is not this one's.
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(2),
                               "type": .string("sudo.expire"), "payload": .object([:])]))
        XCTAssertEqual(model.desktopOnlyRequest?.kind, .secret)
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(3),
                               "type": .string("secret.expire"), "payload": .object([:])]))
        XCTAssertNil(model.desktopOnlyRequest)
        model.suspend()
    }

    /// These kinds exist only in the stream, so a gap or a lost socket makes their
    /// state unknowable. Dropping the card beats showing a stale one.
    func testASequenceGapAndADisconnectBothDropTheDesktopOnlyRequest() async {
        for breakStream in [true, false] {
            let wire = BotFixtureWire()
            let model = await blocked(on: wire)
            wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                                   "type": .string("tour.request"), "payload": .object([:])]))
            XCTAssertEqual(model.desktopOnlyRequest?.kind, .tour)
            if breakStream {
                wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(9),
                                       "type": .string("tool.start"), "payload": .object([:])]))
            } else {
                wire.onDisconnect?(BotFailure.transport)
            }
            XCTAssertNil(model.desktopOnlyRequest)
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
        wire.pendingClarify = .object(["questions": .array([])])
        let model = await blocked(on: wire)
        XCTAssertNil(model.pendingRequest)
        XCTAssertFalse(model.mayAnswer)
        XCTAssertEqual(model.turn, .needsAttention)
        model.suspend()
    }
}
