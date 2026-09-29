import SwiftUI
import XCTest
@testable import HermesMobile

/// The shared edge-fade rule behind the composer toolbar and wide markdown
/// tables: an edge fades only while it hides content.
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

    func testBothFadesMidScroll() {
        let fades = HorizontalOverflowEdgeFades(offset: 90, contentWidth: 500, viewportWidth: 320)

        XCTAssertTrue(fades.leading)
        XCTAssertTrue(fades.trailing)
    }

    func testOnlyLeadingFadeAtEnd() {
        let fades = HorizontalOverflowEdgeFades(offset: 180, contentWidth: 500, viewportWidth: 320)

        XCTAssertTrue(fades.leading)
        XCTAssertFalse(fades.trailing)
    }

    func testEdgesWithinEpsilonCountAsReached() {
        let nearStart = HorizontalOverflowEdgeFades(offset: 3, contentWidth: 500, viewportWidth: 320)
        let nearEnd = HorizontalOverflowEdgeFades(offset: 177, contentWidth: 500, viewportWidth: 320)

        XCTAssertFalse(nearStart.leading)
        XCTAssertFalse(nearEnd.trailing)
    }

    func testRightToLeftFlipsRawOffset() {
        // Raw offset 0 in RTL shows the visual start of the content (its right end),
        // so only the trailing (left) edge hides anything.
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
