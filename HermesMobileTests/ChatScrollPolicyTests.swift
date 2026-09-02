import XCTest
@testable import HermesMobile

final class ChatScrollPolicyTests: XCTestCase {
    func testExistingTranscriptUsesBottomAsItsInitialLayoutAnchor() {
        XCTAssertEqual(ChatScrollPolicy.initialTranscriptAnchor, .bottom)
    }

    func testTranscriptSizeChangesStayBottomAnchoredOnlyWhileFollowingLatest() {
        XCTAssertEqual(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: true),
            .bottom
        )
        XCTAssertNil(ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false))
    }

    func testInitialAsyncWorkWaitsForNavigationAppearanceCompletion() {
        XCTAssertFalse(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: false))
        XCTAssertTrue(ChatInitialAppearancePolicy.shouldBeginAsyncWork(hasCompletedAppearance: true))
    }

    func testBottomThresholdLoosensWhileStreaming() {
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: false),
            ChatScrollPolicy.bottomDetectionThreshold
        )
        XCTAssertEqual(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.streamingBottomDetectionThreshold
        )
        XCTAssertGreaterThan(
            ChatScrollPolicy.bottomThreshold(isStreaming: true),
            ChatScrollPolicy.bottomThreshold(isStreaming: false)
        )
    }

    func testIsNearBottomUsesIdleThresholdWhenNotStreaming() {
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 80, isStreaming: false))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 81, isStreaming: false))
    }

    func testIsNearBottomUsesLooserThresholdWhileStreaming() {
        // 120pt is past the idle threshold but still "near bottom" while streaming.
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: false))
        XCTAssertTrue(ChatScrollPolicy.isNearBottom(distanceFromBottom: 120, isStreaming: true))
        XCTAssertFalse(ChatScrollPolicy.isNearBottom(distanceFromBottom: 161, isStreaming: true))
    }

    func testShouldEnterReadingOlderRequiresHysteresisPastThreshold() {
        let threshold = ChatScrollPolicy.bottomThreshold(isStreaming: false)
        let hysteresis = ChatScrollPolicy.readingOlderHysteresis

        XCTAssertFalse(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis,
                isStreaming: false
            )
        )
        XCTAssertTrue(
            ChatScrollPolicy.shouldEnterReadingOlder(
                distanceFromBottom: threshold + hysteresis + 1,
                isStreaming: false
            )
        )
    }

    // MARK: Follow latch

    private typealias Latch = ChatScrollPolicy.FollowLatch

    private func follow(_ current: Bool, _ event: ChatScrollPolicy.FollowEvent) -> Bool {
        ChatScrollPolicy.resolveFollow(current: Latch(isFollowing: current), event: event).isFollowing
    }

    private func reduce(_ latch: Latch, _ events: ChatScrollPolicy.FollowEvent...) -> Latch {
        events.reduce(latch) { ChatScrollPolicy.resolveFollow(current: $0, event: $1) }
    }

    func testTouchDownTurnsFollowOff() {
        XCTAssertFalse(follow(true, .userScrollBegin))
        XCTAssertFalse(follow(false, .userScrollBegin))
    }

    func testDragEndAboveBottomKeepsFollowOff() {
        XCTAssertFalse(follow(false, .userScrollEnd(isAtBottom: false)))
    }

    func testExplicitResetSurvivesLateDragSettlement() {
        // Drag lifted above the bottom, then send or scroll-to-bottom landed inside the
        // 160 ms settle window. The late settle report must not undo the reset.
        let latch = reduce(Latch(), .userScrollBegin, .reset, .userScrollEnd(isAtBottom: false))
        XCTAssertTrue(latch.isFollowing)
        XCTAssertFalse(latch.ignoresCoastingGesture)
    }

    func testExplicitResetSurvivesCoastingMomentum() {
        // Send or scroll-to-bottom while the transcript is still decelerating: the
        // remaining momentum ticks belong to the gesture that predates the reset.
        let coasting = reduce(
            Latch(),
            .userScrollBegin,
            .reset,
            .contentScrolled(isAtBottom: false, isUserScrolling: true)
        )
        XCTAssertTrue(coasting.isFollowing)

        // Once that momentum settles, the next real drag turns follow off as usual.
        let settled = reduce(coasting, .userScrollEnd(isAtBottom: false))
        XCTAssertTrue(settled.isFollowing)
        XCTAssertFalse(settled.ignoresCoastingGesture)
        XCTAssertFalse(reduce(settled, .contentScrolled(isAtBottom: false, isUserScrolling: true)).isFollowing)
    }

    func testNewDragAfterResetTurnsFollowOff() {
        let latch = reduce(Latch(), .reset, .userScrollBegin)
        XCTAssertFalse(latch.isFollowing)
        XCTAssertFalse(latch.ignoresCoastingGesture)
    }

    func testDragEndAtBottomReArmsFollow() {
        XCTAssertTrue(follow(false, .userScrollEnd(isAtBottom: true)))
    }

    func testMomentumEndDecidesFromWhereItSettled() {
        // A fling that stops mid-transcript stays off; one that lands at the end re-arms.
        XCTAssertFalse(follow(false, .userScrollEnd(isAtBottom: false)))
        XCTAssertTrue(follow(false, .userScrollEnd(isAtBottom: true)))
    }

    func testLayoutGrowthWhileOffNeverReArms() {
        // Streaming tokens push the bottom away; that alone must not re-pin the reader.
        XCTAssertFalse(follow(false, .contentScrolled(isAtBottom: false, isUserScrolling: false)))
    }

    func testLayoutGrowthWhileFollowingStaysOn() {
        // Keyboard presentation and token growth move the offset without a gesture.
        XCTAssertTrue(follow(true, .contentScrolled(isAtBottom: false, isUserScrolling: false)))
    }

    func testNonGestureScrollThatLandsAtBottomFromNearbyReArms() {
        // A collapse near the end clamps the offset to the bottom.
        XCTAssertTrue(follow(false, .contentScrolled(isAtBottom: true, isUserScrolling: false, wasNearBottom: true)))
    }

    func testTransientBottomFromFarAboveDoesNotReArm() {
        // A relayout that momentarily reads "at bottom" while the reader was parked
        // thousands of points up must not switch follow on.
        XCTAssertFalse(follow(false, .contentScrolled(isAtBottom: true, isUserScrolling: false, wasNearBottom: false)))
    }

    func testScrollAwayFromBottomWithoutGestureTurnsFollowOff() {
        // Status-bar tap, VoiceOver, or a hardware-keyboard scroll: no pan gesture,
        // but the reader is being carried away from the bottom.
        XCTAssertFalse(follow(true, .contentScrolled(isAtBottom: false, isUserScrolling: false, movedAwayFromBottom: true)))
    }

    func testExplicitResetSurvivesCoastingMomentumAwayFromBottom() {
        // Momentum ticks after a reset carry the away flag too; they still belong
        // to the gesture that predates the reset.
        let latch = reduce(
            Latch(),
            .userScrollBegin,
            .reset,
            .contentScrolled(isAtBottom: false, isUserScrolling: true, movedAwayFromBottom: true)
        )
        XCTAssertTrue(latch.isFollowing)
    }

    // MARK: Scroll-away detection

    private typealias Geometry = ChatScrollPolicy.ScrollGeometry

    func testDistanceGrowingPastStreamingThresholdIsAScrollAway() {
        let atBottom = Geometry(offsetY: 4300, contentHeight: 5000, visibleHeight: 700)
        // Status-bar scroll: the lazy stack may re-measure on the way, so the
        // content height is allowed to move as long as the distance grows.
        let carriedAway = Geometry(offsetY: 3200, contentHeight: 5200, visibleHeight: 700)
        XCTAssertTrue(ChatScrollPolicy.isScrollingAwayFromBottom(previous: atBottom, current: carriedAway))
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(previous: nil, current: carriedAway))
    }

    func testJitterViewportAndFollowScrollsAreNotScrollAways() {
        let atBottom = Geometry(offsetY: 4300, contentHeight: 5000, visibleHeight: 700)
        // Streaming jitter under the loose threshold.
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: atBottom,
            current: Geometry(offsetY: 4300, contentHeight: 5150, visibleHeight: 700)
        ))
        // Keyboard inset change: viewport changes.
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: atBottom,
            current: Geometry(offsetY: 4300, contentHeight: 5000, visibleHeight: 400)
        ))
        // Follow scroll heading back to the bottom from far away.
        let farAway = Geometry(offsetY: 1000, contentHeight: 5000, visibleHeight: 700)
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: farAway,
            current: Geometry(offsetY: 2000, contentHeight: 5000, visibleHeight: 700)
        ))
        // Size change snapped back to the bottom by the anchor.
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: atBottom,
            current: Geometry(offsetY: 4700, contentHeight: 5400, visibleHeight: 700)
        ))
    }

    func testLiveGestureWinsEvenAtBottom() {
        XCTAssertFalse(follow(true, .contentScrolled(isAtBottom: true, isUserScrolling: true)))
    }

    func testExplicitActionsBypassTheLatch() {
        XCTAssertTrue(follow(false, .reset))
        XCTAssertTrue(follow(true, .reset))
    }

    func testReArmRequiresStrictBottom() {
        XCTAssertTrue(ChatScrollPolicy.isAtBottom(distanceFromBottom: ChatScrollPolicy.followReArmThreshold))
        XCTAssertFalse(ChatScrollPolicy.isAtBottom(distanceFromBottom: ChatScrollPolicy.followReArmThreshold + 1))
        XCTAssertLessThan(ChatScrollPolicy.followReArmThreshold, ChatScrollPolicy.bottomDetectionThreshold)
    }

    func testDragSettleWaitsForLateMomentum() {
        XCTAssertEqual(ChatScrollPolicy.dragSettleDelay, 0.16, accuracy: 0.0001)
        XCTAssertLessThan(ChatScrollPolicy.momentumSettleDelay, ChatScrollPolicy.dragSettleDelay)
    }

    func testDisclosureToggleSuspendsBottomAnchorWhileFollowing() {
        XCTAssertNil(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: true, isDisclosureSettling: true)
        )
        XCTAssertEqual(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: true, isDisclosureSettling: false),
            .bottom
        )
        XCTAssertNil(
            ChatScrollPolicy.sizeChangeAnchor(shouldFollowLatestMessage: false, isDisclosureSettling: false)
        )
    }
}
