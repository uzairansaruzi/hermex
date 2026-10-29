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
    }

    func testBatchReadsEveryExchangeAndHowTheWaitEnded() throws {
        let result = try XCTUnwrap(ClarifyResult(preview: batchPreview))

        XCTAssertEqual(result.exchanges.map(\.question), ["Which environment?", "Which checks should run?", "Branch name?"])
        XCTAssertEqual(result.exchanges.map(\.answers), [["Staging"], ["Lint", "Unit tests"], []])
        XCTAssertEqual(result.lines(toolCallID: "call-1").compactMap(\.note), ["The phone went offline."])
    }

    func testLegacyTimeoutSentinelReadsAsUnansweredTimeout() throws {
        let sentinel = try XCTUnwrap(String(data: JSONEncoder().encode(ClarifyResult.legacyTimeoutResponse), encoding: .utf8))
        for answer in [sentinel, "[\(sentinel)]"] {
            let result = try XCTUnwrap(ClarifyResult(
                preview: #"{"question":"Ship it?","choices_offered":["Yes","No"],"user_response":\#(answer)}"#
            ))
            XCTAssertEqual(result.exchanges, [ClarifyResult.Exchange(question: "Ship it?", answers: [])])
            XCTAssertTrue(result.timedOut)
        }
    }

    func testUnrecognizedResultsKeepTheGenericRow() {
        let previews = [
            #"{"error":"No question provided."}"#,
            #"{"responses":[{"question":"Which?","user_response":3}]}"#,
            #"{"responses":[]}"#,
            #"{"output":"done","exit_code":0}"#
        ]
        for preview in previews {
            let toolCall = ToolCall(name: "clarify", preview: preview, args: nil, isCompleted: true)
            XCTAssertNil(ToolCallSummaryFormatter.row(for: toolCall, isLive: false)?.clarify, preview)
        }

        let otherTool = ToolCall(name: "terminal", preview: batchPreview, args: nil, isCompleted: true)
        XCTAssertNil(ToolCallSummaryFormatter.row(for: otherTool, isLive: false)?.clarify)
    }
}
