import XCTest
@testable import HermesMobile

final class BotActivityTests: XCTestCase {
    private func payload(_ pairs: [String: BotJSON]) -> BotJSON { .object(pairs) }

    func testToolLifecycleUpdatesTheSameRowWithoutDuplicates() {
        var activity = BotTurnActivity()
        XCTAssertTrue(activity.apply(type: "tool.start", payload: payload([
            "tool_id": .string("t1"), "name": .string("terminal"), "context": .string("git status"),
            "args": .object(["command": .string("git status")])
        ])))
        XCTAssertEqual(activity.toolCalls.map(\.isCompleted), [false])
        // A replayed start for the same id is idempotent.
        activity.apply(type: "tool.start", payload: payload(["tool_id": .string("t1"), "name": .string("terminal")]))
        XCTAssertEqual(activity.toolCalls.count, 1)
        activity.apply(type: "tool.complete", payload: payload([
            "tool_id": .string("t1"), "name": .string("terminal"), "duration_s": .number(1.5),
            "result": .object(["output": .string("clean"), "exit_code": .number(0)])
        ]))
        XCTAssertEqual(activity.toolCalls.count, 1)
        XCTAssertTrue(activity.toolCalls[0].isCompleted)
        XCTAssertEqual(activity.toolCalls[0].duration, 1.5)
        XCTAssertEqual(activity.toolCalls[0].args?["command"], .string("git status"))
        let row = ToolCallSummaryFormatter.row(for: activity.toolCalls[0], isLive: true)
        XCTAssertEqual(row?.status, .success)
        XCTAssertEqual(row?.detail, "git status")
    }

    func testErrorEnvelopeReadsAsFailureAndStringResultsStayText() {
        var activity = BotTurnActivity()
        activity.apply(type: "tool.complete", payload: payload([
            "tool_id": .string("t1"), "name": .string("read_file"), "result": .object(["error": .string("No such file")])
        ]))
        activity.apply(type: "tool.complete", payload: payload([
            "tool_id": .string("t2"), "name": .string("web_search"), "result": .string("plain text result")
        ]))
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: activity.toolCalls[0], isLive: false)?.status, .failure)
        XCTAssertEqual(activity.toolCalls[1].preview, "plain text result")
    }

    func testMissingAndUnknownFieldsAreTolerated() {
        var activity = BotTurnActivity()
        activity.apply(type: "tool.start", payload: .null)
        activity.apply(type: "tool.start", payload: payload(["name": .number(3), "args": .string("not an object")]))
        activity.apply(type: "tool.complete", payload: payload(["tool_id": .string("never-started"), "result": .null]))
        activity.apply(type: "reasoning.delta", payload: payload(["text": .bool(true)]))
        activity.apply(type: "notification.show", payload: payload(["level": .string("info")]))
        activity.apply(type: "notification.clear", payload: .array([]))
        activity.apply(type: "review.summary", payload: payload(["text": .string("   ")]))
        XCTAssertFalse(activity.apply(type: "moa.reference", payload: payload(["text": .string("ignored")])))
        XCTAssertEqual(activity.toolCalls.count, 3)
        XCTAssertEqual(Set(activity.toolCalls.map(\.id)).count, 3, "generated ids stay unique")
        XCTAssertTrue(activity.toolCalls[2].isCompleted)
        XCTAssertEqual(activity.reasoning, "")
        XCTAssertTrue(activity.notices.isEmpty)
        XCTAssertTrue(activity.memoryNotes.isEmpty)
    }

    func testBoundsDropOldestToolsAndKeepReasoningTail() {
        var activity = BotTurnActivity()
        for index in 0..<(BotTurnActivity.toolLimit + 10) {
            activity.apply(type: "tool.start", payload: payload(["tool_id": .string("t\(index)"), "name": .string("terminal")]))
        }
        XCTAssertEqual(activity.toolCalls.count, BotTurnActivity.toolLimit)
        XCTAssertEqual(activity.toolCalls.first?.id, "t10")
        for _ in 0..<40 {
            activity.apply(type: "reasoning.delta", payload: payload(["text": .string(String(repeating: "a", count: 1_000))]))
        }
        activity.apply(type: "reasoning.delta", payload: payload(["text": .string("END")]))
        XCTAssertEqual(activity.reasoning.count, BotTurnActivity.reasoningLimit)
        XCTAssertTrue(activity.reasoning.hasSuffix("END"))
        // Neither is reasoning: spinner text, and a block that carried the answer.
        XCTAssertFalse(activity.apply(type: "thinking.delta", payload: payload(["text": .string("pondering")])))
        XCTAssertFalse(activity.apply(type: "reasoning.available", payload: payload(["text": .string("block")])))
        XCTAssertTrue(activity.reasoning.hasSuffix("END"))
        activity.clearTurnWork()
        XCTAssertFalse(activity.hasTurnWork)
    }

    func testNoticesReplaceByKeyClearByKeyAndMemoryNotesAccumulate() {
        var activity = BotTurnActivity()
        activity.apply(type: "notification.show", payload: payload(["key": .string("credits"), "text": .string("Low credits"), "level": .string("warn")]))
        activity.apply(type: "notification.show", payload: payload(["key": .string("credits"), "text": .string("Credits restored"), "level": .string("success")]))
        activity.apply(type: "notification.show", payload: payload(["id": .string("agent"), "text": .string("Still starting")]))
        XCTAssertEqual(activity.notices.map(\.text), ["Credits restored", "Still starting"])
        XCTAssertFalse(activity.notices[0].isWarning)
        activity.apply(type: "notification.clear", payload: payload(["key": .string("agent")]))
        XCTAssertEqual(activity.notices.map(\.id), ["credits"])
        for index in 0..<(BotTurnActivity.noticeLimit + 2) {
            activity.apply(type: "review.summary", payload: payload(["text": .string("note \(index)")]))
        }
        XCTAssertEqual(activity.memoryNotes.count, BotTurnActivity.noticeLimit)
        XCTAssertEqual(activity.memoryNotes.first, "note 2")
    }

    func testPlanParsesTolerantlyAndSkipsMalformedItems() {
        let plan = BotPlan(payload([
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
        XCTAssertNil(BotPlan(payload(["revision": .number(1), "todos": .array([])])))
        XCTAssertNil(BotPlan(payload(["todos": .string("nope")])))
        XCTAssertNil(BotPlan(.null))
    }

    func testSnapshotProjectionAnchorsWorkToTheMessageItPrecedesWithStableIDs() {
        let history: [BotJSON] = [
            .object(["role": .string("user"), "text": .string("Clear the inbox")]),
            .object(["role": .string("assistant"), "reasoning": .string("Archive first")]),
            .object(["role": .string("tool"), "name": .string("terminal"), "context": .string("himalaya move"), "args": .object(["command": .string("himalaya move")])]),
            .object(["role": .string("tool"), "name": .string("write_file"), "context": .string("draft.md")]),
            .object(["role": .string("assistant"), "text": .string("Archived 14 newsletters."), "reasoning_content": .string("Done")]),
            .object(["role": .string("system"), "text": .string("hidden")]),
            .object(["role": .string("tool"), "name": .string("read_file")]),
            .object(["role": .string("mystery"), "text": .string("dropped")])
        ]
        let projected = BotTranscriptProjection.project(history: history, root: "root")
        XCTAssertEqual(projected.messages.map(\.messageId), ["root/0", "root/4"])
        XCTAssertEqual(projected.messages.map(\.content), ["Clear the inbox", "Archived 14 newsletters."])
        XCTAssertEqual(projected.activity.map(\.id), ["root/1/activity", "root/6/activity"])
        XCTAssertEqual(projected.activity[0].anchorMessageID, "root/4")
        XCTAssertEqual(projected.activity[0].reasoning, "Archive first\n\nDone")
        XCTAssertEqual(projected.activity[0].toolCalls.map(\.name), ["terminal", "write_file"])
        XCTAssertEqual(projected.activity[0].toolCalls.map(\.id), ["root/2", "root/3"])
        XCTAssertTrue(projected.activity[0].toolCalls.allSatisfy(\.isCompleted))
        XCTAssertNil(projected.activity[1].anchorMessageID, "work after the last reply renders at the end")
        XCTAssertEqual(ToolCallSummaryFormatter.row(for: projected.activity[0].toolCalls[1], isLive: false)?.detail, "draft.md")
    }

    func testSnapshotProjectionKeepsTimestampsInSecondsAndDropsNonNumbers() {
        let projected = BotTranscriptProjection.project(history: [
            .object(["role": .string("user"), "text": .string("Ping"), "timestamp": .number(1_790_251_200.5)]),
            .object(["role": .string("assistant"), "text": .string("Pong"), "timestamp": .string("1790251260")]),
            .object(["role": .string("assistant"), "text": .string("Later")])
        ], root: "root")
        XCTAssertEqual(projected.messages.map(\.timestamp), [1_790_251_200.5, nil, nil])
    }

    func testSnapshotProjectionCarriesTheHostRowIDAndDropsNonIntegers() {
        let projected = BotTranscriptProjection.project(history: [
            .object(["role": .string("user"), "text": .string("Ping"), "row_id": .number(41)]),
            .object(["role": .string("assistant"), "text": .string("Pong"), "row_id": .string("42")]),
            .object(["role": .string("assistant"), "text": .string("Later"), "row_id": .number(43.5)]),
            .object(["role": .string("assistant"), "text": .string("Legacy")])
        ], root: "root")
        XCTAssertEqual(projected.messages.map(\.rowID), [41, nil, nil, nil])
    }

    func testReactionsParseTolerantlyOnePerAuthor() {
        let projected = BotTranscriptProjection.project(history: [
            .object(["role": .string("assistant"), "text": .string("Done"), "row_id": .number(7),
                     "display_metadata": .object(["reactions": .array([
                        .string("❤️"),
                        .object(["emoji": .string(""), "author": .string("user")]),
                        .object(["emoji": .string("👍"), "author": .string("stranger")]),
                        .object(["emoji": .number(1), "author": .string("user")]),
                        .object(["emoji": .string("👍"), "author": .string("user"), "at": .number(1), "seen": .bool(true)]),
                        .object(["emoji": .string("😂"), "author": .string("user")]),
                        .object(["emoji": .string("‼️"), "author": .string("agent"), "future": .null])
                     ])])])
        ], root: "root")
        XCTAssertEqual(projected.messages.first?.botReactions, [
            BotReaction(emoji: "👍", author: .user), BotReaction(emoji: "‼️", author: .agent)
        ])
        XCTAssertEqual(ChatMessage(role: "user", content: "x", timestamp: nil, messageId: "m").botReactions, [])
    }

    func testReplacingReactionsKeepsOtherMetadataAndAnEmptyListRemovesTheKey() {
        let message = ChatMessage(role: "assistant", content: "Done", timestamp: 5, messageId: "root/1",
                                  displayMetadata: ["delivery": .string("async")], rowID: 7)
        let reacted = message.replacingBotReactions(.array([.object(["emoji": .string("❤️"), "author": .string("user")])]))
        XCTAssertEqual(reacted.botReactions, [BotReaction(emoji: "❤️", author: .user)])
        XCTAssertEqual(reacted.displayMetadata?["delivery"], .string("async"))
        XCTAssertEqual(reacted.rowID, 7)
        XCTAssertEqual(reacted.id, message.id)

        let cleared = reacted.replacingBotReactions(.array([]))
        XCTAssertEqual(cleared.displayMetadata, ["delivery": .string("async")])
        XCTAssertEqual(cleared.botReactions, [])
    }

    func testSnapshotProjectionUsesTypedDelegationDeliveryInsteadOfUserAuthorship() throws {
        let report = "[ASYNC DELEGATION BATCH COMPLETE — deleg_123]\nFull worker report"
        let projected = BotTranscriptProjection.project(history: [
            .object([
                "role": .string("user"),
                "text": .string(report),
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .object([
                    "delegation_id": .string("deleg_123"),
                    "task_count": .number(2),
                    "completed_count": .number(2),
                    "failed_count": .number(0),
                    "duration_seconds": .number(8.48),
                    "future": .object(["field": .bool(true)])
                ])
            ]),
            .object(["role": .string("user"), "text": .string(report)])
        ], root: "root")

        XCTAssertEqual(projected.messages.map(\.role), ["delegation_completion", "user"])
        XCTAssertEqual(projected.messages.map(\.content), [report, report],
                       "the card keeps the server report intact and prefix-like user text stays user-authored")
        let delivery = try XCTUnwrap(projected.messages.first)
        XCTAssertEqual(delivery.displayKind, BotDelegationCompletion.displayKind)
        XCTAssertEqual(delivery.displayMetadata?["delegation_id"], .string("deleg_123"))

        let completion = try XCTUnwrap(BotDelegationCompletion(delivery))
        XCTAssertEqual(completion.delegationID, "deleg_123")
        XCTAssertEqual(completion.taskCount, 2)
        XCTAssertEqual(completion.completedCount, 2)
        XCTAssertEqual(completion.failedCount, 0)
        XCTAssertEqual(completion.durationSeconds, 8.48)
        XCTAssertEqual(completion.report, report)
    }

    // MARK: - Fold Finished Turns

    private func row(_ role: String, _ text: String? = nil, reasoning: String? = nil, at timestamp: Double? = nil,
                     kind: String? = nil) -> BotJSON {
        var fields: [String: BotJSON] = ["role": .string(role)]
        if let text { fields["text"] = .string(text) }
        if let kind { fields["display_kind"] = .string(kind) }
        if let reasoning { fields["reasoning"] = .string(reasoning) }
        if let timestamp { fields["timestamp"] = .number(timestamp) }
        return .object(fields)
    }

    /// user → interim reply with reasoning → tool → interim reply → tool → final reply.
    private func workedTurn(from start: Double? = 100) -> [BotJSON] {
        [row("user", "Clean the inbox", at: start),
         row("assistant", "Looking now", reasoning: "Plan the sweep", at: start.map { $0 + 10 }),
         row("tool"),
         row("assistant", "Halfway there", at: start.map { $0 + 20 }),
         row("tool"),
         row("assistant", "Archived 14.", at: start.map { $0 + 42 })]
    }

    private func folds(_ history: [BotJSON], windowStart: Int = 0, showsCards: Bool = true, foldsTurns: Bool = true,
                       isStreaming: Bool = false, hasLivePrompt: Bool = false) -> (TranscriptTurnFolds, [ChatMessage]) {
        let projected = BotTranscriptProjection.project(history: history, root: "r")
        let byAnchor = Dictionary(grouping: projected.activity, by: \.anchorMessageID)
        let folds = BotTranscriptProjection.turnFolds(
            messages: projected.messages, windowStart: windowStart, activityByAnchor: byAnchor,
            showsCards: showsCards, foldsTurns: foldsTurns, isStreaming: isStreaming, hasLivePrompt: hasLivePrompt
        )
        return (folds, projected.messages)
    }

    func testSettledTurnFoldsItsWorkAndInterimReplyBehindTheElapsedRow() throws {
        let (folds, _) = folds(workedTurn())
        let fold = try XCTUnwrap(folds.folds.first)
        XCTAssertEqual(folds.folds.count, 1)
        XCTAssertEqual(fold.hostRenderID, "r/1", "the row draws above the first reply's reasoning")
        XCTAssertEqual(fold.label, .worked(elapsed: ChatWorkingElapsedFormatter.label(seconds: 42)))

        let first = folds.rowState(for: "r/1", expandedTurnKeys: [])
        XCTAssertEqual(first?.fold, fold)
        XCTAssertEqual(first?.hidesActivity, true)
        XCTAssertEqual(first?.hidesBubble, false, "the first reply stays visible")
        XCTAssertEqual(folds.rowState(for: "r/3", expandedTurnKeys: [])?.hidesBubble, true, "the interim reply folds")
        let last = folds.rowState(for: "r/5", expandedTurnKeys: [])
        XCTAssertEqual(last?.hidesBubble, false, "the final reply stays visible")
        XCTAssertEqual(last?.hidesActivity, true, "the tools before it fold")
        XCTAssertNil(folds.rowState(for: "r/0", expandedTurnKeys: []), "the prompt is never folded")

        let open = folds.rowState(for: "r/3", expandedTurnKeys: [fold.turnKey])
        XCTAssertEqual(open?.isExpanded, true)
        XCTAssertEqual(open?.hidesBubble, false)
    }

    func testTurnWithoutTimestampsReadsWorked() {
        let (folds, _) = folds(workedTurn(from: nil))
        XCTAssertEqual(folds.folds.map(\.label), [.worked(elapsed: nil)])
    }

    func testPreviousTurnStaysFoldedWhileThePromptIsOnlyLiveAndTheSettledRunningTurnStaysOpen() {
        let (whileLive, _) = folds(workedTurn(), isStreaming: true, hasLivePrompt: true)
        XCTAssertEqual(whileLive.folds.map(\.turnKey), ["turn:user:0"], "the finished turn folds while the next prompt is only live")

        let running = workedTurn() + [row("user", "Now the drafts", at: 200)] + workedTurn(from: 210).dropFirst()
        let (settled, _) = folds(running, isStreaming: true)
        XCTAssertEqual(settled.folds.map(\.turnKey), ["turn:user:0"], "the running turn in messages stays open")
        let (finished, _) = folds(running)
        XCTAssertEqual(finished.folds.map(\.turnKey), ["turn:user:0", "turn:user:4"], "keys count messages, not tool rows")
    }

    func testMixedSnapshotWhileRunningKeepsTheCurrentTurnOpen() {
        // The host persisted the prompt, a reasoning-only step and an interim reply mid-turn.
        let history = workedTurn() + [row("user", "Now the drafts", at: 200),
                                      row("assistant", "", reasoning: "Find drafts", at: 205),
                                      row("tool"),
                                      row("assistant", "Checking drafts", reasoning: "Two left", at: 210)]
        let (folds, _) = folds(history, isStreaming: true)
        XCTAssertEqual(folds.folds.map(\.turnKey), ["turn:user:0"])
        XCTAssertNil(folds.rowState(for: "r/7", expandedTurnKeys: []))
        XCTAssertNil(folds.rowState(for: "r/9", expandedTurnKeys: []))
    }

    func testRunningSlashSkillOrDelegationTurnStaysOpen() {
        // A skill turn's row shows its invocation and a delivery projects as a
        // card, so neither matches the in-flight text; the model still names the
        // row by the turn clock, so no prompt is only live and the turn stays open.
        let skill = workedTurn() + [row("user", "/work fix the leak", at: 210, kind: "skill_invocation")]
            + workedTurn(from: 210).dropFirst()
        let delivery = workedTurn() + [row("user", "Report", at: 210, kind: BotDelegationCompletion.displayKind)]
            + workedTurn(from: 210).dropFirst()
        for history in [skill, delivery] {
            let (folds, messages) = folds(history, isStreaming: true)
            XCTAssertEqual(folds.folds.map(\.turnKey), ["turn:user:0"], "only the finished turn folds")
            for message in messages[4...] { XCTAssertNil(folds.rowState(for: message.id, expandedTurnKeys: [])) }
        }
    }

    func testDelegationDeliveryOpensItsOwnTurnTimedFromTheDelivery() throws {
        let kind = BotDelegationCompletion.displayKind
        let history = [row("user", "Research X", at: 1000), row("assistant", "Delegated", at: 1010),
                       row("user", "Report 1", at: 5000, kind: kind),
                       row("assistant", "Reading", reasoning: "Scan it", at: 5005), row("tool"),
                       row("assistant", "Findings 1", at: 5010),
                       row("user", "Report 2", at: 9000, kind: kind), row("assistant", "Findings 2", at: 9005)]
        let (folds, messages) = folds(history)
        XCTAssertEqual(messages.map(\.id), ["r/0", "r/1", "r/2", "r/3", "r/5", "r/6", "r/7"])
        let fold = try XCTUnwrap(folds.folds.first)
        XCTAssertEqual(folds.folds.count, 1, "each delivery's answer is its own turn")
        XCTAssertEqual(fold.turnKey, "turn:user:2")
        XCTAssertEqual(fold.label, .worked(elapsed: ChatWorkingElapsedFormatter.label(seconds: 10)),
                       "timed from the delivery, not across the delegation wait")
        for id in ["r/1", "r/3", "r/5", "r/7"] {
            XCTAssertNotEqual(folds.rowState(for: id, expandedTurnKeys: [])?.hidesBubble, true, "\(id) stays visible")
        }
        XCTAssertNil(folds.rowState(for: "r/2", expandedTurnKeys: []), "the delivery card never folds")
    }

    func testLoadEarlierFindsTheTurnThatWouldHideTheFirstShownReply() throws {
        // The window starts at the interim reply: the partial turn keeps it visible
        // until widening brings its prompt in and folds it.
        let history = workedTurn() + workedTurn(from: 200)
        let interim = "r/9"
        let (before, messages) = folds(history, windowStart: 6)
        XCTAssertEqual(messages[6].id, interim)
        XCTAssertNotEqual(before.rowState(for: interim, expandedTurnKeys: [])?.hidesBubble, true)

        let (after, _) = folds(history, windowStart: 0)
        XCTAssertEqual(after.rowState(for: interim, expandedTurnKeys: [])?.hidesBubble, true)
        let turnKey = try XCTUnwrap(BotTranscriptProjection.turnKey(of: interim, messages: messages, windowStart: 0))
        XCTAssertEqual(turnKey, "turn:user:4")
        XCTAssertEqual(after.rowState(for: interim, expandedTurnKeys: [turnKey])?.hidesBubble, false,
                       "opening that turn keeps the reader's reply built")
    }

    func testActivityAnchoredToAUserRowOrAfterTheLastMessageNeverFolds() {
        // A turn that ended in tools anchors them to the next prompt, or after the last message.
        let history = [row("user", "Run it", at: 100), row("tool"),
                       row("user", "And again", at: 200), row("tool")]
        let (folds, messages) = folds(history)
        XCTAssertTrue(folds.folds.isEmpty)
        for message in messages { XCTAssertNil(folds.rowState(for: message.id, expandedTurnKeys: [])) }
    }

    func testCardsOffFoldsOnlyInterimRepliesAndLeavesActivityOnlyTurnsAlone() {
        let (cardsOff, _) = folds(workedTurn(), showsCards: false)
        XCTAssertEqual(cardsOff.folds.count, 1)
        XCTAssertEqual(cardsOff.folds.first?.hostRenderID, "r/3", "only the interim reply has something to hide")
        XCTAssertEqual(cardsOff.rowState(for: "r/1", expandedTurnKeys: [])?.hidesActivity, false)

        let activityOnly = [row("user", "Clean the inbox", at: 100),
                            row("assistant", "Looking now", reasoning: "Plan", at: 110),
                            row("tool"), row("assistant", "Archived 14.", at: 142)]
        XCTAssertEqual(folds(activityOnly).0.folds.count, 1)
        XCTAssertTrue(folds(activityOnly, showsCards: false).0.folds.isEmpty)
    }

    func testFoldFinishedTurnsOffFoldsNothing() {
        XCTAssertTrue(folds(workedTurn(), foldsTurns: false).0.folds.isEmpty)
    }

    func testWindowOffsetKeepsTurnKeysAbsolute() {
        let history = workedTurn() + workedTurn(from: 200) + workedTurn(from: 300)
        let whole = folds(history).0.folds
        // Four messages per turn: tool rows are activity, not messages.
        let windowed = folds(history, windowStart: 4).0.folds
        XCTAssertEqual(windowed.map(\.turnKey), ["turn:user:4", "turn:user:8"])
        XCTAssertEqual(Array(whole.suffix(2)), windowed, "Load earlier keeps expanded turns expanded")
    }
}
