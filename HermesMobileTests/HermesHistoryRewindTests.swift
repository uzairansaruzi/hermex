import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesHistoryRewindTests: XCTestCase {
    func testTheMenuRewindsOnlyAtSavedPromptsWithoutAttachments() async throws {
        let chat = await openChat([
            row(5, "user", "Read the logs", active: false), row(6, "assistant", "Read.", active: false),
            row(1, "user", "Summarize the logs"), row(2, "assistant", "Two errors."),
            row(3, "user", "Use these\n\n@file:/a/notes.txt"), row(4, "assistant", "Read them.")
        ])
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Run it")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", ["status": .string("complete"), "text": .string("Done.")]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.model.messages.map(\.content), ["Read the logs", "Read.", "Summarize the logs", "Two errors.",
                                                            "Use these", "Read them.", "Run it", "Done."])

        XCTAssertEqual(try menu(chat, at: 0), [.fork, .copy], "a compacted prompt")
        XCTAssertEqual(try menu(chat, at: 1), [.listen, .fork], "the compacted reply")
        XCTAssertEqual(try menu(chat, at: 2), [.edit, .fork, .copy])
        XCTAssertEqual(try menu(chat, at: 3), [.listen, .regenerate, .fork])
        XCTAssertEqual(try menu(chat, at: 4), [.fork, .copy], "a prompt with a file")
        XCTAssertEqual(try menu(chat, at: 5), [.listen, .fork], "the reply to it")
        XCTAssertEqual(try menu(chat, at: 6), [.copy], "a prompt the host has not saved")
        XCTAssertEqual(try menu(chat, at: 7), [.listen])
    }

    func testTheDiscardWarningCountsTheRowsAfterThePrompt() async throws {
        let chat = await openChat(threeTurns)
        XCTAssertEqual(chat.model.transcriptMessagesAfter(try context(chat, at: 2)), 3)
        XCTAssertEqual(chat.model.transcriptMessagesAfter(try context(chat, at: 5)), 0)
    }

    func testEditCutsAtThePromptsRowAndTheTurnTakesItsSavedRows() async throws {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming"), "user_row_id": .number(7)])))

        let edited = await chat.model.editMessage(try context(chat, at: 2), newText: "  Second, edited  ")

        XCTAssertTrue(edited)
        XCTAssertEqual(chat.writes("prompt.submit"), [[
            "session_id": .string("runtime"), "text": .string("Second, edited"), "truncate_before_row_id": .number(3),
            "confirm_truncate": .bool(true), "confirm_empty_truncate": .bool(true)
        ]])
        XCTAssertEqual(chat.model.messages.map(\.content), ["First", "First answer.", "Second, edited"])
        XCTAssertNotNil(chat.model.activeStreamID, "the new turn runs")

        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("New answer.")]))
        chat.receive(event(3, "message.complete", ["status": .string("complete"), "text": .string("New answer."),
                                                   "persisted_turn": .object([
                                                       "row_ids": .array([.number(7), .number(8)]), "complete": .bool(true),
                                                       "user_row_id": .number(7), "final_assistant_row_id": .number(8)
                                                   ])]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.map(\.content), ["First", "First answer.", "Second, edited", "New answer."])
        chat.transcript.rows = [threeTurns[0], threeTurns[1], row(7, "user", "Second, edited"), row(8, "assistant", "New answer.")]
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        await waitUntil("saved rows") { chat.model.messages.last?.rowID == 8 }
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 7, 8])
        XCTAssertEqual(chat.model.messages.map(\.content), ["First", "First answer.", "Second, edited", "New answer."])
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
    }

    func testRegenerateResendsThePromptBeforeTheReply() async throws {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

        let regenerated = await chat.model.regenerateAssistantResponse(try context(chat, at: 3))

        XCTAssertTrue(regenerated)
        XCTAssertEqual(chat.writes("prompt.submit").map { [$0["text"], $0["truncate_before_row_id"]] },
                       [[.string("Second"), .number(3)]])
        XCTAssertEqual(chat.model.messages.map(\.content), ["First", "First answer.", "Second"])
    }

    func testADeepCutIsConfirmedOnlyWhenTheHostAsksAndTheChatAskedFirst() async throws {
        for (index, deep) in [(3, true), (5, false)] {
            let chat = await openChat(threeTurns)
            chat.host.next("prompt.submit", .init(error: 4033, message: "truncation would archive later user turns"))
            chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

            let regenerated = await chat.model.regenerateAssistantResponse(try context(chat, at: index))

            XCTAssertEqual(regenerated, deep, "\(index)")
            XCTAssertEqual(chat.writes("prompt.submit").map { $0["confirm_deep_truncate"] },
                           deep ? [nil, .bool(true)] : [nil], "\(index)")
            if !deep {
                XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4, 5, 6], "nothing is cut")
                XCTAssertNil(chat.model.activeStreamID, "no turn starts")
                XCTAssertNotNil(chat.model.messageActionErrorMessage, "the chat says why")
            }
        }
    }

    func testASkillTurnResendsItsInvocation() async throws {
        let skill = "[IMPORTANT: The user has invoked the \"demo-skill\" skill, indicating they want you to follow its "
            + "instructions. The full skill content is loaded below.]\n\n---\nname: demo-skill\n---\nSay hello.\n\n"
            + "[Skill directory: <skills>/demo-skill]\n\nThe user has provided the following instruction alongside the "
            + "skill invocation: do it\n\n[Runtime note: Reply briefly.]"
        let chat = await openChat([row(1, "user", skill), row(2, "assistant", "Hello.")])
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

        _ = await chat.model.regenerateAssistantResponse(try context(chat, at: 1))

        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [.string("/demo-skill do it")])
    }

    func testRefusalsShowTheirCopyAndCutNothing() async throws {
        let chat = await openChat(threeTurns)
        let refusals: [(Int, String, String)] = [
            (4009, "session busy", "Wait for the current reply to finish."),
            (4018, "target user message is no longer in session history", "This message can’t be changed any more."),
            (5008, "failed to persist history truncation: database is locked",
             "failed to persist history truncation: database is locked")
        ]
        for (attempt, (code, message, shown)) in refusals.enumerated() {
            chat.host.next("prompt.submit", .init(error: code, message: message))
            let edited = await chat.model.editMessage(try context(chat, at: 2), newText: "Second, edited")
            XCTAssertFalse(edited, "\(code)")
            XCTAssertEqual(chat.model.messageActionErrorMessage, shown, "\(code)")
            XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4, 5, 6], "\(code)")
            XCTAssertNil(chat.model.activeStreamID, "\(code)")
            XCTAssertEqual(chat.writes("prompt.submit").count, attempt + 1, "\(code)")
            XCTAssertEqual(chat.model.takeUnsentHermesEdit(), "Second, edited", "\(code)")
            XCTAssertNil(chat.model.takeUnsentHermesEdit(), "taken once")
            chat.model.clearMessageActionError()
        }
    }

    func testAnUnconfirmedRewindIsNeverSentAgain() async throws {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("something new")])))
        let target = try context(chat, at: 2)
        chat.transcript.rows = [threeTurns[0], threeTurns[1], row(7, "user", "Second, edited")]

        let edited = await chat.model.editMessage(target, newText: "Second, edited")

        XCTAssertFalse(edited)
        XCTAssertEqual(chat.model.messageActionErrorMessage, "The server did not confirm the change.")
        XCTAssertEqual(chat.model.takeUnsentHermesEdit(), "Second, edited")
        await waitUntil("reattached") { !chat.model.isHermesSubmissionUncertain }
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 7])
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
    }

    func testRetryResendsTheLastPrompt() async {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

        let result = await chat.model.runHermesSlashCommand("/retry")

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("prompt.submit").map { [$0["text"], $0["truncate_before_row_id"]] },
                       [[.string("Third"), .number(5)]])
        XCTAssertEqual(chat.model.messages.map(\.content), ["First", "First answer.", "Second", "Second answer.", "Third"])
    }

    func testRetryRefusesAPromptWithAttachments() async {
        let chat = await openChat([row(1, "user", "Use these\n\n@file:/a/notes.txt"), row(2, "assistant", "Read them.")])

        let result = await chat.model.runHermesSlashCommand("/retry")

        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "This message can’t be changed any more.")
        XCTAssertEqual(chat.writes("prompt.submit"), [])
    }

    func testACanonicalEditRewindsThenSendsAndARefusedSendKeepsTheText() async throws {
        let rewound = try canonicalMutation("rewind")["result"]
        let chat = await openChat(threeTurns, canonical: true)
        chat.host.always("session.mutate", .init(result: rewound))
        chat.host.always("prompt.submit", .init(error: 4001, message: "invalid_params", data: .object(["reason": .string("invalid_params")])))

        let edited = await chat.model.editMessage(try context(chat, at: 2), newText: "Second, edited")

        XCTAssertFalse(edited)
        let mutation = try XCTUnwrap(chat.writes("session.mutate").first)
        XCTAssertEqual(mutation["operation"], .string("rewind"))
        XCTAssertEqual(mutation["payload"], .object(["target_message_id": .number(3)]))
        XCTAssertEqual(mutation["expected_revision"], .number(2))
        XCTAssertEqual(mutation["expected_generation"], .number(1))
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [.string("Second, edited")])
        XCTAssertNil(chat.writes("prompt.submit").first?["truncate_before_row_id"], "the host refuses the legacy cut keys")
        XCTAssertEqual(chat.model.messageActionErrorMessage,
                       "The later messages were removed, but your edited message wasn’t sent. It’s in the message box: send it again.")
        XCTAssertEqual(chat.model.takeUnsentHermesEdit(), "Second, edited")
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2])
    }

    func testASecondHistoryActionWaitsForTheOneUnderWay() async throws {
        let chat = await openChat(threeTurns, canonical: true)
        let rewinding = expectation(description: "the edit's rewind is on the wire")
        chat.host.expect(rewinding, onNext: "session.mutate")
        chat.host.withhold("session.mutate")
        let edit = Task { await chat.model.editMessage(try context(chat, at: 2), newText: "Second, edited") }
        await fulfillment(of: [rewinding], timeout: 2)

        let regenerated = await chat.model.regenerateAssistantResponse(try context(chat, at: 3))

        XCTAssertFalse(regenerated)
        XCTAssertEqual(chat.writes("session.mutate").count, 1)
        XCTAssertEqual(chat.writes("prompt.submit"), [])
        edit.cancel()
    }

    func testACanonicalUndoRewindsTheLastPromptAndAStaleOneChangesNothing() async throws {
        let stale = try canonicalMutation("stale_generation")["error"]
        let chat = await openChat(threeTurns, canonical: true)
        chat.host.next("session.mutate", .init(error: stale["code"].integer, message: stale["message"].text ?? "", data: stale["data"]))
        chat.host.next("session.mutate", .init(result: .object(["rewound_count": .number(2), "revision": .number(9)])))

        let refused = await chat.model.runHermesSlashCommand("/undo")
        XCTAssertNotEqual(refused, .executed(message: nil))
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4, 5, 6], "nothing changed")

        chat.transcript.rows = Array(threeTurns.prefix(4))
        let undone = await chat.model.runHermesSlashCommand("/undo")
        XCTAssertEqual(undone, .executed(message: nil))
        let tries = chat.writes("session.mutate")
        XCTAssertEqual(tries.map { $0["payload"] }, Array(repeating: .object(["target_message_id": .number(5)]), count: 2))
        XCTAssertEqual(tries.last?["expected_revision"], stale["data"]["revision"])
        XCTAssertEqual(tries.last?["expected_generation"], stale["data"]["execution_generation"])
        XCTAssertNotEqual(tries.first?["request_id"], tries.last?["request_id"], "a refused edit is a new one when tried again")
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4])
    }

    func testUndoRemovesTheLastExchange() async {
        let chat = await openChat(threeTurns)
        chat.host.always("session.undo", .init(result: .object(["removed": .number(2)])))
        chat.transcript.rows = Array(threeTurns.prefix(4))

        let result = await chat.model.runHermesSlashCommand("/undo")

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("session.undo"), [["session_id": .string("runtime")]])
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4])
        XCTAssertEqual(chat.writes("slash.exec"), [], "never the host's own /undo")
    }

    func testARollbackThatRewindsTheNewestTurnReplacesTheTranscript() async throws {
        let file = Self.fixtures.appendingPathComponent("slash-commands.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("The source tree is not present (physical device or remote runner).") }
        let recorded = try JSONDecoder().decode(BotJSON.self, from: data)
        for canonical in [false, true] {
            let chat = await openChat(threeTurns, canonical: canonical)
            chat.host.always("rollback.list", .init(result: recorded["rollback.list"]))
            chat.host.next("rollback.restore", .init(result: recorded["rollback.restore whole tree, nothing rewound"]))
            chat.host.next("rollback.restore", .init(result: recorded["rollback.restore whole tree, rewound"]))
            chat.transcript.rows = Array(threeTurns.prefix(4))

            _ = await chat.model.runHermesSlashCommand("/rollback 1")
            _ = await chat.model.confirmHermesRollback(try XCTUnwrap(chat.model.pendingHermesRollback))
            XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4, 5, 6], "canonical: \(canonical)")

            _ = await chat.model.runHermesSlashCommand("/rollback 1")
            _ = await chat.model.confirmHermesRollback(try XCTUnwrap(chat.model.pendingHermesRollback))
            XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4], "canonical: \(canonical)")
        }
    }

    func testSendWaitsWhileAWholeTreeRollbackIsOut() async throws {
        let file = Self.fixtures.appendingPathComponent("slash-commands.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("The source tree is not present (physical device or remote runner).") }
        let recorded = try JSONDecoder().decode(BotJSON.self, from: data)
        let chat = await openChat(threeTurns, canonical: true)
        chat.host.always("rollback.list", .init(result: recorded["rollback.list"]))
        let restoring = expectation(description: "the restore is on the wire")
        chat.host.expect(restoring, onNext: "rollback.restore")
        chat.host.withhold("rollback.restore")

        _ = await chat.model.runHermesSlashCommand("/rollback 1")
        let request = try XCTUnwrap(chat.model.pendingHermesRollback)
        let restore = Task { await chat.model.confirmHermesRollback(request) }
        await fulfillment(of: [restoring], timeout: 2)

        XCTAssertTrue(chat.model.isUndoingExchange, "the composer holds Send")
        restore.cancel()
    }

    func testUndoTakesTheUndoneTurnsPlan() async {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Plan it")
        chat.transcript.rows = threeTurns + [row(7, "user", "Plan it"), row(8, "assistant", "Done.")]
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "todo.updated", ["revision": .number(1), "todos": .array([
            .object(["id": .string("a"), "content": .string("Read"), "status": .string("completed")])
        ])]))
        chat.receive(event(3, "message.complete", ["status": .string("complete"), "text": .string("Done.")]))
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        XCTAssertEqual(chat.model.hermesActivity?.settledPlan?.followsLastPrompt, true)

        chat.host.always("session.undo", .init(result: .object(["removed": .number(2)])))
        chat.transcript.rows = threeTurns
        let result = await chat.model.runHermesSlashCommand("/undo")

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.model.messages.last?.content, "Third answer.")
        XCTAssertNil(chat.model.hermesActivity?.settledPlan, "the plan went with its exchange")
    }

    func testAnUndoWhoseReadFailsHoldsSendUntilTheReattachShowsIt() async {
        let chat = await openChat(threeTurns)
        chat.host.always("session.undo", .init(result: .object(["removed": .number(2)])))
        chat.transcript.rows = Array(threeTurns.prefix(4))
        chat.transcript.failingReads = 1

        let result = await chat.model.runHermesSlashCommand("/undo")

        XCTAssertEqual(result, .notDelivered)
        XCTAssertTrue(chat.model.isHermesSubmissionUncertain)
        await waitUntil("reattached") { !chat.model.isHermesSubmissionUncertain }
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4])
        XCTAssertEqual(chat.writes("session.undo").count, 1)
    }

    func testASecondUndoIsRefusedWhileTheFirstIsOut() async {
        let chat = await openChat(threeTurns)
        chat.host.always("session.undo", .init(result: .object(["removed": .number(2)])))
        chat.transcript.rows = Array(threeTurns.prefix(4))

        let other = Task { await chat.model.runHermesSlashCommand("/undo") }
        let results = [await chat.model.runHermesSlashCommand("/undo"), await other.value]

        XCTAssertEqual(results.filter { $0 == .executed(message: nil) }.count, 1)
        XCTAssertEqual(results.filter { $0 == .notDelivered }.count, 1)
        XCTAssertEqual(chat.writes("session.undo").count, 1)
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 4])
    }

    func testRetryResendsTheHostsRawPromptOnceAtTheFailedPromptsRow() async throws {
        let chat = await openChat(threeTurns)
        try await failTurn(chat, prompt: "Fourth")
        XCTAssertEqual(chat.writes("prompt.submit").count, 1, "only the failed send went out")
        let messages = chat.model.messages.map(\.content)

        async let first: Void = chat.model.retryHermesFailedTurn()
        async let second: Void = chat.model.retryHermesFailedTurn()
        _ = await (first, second)

        XCTAssertEqual(chat.writes("prompt.submit").dropFirst().map { [$0["text"], $0["truncate_before_row_id"]] },
                       [[.string(Self.rawFailedPrompt), .number(7)]], "one retry, of the host's raw prompt")
        XCTAssertEqual(chat.model.messages.map(\.content), Array(messages.dropLast()) + ["Fourth"],
                       "the retried prompt takes the failed turn's place, its file as a chip")
        XCTAssertEqual(chat.model.messages.last?.attachments?.map(\.name), ["notes.txt"])
        XCTAssertNil(chat.model.hermesActivity?.failure, "the new turn clears the outcome")
        XCTAssertNotNil(chat.model.activeStreamID)
    }

    func testRetryAfterAFailureWithNoReceiptCutsAtThePromptTheHostSaved() async throws {
        let chat = await openChat(threeTurns)
        try await failTurn(chat, prompt: "Fourth", receipt: false)

        await chat.model.retryHermesFailedTurn()
        XCTAssertEqual(chat.writes("prompt.submit").dropFirst().map { [$0["text"], $0["truncate_before_row_id"]] },
                       [[.string(Self.rawFailedPrompt), .number(7)]])
    }

    func testRetryOfATurnWhosePromptTheChatNeverShowedKeepsTheEarlierExchange() async {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        chat.host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")]),
            "inflight": .object(["user": .string("Elsewhere"), "assistant": .string(""), "started_at": .number(1_790_000_009),
                                 "error": .string("HTTP 429"), "status": .string("error"), "recoverable": .bool(true),
                                 "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"),
                                                           "retryable": .bool(true)])])
        ])))
        chat.transcript.rows = threeTurns + [row(9, "user", "Elsewhere")]
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", [
            "status": .string("error"), "text": .string("HTTP 429"), "error": .string("HTTP 429"), "recoverable": .bool(true),
            "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"), "retryable": .bool(true)])
        ]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        await waitUntil("Retry offered") { chat.model.hermesActivity?.retryTarget != nil }
        let shown = chat.model.messages.map(\.content)
        XCTAssertEqual(shown, ["First", "First answer.", "Second", "Second answer.", "Third", "Third answer."])

        await chat.model.retryHermesFailedTurn()

        XCTAssertEqual(chat.writes("prompt.submit").map { [$0["text"], $0["truncate_before_row_id"]] },
                       [[.string("Elsewhere"), .number(9)]])
        XCTAssertEqual(chat.model.messages.map(\.content), shown + ["Elsewhere"], "the earlier exchange stays")
    }

    func testRetryOfALaterTurnThanTheChatsOwnKeepsItsPrompt() async {
        let chat = await openChat(threeTurns)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Fourth")
        chat.host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")]),
            "inflight": .object(["user": .string("Elsewhere"), "assistant": .string(""), "started_at": .number(1_790_000_009),
                                 "error": .string("HTTP 429"), "status": .string("error"), "recoverable": .bool(true),
                                 "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"),
                                                           "retryable": .bool(true)])])
        ])))
        chat.transcript.rows = threeTurns + [row(7, "user", "Fourth"), row(9, "user", "Elsewhere")]
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", [
            "status": .string("error"), "text": .string("HTTP 429"), "error": .string("HTTP 429"), "recoverable": .bool(true),
            "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"), "retryable": .bool(true)]),
            "persisted_turn": .object(["row_ids": .array([.number(7)]), "complete": .bool(false), "user_row_id": .number(7)])
        ]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        await waitUntil("Retry offered") { chat.model.hermesActivity?.retryTarget?.rowID == 9 }
        let shown = chat.model.messages.map(\.content)
        XCTAssertEqual(shown.last, "Fourth")

        await chat.model.retryHermesFailedTurn()

        XCTAssertEqual(chat.writes("prompt.submit").dropFirst().map { [$0["text"], $0["truncate_before_row_id"]] },
                       [[.string("Elsewhere"), .number(9)]])
        XCTAssertEqual(chat.model.messages.map(\.content), shown + ["Elsewhere"], "the chat's own prompt stays")
    }

    func testRetryOfAFailedSkillTurnLeavesOnePrompt() async throws {
        let chat = await openChat(threeTurns)
        await waitUntil("the catalog") { chat.model.hermesSlashCommands?.catalog.skills.isEmpty == false }
        chat.host.always("command.dispatch", .init(result: .object([
            "type": .string("skill"), "name": .string("demo-skill"), "message": .string(Self.skillPrompt),
            "display": .string("/demo-skill do it")
        ])))
        try await failTurn(chat, prompt: "/demo-skill do it", raw: Self.skillPrompt)
        let shown = chat.model.messages.map(\.content)
        XCTAssertEqual(shown.last, "/demo-skill do it")

        await chat.model.retryHermesFailedTurn()

        XCTAssertEqual(chat.writes("prompt.submit").dropFirst().map { [$0["text"], $0["truncate_before_row_id"]] },
                       [[.string(Self.skillPrompt), .number(7)]])
        XCTAssertEqual(chat.model.messages.dropLast().map(\.content), Array(shown.dropLast()), "the failed line gives way")
        XCTAssertEqual(chat.model.messages.filter { $0.role == "user" }.count, 4, "one prompt for the retried turn")
    }

    func testARetryRefusalSaysWhyAndA4018HidesRetry() async throws {
        let chat = await openChat(threeTurns)
        try await failTurn(chat, prompt: "Fourth")
        let messages = chat.model.messages

        chat.host.next("prompt.submit", .init(error: 4009, message: "session busy"))
        await chat.model.retryHermesFailedTurn()
        XCTAssertEqual(chat.model.sendErrorMessage, "Wait for the current reply to finish.")
        XCTAssertEqual(chat.model.messages, messages, "a busy host changed nothing")
        XCTAssertNotNil(chat.model.hermesActivity?.retryTarget, "Retry stays")

        chat.host.next("prompt.submit", .init(error: 4018, message: "target user message is no longer in session history"))
        let reads = HermesHostFixture.count("/api/sessions/tip/messages")
        await chat.model.retryHermesFailedTurn()
        XCTAssertEqual(chat.model.sendErrorMessage, "This message can’t be changed any more.")
        XCTAssertNil(chat.model.hermesActivity?.retryTarget, "the same cut would fail again")
        await waitUntil("reread") { chat.model.messages.last?.rowID == 7 }
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/tip/messages"), reads + 1, "the chat read the session again")
        XCTAssertNotNil(chat.model.hermesActivity?.failure, "the outcome stays; only Retry goes")
        XCTAssertNil(chat.model.hermesActivity?.retryTarget, "a reread does not bring it back")
        XCTAssertEqual(chat.writes("prompt.submit").count, 3)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/HermesAgent")
    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private var threeTurns: [BotJSON] {
        [row(1, "user", "First"), row(2, "assistant", "First answer."), row(3, "user", "Second"),
         row(4, "assistant", "Second answer."), row(5, "user", "Third"), row(6, "assistant", "Third answer.")]
    }

    private final class Transcript: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [BotJSON]
        private var failing = 0
        init(_ rows: [BotJSON]) { stored = rows }
        var rows: [BotJSON] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        var failingReads: Int {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }
        func takeFailure() -> Bool {
            lock.withLock {
                guard failing > 0 else { return false }
                failing -= 1
                return true
            }
        }
    }

    private struct Chat {
        let model: ChatViewModel
        let host: BotSocketHost
        let client: BotClient
        let transcript: Transcript

        @MainActor func receive(_ frame: BotJSON) { client.onEvent?(frame) }

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private func openChat(_ rows: [BotJSON], canonical: Bool = false) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: canonical ? .object([
            "session_id": .string("tip"), "stored_session_id": .string("tip"), "replay_epoch": .string("epoch"),
            "subscription_id": .string("sub-1"), "revision": .number(2), "execution_generation": .number(1),
            "running": .bool(false), "messages": .array([]), "pending": .array([]), "prompts": .array([]),
            "info": .object(["profile_name": .string("default")])
        ]) : .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("commands.catalog", .init(result: .object(["skills": .object(["/demo-skill": .object(["origin": .string("local")])])])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let client = BotClient(http: host.connection(Self.connection, canonical: canonical))
        let transcript = Transcript(rows)
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/sessions/tip/messages" else { return nil }
            if transcript.takeFailure() { return .json(502, .object(["detail": .string("Bad Gateway")])) }
            return .json(200, .object(["session_id": .string("tip"), "messages": .array(transcript.rows)]))
        }
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: .session(profile: "default", key: "tip"), wire: client,
                                        reconnectDelay: { _ in })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true }))
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, host: host, client: client, transcript: transcript)
    }

    private static let rawFailedPrompt = "Fourth\n\n@file:/a/notes.txt"
    private static let skillPrompt = "[IMPORTANT: The user has invoked the \"demo-skill\" skill.]\n\nSay hello.\n\n"
        + "The user has provided the following instruction alongside the skill invocation: do it"

    private func failTurn(_ chat: Chat, prompt: String, raw: String = rawFailedPrompt, receipt: Bool = true) async throws {
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        if prompt.hasPrefix("/") {
            _ = await chat.model.runHermesSlashCommand(prompt)
        } else {
            _ = await chat.model.sendMessage(prompt)
        }
        let failed = BotJSON.object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")]),
            "inflight": .object(["user": .string(raw), "assistant": .string(""), "started_at": .number(1_790_000_007),
                                 "error": .string("HTTP 429"), "status": .string("error"), "recoverable": .bool(true),
                                 "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"),
                                                           "retryable": .bool(true)])])
        ])
        chat.host.always("session.resume", .init(result: failed))
        chat.transcript.rows = threeTurns + [row(7, "user", raw)]
        chat.receive(event(1, "message.start"))
        var completion: [String: BotJSON] = [
            "status": .string("error"), "text": .string("HTTP 429"), "error": .string("HTTP 429"), "recoverable": .bool(true),
            "error_surface": .object(["layer": .string("provider"), "code": .string("rate_limit"), "retryable": .bool(true)])
        ]
        if receipt {
            completion["persisted_turn"] = .object(["row_ids": .array([.number(7)]), "complete": .bool(false), "user_row_id": .number(7)])
        }
        chat.receive(event(2, "message.complete", completion))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        await waitUntil("Retry offered") { chat.model.hermesActivity?.retryTarget != nil }
        XCTAssertTrue(chat.model.mayRetryHermesTurn)
    }

    private func canonicalMutation(_ name: String) throws -> BotJSON {
        let file = Self.fixtures.appendingPathComponent("canonical-mutations.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("The source tree is not present (physical device or remote runner).") }
        return try JSONDecoder().decode(BotJSON.self, from: data)["reply"][name]
    }

    private func context(_ chat: Chat, at index: Int) throws -> MessageActionContext {
        try XCTUnwrap(chat.model.actionContext(for: chat.model.messages[index], visibleIndex: index))
    }

    private func menu(_ chat: Chat, at index: Int) throws -> [ChatMessageActionItem.Kind] {
        ChatMessageActionMenu(
            context: try context(chat, at: index), listeningMessageID: nil, isViewingCachedData: false,
            hasActiveStream: false, isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
            onToggleListening: { _ in }, onRegenerate: { _ in }, onEdit: { _ in }, onFork: { _ in }, onCopy: { _ in }
        ).items.map(\.kind)
    }

    private func row(_ id: Int, _ role: String, _ content: String, active: Bool = true) -> BotJSON {
        .object(["id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role), "content": .string(content),
                 "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(active ? 1 : 0),
                 "compacted": .number(active ? 0 : 1)])
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:]) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }
}
