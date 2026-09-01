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

    private func follow(_ current: Bool, _ event: ChatScrollPolicy.FollowEvent) -> Bool {
        ChatScrollPolicy.resolveFollow(current: current, event: event)
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
        let afterReset = follow(follow(true, .userScrollBegin), .reset)
        XCTAssertTrue(afterReset)
        XCTAssertTrue(follow(afterReset, .userScrollEnd(isAtBottom: false)))
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

    func testNonGestureScrollThatLandsAtBottomReArms() {
        XCTAssertTrue(follow(false, .contentScrolled(isAtBottom: true, isUserScrolling: false)))
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
