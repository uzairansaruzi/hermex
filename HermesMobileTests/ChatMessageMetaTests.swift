import XCTest
@testable import HermesMobile

final class ChatMessageMetaTests: XCTestCase {
    func testOnlyTheLastReplyOfASettledTurnIsTerminal() {
        let messages = [
            user("u1"),
            assistant("a1", text: "Looking."),
            assistant("a2", text: "Still looking."),
            assistant("a3", text: "Done.")
        ]

        XCTAssertEqual(terminalIDs(messages), ["transcript:3"])
    }

    func testActivityOnlyShellAfterTheReplyDoesNotTakeTerminal() {
        let messages = [
            user("u1"),
            assistant("a1", text: "Done."),
            assistant("a2", text: nil)
        ]

        XCTAssertEqual(terminalIDs(messages), ["transcript:1"])
    }

    func testTheTurnBeingAnsweredHasNoTerminalReplyWhileItStreams() {
        let messages = [
            user("u1"),
            assistant("a1", text: "First answer."),
            user("u2"),
            assistant("a2", text: "Partial")
        ]

        XCTAssertEqual(
            terminalIDs(messages, isStreamActive: true, streamingAssistantMessageID: "a2"),
            ["transcript:1"]
        )
        XCTAssertEqual(terminalIDs(messages), ["transcript:1", "transcript:3"])
    }

    func testTurnHoldingTheStreamingMessageIsNotTerminal() {
        let messages = [
            user("u1"),
            assistant("a1", text: "Regenerating"),
            user("u2"),
            assistant("a2", text: "Second answer.")
        ]

        XCTAssertEqual(
            terminalIDs(messages, isStreamActive: true, streamingAssistantMessageID: "a1"),
            []
        )
    }

    func testRepliesBeforeTheFirstUserBoundaryFormTheirOwnTurn() {
        let messages = [
            assistant("a0", text: "Earlier page tail."),
            user("u1"),
            assistant("a1", text: "Done.")
        ]

        XCTAssertEqual(terminalIDs(messages), ["transcript:0", "transcript:2"])
    }

    func testRenderIDsFollowPagedOffsets() {
        let messages = [
            user("u1"),
            assistant("a1", text: "Done.")
        ]

        XCTAssertEqual(terminalIDs(messages, messageOffset: 40), ["transcript:41"])
    }

    // MARK: - Helpers

    private func terminalIDs(
        _ messages: [ChatMessage],
        messageOffset: Int? = nil,
        isStreamActive: Bool = false,
        streamingAssistantMessageID: String? = nil
    ) -> Set<String> {
        let transcript = ChatViewModel.transcriptMessages(
            from: messages,
            messageOffset: messageOffset,
            renderedActivityAnchorIDs: []
        )
        return TranscriptMessageMetaPolicy.terminalReplyRenderIDs(
            transcriptMessages: transcript,
            messages: messages,
            messageOffset: messageOffset,
            rendersBubble: { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false },
            isStreamActive: isStreamActive,
            streamingAssistantMessageID: streamingAssistantMessageID
        )
    }

    private func user(_ id: String) -> ChatMessage {
        ChatMessage(role: "user", content: "Do the thing", timestamp: 100, messageId: id)
    }

    private func assistant(_ id: String, text: String?) -> ChatMessage {
        ChatMessage(role: "assistant", content: text, timestamp: 110, messageId: id)
    }
}
