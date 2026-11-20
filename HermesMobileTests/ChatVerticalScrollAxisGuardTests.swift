import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatVerticalScrollAxisGuardTests: XCTestCase {
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

        scrollView.contentSize = CGSize(width: 1_400, height: 1_200)

        let expected = 1_400 + scrollView.adjustedContentInset.right - scrollView.bounds.width
        XCTAssertEqual(scrollView.contentOffset.x, expected, accuracy: 0.001)
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

    func testReflowRestoresAgainstTheNewFrameUntilTheReaderScrolls() {
        let scrollView = makeScrollView()
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)
        let narrow = ChatScrollPositionController.Layout(contentWidth: 288, dynamicTypeSize: .large)
        let wide = ChatScrollPositionController.Layout(contentWidth: 768, dynamicTypeSize: .large)
        controller.rowFrameChanged(id: "prompt", frame: CGRect(x: 0, y: 0, width: 288, height: 400), layout: narrow, isFollowing: false)
        controller.rowFrameChanged(id: "reply", frame: CGRect(x: 0, y: 408, width: 288, height: 600), layout: narrow, isFollowing: false)
        scrollView.contentOffset.y = 648

        controller.rowFrameChanged(id: "prompt", frame: CGRect(x: 0, y: 0, width: 768, height: 200), layout: wide, isFollowing: false)
        controller.rowFrameChanged(id: "reply", frame: CGRect(x: 0, y: 208, width: 768, height: 300), layout: wide, isFollowing: false)
        XCTAssertEqual(scrollView.contentOffset.y, 328, accuracy: 0.001)

        scrollView.contentSize.height += 100
        scrollView.contentOffset.y = 100
        controller.rowFrameChanged(id: "reply", frame: CGRect(x: 0, y: 208, width: 768, height: 340), layout: wide, isFollowing: false)
        XCTAssertEqual(scrollView.contentOffset.y, 100, accuracy: 0.001)
    }

    func testReflowYieldsToFollowAndToAnInFlightPrepend() {
        let narrow = ChatScrollPositionController.Layout(contentWidth: 288, dynamicTypeSize: .large)
        let larger = ChatScrollPositionController.Layout(contentWidth: 288, dynamicTypeSize: .xxxLarge)
        let tall = CGRect(x: 0, y: 0, width: 288, height: 600)
        let taller = CGRect(x: 0, y: 0, width: 288, height: 1_000)

        let following = makeScrollView()
        following.contentOffset.y = 240
        let followController = ChatScrollPositionController()
        followController.attach(to: following)
        followController.rowFrameChanged(id: "reply", frame: tall, layout: narrow, isFollowing: true)
        followController.rowFrameChanged(id: "reply", frame: taller, layout: larger, isFollowing: true)
        XCTAssertEqual(following.contentOffset.y, 240, accuracy: 0.001)

        let prepending = makeScrollView()
        prepending.contentOffset.y = 240
        let prependController = ChatScrollPositionController()
        prependController.attach(to: prepending)
        prependController.rowFrameChanged(id: "reply", frame: tall, layout: narrow, isFollowing: false)
        XCTAssertTrue(prependController.capture())
        prependController.rowFrameChanged(id: "reply", frame: taller, layout: larger, isFollowing: false)
        XCTAssertEqual(prepending.contentOffset.y, 240, accuracy: 0.001)
        XCTAssertTrue(prependController.restoreAfterPrepend())
    }

    func testReflowKeepsAReaderAtTheTopThroughSwiftUIMovingThem() {
        let scrollView = makeScrollView()
        scrollView.contentInset.top = 100
        scrollView.contentOffset.y = -100
        let controller = ChatScrollPositionController()
        controller.attach(to: scrollView)
        let narrow = ChatScrollPositionController.Layout(contentWidth: 288, dynamicTypeSize: .large)
        let wide = ChatScrollPositionController.Layout(contentWidth: 768, dynamicTypeSize: .large)
        controller.rowFrameChanged(id: "prompt", frame: CGRect(x: 0, y: 0, width: 288, height: 400), layout: narrow, isFollowing: false)
        controller.rowFrameChanged(id: "reply", frame: CGRect(x: 0, y: 408, width: 288, height: 800), layout: narrow, isFollowing: false)

        controller.rowFrameChanged(id: "prompt", frame: CGRect(x: 0, y: 0, width: 768, height: 200), layout: wide, isFollowing: false)
        controller.rowFrameChanged(id: "reply", frame: CGRect(x: 0, y: 208, width: 768, height: 400), layout: wide, isFollowing: false)
        scrollView.contentInset.top = 50
        scrollView.contentSize.height = 608
        scrollView.contentOffset.y = 300

        XCTAssertEqual(scrollView.contentOffset.y, -50, accuracy: 0.001)
    }

    func testHandoffPassesThroughATranscriptThatNeverAttached() {
        let continuity = ChatContinuity()
        let narrow = ChatScrollPositionController.Layout(contentWidth: 288, dynamicTypeSize: .large)
        let wide = ChatScrollPositionController.Layout(contentWidth: 768, dynamicTypeSize: .large)
        let oldScrollView = makeScrollView()
        let old = ChatScrollPositionController()
        old.attach(to: oldScrollView)
        old.rowFrameChanged(id: "reply", frame: CGRect(x: 0, y: 408, width: 288, height: 600), layout: narrow, isFollowing: false)
        oldScrollView.contentOffset.y = 648
        continuity.transcriptAppeared(old, isFollowing: false)

        continuity.transcriptAppeared(ChatScrollPositionController(), isFollowing: false)
        let newScrollView = makeScrollView()
        let new = ChatScrollPositionController()
        continuity.transcriptAppeared(new, isFollowing: false)
        new.attach(to: newScrollView)
        new.rowFrameChanged(id: "reply", frame: CGRect(x: 0, y: 208, width: 768, height: 300), layout: wide, isFollowing: false)

        XCTAssertEqual(newScrollView.contentOffset.y, 328, accuracy: 0.001)
    }

    private func makeScrollView() -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        scrollView.contentSize = CGSize(width: 320, height: 1_200)
        return scrollView
    }
}
