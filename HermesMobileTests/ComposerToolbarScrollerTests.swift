import SwiftUI
import XCTest
@testable import HermesMobile

final class ComposerToolbarScrollerTests: XCTestCase {
    func testNoFadesWhenContentFits() {
        let fades = ComposerToolbarEdgeFades(offset: 0, contentWidth: 300, viewportWidth: 320)

        XCTAssertFalse(fades.leading)
        XCTAssertFalse(fades.trailing)
    }

    func testOnlyTrailingFadeAtStartOfOverflowingContent() {
        let fades = ComposerToolbarEdgeFades(offset: 0, contentWidth: 500, viewportWidth: 320)

        XCTAssertFalse(fades.leading)
        XCTAssertTrue(fades.trailing)
    }

    func testBothFadesMidScroll() {
        let fades = ComposerToolbarEdgeFades(offset: 90, contentWidth: 500, viewportWidth: 320)

        XCTAssertTrue(fades.leading)
        XCTAssertTrue(fades.trailing)
    }

    func testOnlyLeadingFadeAtEnd() {
        let fades = ComposerToolbarEdgeFades(offset: 180, contentWidth: 500, viewportWidth: 320)

        XCTAssertTrue(fades.leading)
        XCTAssertFalse(fades.trailing)
    }

    func testEdgesWithinEpsilonCountAsReached() {
        let nearStart = ComposerToolbarEdgeFades(offset: 3, contentWidth: 500, viewportWidth: 320)
        let nearEnd = ComposerToolbarEdgeFades(offset: 177, contentWidth: 500, viewportWidth: 320)

        XCTAssertFalse(nearStart.leading)
        XCTAssertFalse(nearEnd.trailing)
    }

    func testRightToLeftFlipsRawOffset() {
        // Raw offset 0 in RTL shows the visual start of the content (its right end),
        // so only the trailing (left) edge hides anything.
        let atStart = ComposerToolbarEdgeFades(
            offset: 180, contentWidth: 500, viewportWidth: 320, layoutDirection: .rightToLeft
        )
        let atEnd = ComposerToolbarEdgeFades(
            offset: 0, contentWidth: 500, viewportWidth: 320, layoutDirection: .rightToLeft
        )

        XCTAssertFalse(atStart.leading)
        XCTAssertTrue(atStart.trailing)
        XCTAssertTrue(atEnd.leading)
        XCTAssertFalse(atEnd.trailing)
    }

    func testReasoningRendersStaticOnlyForOneSupportedEffort() {
        XCTAssertEqual(ReasoningEffortOption.singleOption(forSupportedEfforts: ["high"])?.id, "high")
        XCTAssertEqual(ReasoningEffortOption.singleOption(forSupportedEfforts: [" High ", "high"])?.id, "high")
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: ["low", "high"]))
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: nil))
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: []))
    }
}
