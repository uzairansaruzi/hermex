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

    func testAutoScrollPausedWhileUserInteracting() {
        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: true,
                cooldownUntil: nil
            )
        )
    }

    func testAutoScrollPausedDuringCooldownWindow() {
        let now = Date()
        let future = now.addingTimeInterval(0.1)

        XCTAssertTrue(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: future,
                now: now
            )
        )
    }

    func testAutoScrollResumesAfterCooldownExpires() {
        let now = Date()
        let past = now.addingTimeInterval(-0.1)

        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: past,
                now: now
            )
        )
    }

    func testAutoScrollNotPausedWithoutInteractionOrCooldown() {
        XCTAssertFalse(
            ChatScrollPolicy.isAutoScrollPaused(
                isUserInteracting: false,
                cooldownUntil: nil
            )
        )
    }

    func testCooldownDeadlineIsUserScrollCooldownInFuture() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let deadline = ChatScrollPolicy.cooldownDeadline(after: base)

        XCTAssertEqual(
            deadline.timeIntervalSince(base),
            ChatScrollPolicy.userScrollCooldown,
            accuracy: 0.0001
        )
    }
}
