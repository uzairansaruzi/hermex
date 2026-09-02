import XCTest
@testable import HermesMobile

final class TranscriptLogRowBodyWindowTests: XCTestCase {
    private let cap = TranscriptLogRowMetrics.bodyWindowHeight

    func testUnmeasuredContentLeavesTheWindowFreeAndStill() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: nil, cap: cap)

        XCTAssertNil(layout.frameHeight)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentBelowTheCapTakesItsNaturalHeightWithoutScrolling() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: 96, cap: cap)

        XCTAssertEqual(layout.frameHeight, 96)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentAtTheCapFillsTheWindowWithoutScrolling() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: cap, cap: cap)

        XCTAssertEqual(layout.frameHeight, cap)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentAboveTheCapClipsToTheWindowAndScrolls() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: 1_800, cap: cap)

        XCTAssertEqual(layout.frameHeight, cap)
        XCTAssertTrue(layout.scrolls)
    }

    func testTheCapIsTwoHundredFortyPoints() {
        XCTAssertEqual(cap, 240)
    }
}
