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
            // A regular Hermes chat names Hermes where Bot Chat names the bot (#1141).
            XCTAssertNotEqual(kind.title(.hermes), kind.title(.bot))
            XCTAssertNotEqual(kind.detail(.hermes), kind.detail(.bot))
        }
    }

    /// `mcp.setup` no longer exists at the pin, and password-vault prompts are not answered
    /// from the phone (#1148); they and any future method still block the bot, but have no
    /// card the phone could answer.
    func testUnknownMethodsBlockWithoutACard() {
        for method in ["mcp.setup", "vault.unlock_prompt", "vault.save_login", "vault.code", "future.prompt"] {
            let request = BotServerRequest(frame(method))
            XCTAssertEqual(request?.method, method)
            XCTAssertNil(request?.pending)
        }
    }
}

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
