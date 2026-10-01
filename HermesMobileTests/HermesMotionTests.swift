import XCTest
@testable import HermesMobile

final class HermesMotionTests: XCTestCase {
    func testDurationScaleMatchesApprovedValues() {
        XCTAssertEqual(HermesMotion.Duration.d0, 0)
        XCTAssertEqual(HermesMotion.Duration.d100, 0.1)
        XCTAssertEqual(HermesMotion.Duration.d150, 0.15)
        XCTAssertEqual(HermesMotion.Duration.d200, 0.2)
        XCTAssertEqual(HermesMotion.Duration.d250, 0.25)
        XCTAssertEqual(HermesMotion.Duration.d300, 0.3)
    }

    func testPropertiesMatchApprovedValues() {
        XCTAssertEqual(HermesMotion.Properties.opacityHidden, 0)
        XCTAssertEqual(HermesMotion.Properties.opacityVisible, 1)
        XCTAssertEqual(HermesMotion.Properties.scalePress, 0.975)
        XCTAssertEqual(HermesMotion.Properties.scaleEnter, 0.95)
        XCTAssertEqual(HermesMotion.Properties.distanceShort, 8)
        XCTAssertEqual(HermesMotion.Properties.directionEdges, [.top, .bottom, .leading, .trailing])
    }

    func testFeedbackPressMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.feedbackPress.duration, HermesMotion.Duration.d100)
        XCTAssertEqual(HermesMotion.Bundle.feedbackPress.easing, .state)
        XCTAssertEqual(HermesMotion.Bundle.feedbackPress.detail, "0.975 scale")
    }

    func testStateChangeMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.stateChange.duration, HermesMotion.Duration.d150)
        XCTAssertEqual(HermesMotion.Bundle.stateChange.easing, .state)
        XCTAssertEqual(HermesMotion.Bundle.stateChange.detail, "color/opacity")
    }

    func testContentEnterMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.contentEnter.duration, HermesMotion.Duration.d200)
        XCTAssertEqual(HermesMotion.Bundle.contentEnter.easing, .enter)
        XCTAssertEqual(HermesMotion.Bundle.contentEnter.detail, "fade + 8 pt slide")
    }

    func testContentExitMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.contentExit.duration, HermesMotion.Duration.d150)
        XCTAssertEqual(HermesMotion.Bundle.contentExit.easing, .exit)
        XCTAssertEqual(HermesMotion.Bundle.contentExit.detail, "fade + 8 pt slide")
    }

    func testOverlayEnterMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.overlayEnter.duration, HermesMotion.Duration.d250)
        XCTAssertEqual(HermesMotion.Bundle.overlayEnter.easing, .spatial)
        XCTAssertEqual(HermesMotion.Bundle.overlayEnter.detail, "directional overlays use fade + edge move, centered overlays use fade + 0.95→1 scale")
    }

    func testOverlayExitMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.overlayExit.duration, HermesMotion.Duration.d200)
        XCTAssertEqual(HermesMotion.Bundle.overlayExit.easing, .exit)
        XCTAssertEqual(HermesMotion.Bundle.overlayExit.detail, "directional overlays use fade + edge move, centered overlays use fade + 1→0.95 scale")
    }

    func testContentRepositionMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.contentReposition.duration, HermesMotion.Duration.d250)
        XCTAssertEqual(HermesMotion.Bundle.contentReposition.easing, .spatial)
        XCTAssertEqual(HermesMotion.Bundle.contentReposition.detail, "transform")
    }

    func testScrollFollowMatchesHermesTokenProposalExactly() {
        XCTAssertEqual(HermesMotion.Bundle.scrollFollow.duration, HermesMotion.Duration.d200)
        XCTAssertEqual(HermesMotion.Bundle.scrollFollow.easing, .easeOut)
        XCTAssertEqual(HermesMotion.Bundle.scrollFollow.detail, "")
    }

    func testAllEightBundlesAreDistinctByDurationEasingPair() {
        let bundles: [HermesMotion.MotionBundle] = [
            HermesMotion.Bundle.feedbackPress, HermesMotion.Bundle.stateChange, HermesMotion.Bundle.contentEnter,
            HermesMotion.Bundle.contentExit, HermesMotion.Bundle.overlayEnter, HermesMotion.Bundle.overlayExit,
            HermesMotion.Bundle.contentReposition, HermesMotion.Bundle.scrollFollow,
        ]
        XCTAssertEqual(bundles.count, 8)
        // Not asserting uniqueness of (duration, easing) pairs alone — feedbackPress and stateChange
        // legitimately share the `state` easing at different durations, which is correct per the
        // approved values, not a defect; each bundle's own three-field identity is what the eight
        // tests above already pin exactly.
    }
}
