import XCTest
@testable import HermesMobile

final class CompressionAnchorResolverTests: XCTestCase {
    func testKeyWithoutSummaryOrMarkerShowsNoCard() {
        let messages = [
            makeMessage(role: "user", content: "Hello"),
            makeMessage(role: "assistant", content: "Hi"),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(key: key(role: "assistant", text: "Hi"))
        )

        XCTAssertNil(resolution)
    }

    func testLiteralCompactionMarkerReferenceTextSuppressesCard() {
        let messages = [
            makeMessage(role: "user", content: "Hello"),
            makeMessage(role: "assistant", content: "[Context compaction]\nOlder messages were summarized."),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(visibleIdx: 0, summary: "Older messages were summarized.")
        )

        XCTAssertNil(resolution)
    }

    func testSummaryNotContainedInMarkerFallsBackToSummaryText() {
        let messages = [
            makeMessage(role: "user", content: "Hello"),
            makeMessage(role: "assistant", content: "[Context compaction]\nAn unrelated earlier compaction."),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(visibleIdx: 0, summary: "A fresh summary of the conversation.")
        )

        XCTAssertEqual(resolution?.referenceText, "A fresh summary of the conversation.")
    }

    func testKeyMatchPlacesCardAfterAnchorMessage() {
        let messages = [
            makeMessage(role: "user", content: "Hello", ts: 1),
            makeMessage(role: "assistant", content: "Hi there", ts: 2),
            makeMessage(role: "user", content: "Next question", ts: 3),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(
                key: key(role: "assistant", ts: 2, text: "Hi there"),
                summary: "Compressed summary."
            )
        )

        XCTAssertEqual(resolution?.referenceText, "Compressed summary.")
        XCTAssertEqual(resolution?.placement, .afterLoadedMessageIndex(1))
    }

    func testKeyMatchPrefersLatestMatchingMessage() {
        let messages = [
            makeMessage(role: "user", content: "Same text"),
            makeMessage(role: "assistant", content: "Reply"),
            makeMessage(role: "user", content: "Same text"),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(key: key(role: "user", text: "Same text"), summary: "Summary.")
        )

        XCTAssertEqual(resolution?.placement, .afterLoadedMessageIndex(2))
    }

    func testKeyMatchesWhenEitherTimestampMissing() {
        let messages = [
            makeMessage(role: "user", content: "Hello", ts: 123),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(key: key(role: "user", ts: nil, text: "Hello"), summary: "Summary.")
        )

        XCTAssertEqual(resolution?.placement, .afterLoadedMessageIndex(0))
    }

    func testKeyTimestampMismatchPreventsMatch() {
        let messages = [
            makeMessage(role: "user", content: "Hello", ts: 123),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(key: key(role: "user", ts: 456, text: "Hello"), summary: "Summary.")
        )

        XCTAssertEqual(resolution?.placement, .top)
    }

    func testKeyMatchesWhitespaceNormalizedTruncatedText() {
        let longText = Array(repeating: "word", count: 60).joined(separator: "\n  ")
        let messages = [
            makeMessage(role: "user", content: longText),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(
                key: key(role: "user", text: CompressionAnchorResolver.normalizedAnchorText(longText)),
                summary: "Summary."
            )
        )

        XCTAssertEqual(resolution?.placement, .afterLoadedMessageIndex(0))
    }

    func testKeyMismatchFallsBackToVisibleIndex() {
        let messages = [
            makeMessage(role: "user", content: "First", ts: 1),
            makeMessage(role: "tool", content: "tool result", ts: 2),
            makeMessage(role: "assistant", content: "Second", ts: 3),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(
                visibleIdx: 1,
                key: key(role: "user", text: "Not in the transcript"),
                summary: "Summary."
            )
        )

        XCTAssertEqual(resolution?.placement, .afterLoadedMessageIndex(2))
    }

    func testIndexBeyondLoadedMessagesClampsToLastVisibleMessage() {
        let messages = [
            makeMessage(role: "user", content: "First"),
            makeMessage(role: "assistant", content: "Second"),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(visibleIdx: 99, summary: "Summary.")
        )

        XCTAssertEqual(resolution?.placement, .afterLoadedMessageIndex(1))
    }

    func testIndexPredatingLoadedTailWindowClampsToTop() {
        let messages = [
            makeMessage(role: "user", content: "Tail message"),
            makeMessage(role: "assistant", content: "Tail reply"),
        ]

        let resolution = resolve(
            messages: messages,
            messagesOffset: 40,
            metadata: metadata(visibleIdx: 5, summary: "Summary.")
        )

        XCTAssertEqual(resolution?.placement, .top)
    }

    func testIndexFallbackSkipsMarkerMessages() {
        let messages = [
            makeMessage(role: "user", content: "First"),
            makeMessage(
                role: "user",
                content: "[Your active task list was preserved across context compression]\n- task"
            ),
            makeMessage(role: "assistant", content: "Second"),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(visibleIdx: 1, summary: "Summary.")
        )

        XCTAssertEqual(resolution?.placement, .afterLoadedMessageIndex(2))
    }

    func testIndexWithNoVisibleMessagesPlacesCardAtTop() {
        let messages = [
            makeMessage(role: "tool", content: "tool result"),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(visibleIdx: 0, summary: "Summary.")
        )

        XCTAssertEqual(resolution?.placement, .top)
    }

    func testSummaryOnlyPlacesCardAtTop() {
        let messages = [
            makeMessage(role: "user", content: "Hello"),
        ]

        let resolution = resolve(
            messages: messages,
            metadata: metadata(summary: "Only a summary survived.")
        )

        XCTAssertEqual(resolution?.referenceText, "Only a summary survived.")
        XCTAssertEqual(resolution?.placement, .top)
    }

    func testWhitespaceOnlySummaryWithoutAnchorShowsNoCard() {
        let resolution = resolve(
            messages: [makeMessage(role: "user", content: "Hello")],
            metadata: metadata(summary: "   \n  ")
        )

        XCTAssertNil(resolution)
    }

    func testCardMapsAnchorIndexToOffsetAdjustedRenderID() {
        let messages = [
            makeMessage(role: "user", content: "Hello", messageId: "m0"),
            makeMessage(role: "assistant", content: "Hi there", messageId: "m1"),
            makeMessage(role: "user", content: "Next", messageId: "m2"),
        ]
        let transcript = ChatViewModel.transcriptMessages(from: messages, messageOffset: 10)

        let card = ChatViewModel.compressionReferenceCard(
            messages: messages,
            messagesOffset: 10,
            transcriptMessages: transcript,
            metadata: metadata(key: key(role: "assistant", text: "Hi there"), summary: "Summary.")
        )

        XCTAssertEqual(card?.afterRenderID, "transcript:11")
    }

    func testTopPlacementMapsToNilRenderID() {
        let messages = [
            makeMessage(role: "user", content: "Hello", messageId: "m0"),
        ]
        let transcript = ChatViewModel.transcriptMessages(from: messages, messageOffset: 0)

        let card = ChatViewModel.compressionReferenceCard(
            messages: messages,
            messagesOffset: 0,
            transcriptMessages: transcript,
            metadata: metadata(summary: "Only a summary.")
        )

        XCTAssertEqual(card?.referenceText, "Only a summary.")
        XCTAssertNil(card?.afterRenderID)
    }

    private func resolve(
        messages: [ChatMessage],
        messagesOffset: Int = 0,
        metadata: CompressionAnchorMetadata?
    ) -> CompressionAnchorResolver.Resolution? {
        CompressionAnchorResolver.resolve(
            messages: messages,
            messagesOffset: messagesOffset,
            metadata: metadata
        )
    }

    private func metadata(
        visibleIdx: Int? = nil,
        key: CompressionAnchorMessageKey? = nil,
        summary: String? = nil
    ) -> CompressionAnchorMetadata {
        CompressionAnchorMetadata(visibleIdx: visibleIdx, messageKey: key, summary: summary)
    }

    private func key(
        role: String?,
        ts: Double? = nil,
        text: String?,
        attachments: Int? = nil
    ) -> CompressionAnchorMessageKey {
        CompressionAnchorMessageKey(role: role, ts: ts, text: text, attachments: attachments)
    }

    private func makeMessage(
        role: String?,
        content: String?,
        ts: Double? = nil,
        messageId: String? = nil,
        attachments: [MessageAttachment]? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: role,
            content: content,
            timestamp: ts,
            messageId: messageId,
            attachments: attachments
        )
    }
}
