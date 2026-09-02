import XCTest
@testable import HermesMobile

/// Only transcript rows born in the last few seconds earn an entrance; cached
/// history, reloads, and reattached transcripts must render in place.
final class ChatTranscriptRowEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRowCreatedMomentsAgoIsFresh() {
        XCTAssertTrue(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970, now: now))
        XCTAssertTrue(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970 - 2.9, now: now))
    }

    func testRowOlderThanWindowIsNotFresh() {
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970 - 3, now: now))
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970 - 3_600, now: now))
    }

    func testServerClockRunningAheadDoesNotMakeHistoryFresh() {
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970 + 60, now: now))
    }

    func testMissingOrNonFiniteTimestampIsNeverFresh() {
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: nil, now: now))
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: .nan, now: now))
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: .infinity, now: now))
    }
}
