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

    // MARK: - Gap separators

    func testGapStartsAtExactlyThirtyMinutesButNotOneSecondSooner() {
        let starts = TranscriptTimeline.gapStarts([
            (id: "a", timestamp: 1_000),
            (id: "b", timestamp: 1_000 + 1_799),
            (id: "c", timestamp: 1_000 + 1_799 + 1_800)
        ])
        XCTAssertEqual(starts, ["a", "c"], "the first row dates the window; 29:59 is no gap, 30:00 is")
    }

    func testRowsWithoutTimestampsNeverStartAGapAndAreSkippedAsPrevious() {
        let starts = TranscriptTimeline.gapStarts([
            (id: "tool", timestamp: nil),
            (id: "zero", timestamp: 0),
            (id: "first", timestamp: 5_000),
            (id: "unstamped", timestamp: nil),
            (id: "near", timestamp: 5_000 + 1_000),
            (id: "nan", timestamp: .nan),
            (id: "late", timestamp: 5_000 + 1_000 + 1_800)
        ])
        XCTAssertEqual(starts, ["first", "late"])
        XCTAssertTrue(TranscriptTimeline.gapStarts([(id: 1, timestamp: nil)]).isEmpty)
    }

    func testSeparatorNamesTodayAndYesterdayRelatively() throws {
        // Relative day names read the real clock, so "now" is the real date here.
        let now = Date()
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let english = Locale(identifier: "en_US")
        let today = try XCTUnwrap(separator(now.timeIntervalSince1970, now: now, locale: english, timeZone: utc))
        let yesterday = try XCTUnwrap(separator(now.timeIntervalSince1970 - 86_400, now: now, locale: english, timeZone: utc))
        XCTAssertTrue(today.hasPrefix("Today"), today)
        XCTAssertTrue(yesterday.hasPrefix("Yesterday"), yesterday)
        XCTAssertTrue(today.contains(ChatMessageTimestampFormatter.shortTime(
            forUnixTimestamp: now.timeIntervalSince1970, locale: english, timeZone: utc
        ) ?? "-"), today)
        let german = try XCTUnwrap(separator(now.timeIntervalSince1970, now: now, locale: Locale(identifier: "de_DE"), timeZone: utc))
        XCTAssertTrue(german.hasPrefix("Heute"), german)
    }

    func testSeparatorUsesAWeekdayWithinTheWeekThenADate() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let english = Locale(identifier: "en_US")
        // Thursday 24 September 2026, 12:00 UTC.
        let now = Date(timeIntervalSince1970: 1_790_251_200)
        let monday = now.timeIntervalSince1970 - 3 * 86_400 + 4 * 3_600 + 24 * 60
        let lastWeek = now.timeIntervalSince1970 - 7 * 86_400
        let lastYear = now.timeIntervalSince1970 - 365 * 86_400

        XCTAssertEqual(separator(monday, now: now, locale: english, timeZone: utc), "Monday 4:24\u{202F}PM")
        let sameYear = try XCTUnwrap(separator(lastWeek, now: now, locale: english, timeZone: utc))
        XCTAssertTrue(sameYear.hasPrefix("Sep 17"), sameYear)
        XCTAssertFalse(sameYear.contains("2026"), sameYear)
        let otherYear = try XCTUnwrap(separator(lastYear, now: now, locale: english, timeZone: utc))
        XCTAssertTrue(otherYear.contains("2025"), otherYear)
        XCTAssertNil(separator(nil, now: now, locale: english, timeZone: utc))
    }

    // MARK: - Helpers

    private func separator(_ timestamp: Double?, now: Date, locale: Locale, timeZone: TimeZone) -> String? {
        ChatMessageTimestampFormatter.separator(forUnixTimestamp: timestamp, now: now, locale: locale, timeZone: timeZone)
    }

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
