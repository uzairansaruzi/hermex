import XCTest
@testable import HermesMobile

final class ChatMarkerMessageClassifierTests: XCTestCase {
    // MARK: - Context compaction

    func testBracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "user", content: "[Context compaction] Summary of earlier conversation…")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testUnbracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "assistant", content: "Context compaction: the prior history was summarized.")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testToolRoleNeverMatches() {
        let message = makeMessage(role: "tool", content: "[context compaction] details")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNonMarkerTextStartingWithContextDoesNotMatch() {
        let message = makeMessage(role: "user", content: "Context windows are interesting — explain compaction.")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Preserved task list

    func testPreservedTaskListPrefixMatchesForUserRole() {
        let message = makeMessage(
            role: "user",
            content: "[Your active task list was preserved across context compression]\n1. Do the thing"
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .preservedTaskList)
    }

    func testPreservedTaskListPrefixDoesNotMatchNonUserRoles() {
        let message = makeMessage(
            role: "assistant",
            content: "[Your active task list was preserved across context compression] tasks"
        )
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Plain messages

    // MARK: - Card body

    func testCardBodyStripsPreservedTaskListMarker() {
        let body = ChatMarkerMessageClassifier.cardBody(
            for: .preservedTaskList,
            content: "[Your active task list was preserved across context compression]\n1. First task\n2. Second task"
        )
        XCTAssertEqual(body, "1. First task\n2. Second task")
    }

    // MARK: - Helpers

    private func makeMessage(role: String?, content: String?) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: nil, messageId: "test-id")
    }
}
