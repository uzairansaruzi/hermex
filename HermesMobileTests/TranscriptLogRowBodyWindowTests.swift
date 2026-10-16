import XCTest
@testable import HermesMobile

final class TranscriptLogRowBodyWindowTests: XCTestCase {
    private let cap = TranscriptLogRowMetrics.bodyWindowHeight

    func testUnmeasuredContentStartsClosed() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: nil, cap: cap)

        XCTAssertEqual(layout.frameHeight, 0)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentBelowTheCapTakesItsNaturalHeightWithoutScrolling() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: 96, cap: cap)

        XCTAssertEqual(layout.frameHeight, 96)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentAboveTheCapClipsToTheWindowAndScrolls() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: 1_800, cap: cap)

        XCTAssertEqual(layout.frameHeight, cap)
        XCTAssertTrue(layout.scrolls)
    }
}
