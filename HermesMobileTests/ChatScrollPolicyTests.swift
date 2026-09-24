import SwiftUI
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

    func testLatestArrowHidesAtBottomEvenWhenFollowingIsPaused() {
        for streaming in [false, true] {
            let isNearBottom = ChatScrollPolicy.isNearBottom(distanceFromBottom: 0, isStreaming: streaming)
            XCTAssertFalse(ChatScrollPolicy.showsScrollToBottomButton(
                isNearBottom: isNearBottom, isStreaming: streaming, isFollowing: false
            ))
        }
    }

    func testLatestArrowUsesTheSameIdleAndStreamingThresholds() {
        for (distance, streaming, following, visible) in [
            (80.0, false, false, false), (81, false, false, true),
            (120, true, false, false), (161, true, false, true), (161, true, true, false)
        ] {
            let isNearBottom = ChatScrollPolicy.isNearBottom(distanceFromBottom: distance, isStreaming: streaming)
            XCTAssertEqual(ChatScrollPolicy.showsScrollToBottomButton(
                isNearBottom: isNearBottom, isStreaming: streaming, isFollowing: following
            ), visible)
        }
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

/// The transcript's disclosure and link actions reach every row through the
/// environment. The owners rebuild their closures on each pass (every stream
/// tick and keystroke), so these pin that readers behind a skipped boundary
/// (the transcript's `.equatable()` rows) are not re-evaluated, while a tap
/// still runs the latest closure.
@MainActor
final class ChatTranscriptEnvironmentStabilityTests: XCTestCase {
    func testDisclosureReadersSkipOwnerPassesAndRunTheLatestHandler() throws {
        let probe = EnvironmentStabilityProbe()
        let window = host(DisclosureOwner(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }

        advance(probe, window: window, passes: 3)

        XCTAssertEqual(probe.ownerPasses, 4, "The owner must re-run on each tick for this to test anything")
        // The old per-pass closures re-ran the reader on every owner pass (4); a slow runner can add one layout pass.
        XCTAssertLessThanOrEqual(probe.readerPasses, 2)
        try XCTUnwrap(probe.disclosure)()
        XCTAssertEqual(probe.handledTick, 3)
    }

    func testLinkReadersSkipOwnerPassesAndRouteThroughTheLatestHandler() throws {
        let probe = EnvironmentStabilityProbe()
        let window = host(LinkOwner(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }

        advance(probe, window: window, passes: 3)

        XCTAssertEqual(probe.ownerPasses, 4, "The owner must re-run on each tick for this to test anything")
        // The old per-pass closures re-ran the reader on every owner pass (4); a slow runner can add one layout pass.
        XCTAssertLessThanOrEqual(probe.readerPasses, 2)
        try XCTUnwrap(probe.openURL)(URL(string: "https://example.com/file.swift")!)
        XCTAssertEqual(probe.handledTick, 3)
    }

    /// The owners pass method references, which capture the view and so its
    /// state. Holding them must not keep that state alive after the screen goes.
    func testHandlersThatCaptureTheOwnerDoNotOutliveIt() {
        let released = expectation(description: "The owner's state is released with its screen")
        autoreleasepool {
            let window = host(SelfCapturingOwner(onRelease: released.fulfill))
            window.isHidden = true
            window.rootViewController = nil
        }
        wait(for: [released], timeout: 2)
    }

    private func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func advance(_ probe: EnvironmentStabilityProbe, window: UIWindow, passes: Int) {
        for _ in 0..<passes {
            probe.tick += 1
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
        }
    }
}

@Observable
private final class EnvironmentStabilityProbe {
    var tick = 0
    @ObservationIgnored var ownerPasses = 0
    @ObservationIgnored var readerPasses = 0
    @ObservationIgnored var handledTick: Int?
    @ObservationIgnored var disclosure: ChatDisclosureToggleAction?
    @ObservationIgnored var openURL: OpenURLAction?
}

/// Rebuilds its disclosure closure on every tick, as the transcript does per stream tick.
private struct DisclosureOwner: View {
    let probe: EnvironmentStabilityProbe

    var body: some View {
        let tick = probe.tick
        probe.ownerPasses += 1
        return VStack {
            Text("\(tick)")
            SettledRow(probe: probe)
        }
        .chatDisclosureToggled { probe.handledTick = tick }
    }
}

/// Rebuilds its link closure on every tick, as ChatView does per stream tick and keystroke.
private struct LinkOwner: View {
    let probe: EnvironmentStabilityProbe

    var body: some View {
        let tick = probe.tick
        probe.ownerPasses += 1
        return VStack {
            Text("\(tick)")
            SettledRow(probe: probe)
        }
        .transcriptLinks { _ in
            probe.handledTick = tick
            return .handled
        }
    }
}

/// Stands in for a settled transcript row: its inputs never change, so only an
/// environment change can reach the readers inside it.
private struct SettledRow: View {
    let probe: EnvironmentStabilityProbe

    var body: some View {
        KeyReader(probe: probe)
    }
}

private struct KeyReader: View {
    let probe: EnvironmentStabilityProbe
    @Environment(\.chatDisclosureToggled) private var disclosure
    @Environment(\.openURL) private var openURL

    var body: some View {
        probe.readerPasses += 1
        probe.disclosure = disclosure
        probe.openURL = openURL
        return Color.clear.frame(width: 1, height: 1)
    }
}


private final class OwnedModel {
    let onRelease: () -> Void

    init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }

    deinit { onRelease() }
}

/// Mirrors ChatView and BotChatView: the handlers are methods on a view that
/// owns a model in `@State`.
private struct SelfCapturingOwner: View {
    @State private var model: OwnedModel
    @State private var toggles = 0

    init(onRelease: @escaping () -> Void) {
        _model = State(initialValue: OwnedModel(onRelease: onRelease))
    }

    var body: some View {
        Text("\(toggles)")
            .chatDisclosureToggled(perform: toggled)
            .transcriptLinks(perform: open)
    }

    private func toggled() { toggles += 1 }

    private func open(_ url: URL) -> OpenURLAction.Result {
        toggles += 1
        return .handled
    }
}
