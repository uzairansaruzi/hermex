import XCTest
import SwiftUI
@testable import HermesMobile

final class HermesShadowTests: XCTestCase {
    // .none is invisible by design (the default/fallback shadow) — it has no rendered evidence to
    // screenshot; this unit-test assertion is its only verification, not a gap to fill later.
    func testNoneIsFullyTransparentInBothAppearances() {
        XCTAssertEqual(HermesShadow.none.resolved(for: .light), .init(opacity: 0, radius: 0, x: 0, y: 0))
        XCTAssertEqual(HermesShadow.none.resolved(for: .dark), .init(opacity: 0, radius: 0, x: 0, y: 0))
    }

    func testControlSubtleRestingMatchesGroundedValueInBothAppearances() {
        let expected = HermesShadow.Resolved(opacity: 0.12, radius: 4, x: 0, y: 1)
        XCTAssertEqual(HermesShadow.controlSubtleResting.resolved(for: .light), expected)
        XCTAssertEqual(HermesShadow.controlSubtleResting.resolved(for: .dark), expected)
    }

    func testControlSubtlePressedMatchesGroundedValueInBothAppearances() {
        let expected = HermesShadow.Resolved(opacity: 0.06, radius: 1, x: 0, y: 0)
        XCTAssertEqual(HermesShadow.controlSubtlePressed.resolved(for: .light), expected)
        XCTAssertEqual(HermesShadow.controlSubtlePressed.resolved(for: .dark), expected)
    }

    func testControlElevatedRestingIsAppearanceAdaptive() {
        XCTAssertEqual(HermesShadow.controlElevatedResting.resolved(for: .light), .init(opacity: 0.18, radius: 16, x: 0, y: 8))
        XCTAssertEqual(HermesShadow.controlElevatedResting.resolved(for: .dark), .init(opacity: 0.32, radius: 16, x: 0, y: 8))
    }

    func testControlElevatedPressedIsAppearanceAdaptive() {
        XCTAssertEqual(HermesShadow.controlElevatedPressed.resolved(for: .light), .init(opacity: 0.10, radius: 8, x: 0, y: 3))
        XCTAssertEqual(HermesShadow.controlElevatedPressed.resolved(for: .dark), .init(opacity: 0.18, radius: 8, x: 0, y: 3))
    }

    func testPopoverMatchesGroundedValueInBothAppearances() {
        let expected = HermesShadow.Resolved(opacity: 0.14, radius: 12, x: 0, y: 4)
        XCTAssertEqual(HermesShadow.popover.resolved(for: .light), expected)
        XCTAssertEqual(HermesShadow.popover.resolved(for: .dark), expected)
    }

    func testChromeIsAppearanceAdaptive() {
        XCTAssertEqual(HermesShadow.chrome.resolved(for: .light), .init(opacity: 0.12, radius: 14, x: 0, y: 6))
        XCTAssertEqual(HermesShadow.chrome.resolved(for: .dark), .init(opacity: 0.28, radius: 14, x: 0, y: 6))
    }

    func testOverlayMatchesGroundedValueInBothAppearances() {
        let expected = HermesShadow.Resolved(opacity: 0.22, radius: 18, x: 0, y: 12)
        XCTAssertEqual(HermesShadow.overlay.resolved(for: .light), expected)
        XCTAssertEqual(HermesShadow.overlay.resolved(for: .dark), expected)
    }

    func testSubtleAndElevatedTiersRemainDistinctInBothRestingAndPressedState() {
        XCTAssertNotEqual(HermesShadow.controlSubtleResting.resolved(for: .light), HermesShadow.controlElevatedResting.resolved(for: .light))
        XCTAssertNotEqual(HermesShadow.controlSubtlePressed.resolved(for: .light), HermesShadow.controlElevatedPressed.resolved(for: .light))
    }

    func testHermesShadowModifierCompilesAndAppliesToAView() {
        let view: some View = Text("proof").hermesShadow(.popover)
        XCTAssertNotNil(view)
    }
}
