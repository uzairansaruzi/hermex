import XCTest
@testable import HermesMobile

/// The chat column fills a phone and stops at a readable width on iPad and in
/// iPhone landscape.
final class ChatReadingWidthTests: XCTestCase {
    func testPhonePortraitKeepsTheViewportLessItsPadding() {
        XCTAssertEqual(ChatReadingWidth.contentWidth(viewportWidth: 393, horizontalPadding: 16), 361)
    }

    func testWideViewportsStopAtTheReadingWidth() {
        XCTAssertEqual(ChatReadingWidth.contentWidth(viewportWidth: 1_366, horizontalPadding: 16), 768)
        XCTAssertEqual(ChatReadingWidth.contentWidth(viewportWidth: 932, horizontalPadding: 16), 768)
    }

    func testAnEmptyViewportGivesAnEmptyColumn() {
        XCTAssertEqual(ChatReadingWidth.contentWidth(viewportWidth: 0, horizontalPadding: 16), 0)
    }

    func testAccessibilityPaddingIsHonoured() {
        XCTAssertEqual(ChatReadingWidth.contentWidth(viewportWidth: 393, horizontalPadding: 20), 353)
    }

    func testACappedComposerLinesUpWithTheCappedColumn() {
        // The composer keeps its own 16 pt side insets inside the cap.
        let composerWidth = min(1_366, ChatReadingWidth.maximumWidth(horizontalPadding: 16))

        XCTAssertEqual(composerWidth - 2 * 16, 768)
    }
}
