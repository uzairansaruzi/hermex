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
        activity.apply(type: "thinking.delta", payload: payload(["text": .bool(true)]))
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
        activity.apply(type: "reasoning.available", payload: payload(["text": .string("block")]))
        XCTAssertTrue(activity.reasoning.hasSuffix("END\nblock"))
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
}
