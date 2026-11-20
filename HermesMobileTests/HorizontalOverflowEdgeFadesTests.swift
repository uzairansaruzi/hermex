import SwiftUI
import XCTest
@testable import HermesMobile

final class HorizontalOverflowEdgeFadesTests: XCTestCase {
    func testNoFadesWhenContentFits() {
        let fades = HorizontalOverflowEdgeFades(offset: 0, contentWidth: 300, viewportWidth: 320)

        XCTAssertFalse(fades.leading)
        XCTAssertFalse(fades.trailing)
    }

    func testOnlyTrailingFadeAtStartOfOverflowingContent() {
        let fades = HorizontalOverflowEdgeFades(offset: 0, contentWidth: 500, viewportWidth: 320)

        XCTAssertFalse(fades.leading)
        XCTAssertTrue(fades.trailing)
    }

    func testOnlyLeadingFadeAtEnd() {
        let fades = HorizontalOverflowEdgeFades(offset: 180, contentWidth: 500, viewportWidth: 320)

        XCTAssertTrue(fades.leading)
        XCTAssertFalse(fades.trailing)
    }

    func testRightToLeftFlipsRawOffset() {
        let atStart = HorizontalOverflowEdgeFades(
            offset: 180, contentWidth: 500, viewportWidth: 320, layoutDirection: .rightToLeft
        )
        let atEnd = HorizontalOverflowEdgeFades(
            offset: 0, contentWidth: 500, viewportWidth: 320, layoutDirection: .rightToLeft
        )

        XCTAssertFalse(atStart.leading)
        XCTAssertTrue(atStart.trailing)
        XCTAssertTrue(atEnd.leading)
        XCTAssertFalse(atEnd.trailing)
    }
}
