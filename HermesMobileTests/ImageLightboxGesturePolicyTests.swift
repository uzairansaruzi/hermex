import XCTest
@testable import HermesMobile

final class ImageLightboxGesturePolicyTests: XCTestCase {
    func testDismissDragOnlyStartsAtFitScale() {
        let downward = CGPoint(x: 0, y: 600)

        XCTAssertTrue(
            ImageLightboxGesturePolicy.canBeginDismiss(
                zoomScale: 1,
                minimumZoomScale: 1,
                velocity: downward
            )
        )
        XCTAssertFalse(
            ImageLightboxGesturePolicy.canBeginDismiss(
                zoomScale: 2.5,
                minimumZoomScale: 1,
                velocity: downward
            )
        )
    }

    func testDismissDragIgnoresUpwardAndSidewaysDrags() {
        let cases: [CGPoint] = [
            CGPoint(x: 0, y: -600),
            CGPoint(x: 900, y: 200),
            CGPoint(x: -900, y: 200)
        ]

        for velocity in cases {
            XCTAssertFalse(
                ImageLightboxGesturePolicy.canBeginDismiss(
                    zoomScale: 1,
                    minimumZoomScale: 1,
                    velocity: velocity
                ),
                "\(velocity)"
            )
        }
    }

    func testClosesOnDistanceOrSpeed() {
        XCTAssertTrue(ImageLightboxGesturePolicy.shouldDismiss(translation: 160, velocity: 40))
        XCTAssertTrue(ImageLightboxGesturePolicy.shouldDismiss(translation: 30, velocity: 1_400))
        XCTAssertFalse(ImageLightboxGesturePolicy.shouldDismiss(translation: 30, velocity: 40))
        XCTAssertFalse(ImageLightboxGesturePolicy.shouldDismiss(translation: -400, velocity: -1_400))
    }
}
