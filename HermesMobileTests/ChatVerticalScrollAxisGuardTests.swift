import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatVerticalScrollAxisGuardTests: XCTestCase {
    func testGuardConfiguresEnclosingScrollViewForVerticalAxis() {
        let scrollView = makeOversizedScrollView()
        let guardView = attachGuardView(to: scrollView)

        guardView.attachToNearestScrollViewIfNeeded()

        XCTAssertFalse(scrollView.alwaysBounceHorizontal)
        XCTAssertFalse(scrollView.showsHorizontalScrollIndicator)
        XCTAssertTrue(scrollView.isDirectionalLockEnabled)
    }

    func testGuardClampsHorizontalOffsetToAdjustedLeftInset() {
        let scrollView = makeOversizedScrollView(leftInset: 12)
        let guardView = attachGuardView(to: scrollView)
        scrollView.contentOffset = CGPoint(x: 140, y: 30)

        guardView.attachToNearestScrollViewIfNeeded()

        XCTAssertEqual(scrollView.contentOffset.x, -scrollView.adjustedContentInset.left, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 30, accuracy: 0.001)

        scrollView.contentOffset = CGPoint(x: 88, y: 44)

        XCTAssertEqual(scrollView.contentOffset.x, -scrollView.adjustedContentInset.left, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 44, accuracy: 0.001)
    }

    func testGuardClampsHorizontalOffsetToRTLLeadingEdge() {
        let scrollView = makeOversizedScrollView(leftInset: 12, rightInset: 8)
        let guardView = attachGuardView(to: scrollView)
        guardView.isRightToLeft = true
        scrollView.contentOffset = CGPoint(x: 40, y: 30)

        guardView.attachToNearestScrollViewIfNeeded()

        // RTL leading edge is the physical right: content trailing edge meets the
        // viewport → contentSize.width + right inset - viewport width.
        let expected = scrollView.contentSize.width
            + scrollView.adjustedContentInset.right
            - scrollView.bounds.width
        XCTAssertEqual(scrollView.contentOffset.x, expected, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 30, accuracy: 0.001)

        scrollView.contentOffset = CGPoint(x: 120, y: 44)
        XCTAssertEqual(scrollView.contentOffset.x, expected, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 44, accuracy: 0.001)
    }

    func testGuardReclampsWhenContentSizeGrowsUnderRTL() {
        let scrollView = makeOversizedScrollView(rightInset: 8)
        let guardView = attachGuardView(to: scrollView)
        guardView.isRightToLeft = true
        guardView.attachToNearestScrollViewIfNeeded()

        // Growing the content width changes the RTL rest offset; observing
        // contentSize must re-clamp immediately, without a manual scroll.
        scrollView.contentSize = CGSize(width: 1_400, height: 1_200)

        let expected = 1_400 + scrollView.adjustedContentInset.right - scrollView.bounds.width
        XCTAssertEqual(scrollView.contentOffset.x, expected, accuracy: 0.001)
    }

    func testPinnedOffsetHelperLTRUsesNegativeLeftInset() {
        let x = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: false,
            adjustedInset: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 8),
            contentSize: CGSize(width: 900, height: 1_200),
            boundsSize: CGSize(width: 320, height: 480)
        )
        XCTAssertEqual(x, -12, accuracy: 0.001)
    }

    func testPinnedOffsetHelperRTLPinsToTrailingEdgeWhenContentOverflows() {
        let x = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: true,
            adjustedInset: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8),
            contentSize: CGSize(width: 900, height: 1_200),
            boundsSize: CGSize(width: 320, height: 480)
        )
        XCTAssertEqual(x, 900 + 8 - 320, accuracy: 0.001)
    }

    func testPinnedOffsetHelperResolvesToZeroWhenTranscriptHasNoOverflowOrInset() {
        // The normal transcript case: content fits the viewport, no horizontal
        // inset — both directions rest at 0, so the toggle changes nothing here.
        let inset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let content = CGSize(width: 320, height: 1_200)
        let bounds = CGSize(width: 320, height: 480)
        let ltr = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: false, adjustedInset: inset, contentSize: content, boundsSize: bounds
        )
        let rtl = ChatVerticalScrollAxisGuardView.pinnedHorizontalOffsetX(
            isRightToLeft: true, adjustedInset: inset, contentSize: content, boundsSize: bounds
        )
        XCTAssertEqual(ltr, 0, accuracy: 0.001)
        XCTAssertEqual(rtl, 0, accuracy: 0.001)
    }

    func testGuardDetachesObserversWhenRemovedFromSuperview() {
        let scrollView = makeOversizedScrollView()
        let guardView = attachGuardView(to: scrollView)
        guardView.attachToNearestScrollViewIfNeeded()

        guardView.removeFromSuperview()
        scrollView.contentOffset = CGPoint(x: 88, y: 44)

        XCTAssertEqual(scrollView.contentOffset.x, 88, accuracy: 0.001)
        XCTAssertEqual(scrollView.contentOffset.y, 44, accuracy: 0.001)
    }

    private func makeOversizedScrollView(leftInset: CGFloat = 0, rightInset: CGFloat = 0) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 900, height: 1_200)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: leftInset, bottom: 0, right: rightInset)
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.isDirectionalLockEnabled = false
        return scrollView
    }

    private func attachGuardView(to scrollView: UIScrollView) -> ChatVerticalScrollAxisGuardView {
        let contentView = UIView(frame: CGRect(origin: .zero, size: scrollView.contentSize))
        let guardView = ChatVerticalScrollAxisGuardView()
        contentView.addSubview(guardView)
        scrollView.addSubview(contentView)
        return guardView
    }
}

@MainActor
final class ChatScrollPositionControllerTests: XCTestCase {
    func testPrependCompensatesByExactContentHeightGrowth() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        XCTAssertTrue(controller.restoreAfterPrepend())

        scrollView.contentSize.height += 640

        XCTAssertEqual(scrollView.contentOffset.y, 880, accuracy: 0.001)
    }

    func testHoldPutsBackAnAnchorSwiftUIReappliesOnSizeChange() {
        // Reader parked at the exact top; a disclosure grows a row below them and
        // SwiftUI re-applies the bottom anchor. The hold restores the top.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        scrollView.contentSize.height += 640
        scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height

        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.001)
    }

    func testHoldClampsWhenARowBelowCollapses() {
        // Reader at the bottom collapses a row: the content shrinks under them, so
        // the held offset can only clamp to the new maximum.
        let scrollView = makeScrollView()
        let bottom = scrollView.contentSize.height - scrollView.bounds.height
        scrollView.contentOffset = CGPoint(x: 0, y: bottom)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        scrollView.contentSize.height -= 200

        XCTAssertEqual(scrollView.contentOffset.y, bottom - 200, accuracy: 0.001)
    }

    func testReleasedHoldLetsOffsetChangesThrough() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        controller.releaseHold()
        scrollView.contentOffset.y = 300

        XCTAssertEqual(scrollView.contentOffset.y, 300, accuracy: 0.001)
    }

    func testHoldKeepsRevertingAcrossALongRelayout() {
        // 28 lazy rows settle over many frames; each frame SwiftUI re-applies the
        // bottom anchor and each time the pin puts the reader back.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        for growth in [640, 400, 220, 90, 40] as [CGFloat] {
            scrollView.contentSize.height += growth
            scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height
            XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.001)
        }
    }

    func testHoldResyncsSwiftUIOnlyAfterItHadToRevert() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        let resynced = expectation(description: "resync after revert")
        controller.holdPosition { resynced.fulfill() }
        scrollView.contentSize.height += 640
        scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height

        wait(for: [resynced], timeout: 2)
        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.001)
    }

    func testDeliberateScrollDuringHoldReleasesItInsteadOfReverting() {
        // VoiceOver or a hardware keyboard moves the offset with no size change in
        // the same turn: that is a real scroll, and the hold must let it stand.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        scrollView.contentOffset.y = 300

        XCTAssertEqual(scrollView.contentOffset.y, 300, accuracy: 0.001)
        XCTAssertFalse(controller.isHoldingPosition)
    }

    func testResyncOnlyDescribesAHeldTop() {
        XCTAssertTrue(ChatScrollPositionController.shouldResync(
            didRevertSwiftUIOffset: true, heldOffsetY: -116, minimumOffsetY: -116
        ))
        XCTAssertFalse(ChatScrollPositionController.shouldResync(
            didRevertSwiftUIOffset: true, heldOffsetY: 240, minimumOffsetY: -116
        ))
        XCTAssertFalse(ChatScrollPositionController.shouldResync(
            didRevertSwiftUIOffset: false, heldOffsetY: -116, minimumOffsetY: -116
        ))
    }

    func testFinishedHoldDoesNotFlagTheNextPrependCaptureAsAHold() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        controller.holdPosition {}
        controller.releaseHold()
        XCTAssertTrue(controller.capture())

        XCTAssertFalse(controller.isHoldingPosition)
        XCTAssertTrue(controller.restoreAfterPrepend())
    }

    func testHoldArmedDuringAnInFlightPrependInvalidatesTheCapture() {
        // Load Older is awaiting the server when the reader toggles a row. The
        // hold's baseline must not be mistaken for the prepend capture once the
        // rows land, or the row's growth would be compensated as prepended
        // content.
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        controller.holdPosition {}

        XCTAssertFalse(controller.restoreAfterPrepend())
        scrollView.contentSize.height += 640
        XCTAssertEqual(scrollView.contentOffset.y, 240, accuracy: 0.001)
    }

    func testReleaseHoldLeavesPrependPreservationAlone() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        XCTAssertTrue(controller.restoreAfterPrepend())
        controller.releaseHold()
        scrollView.contentSize.height += 640

        XCTAssertEqual(scrollView.contentOffset.y, 880, accuracy: 0.001)
    }

    func testCancelledPrependDoesNotMoveScrollPosition() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        controller.cancelPreservation()
        scrollView.contentSize.height += 640

        XCTAssertEqual(scrollView.contentOffset.y, 240, accuracy: 0.001)
    }

    func testPrependDoesNotOverrideMovementWhileRequestIsInFlight() {
        let scrollView = makeScrollView()
        scrollView.contentOffset = CGPoint(x: 0, y: 240)
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)

        XCTAssertTrue(controller.capture())
        scrollView.contentOffset.y = 300

        XCTAssertFalse(controller.restoreAfterPrepend())
        scrollView.contentSize.height += 640
        XCTAssertEqual(scrollView.contentOffset.y, 300, accuracy: 0.001)
    }

    func testCompensatedOffsetClampsToScrollableBounds() {
        let inset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)

        XCTAssertEqual(
            ChatScrollPositionController.compensatedOffsetY(
                baselineOffsetY: -12,
                contentHeightDelta: -100,
                adjustedInset: inset,
                contentSizeHeight: 1_200,
                boundsHeight: 480
            ),
            -12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ChatScrollPositionController.compensatedOffsetY(
                baselineOffsetY: 700,
                contentHeightDelta: 500,
                adjustedInset: inset,
                contentSizeHeight: 1_200,
                boundsHeight: 480
            ),
            740,
            accuracy: 0.001
        )
    }

    private func makeScrollView() -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        return scrollView
    }
}
