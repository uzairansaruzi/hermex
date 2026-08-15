import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatVerticalScrollAxisGuardTests: XCTestCase {
    func testDisclosurePreserverRestoresExactVerticalOffset() {
        let scrollView = makeOversizedScrollView()
        let preserver = ChatScrollPositionPreserver()
        scrollView.contentOffset.y = 320
        preserver.attach(to: scrollView)
        XCTAssertTrue(preserver.isAttached)
        preserver.preserveCurrentVerticalOffset(for: 1)

        scrollView.contentOffset.y = 900
        preserver.enforcePreservedOffset()

        XCTAssertEqual(scrollView.contentOffset.y, 320, accuracy: 0.001)
        preserver.cancelPreservation()
    }

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
