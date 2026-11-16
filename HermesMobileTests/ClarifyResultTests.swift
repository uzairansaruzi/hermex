import XCTest
@testable import HermesMobile

final class ClarifyResultTests: XCTestCase {
    /// The batch shape `tools/clarify_tool.py` returns at the pinned hermes-agent commit.
    private let batchPreview = """
    {"responses":[{"id":"env","question":"Which environment?","choices_offered":["Staging","Production"],"user_response":"Staging"},{"question":"Which checks should run?","choices_offered":["Lint","Unit tests","UI tests"],"user_response":["Lint","Unit tests"],"future_field":1},{"question":"Branch name?","choices_offered":null,"user_response":""}],"timed_out":true,"notice":"The phone went offline."}
    """

    func testAnsweredClarifyRowAndCopyReadAsQuestionAndAnswer() throws {
        let toolCall = ToolCall(
            name: "clarify",
            preview: batchPreview,
            args: ["questions": .array([.object(["question": .string("Which environment?")])])],
            isCompleted: true
        )

        let row = try XCTUnwrap(ToolCallSummaryFormatter.row(for: toolCall, isLive: false))
        let detail = try XCTUnwrap(row.detail)
        XCTAssertTrue(detail.contains("Which environment?"))
        XCTAssertTrue(detail.contains("Staging"))

        let copy = ToolCallSummaryFormatter.copyText(for: toolCall)
        XCTAssertTrue(copy.contains("Lint, Unit tests"))
        XCTAssertTrue(copy.contains("The phone went offline."))
        XCTAssertFalse(copy.contains("user_response"))
        XCTAssertFalse(copy.contains("?."), "A question's own mark ends it; no second period.")
    }

    func testBatchReadsEveryExchangeAndHowTheWaitEnded() throws {
        let result = try XCTUnwrap(ClarifyResult(preview: batchPreview))

        XCTAssertEqual(result.exchanges.map(\.question), ["Which environment?", "Which checks should run?", "Branch name?"])
        XCTAssertEqual(result.exchanges.map(\.answers), [["Staging"], ["Lint", "Unit tests"], []])
        XCTAssertEqual(result.lines(toolCallID: "call-1").compactMap(\.note), ["The phone went offline."])
    }

    func testFoldedTurnShowsEachAnswerOnceAndOnlyWhileFolded() {
        let groups = [ToolCallGroup(anchorMessageID: "a1", toolCalls: [
            ToolCall(id: "call-1", name: "clarify", preview: batchPreview, args: nil, isCompleted: true),
            ToolCall(id: "call-2", name: "terminal", preview: batchPreview, args: nil, isCompleted: true),
            ToolCall(
                id: "call-3",
                name: "clarify",
                preview: #"{"question":"Ship it?","choices_offered":null,"user_response":"Yes"}"#,
                args: nil,
                isCompleted: true
            )
        ])]
        let folded = TranscriptTurnFoldRowState(fold: nil, isExpanded: false, hidesBubble: false, hidesActivity: true)
        let expanded = TranscriptTurnFoldRowState(fold: nil, isExpanded: true, hidesBubble: false, hidesActivity: false)
        func lines(_ foldState: TranscriptTurnFoldRowState?, cardsOn: Bool = true) -> [String] {
            ChatTranscriptMessageBlock.foldedQuestionLines(
                in: groups,
                foldState: foldState,
                showsThinkingAndToolCards: cardsOn
            ).map(\.id)
        }

        XCTAssertEqual(lines(folded), ["call-1#0", "call-1#1", "call-1#2", "call-3#0"])
        // Expanded and unfolded rows draw the clarify rows instead; cards off shows neither.
        XCTAssertEqual(lines(expanded), [])
        XCTAssertEqual(lines(nil), [])
        XCTAssertEqual(lines(folded, cardsOn: false), [])
    }

    func testLegacyTimeoutSentinelReadsAsUnansweredTimeout() throws {
        // `TIMEOUT_RESPONSE` in `tools/clarify_tool.py` at the pinned hermes-agent commit.
        let sentinel = #""The user did not provide a response within the time limit. Use your best judgement to make the choice and proceed.""#
        for answer in [sentinel, "[\(sentinel)]"] {
            let result = try XCTUnwrap(ClarifyResult(
                preview: #"{"question":"Ship it?","choices_offered":["Yes","No"],"user_response":\#(answer)}"#
            ))
            XCTAssertEqual(result.exchanges, [ClarifyResult.Exchange(question: "Ship it?", answers: [])])
            XCTAssertTrue(result.timedOut)
        }
    }

    func testUnrecognizedResultsKeepTheGenericRow() throws {
        let previews = [
            #"{"error":"No question provided."}"#,
            #"{"responses":[{"question":"Which?","user_response":3}]}"#,
            #"{"responses":[]}"#,
            #"{"output":"done","exit_code":0}"#
        ]
        for preview in previews {
            let toolCall = ToolCall(name: "clarify", preview: preview, args: nil, isCompleted: true)
            let row = try XCTUnwrap(ToolCallSummaryFormatter.row(for: toolCall, isLive: false), preview)
            XCTAssertNil(row.clarify, preview)
        }

        let otherTool = ToolCall(name: "terminal", preview: batchPreview, args: nil, isCompleted: true)
        XCTAssertNil(try XCTUnwrap(ToolCallSummaryFormatter.row(for: otherTool, isLive: false)).clarify)
    }
}
