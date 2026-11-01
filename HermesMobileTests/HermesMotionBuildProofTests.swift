import XCTest
import SwiftUI
@testable import HermesMobile

final class HermesMotionBuildProofTests: XCTestCase {
    func testSpringValuesCompileAndAreNonNil() {
        let values: [Animation] = [HermesMotion.Springs.responsive, HermesMotion.Springs.settle]
        XCTAssertEqual(values.count, 2)
    }

    func testAnimationForResolvesEveryBundleAndAppliesToAView() {
        let bundles: [HermesMotion.MotionBundle] = [
            HermesMotion.Bundle.feedbackPress, HermesMotion.Bundle.stateChange, HermesMotion.Bundle.contentEnter,
            HermesMotion.Bundle.contentExit, HermesMotion.Bundle.overlayEnter, HermesMotion.Bundle.overlayExit,
            HermesMotion.Bundle.contentReposition, HermesMotion.Bundle.scrollFollow,
        ]
        for bundle in bundles {
            let anim = HermesMotion.animation(for: bundle)
            let view: some View = Text("proof").animation(anim, value: 0)
            XCTAssertNotNil(view)
        }
    }
}
