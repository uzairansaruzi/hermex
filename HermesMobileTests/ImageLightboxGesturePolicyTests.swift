import XCTest
@testable import HermesMobile

/// The lightbox's two gesture rules: the dismiss drag exists only at fit scale, and it
/// closes on either distance or speed.
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
        // A slow, long drag.
        XCTAssertTrue(ImageLightboxGesturePolicy.shouldDismiss(translation: 160, velocity: 40))
        // A short, fast flick.
        XCTAssertTrue(ImageLightboxGesturePolicy.shouldDismiss(translation: 30, velocity: 1_400))
        // A small nudge either way stays open.
        XCTAssertFalse(ImageLightboxGesturePolicy.shouldDismiss(translation: 30, velocity: 40))
        XCTAssertFalse(ImageLightboxGesturePolicy.shouldDismiss(translation: -400, velocity: -1_400))
    }

    func testZoomCeilingReachesThePixelsWithoutRunningAway() {
        // A screenshot far wider than the phone can zoom to its own pixels.
        XCTAssertEqual(
            ImageLightboxGesturePolicy.maximumZoomScale(imagePixelWidth: 2_400, fittedWidth: 400),
            6
        )
        // A small image still gets a useful ceiling.
        XCTAssertEqual(
            ImageLightboxGesturePolicy.maximumZoomScale(imagePixelWidth: 200, fittedWidth: 400),
            3
        )
        // An enormous one is capped so it cannot become a maze.
        XCTAssertEqual(
            ImageLightboxGesturePolicy.maximumZoomScale(imagePixelWidth: 12_000, fittedWidth: 400),
            8
        )
        // A viewport that has not been laid out yet still returns something usable.
        XCTAssertEqual(
            ImageLightboxGesturePolicy.maximumZoomScale(imagePixelWidth: 2_400, fittedWidth: 0),
            3
        )
    }

    func testDoubleTapNeverExceedsTheCeiling() {
        XCTAssertEqual(ImageLightboxGesturePolicy.doubleTapZoomScale(maximumZoomScale: 6), 2.5)
        XCTAssertEqual(ImageLightboxGesturePolicy.doubleTapZoomScale(maximumZoomScale: 2), 2)
    }
}
