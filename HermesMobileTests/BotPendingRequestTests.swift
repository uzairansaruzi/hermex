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

    /// `pattern_keys` wins over `pattern_key`; both, and `tool_name`, are optional.
    func testApprovalReadsPatternKeysAndToolName() {
        let mixed = BotApprovalRequest(.object([
            "request_id": .string("a"), "pattern_key": .string("tirith:shortened_url"),
            "pattern_keys": .array([.string("tirith:shortened_url"), .string("recursive delete")]),
            "tool_name": .string("terminal")
        ]))
        XCTAssertEqual(mixed?.patternKeys, ["tirith:shortened_url", "recursive delete"])
        XCTAssertEqual(mixed?.toolName, "terminal")

        let single = BotApprovalRequest(.object([
            "request_id": .string("b"), "pattern_key": .string("recursive delete"), "pattern_keys": .array([])
        ]))
        XCTAssertEqual(single?.patternKeys, ["recursive delete"])
        XCTAssertNil(single?.toolName)

        XCTAssertEqual(BotApprovalRequest(.object(["request_id": .string("c")]))?.patternKeys, [])
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
            "preview.act": .previewAct, "tour": .tour
        ]
        XCTAssertEqual(Set(expected.values), Set(BotDesktopTaskRequest.Kind.allCases))
        for (method, kind) in expected {
            XCTAssertEqual(BotServerRequest(frame(method))?.pending,
                           .desktopTask(BotDesktopTaskRequest(kind: kind, requestID: "srq-1")))
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.detail.isEmpty)
        }
    }

    /// The password-vault prompts are answered here like sudo and secret, and
    /// carry what their card names: the password manager, the site and the
    /// origin a login is saved for, and the host's hint when it sent one.
    func testVaultPromptsAreAnswerableCredentialsWithTheirParams() {
        let unlock = BotServerRequest(frame("vault.unlock_prompt", params: [
            "backend": .string("onepassword"), "display_name": .string("1Password")
        ]))?.pending
        XCTAssertEqual(unlock, .credential(BotCredentialRequest(
            kind: .vaultUnlock, requestID: "srq-1", envVar: nil, prompt: nil, displayName: "1Password"
        )))
        let save = BotServerRequest(frame("vault.save_login", params: [
            "origin": .string("https://github.com"), "site": .string("github.com")
        ]))?.pending
        XCTAssertEqual(save, .credential(BotCredentialRequest(
            kind: .vaultSaveLogin, requestID: "srq-1", envVar: nil, prompt: nil,
            origin: "https://github.com", site: "github.com"
        )))
        // At the pin the host always sends an empty hint; blank reads as absent.
        let code = BotServerRequest(frame("vault.code", params: ["site": .string("github.com"), "hint": .string("")]))?.pending
        XCTAssertEqual(code, .credential(BotCredentialRequest(
            kind: .vaultCode, requestID: "srq-1", envVar: nil, prompt: nil, site: "github.com"
        )))
        for pending in [unlock, save, code] { XCTAssertEqual(pending?.isAnswerable, true) }

        guard case .credential(let unlockRequest)? = unlock, case .credential(let saveRequest)? = save,
              case .credential(let codeRequest)? = code else { return XCTFail("Expected three credential requests") }
        XCTAssertTrue(unlockRequest.title.contains("1Password"), unlockRequest.title)
        XCTAssertTrue(unlockRequest.handling.contains("1Password"), unlockRequest.handling)
        XCTAssertTrue(saveRequest.title.contains("github.com"), saveRequest.title)
        XCTAssertTrue(codeRequest.title.contains("github.com"), codeRequest.title)
        // The host's hint, when it sends one, is the card's own words for the code.
        guard case .credential(let hinted)? = BotServerRequest(frame("vault.code", params: [
            "hint": .string("Check your authenticator app")
        ]))?.pending else { return XCTFail("Expected a code request") }
        XCTAssertEqual(hinted.detail, "Check your authenticator app")
        XCTAssertNotEqual(codeRequest.detail, hinted.detail)
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

    // MARK: password-vault prompts

    /// The master password is answered here like sudo, as the prompt's `value`.
    func testAVaultUnlockSendsTheMasterPasswordAsItsValue() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("vault.unlock_prompt", id: "unlock-1", params: [
            "backend": .string("onepassword"), "display_name": .string("1Password")
        ]))
        XCTAssertTrue(model.mayAnswer)
        await model.answerCredential(action(model), value: "correct horse")
        XCTAssertEqual(wire.calls.last { $0.0 == "request.answer" }?.1,
                       ["id": .string("unlock-1"), "result": .object(["value": .string("correct horse")])])
        XCTAssertEqual(model.requestResolution, BotRequestResolution(requestID: "unlock-1", outcome: .answered))
        XCTAssertNil(model.pendingRequest)
        model.suspend()
    }

    /// A login goes as one JSON-encoded string holding both fields, built by an
    /// encoder so a quote or backslash in the password cannot break it. A login
    /// missing either field has no value to send at all.
    func testASaveLoginSendsIdentifierAndPasswordAsOneJSONString() async throws {
        XCTAssertNil(BotCredentialRequest.saveLoginValue(identifier: "", password: "hunter2"))
        XCTAssertNil(BotCredentialRequest.saveLoginValue(identifier: "  ", password: "hunter2"))
        XCTAssertNil(BotCredentialRequest.saveLoginValue(identifier: "tomsmith", password: ""))

        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("vault.save_login", id: "save-1", params: [
            "origin": .string("https://github.com"), "site": .string("github.com")
        ]))
        let password = #"Super "Secret" \Password!"#
        let value = try XCTUnwrap(BotCredentialRequest.saveLoginValue(identifier: " tomsmith ", password: password))
        await model.answerCredential(action(model), value: value)

        let sent = try XCTUnwrap(wire.calls.last { $0.0 == "request.answer" }?.1)
        XCTAssertEqual(sent["id"], .string("save-1"))
        let json = try XCTUnwrap(sent["result"]?["value"].text, "The value is a string, not an object")
        let login = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        XCTAssertEqual(login, ["identifier": "tomsmith", "password": password])
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        model.suspend()
    }

    /// The host strips spaces and dashes itself, so the phone sends the code untouched.
    func testAVaultCodeIsSentAsTyped() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("vault.code", id: "code-1", params: [
            "site": .string("github.com"), "hint": .string("")
        ]))
        await model.answerCredential(action(model), value: "123 456")
        XCTAssertEqual(wire.calls.last { $0.0 == "request.answer" }?.1,
                       ["id": .string("code-1"), "result": .object(["value": .string("123 456")])])
        XCTAssertEqual(model.requestResolution?.outcome, .answered)
        model.suspend()
    }

    /// Skip is the host's own decline for every vault prompt: an empty value
    /// releases the bot now instead of parking it until the prompt times out.
    func testSkippingAVaultPromptSendsAnEmptyValue() async {
        for method in ["vault.unlock_prompt", "vault.save_login", "vault.code"] {
            let wire = BotFixtureWire()
            let model = await blocked(on: wire)
            wire.onEvent?(serverRequest(method, id: "vault-1", params: ["site": .string("example.com")]))
            XCTAssertTrue(model.mayAnswer, method)
            await model.skipCredential(action(model))
            XCTAssertEqual(wire.calls.last { $0.0 == "request.answer" }?.1,
                           ["id": .string("vault-1"), "result": .object(["value": .string("")])], method)
            XCTAssertEqual(model.requestResolution?.outcome, .answered, method)
            XCTAssertNil(model.pendingRequest, method)
            model.suspend()
        }
    }

    /// A prompt the host already timed out answers `expired`: the card goes
    /// inert, the connection stays up, and the code is sent once, never again.
    func testAnExpiredVaultPromptReportsAlreadyResolved() async {
        let wire = BotFixtureWire(); wire.answerStatus = "expired"
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("vault.code", id: "code-2", params: ["site": .string("github.com")]))
        await model.answerCredential(action(model), value: "123456")
        XCTAssertEqual(wire.calls.filter { $0.0 == "request.answer" }.count, 1)
        XCTAssertEqual(model.requestResolution, BotRequestResolution(requestID: "code-2", outcome: .alreadyResolved))
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.mayAnswer)
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

    /// A Desktop task has no answer from here: an answer aimed at one, even the
    /// empty value Skip sends, never reaches the wire.
    func testADesktopTaskIsNeverAnswered() async {
        let wire = BotFixtureWire()
        let model = await blocked(on: wire)
        wire.onEvent?(serverRequest("preview.read", id: "prev-1"))
        XCTAssertNil(model.prepareAnswer())
        let forged = BotConversation.AnswerAction(generation: 0, runtime: "runtime", requestID: "prev-1")
        await model.skipCredential(forged)
        await model.answerCredential(forged, value: "never sent")
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

    /// A connection operation with no row the phone can read has no card to
    /// show, but the bot is parked on it all the same. The snapshot's
    /// `pending_connection` says so, and the turn must not claim it is working.
    func testAnUnreadableConnectionOperationShowsAttentionWithoutACard() async {
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
        await model.skipCredential(action(model))
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

// MARK: connection operations

/// Builders for `manage_connections` frames in the host's shapes
/// (`tui_gateway/contracts/connectors_operation.py` at the pin).
enum BotConnectionFixture {
    static let deadline = 1_900_000_000.0

    static func gmail(state: String = "pending") -> BotJSON {
        .object(["name": .string("gmail"), "kind": .string("connector"), "action": .string("connect"),
                 "state": .string(state), "connect_url": .string("https://accounts.example/oauth?op=1"),
                 "detail": .string("Read, label and archive mail.")])
    }

    static func github(state: String = "pending") -> BotJSON {
        .object(["name": .string("github"), "kind": .string("mcp"), "action": .string("install"),
                 "state": .string(state),
                 "required_env": .array([
                    .object(["name": .string("GITHUB_TOKEN"), "required": .bool(true), "secret": .bool(true),
                             "default": .string(""), "prompt": .string("A fine-grained token")]),
                    .object(["name": .string("GITHUB_HOST"), "required": .bool(false), "secret": .bool(false),
                             "default": .string("github.com")])
                 ])])
    }

    static func operation(_ id: String = "op-1", seq: Int = 1, settled: Bool? = nil,
                          targets: [BotJSON] = [gmail(), github()]) -> BotJSON {
        var fields: [String: BotJSON] = [
            "op_id": .string(id), "seq": .number(Double(seq)), "deadline_at": .number(deadline),
            "timeout_seconds": .number(300), "targets": .array(targets), "tool_call_id": .string("call-1")
        ]
        if let settled { fields["settled"] = .bool(settled) }
        return .object(fields)
    }

    static func event(_ type: String, seq: Int, payload: BotJSON) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type), "payload": payload])
    }
}

extension BotPendingRequestParsingTests {
    /// Unknown values keep their row but offer nothing; a row without a name or a
    /// repeated name is dropped; the update frame's own `from`/`to` keys are ignored.
    func testConnectionOperationReadsEveryHostShapeTolerantly() throws {
        var payload = BotConnectionFixture.operation(seq: 7, settled: false, targets: [
            BotConnectionFixture.gmail(),
            BotConnectionFixture.github(),
            .object(["name": .string("linear"), "kind": .string("mcp"), "action": .string("authorize"),
                     "state": .string("initiated"), "connect_url": .string("https://mcp.linear.app/authorize")]),
            .object(["name": .string("notion"), "kind": .string("mcp"), "action": .string("enable"), "state": .string("pending")]),
            .object(["name": .string("future"), "kind": .string("hologram"), "action": .string("beam"), "state": .string("paused"),
                     "connect_url": .string("https://example.com")]),
            .object(["kind": .string("connector"), "state": .string("pending")]),
            BotConnectionFixture.gmail(state: "connected")
        ]).fields!
        payload["target"] = .string("gmail"); payload["from"] = .string("pending"); payload["to"] = .string("initiated")
        payload["actor"] = .string("backend_watcher"); payload["detail"] = .string("change detail, not a row")
        let operation = try XCTUnwrap(BotConnectionOperation(.object(payload)))

        XCTAssertEqual(operation.opID, "op-1")
        XCTAssertEqual(operation.seq, 7)
        XCTAssertEqual(operation.deadline, Date(timeIntervalSince1970: BotConnectionFixture.deadline))
        XCTAssertFalse(operation.isSettled)
        XCTAssertEqual(operation.targets.map(\.name), ["gmail", "github", "linear", "notion", "future"])
        XCTAssertEqual(operation.targets[0].state, .pending)
        XCTAssertEqual(operation.targets[0].detail, "Read, label and archive mail.")

        let github = operation.targets[1]
        XCTAssertEqual(github.requiredEnv.map(\.name), ["GITHUB_TOKEN", "GITHUB_HOST"])
        XCTAssertTrue(github.requiredEnv[0].isSecret)
        XCTAssertNil(github.requiredEnv[0].defaultValue)
        XCTAssertEqual(github.requiredEnv[1].defaultValue, "github.com")
        XCTAssertFalse(github.requiredEnv[1].isRequired)
        // A missing `required_env` is an install with nothing left to ask.
        XCTAssertEqual(operation.targets[3].requiredEnv, [])

        let future = operation.targets[4]
        XCTAssertNil(future.kind); XCTAssertNil(future.action); XCTAssertNil(future.state)
        XCTAssertFalse(future.canSkip); XCTAssertFalse(future.canConnect)
        XCTAssertNil(future.linkToOpen); XCTAssertFalse(future.finishesOnTheMac)

        // A known kind and state do not make an unknown action answerable.
        var teleport = BotConnectionFixture.gmail().fields!
        teleport["action"] = .string("teleport")
        let unknownAction = try XCTUnwrap(BotConnectionOperation.Target(.object(teleport)))
        XCTAssertNil(unknownAction.action)
        XCTAssertFalse(unknownAction.canSkip)
        XCTAssertNil(unknownAction.linkToOpen)
    }

    func testAConnectionOperationWithoutAnIdCounterDeadlineOrRowIsNotShown() {
        var valid = BotConnectionFixture.operation().fields!
        for key in ["op_id", "seq", "deadline_at", "targets"] {
            var broken = valid; broken.removeValue(forKey: key)
            XCTAssertNil(BotConnectionOperation(.object(broken)), key)
        }
        valid["targets"] = .array([.object(["kind": .string("mcp")])])
        XCTAssertNil(BotConnectionOperation(.object(valid)))
        XCTAssertNil(BotConnectionOperation(.null))
    }

    /// Each row offers only the moves the host allows for its kind and state.
    func testConnectionRowsOfferOnlyWhatTheHostAllows() throws {
        func row(_ json: BotJSON) throws -> BotConnectionOperation.Target {
            try XCTUnwrap(BotConnectionOperation.Target(json))
        }
        // A managed connector opens its https sign-in while pending or started.
        let gmail = try row(BotConnectionFixture.gmail())
        XCTAssertEqual(gmail.linkToOpen, URL(string: "https://accounts.example/oauth?op=1"))
        XCTAssertFalse(gmail.canConnect)
        XCTAssertTrue(gmail.canSkip)
        for state in ["failed", "expired"] {
            let dead = try row(BotConnectionFixture.gmail(state: state))
            XCTAssertNil(dead.linkToOpen, state)
            XCTAssertTrue(dead.canSkip, state)
        }
        for state in ["connected", "skipped", "not_connected", "unavailable"] {
            XCTAssertFalse(try row(BotConnectionFixture.gmail(state: state)).canSkip, state)
        }
        var app = BotConnectionFixture.gmail().fields!
        app["connect_url"] = .string("hermes-desktop://connections/done")
        XCTAssertNil(try row(.object(app)).linkToOpen)

        // An MCP sign-in returns to the Mac's loopback: never a phone link.
        let linear = try row(.object(["name": .string("linear"), "kind": .string("mcp"), "action": .string("authorize"),
                                      "state": .string("initiated"), "connect_url": .string("https://mcp.linear.app/a")]))
        XCTAssertNil(linear.linkToOpen)
        XCTAssertTrue(linear.finishesOnTheMac)
        XCTAssertFalse(linear.canConnect)
        XCTAssertTrue(linear.canSkip)
        var oauthInstall = BotConnectionFixture.github(state: "initiated").fields!
        oauthInstall["connect_url"] = .string("https://auth.example/authorize")
        XCTAssertTrue(try row(.object(oauthInstall)).finishesOnTheMac)

        // An install connects once every required value is filled, and only with declared names.
        let github = try row(BotConnectionFixture.github())
        XCTAssertTrue(github.canConnect)
        XCTAssertFalse(github.accepts([:]))
        XCTAssertFalse(github.accepts(["GITHUB_TOKEN": ""]))
        XCTAssertTrue(github.accepts(["GITHUB_TOKEN": "ghp_1"]))
        XCTAssertTrue(github.accepts(["GITHUB_TOKEN": "ghp_1", "GITHUB_HOST": "ghe.example"]))
        XCTAssertFalse(github.accepts(["GITHUB_TOKEN": "ghp_1", "PATH": "/tmp"]))
        XCTAssertTrue(try row(BotConnectionFixture.github(state: "failed")).canConnect)
        XCTAssertFalse(try row(BotConnectionFixture.github(state: "initiated")).canConnect)
        let enable = try row(.object(["name": .string("notion"), "kind": .string("mcp"), "action": .string("enable"),
                                      "state": .string("pending")]))
        XCTAssertTrue(enable.accepts([:]))
    }

    /// A plain field starts at its default and Connect sends it, because the host
    /// never fills one in: a required one is ready untouched, and only emptying it
    /// holds Connect back.
    func testConnectionFieldsSendTheirDefaultUntouched() throws {
        let linear = try XCTUnwrap(BotConnectionOperation.Target(.object([
            "name": .string("linear"), "kind": .string("mcp"), "action": .string("install"), "state": .string("pending"),
            "required_env": .array([.object(["name": .string("LINEAR_URL"), "required": .bool(true),
                                             "secret": .bool(false), "default": .string("https://api.linear.app")])])
        ])))
        XCTAssertEqual(linear.env(from: [:]), ["LINEAR_URL": "https://api.linear.app"])
        XCTAssertTrue(linear.accepts(linear.env(from: [:])))
        XCTAssertEqual(linear.env(from: ["LINEAR_URL": " https://linear.example "]), ["LINEAR_URL": "https://linear.example"])
        XCTAssertFalse(linear.accepts(linear.env(from: ["LINEAR_URL": " "])))

        // An optional default rides along too; a secret never has one.
        let github = try XCTUnwrap(BotConnectionOperation.Target(BotConnectionFixture.github()))
        XCTAssertEqual(github.env(from: ["GITHUB_TOKEN": "ghp_1"]), ["GITHUB_TOKEN": "ghp_1", "GITHUB_HOST": "github.com"])
        XCTAssertEqual(github.env(from: ["GITHUB_TOKEN": "ghp_1", "GITHUB_HOST": ""]), ["GITHUB_TOKEN": "ghp_1"])
    }

    func testConnectionAnswersUseTheHostsResultShape() {
        XCTAssertEqual(BotConnectionOperation.Answer.skip(target: "gmail").result,
                       .object(["targets": .array([.object(["name": .string("gmail"), "status": .string("skipped")])])]))
        XCTAssertEqual(BotConnectionOperation.Answer.connect(target: "notion", env: [:]).result,
                       .object(["targets": .array([.object(["name": .string("notion"), "status": .string("approved")])])]))
        XCTAssertEqual(BotConnectionOperation.Answer.connect(target: "github", env: ["GITHUB_TOKEN": "ghp_1"]).result,
                       .object(["targets": .array([.object(["name": .string("github"), "status": .string("approved"),
                                                            "env": .object(["GITHUB_TOKEN": .string("ghp_1")])])])]))
        XCTAssertEqual(BotConnectionOperation.Answer.continueWithout.result, .object(["settled_by": .string("continue")]))
    }

    /// A frame that is not newer, or belongs to another operation, moves nothing.
    func testOnlyANewerFrameOfTheSameOperationReplacesIt() throws {
        let held = try XCTUnwrap(BotConnectionOperation(BotConnectionFixture.operation(seq: 3)))
        let older = try XCTUnwrap(BotConnectionOperation(BotConnectionFixture.operation(seq: 2, targets: [BotConnectionFixture.gmail(state: "connected")])))
        let equal = try XCTUnwrap(BotConnectionOperation(BotConnectionFixture.operation(seq: 3, targets: [BotConnectionFixture.gmail(state: "connected")])))
        let foreign = try XCTUnwrap(BotConnectionOperation(BotConnectionFixture.operation("op-2", seq: 9)))
        let newer = try XCTUnwrap(BotConnectionOperation(BotConnectionFixture.operation(seq: 4, targets: [BotConnectionFixture.gmail(state: "connected")])))
        XCTAssertEqual(held.applying(older), held)
        XCTAssertEqual(held.applying(equal), held)
        XCTAssertEqual(held.applying(foreign), held)
        XCTAssertEqual(held.applying(newer), newer)
    }

    func testTheDeadlineReadsInWholeMinutesAndNeverBelowOne() {
        let deadline = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(BotConnectionOperation.minutesLeft(until: deadline, now: deadline.addingTimeInterval(-300)), 5)
        XCTAssertEqual(BotConnectionOperation.minutesLeft(until: deadline, now: deadline.addingTimeInterval(-241)), 5)
        XCTAssertEqual(BotConnectionOperation.minutesLeft(until: deadline, now: deadline.addingTimeInterval(-240)), 4)
        XCTAssertEqual(BotConnectionOperation.minutesLeft(until: deadline, now: deadline.addingTimeInterval(30)), 1)
    }
}

extension BotAnsweringTests {
    private func operation(_ model: BotConversation) -> BotConnectionOperation? {
        guard case .connection(let operation)? = model.pendingRequest else { return nil }
        return operation
    }

    /// The card restores from the snapshot with the host's deadline, follows only
    /// newer frames, and leaves on the settled one without an older frame or
    /// snapshot bringing it back.
    func testAConnectionCardRestoresFollowsNewerFramesAndLeavesWhenSettled() async throws {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation(seq: 2)
        let model = await blocked(on: wire)
        let restored = try XCTUnwrap(operation(model))
        XCTAssertEqual(restored.seq, 2)
        XCTAssertEqual(restored.deadline, Date(timeIntervalSince1970: BotConnectionFixture.deadline))
        XCTAssertEqual(model.turn, .needsAttention)
        XCTAssertTrue(model.mayAnswer)

        wire.onEvent?(BotConnectionFixture.event("connection.update", seq: 1, payload: BotConnectionFixture.operation(
            seq: 1, settled: false, targets: [BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github()])))
        XCTAssertEqual(operation(model)?.targets.first?.state, .pending)

        wire.onEvent?(BotConnectionFixture.event("connection.update", seq: 2, payload: BotConnectionFixture.operation(
            seq: 3, settled: false, targets: [BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github()])))
        XCTAssertEqual(operation(model)?.targets.first?.state, .connected)
        // The snapshot this frame triggers still holds seq 2; it must not regress the row.
        // The turn does not change, so wait on the host serving that read instead.
        let served = expectation(description: "Snapshot served")
        wire.transformResume = { snapshot in
            wire.transformResume = nil
            served.fulfill()
            return snapshot
        }
        await fulfillment(of: [served], timeout: 5)
        XCTAssertEqual(operation(model)?.seq, 3)
        XCTAssertEqual(model.turn, .needsAttention)

        wire.onEvent?(BotConnectionFixture.event("connection.update", seq: 3, payload: BotConnectionFixture.operation(
            seq: 4, settled: true, targets: [BotConnectionFixture.gmail(state: "connected"), BotConnectionFixture.github(state: "not_connected")])))
        XCTAssertNil(model.pendingRequest)
        // A late request frame for the settled operation stays closed.
        wire.onEvent?(BotConnectionFixture.event("connection.request", seq: 4, payload: BotConnectionFixture.operation(seq: 2)))
        XCTAssertNil(model.pendingRequest)
        wire.pendingConnection = .null
        await awaitSnapshot(model)
        XCTAssertNil(model.pendingRequest)
        XCTAssertEqual(model.turn, .running)
        model.suspend()
    }

    /// Resume omits `pending_connection` once nothing is open: answered at the
    /// Mac, or timed out. The card goes with it.
    func testAResumeWithoutPendingConnectionClearsTheCard() async {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation()
        let model = await blocked(on: wire)
        XCTAssertNotNil(operation(model))
        wire.pendingConnection = .null
        wire.onEvent?(.object(["session_id": .string("runtime"), "seq": .number(1),
                               "type": .string("session.info"), "payload": .object([:])]))
        await awaitSnapshot(model)
        XCTAssertNil(model.pendingRequest)
        XCTAssertEqual(model.turn, .running)
        model.suspend()
    }

    /// A reconnect drops the card and restores it from the host, even when the
    /// replay ring repeats the request frame: one card, one row per app.
    func testAReconnectRestoresTheCardWithoutADuplicateRow() async {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation(seq: 2)
        let model = await blocked(on: wire)
        wire.onDisconnect?(BotFailure.transport)
        XCTAssertNil(model.pendingRequest)
        wire.replay = BotFixtureWire.replay(latest: 1, events: [
            BotConnectionFixture.event("connection.request", seq: 1, payload: BotConnectionFixture.operation(seq: 1))
        ])
        await model.recover()
        XCTAssertEqual(operation(model)?.seq, 2)
        XCTAssertEqual(operation(model)?.targets.map(\.name), ["gmail", "github"])
        XCTAssertEqual(model.turn, .needsAttention)
        model.suspend()
    }

    /// Skip answers only its row: the operation stays open and answerable. Connect
    /// sends the typed values once and only when every required one is there.
    func testSkipAndConnectAnswerOneRowAndLeaveTheOperationOpen() async {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation()
        let model = await blocked(on: wire)

        await model.respondToConnection(action(model), .skip(target: "gmail"))
        XCTAssertEqual(wire.calls.last { $0.0 == "connection.respond" }?.1, [
            "owner": .object(["type": .string("session"), "session_id": .string("runtime")]), "op_id": .string("op-1"),
            "result": .object(["targets": .array([.object(["name": .string("gmail"), "status": .string("skipped")])])])
        ])
        XCTAssertNotNil(operation(model))
        XCTAssertEqual(model.turn, .needsAttention)
        XCTAssertNil(model.requestResolution)
        XCTAssertTrue(model.mayAnswer)

        await model.respondToConnection(action(model), .connect(target: "github", env: ["GITHUB_HOST": "ghe.example"]))
        await model.respondToConnection(action(model), .connect(target: "gmail", env: [:]))
        XCTAssertEqual(wire.calls.filter { $0.0 == "connection.respond" }.count, 1)

        await model.respondToConnection(action(model), .connect(target: "github", env: ["GITHUB_TOKEN": "ghp_1"]))
        let sent = wire.calls.filter { $0.0 == "connection.respond" }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.1["result"], .object(["targets": .array([.object([
            "name": .string("github"), "status": .string("approved"), "env": .object(["GITHUB_TOKEN": .string("ghp_1")])
        ])])]))
        model.suspend()
    }

    /// Continue settles the whole operation: the card goes at once and the host
    /// decides what the turn does next.
    func testContinueSettlesTheOperationAndReleasesTheBot() async {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation()
        wire.connectionRespond = { _ in
            wire.pendingConnection = .null
            return .object(["status": .string("ok"), "settled": .bool(true)])
        }
        let model = await blocked(on: wire)
        await model.respondToConnection(action(model), .continueWithout)
        XCTAssertEqual(wire.calls.last { $0.0 == "connection.respond" }?.1["result"], .object(["settled_by": .string("continue")]))
        XCTAssertNil(model.pendingRequest)
        await awaitSnapshot(model)
        XCTAssertEqual(model.turn, .running)
        model.suspend()
    }

    /// 4004 means the operation settled before the answer landed: the card goes
    /// inert with that verdict, the connection stays up, and a snapshot follows.
    func testAnAnswerToASettledOperationReportsAlreadyResolved() async {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation()
        wire.respondFailure = .rejected(4004)
        let model = await blocked(on: wire)
        await model.respondToConnection(action(model), .skip(target: "gmail"))
        XCTAssertEqual(model.requestResolution, BotRequestResolution(requestID: "op-1", outcome: .alreadyResolved))
        XCTAssertFalse(model.mayAnswer)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.connectionState, .connected)
        wire.pendingConnection = .null
        await awaitSnapshot(model)
        XCTAssertNil(model.pendingRequest)
        model.suspend()
    }

    /// A lost reply cannot tell sent from not sent: the outcome is unknown and
    /// the answer is never resent.
    func testALostConnectionAnswerIsUncertainAndNeverResent() async {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation()
        let model = await blocked(on: wire)
        wire.respondFailure = .transport
        await model.respondToConnection(action(model), .continueWithout)
        XCTAssertEqual(model.requestResolution?.outcome, .uncertain)
        XCTAssertEqual(model.connectionState, .disconnected)
        wire.respondFailure = nil
        await model.recover()
        XCTAssertEqual(wire.calls.filter { $0.0 == "connection.respond" }.count, 1)
        XCTAssertTrue(model.mayAnswer)
        model.suspend()
    }

    /// Guide or Queue while the card is open releases the operation first, so the
    /// message does not wait behind the blocked tool. A host that already settled
    /// it (4004) does not hold the message back; Interrupt needs no Continue.
    func testGuideAndQueueContinueAnOpenOperationBeforeTheMessage() async throws {
        for (mode, settledAlready) in [(BotPromptMode.steer, false), (.queue, false), (.steer, true), (.redirect, false)] {
            let wire = BotFixtureWire()
            wire.pendingConnection = BotConnectionFixture.operation()
            wire.connectionRespond = { _ in
                if settledAlready { throw BotFailure.rejected(4004) }
                return .object(["status": .string("ok"), "settled": .bool(true)])
            }
            let model = await blocked(on: wire)
            model.editDraft("check the inbox")
            await model.submit(try XCTUnwrap(model.preparePrompt(mode)))
            let methods = wire.calls.map(\.0).filter { $0 == "connection.respond" || $0 == mode.call(runtime: "", text: "").method }
            if mode == .redirect {
                XCTAssertEqual(methods, [mode.call(runtime: "", text: "").method])
            } else {
                XCTAssertEqual(methods, ["connection.respond", mode.call(runtime: "", text: "").method], "\(mode)")
                XCTAssertEqual(wire.calls.first { $0.0 == "connection.respond" }?.1["result"],
                               .object(["settled_by": .string("continue")]))
            }
            XCTAssertEqual(model.draft, "")
            model.suspend()
        }
    }

    /// A lost Continue fails the message before it is dispatched: the draft stays
    /// and nothing is retried.
    func testALostContinueHoldsTheMessageBack() async throws {
        let wire = BotFixtureWire()
        wire.pendingConnection = BotConnectionFixture.operation()
        wire.connectionRespond = { _ in throw BotFailure.transport }
        let model = await blocked(on: wire)
        model.editDraft("check the inbox")
        await model.submit(try XCTUnwrap(model.preparePrompt(.steer)))
        XCTAssertFalse(wire.calls.contains { $0.0 == "session.steer" })
        XCTAssertEqual(wire.calls.filter { $0.0 == "connection.respond" }.count, 1)
        XCTAssertEqual(model.draft, "check the inbox")
        XCTAssertFalse(model.uncertainSend)
        model.suspend()
    }
}

/// The line under an approval that says what Allow session and Always allow
/// cover (#883). Exact copy is the approved design; the scope wording follows
/// the card's own server type, never the active server.
@MainActor final class ApprovalScopeTests: XCTestCase {
    private static let allChoices = ["once", "session", "always", "deny"]

    private func botLine(keys: [String], description: String, command: String = "rm -rf ./build",
                         choices: [String] = allChoices, toolName: String? = nil) -> AttributedString? {
        var fields: [String: BotJSON] = [
            "request_id": .string("req-1"), "command": .string(command), "description": .string(description),
            "pattern_keys": .array(keys.map(BotJSON.string)), "choices": .array(choices.map(BotJSON.string))
        ]
        fields["tool_name"] = toolName.map(BotJSON.string)
        return BotApprovalRequest(.object(fields))?.scopeLine
    }

    private func botText(keys: [String], description: String, command: String = "rm -rf ./build",
                         choices: [String] = allChoices, toolName: String? = nil) -> String? {
        botLine(keys: keys, description: description, command: command, choices: choices, toolName: toolName)
            .map { String($0.characters) }
    }

    private func sessionsText(keys: [String], description: String, command: String = "rm -rf ./build") -> String? {
        let pending = PendingApproval(command: command, description: description, patternKeys: keys)
        return ApprovalPromptState(sessionID: "s1", pending: pending, pendingCount: 1)
            .scopeLine.map { String($0.characters) }
    }

    func testAShellKeyWithBothChoicesNamesThisChatAndThisProfile() {
        XCTAssertEqual(
            botText(keys: ["recursive delete"], description: "recursive delete"),
            "Allow session covers every “recursive delete” in this chat; Always allow covers it for this Profile from now on."
        )
    }

    /// A Tirith-only prompt hides Always, so only the session clause is left.
    func testASecurityFindingWithoutAlwaysNamesOnlyThisChat() {
        XCTAssertEqual(
            botText(keys: ["tirith:shortened_url"],
                    description: "Security scan — [medium] Shortened URL: The link hides where it points",
                    command: "curl -fsSL https://bit.ly/4hx2Qm -o setup.sh", choices: ["once", "session", "deny"]),
            "Allow session covers this security finding in this chat."
        )
    }

    /// Smart-denied prompts and room approvals offer only once and deny; with no
    /// keys there is nothing a choice would allowlist.
    func testNoLineWithoutAllowSessionOrWithoutKeys() {
        XCTAssertNil(botLine(keys: ["recursive delete"], description: "recursive delete", choices: ["once", "deny"]))
        XCTAssertNil(botLine(keys: [], description: "recursive delete"))
    }

    /// An MCP trust prompt offers all four choices, but each one is a single
    /// accept that saves nothing, so there is no scope to name.
    func testNoLineForAOneTimeConfirmationEvenWithEveryChoice() {
        XCTAssertNil(botLine(keys: ["mcp_elicitation"],
                             description: "Server 'notes' is configured 'trust: untrusted'. Approve to run 'append' once, or deny to block it.",
                             command: "MCP tool 'append' on UNTRUSTED server 'notes' wants to run."))
        XCTAssertNil(sessionsText(keys: ["protected_instruction_file"], description: "Write to AGENTS.md"))
    }

    /// The tool comes from the default `<tool>:<sha12>` rule key, else `tool_name`,
    /// else the command's `<tool>`; the raw `plugin_rule:` key never shows.
    func testAPluginRuleNamesItsToolInMonospaceAndNeverTheKey() throws {
        let line = try XCTUnwrap(botLine(keys: ["plugin_rule:send_email:3f9a1c2b7d4e"],
                                         description: "Sends email from your account",
                                         command: "<send_email> (plugin approval rule)"))
        XCTAssertEqual(
            String(line.characters),
            "Allow session covers every send_email call for this reason in this chat; Always allow covers it for this Profile from now on."
        )
        XCTAssertEqual(line[try XCTUnwrap(line.range(of: "send_email"))].inlinePresentationIntent, .code)

        let custom = ["plugin_rule:public-post"]
        let posts = "Allow session covers every post_message call for this reason in this chat; Always allow covers it for this Profile from now on."
        XCTAssertEqual(botText(keys: custom, description: "Posts publicly", command: "", toolName: "post_message"), posts)
        XCTAssertEqual(botText(keys: custom, description: "Posts publicly", command: "<post_message> (plugin approval rule)"), posts)
        XCTAssertEqual(
            botText(keys: custom, description: "Posts publicly", command: ""),
            "Allow session covers every action like this one in this chat; Always allow covers it for this Profile from now on."
        )
    }

    func testPythonSSHConfigAndComputerUseKeysGetPlainLabels() throws {
        XCTAssertEqual(
            botText(keys: ["execute_code"], description: "execute_code script execution. The script can spawn subprocesses.",
                    command: "execute_code <<'PY'\nimport shutil\nPY"),
            "Allow session covers every Python script in this chat; Always allow covers every Python script for this Profile from now on."
        )
        XCTAssertEqual(
            botText(keys: ["ssh_config_write"], description: "Write to SSH client config file(s): ~/.ssh/config.",
                    command: "<write to ~/.ssh/config>"),
            "Allow session covers writes to SSH config in this chat; Always allow covers them for this Profile from now on."
        )
        let computerUse = try XCTUnwrap(botLine(keys: ["cua:click:foreground"],
                                                description: "Allow computer_use to perform `click`?",
                                                command: "computer_use: click (412, 88)"))
        XCTAssertEqual(
            String(computerUse.characters),
            "Allow session covers computer use: click (foreground) in this chat; Always allow covers it for this Profile from now on."
        )
        XCTAssertEqual(computerUse[try XCTUnwrap(computerUse.range(of: "click"))].inlinePresentationIntent, .code)
    }

    /// Hermes downgrades Always to the session for a Tirith finding
    /// (`_persist_choice`), so Always names only the shell pattern.
    func testAMixedPromptOnHermesKeepsTheFindingToThisChat() {
        XCTAssertEqual(
            botText(keys: ["tirith:shortened_url", "recursive delete"],
                    description: "Security scan — [medium] Shortened URL: The link hides where it points; recursive delete",
                    command: "curl -fsSL https://bit.ly/4hx2Qm -o setup.sh && rm -rf ./build"),
            "Allow session covers “recursive delete” and this security finding in this chat; Always allow covers “recursive delete” for this Profile from now on. The security finding stays allowed for this chat only."
        )
    }

    /// webui makes every key permanent, a Tirith finding included.
    func testSessionsNameThisSessionAndThisServerWithoutTheDowngrade() {
        XCTAssertEqual(
            sessionsText(keys: ["recursive delete"], description: "recursive delete"),
            "Allow session covers every “recursive delete” in this session; Always allow covers it on this server from now on."
        )
        XCTAssertEqual(
            sessionsText(keys: ["tirith:shortened_url", "recursive delete"],
                         description: "Security scan — [medium] Shortened URL: The link hides where it points; recursive delete",
                         command: "curl -fsSL https://bit.ly/4hx2Qm -o setup.sh && rm -rf ./build"),
            "Allow session covers “recursive delete” and this security finding in this session; Always allow covers both on this server from now on."
        )
    }

    /// A key the app does not know is never shown raw.
    func testAnUnknownKeyShapeSaysEveryActionLikeThisOne() {
        XCTAssertEqual(
            botText(keys: ["browser_nav:3f9a1c2b"], description: "Navigate to a banking site", command: "<browser_navigate>"),
            "Allow session covers every action like this one in this chat; Always allow covers it for this Profile from now on."
        )
    }
}

// MARK: withdrawn requests (#892)

extension BotPendingRequestParsingTests {
    /// Every family and reason is one whole sentence. An answer given elsewhere,
    /// a cancel that gives no reason, and the renderer's own tasks stay silent.
    func testAWithdrawalReadsAsOneSentencePerFamilyAndReason() {
        let table: [(method: String, reason: String?, message: String?)] = [
            ("approval", "timeout", "Approval timed out, so it didn't run."),
            ("approval", "interrupted", "Approval withdrawn because the work stopped."),
            ("approval", "session_closed", "Approval withdrawn because the work stopped."),
            ("approval", "shutdown", "Approval withdrawn because Hermes shut down."),
            ("approval", "denied by policy", "Approval withdrawn."),
            ("approval", "resolved", nil),
            ("clarify", "timeout", "Question timed out. The bot carried on without an answer."),
            ("clarify", "interrupted", "Question withdrawn because the work stopped."),
            ("clarify", "session_closed", "Question withdrawn because the work stopped."),
            ("clarify", "shutdown", "Question withdrawn because Hermes shut down."),
            ("clarify", "client_gone", "Question withdrawn."),
            ("clarify", "resolved", nil),
            ("sudo", "timeout", "Request timed out. The bot carried on without it."),
            ("secret", "interrupted", "Request withdrawn because the work stopped."),
            ("vault.code", "session_closed", "Request withdrawn because the work stopped."),
            ("vault.unlock_prompt", "shutdown", "Request withdrawn because Hermes shut down."),
            ("vault.save_login", "client_gone", "Request withdrawn."),
            ("sudo", "resolved", nil),
            ("sudo", nil, nil),
            ("sudo", " ", nil)
        ] + ["tour", "terminal.read", "window.read", "preview.read", "preview.act"].map { ($0, "timeout", nil) }
        for row in table {
            XCTAssertEqual(BotRequestWithdrawal(method: row.method, reason: row.reason)?.message, row.message,
                           "\(row.method) \(row.reason ?? "nil")")
        }
        XCTAssertEqual(BotRequestWithdrawal(method: "approval", reason: "timeout")?.systemImage, "clock")
        XCTAssertEqual(BotRequestWithdrawal(method: "clarify", reason: "shutdown")?.systemImage, "stop.circle")
    }
}

extension BotAnsweringTests {
    private func cancel(_ id: String, _ method: String, reason: String?, seq: Int) -> BotJSON {
        var payload: [String: BotJSON] = ["id": .string(id), "method": .string(method)]
        if let reason { payload["reason"] = .string(reason) }
        return .object(["session_id": .string("runtime"), "seq": .number(Double(seq)),
                        "type": .string("request.cancel"), "payload": .object(payload)])
    }

    /// An approval on screen the way the host shows one: its envelope in
    /// `open_requests` and its queue entry in `pending_approval`. The host has
    /// dropped both by the time it sends `request.cancel`, so later reads omit them.
    private func approvalOnScreen(_ wire: BotFixtureWire) async -> BotConversation {
        wire.pendingApproval = BotFixtureWire.approval()
        wire.openRequests = .array([serverRequest("approval", id: "srq-a", params: BotFixtureWire.approval().fields!)])
        let model = await blocked(on: wire)
        XCTAssertEqual(model.pendingRequest?.requestID, "req-1")
        wire.pendingApproval = nil
        wire.openRequests = .array([])
        return model
    }

    func testATimedOutApprovalLeavesANote() async {
        let wire = BotFixtureWire()
        let model = await approvalOnScreen(wire)
        wire.onEvent?(cancel("srq-a", "approval", reason: "timeout", seq: 1))
        XCTAssertNil(model.pendingRequest)
        XCTAssertEqual(model.withdrawnRequest?.message, "Approval timed out, so it didn't run.")
        // The host's next read agrees the card is gone, and the note stays in its place.
        await awaitSnapshot(model)
        XCTAssertEqual(model.withdrawnRequest?.message, "Approval timed out, so it didn't run.")
        model.suspend()
    }

    func testAnApprovalResolvedElsewhereLeavesNoNote() async {
        let wire = BotFixtureWire()
        let model = await approvalOnScreen(wire)
        wire.onEvent?(cancel("srq-a", "approval", reason: "resolved", seq: 1))
        XCTAssertNil(model.pendingRequest)
        XCTAssertNil(model.withdrawnRequest)
        model.suspend()
    }

    /// The user who tapped Stop already knows, whether the host's withdrawal
    /// arrives after the acknowledgement or in the replay after the Stop's
    /// reply was lost.
    func testAStopFromThisPhoneWithdrawsWithoutANote() async throws {
        for reason in ["interrupted", "session_closed"] {
            for lost in [false, true] {
                let wire = BotFixtureWire(); wire.openClarify = BotFixtureWire.clarify()
                let model = await blocked(on: wire)
                let withdraw = cancel("clr-1", "clarify", reason: reason, seq: 1)
                if lost { wire.stopFailure = .transport }
                await model.stop(try XCTUnwrap(model.prepareStop()))
                wire.openClarify = .null
                if lost {
                    wire.stopFailure = nil
                    wire.replay = BotFixtureWire.replay(latest: 1, events: [withdraw])
                    await model.recover()
                } else {
                    wire.onEvent?(withdraw)
                }
                XCTAssertNil(model.pendingRequest)
                XCTAssertNil(model.withdrawnRequest, "\(reason), lost reply: \(lost)")
                model.suspend()
            }
        }
    }

    func testAStopFromElsewhereLeavesANote() async {
        for reason in ["interrupted", "session_closed"] {
            let wire = BotFixtureWire(); wire.openClarify = BotFixtureWire.clarify()
            let model = await blocked(on: wire)
            wire.openClarify = .null
            wire.onEvent?(cancel("clr-1", "clarify", reason: reason, seq: 1))
            XCTAssertEqual(model.withdrawnRequest?.message, "Question withdrawn because the work stopped.", reason)
            model.suspend()
        }
    }

    /// Interrupt (Stop & send) and a voice stop are this phone's own stop too, even when the
    /// host withdraws the card before it acknowledges the message. A plain Queue,
    /// and an Interrupt the host queued for the next turn because the current one
    /// was still being built, stop nothing, so a stop from elsewhere after them
    /// still says so.
    func testStopAndSendAndAVoiceStopWithdrawWithoutANote() async throws {
        let cases: [(BotPromptMode, BotJSON?, Bool, stoppedHere: Bool)] = [
            (.redirect, .object(["status": .string("redirected")]), false, true),
            (.redirect, .object(["status": .string("redirected")]), true, true),
            (.queue, .object(["voice_stopped": .bool(true)]), false, true),
            (.queue, nil, false, false),
            (.redirect, .object(["status": .string("queued")]), false, false)
        ]
        for (mode, reply, beforeReply, stoppedHere) in cases {
            for reason in ["interrupted", "session_closed"] {
                let wire = BotFixtureWire(); wire.openClarify = BotFixtureWire.clarify()
                wire.promptReply = reply
                let model = await blocked(on: wire)
                let withdraw = cancel("clr-1", "clarify", reason: reason, seq: 1)
                if beforeReply {
                    wire.beforeSubmit = { [weak model] in
                        wire.openClarify = .null
                        wire.onEvent?(withdraw)
                        XCTAssertNil(model?.withdrawnRequest, "No note while the Interrupt is in flight")
                    }
                }
                model.editDraft("stop")
                await model.submit(try XCTUnwrap(model.preparePrompt(mode)))
                if !beforeReply {
                    wire.openClarify = .null
                    wire.onEvent?(withdraw)
                }
                XCTAssertNil(model.pendingRequest)
                XCTAssertEqual(model.withdrawnRequest?.message,
                               stoppedHere ? nil : "Question withdrawn because the work stopped.",
                               "\(mode) \(reply?["status"].text ?? "") \(reason) before reply: \(beforeReply)")
                model.suspend()
            }
        }
    }

    func testACancelForARequestNotOnScreenLeavesNoNote() async {
        let wire = BotFixtureWire(); wire.openClarify = BotFixtureWire.clarify()
        wire.openRequests = .array([serverRequest("sudo", id: "sudo-1")])
        let model = await blocked(on: wire)
        guard case .question? = model.pendingRequest else { return XCTFail("Expected the question on screen") }
        wire.openRequests = .array([])
        wire.onEvent?(cancel("sudo-1", "sudo", reason: "timeout", seq: 1))
        wire.onEvent?(cancel("never-seen", "clarify", reason: "timeout", seq: 2))
        // The question's id under another method is not the question (#530).
        wire.onEvent?(cancel("clr-1", "sudo", reason: "timeout", seq: 3))
        XCTAssertEqual(model.pendingRequest?.requestID, "clr-1")
        XCTAssertNil(model.withdrawnRequest)
        model.suspend()
    }

    /// The renderer's own tasks already say the bot carries on without them. A
    /// password-manager prompt waits for a person, so its timeout is worth saying.
    func testRendererTasksTimeOutSilently() async {
        for method in ["tour", "terminal.read", "window.read", "preview.read", "preview.act", "vault.code"] {
            let wire = BotFixtureWire()
            wire.openRequests = .array([serverRequest(method, id: "task-1")])
            let model = await blocked(on: wire)
            XCTAssertEqual(model.pendingRequest?.requestID, "task-1", method)
            wire.openRequests = .array([])
            wire.onEvent?(cancel("task-1", method, reason: "timeout", seq: 1))
            XCTAssertNil(model.pendingRequest)
            XCTAssertEqual(model.withdrawnRequest?.message,
                           method == "vault.code" ? "Request timed out. The bot carried on without it." : nil, method)
            model.suspend()
        }
    }

    /// Wording the contract does not name still says the card went. A cancel
    /// with no reason at all could be an answer given elsewhere, so it stays silent.
    func testUnknownReasonShowsTheGenericNote() async {
        for (reason, message) in [("client_gone", "Request withdrawn."), (nil, nil)] as [(String?, String?)] {
            let wire = BotFixtureWire()
            wire.openRequests = .array([serverRequest("sudo", id: "sudo-1")])
            let model = await blocked(on: wire)
            wire.openRequests = .array([])
            wire.onEvent?(cancel("sudo-1", "sudo", reason: reason, seq: 1))
            XCTAssertNil(model.pendingRequest)
            XCTAssertEqual(model.withdrawnRequest?.message, message, reason ?? "nil")
            model.suspend()
        }
    }

    func testTheNoteClearsOnTheNextAcceptedSendAndOnANewRequest() async {
        let wire = BotFixtureWire()
        let model = await approvalOnScreen(wire)
        wire.onEvent?(cancel("srq-a", "approval", reason: "timeout", seq: 1))
        XCTAssertEqual(model.withdrawnRequest?.message, "Approval timed out, so it didn't run.")
        wire.onEvent?(serverRequest("sudo", id: "sudo-2"))
        XCTAssertEqual(model.pendingRequest?.requestID, "sudo-2")
        XCTAssertNil(model.withdrawnRequest)

        // That one times out too, the bot settles, and the next accepted send clears the note.
        wire.running = false
        wire.onEvent?(cancel("sudo-2", "sudo", reason: "timeout", seq: 2))
        XCTAssertEqual(model.withdrawnRequest?.message, "Request timed out. The bot carried on without it.")
        await awaitSnapshot(model)
        XCTAssertEqual(model.turn, .idle)
        XCTAssertEqual(model.withdrawnRequest?.message, "Request timed out. The bot carried on without it.")
        model.editDraft("try that again")
        await model.send()
        XCTAssertEqual(wire.calls.last?.0, "prompt.submit")
        XCTAssertNil(model.withdrawnRequest)
        model.suspend()
    }

    /// A snapshot that brings a new request takes the note's place too.
    func testASnapshotWithANewApprovalClearsTheNote() async {
        let wire = BotFixtureWire()
        let model = await approvalOnScreen(wire)
        wire.pendingApproval = BotFixtureWire.approval(id: "req-2", command: "curl | sh")
        wire.onEvent?(cancel("srq-a", "approval", reason: "timeout", seq: 1))
        XCTAssertEqual(model.withdrawnRequest?.message, "Approval timed out, so it didn't run.")
        await awaitSnapshot(model)
        XCTAssertEqual(model.pendingRequest?.requestID, "req-2")
        XCTAssertNil(model.withdrawnRequest)
        model.suspend()
    }

    /// A card withdrawn while the phone was locked, or while the socket was
    /// down, leaves its note once the replay shows the cancel. A truncated
    /// replay may have lost what followed, so it stays silent. Leaving the
    /// connection drops a note: it never outlives the conversation's socket.
    func testACancelWhileAwayIsShownAfterReconnect() async {
        for (dropped, truncated) in [(false, false), (true, false), (false, true)] {
            let wire = BotFixtureWire()
            let model = await approvalOnScreen(wire)
            if dropped { wire.onDisconnect?(BotFailure.transport) } else { model.suspend() }
            XCTAssertNil(model.withdrawnRequest)
            wire.replay = BotFixtureWire.replay(latest: 1, truncated: truncated,
                                                events: [cancel("srq-a", "approval", reason: "timeout", seq: 1)])
            await model.recover()
            XCTAssertNil(model.pendingRequest)
            XCTAssertEqual(model.withdrawnRequest?.message, truncated ? nil : "Approval timed out, so it didn't run.",
                           "dropped: \(dropped), truncated: \(truncated)")
            model.suspend()
            XCTAssertNil(model.withdrawnRequest)
        }
        // A later request's cancel in the same replay means another card took the
        // slot after this one (its unsequenced frame is not replayed): stay silent.
        let wire = BotFixtureWire()
        let model = await approvalOnScreen(wire)
        model.suspend()
        wire.replay = BotFixtureWire.replay(latest: 2, truncated: false,
                                            events: [cancel("srq-a", "approval", reason: "timeout", seq: 1),
                                                     cancel("srq-b", "approval", reason: "resolved", seq: 2)])
        await model.recover()
        XCTAssertNil(model.pendingRequest)
        XCTAssertNil(model.withdrawnRequest)
        model.suspend()
    }
}
