import XCTest
@testable import HermesMobile

final class ChatTranscriptRowEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRowOlderThanWindowIsNotFresh() {
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970 - 3, now: now))
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970 - 3_600, now: now))
    }

    func testServerClockRunningAheadDoesNotMakeHistoryFresh() {
        XCTAssertFalse(ChatTranscriptRowFreshness.isFresh(timestamp: now.timeIntervalSince1970 + 60, now: now))
    }

    func testReduceMotionTurnsTheToolRowEntranceOff() {
        XCTAssertFalse(ToolActivityEntrance.animatesNewestRow(isLive: true, isReplaying: false, reduceMotion: true))
    }

    func testToolRowsAReattachedStreamReplaysDrawInPlace() {
        XCTAssertFalse(ToolActivityEntrance.animatesNewestRow(isLive: true, isReplaying: true, reduceMotion: false))
    }
}
