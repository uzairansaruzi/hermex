import SwiftUI
import XCTest
@testable import HermesMobile

final class ChatScrollPolicyTests: XCTestCase {
    @MainActor
    func testFailedHistoryLoadLeavesPositionAlone() async {
        var position = ScrollPosition(id: "reading", anchor: .top)
        let original = position
        await ChatScrollPolicy.loadOlderMessages(
            position: Binding(get: { position }, set: { position = $0 }), firstMessageID: "first"
        ) { false }
        XCTAssertEqual(position, original)
    }

    @MainActor
    func testHistoryLoadDoesNotOverrideMovementDuringRequest() async {
        var position = ScrollPosition(id: "reading", anchor: .top)
        await ChatScrollPolicy.loadOlderMessages(
            position: Binding(get: { position }, set: { position = $0 }), firstMessageID: "first"
        ) {
            position.scrollTo(id: "another-message", anchor: .top)
            return true
        }
        XCTAssertEqual(position.viewID(type: String.self), "another-message")
    }

    @MainActor
    func testCancelledHistoryLoadDoesNotRestorePosition() async {
        var position = ScrollPosition(id: "reading", anchor: .top)
        let original = position
        let request = Task { @MainActor in
            await ChatScrollPolicy.loadOlderMessages(
                position: Binding(get: { position }, set: { position = $0 }), firstMessageID: "first"
            ) {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        await request.value
        XCTAssertEqual(position, original)
    }

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


@MainActor
final class ChatTranscriptLayoutTests: XCTestCase {
    func testLongTranscriptPreservesHistoryAndFollowsStreamingAtBottom() async throws {
        let state = TranscriptLayoutFixture()
        let host = UIHostingController(rootView: TranscriptLayoutFixtureView(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await render(window)
        let scroll = try XCTUnwrap(findScrollView(host.view))
        state.trigger += 1
        await render(window)
        await render(window)
        XCTAssertGreaterThan(scroll.contentSize.height, 10000)
        XCTAssertGreaterThan(scroll.contentOffset.y, 10000)
        state.latch = .init(isFollowing: false)
        state.position.scrollTo(id: "message-0", anchor: .top)
        await render(window)
        await render(window)
        XCTAssertGreaterThan(scroll.contentSize.height - scroll.bounds.height - scroll.contentOffset.y, 1000,
                             "The test must leave the bottom before requesting a return to it.")
        state.position.scrollTo(id: "message-1", anchor: .top)
        await render(window)
        await render(window)
        let beforeLeaf = try XCTUnwrap(findMessageLeaf(host.view, prefix: "Message 1."))
        let beforeY = beforeLeaf.convert(beforeLeaf.bounds, to: window).minY
        await ChatScrollPolicy.loadOlderMessages(
            position: Binding(get: { state.position }, set: { state.position = $0 }),
            firstMessageID: state.messages.first?.id
        ) {
            state.messages.insert(contentsOf: (-20..<0).map { index in
                ChatMessage(role: "user", content: String(repeating: "Older message \(index).\n", count: 15),
                            timestamp: 0, messageId: "message-\(index)")
            }, at: 0)
            return true
        }
        await render(window)
        await render(window)
        let afterLeaf = try XCTUnwrap(findMessageLeaf(host.view, prefix: "Message 1."))
        let afterY = afterLeaf.convert(afterLeaf.bounds, to: window).minY
        XCTAssertEqual(afterY, beforeY, accuracy: 2, "Loading history must keep the visible message in place.")
        state.latch = ChatScrollPolicy.resolveFollow(current: state.latch, event: .reset)
        let jumped = XCTKVOExpectation(keyPath: "contentOffset", object: scroll)
        jumped.handler = { object, _ in
            MainActor.assumeIsolated {
                guard let scroll = object as? UIScrollView else { return false }
                return scroll.contentSize.height - scroll.bounds.height
                    + scroll.adjustedContentInset.bottom - scroll.contentOffset.y <= 12
            }
        }
        withAnimation(ChatMotion.scrollToLatest(reduceMotion: false)) {
            state.position.scrollTo(edge: .bottom)
        }
        await fulfillment(of: [jumped], timeout: 5)
        await render(window)
        await render(window)
        let distance = max(0, scroll.contentSize.height - scroll.bounds.height
                           + scroll.adjustedContentInset.bottom - scroll.contentOffset.y)
        XCTAssertLessThanOrEqual(distance, 12, "Jump to latest must reach the actual bottom.")
        XCTAssertTrue(state.latch.isFollowing, "Lazy measurement must not disarm follow after a jump.")
        state.isStreaming = true
        await render(window)
        for chunk in 1...12 {
            let last = try XCTUnwrap(state.messages.last)
            state.messages[state.messages.count - 1] = ChatMessage(
                role: last.role,
                content: (last.content ?? "") + String(repeating: "Incoming text wraps onto new lines. ", count: 12),
                timestamp: last.timestamp, messageId: last.messageId
            )
            state.trigger += 1
            await render(window)
            await render(window)
            let distance = max(0, scroll.contentSize.height - scroll.bounds.height
                               + scroll.adjustedContentInset.bottom - scroll.contentOffset.y)
            XCTAssertLessThanOrEqual(distance, 12, "Streaming must remain at the bottom, chunk \(chunk).")
            XCTAssertTrue(state.latch.isFollowing, "Streaming measurement must not disarm follow.")
        }
        state.latch = .init(isFollowing: false)
        state.position.scrollTo(id: "message-1", anchor: .top)
        await render(window)
        await render(window)
        let readingLeaf = try XCTUnwrap(findMessageLeaf(host.view, prefix: "Message 1."))
        let readingY = readingLeaf.convert(readingLeaf.bounds, to: window).minY
        let last = try XCTUnwrap(state.messages.last)
        state.messages[state.messages.count - 1] = ChatMessage(
            role: last.role, content: (last.content ?? "") + String(repeating: "More incoming text. ", count: 40),
            timestamp: last.timestamp, messageId: last.messageId
        )
        state.trigger += 1
        await render(window)
        await render(window)
        let stillReadingLeaf = try XCTUnwrap(findMessageLeaf(host.view, prefix: "Message 1."))
        XCTAssertEqual(stillReadingLeaf.convert(stillReadingLeaf.bounds, to: window).minY, readingY, accuracy: 2)
        XCTAssertFalse(state.latch.isFollowing, "Incoming text must not pull a reader out of history.")
    }

    private func render(_ window: UIWindow) async {
        let rendered = expectation(description: "Transcript layout and display committed")
        let frame = TranscriptTestFrame {
            window.layoutIfNeeded()
            _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            rendered.fulfill()
        }
        frame.start()
        await fulfillment(of: [rendered], timeout: 10)
        frame.stop()
    }

    private func findScrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView($0) }.first
    }

    private func findMessageLeaf(_ view: UIView, prefix: String) -> ResponseSelectionLeafView? {
        if let leaf = view as? ResponseSelectionLeafView, leaf.text.hasPrefix(prefix) { return leaf }
        return view.subviews.lazy.compactMap { self.findMessageLeaf($0, prefix: prefix) }.first
    }
}

@MainActor
private final class TranscriptTestFrame: NSObject {
    let onFrame: () -> Void
    var link: CADisplayLink?
    var frames = 0
    init(onFrame: @escaping () -> Void) { self.onFrame = onFrame }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() {
        frames += 1
        guard frames == 3 else { return }
        stop()
        onFrame()
    }
}

@MainActor @Observable
private final class TranscriptLayoutFixture {
    var messages: [ChatMessage] = (0..<150).map { index in
        ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: String(repeating: "Message \(index). A paragraph with enough text to wrap across several lines.\n\n",
                                    count: index.isMultiple(of: 3) ? 30 : 2),
                    timestamp: 1, messageId: "message-\(index)")
    }
    var latch = ChatScrollPolicy.FollowLatch()
    var nearBottom = true
    var position = ScrollPosition(idType: String.self, edge: .bottom)
    var isStreaming = false
    var trigger = 0

    func metrics(_ metrics: ChatScrollMetrics) {
        let wasNear = nearBottom
        nearBottom = ChatScrollPolicy.isNearBottom(distanceFromBottom: metrics.distanceFromBottom, isStreaming: isStreaming)
        latch = ChatScrollPolicy.resolveFollow(current: latch, event: .contentScrolled(
            isAtBottom: ChatScrollPolicy.isAtBottom(distanceFromBottom: metrics.distanceFromBottom),
            isUserScrolling: metrics.isUserInteracting,
            movedAwayFromBottom: metrics.movedAwayFromBottom, wasNearBottom: wasNear
        ))
    }

    func jump() {
        position.scrollTo(edge: .bottom)
    }
}

private struct TranscriptLayoutFixtureView: View {
    let state: TranscriptLayoutFixture
    var body: some View {
        @Bindable var state = state
        return ChatTranscriptView(
            scrollPosition: $state.position,
            isLoading: false, errorMessage: nil, messages: state.messages,
            displayedTranscriptMessages: state.messages.enumerated().map {
                TranscriptMessage(loadedIndex: $0.offset, renderID: $0.element.id, anchorID: $0.element.id, message: $0.element)
            },
            compressionReferenceCard: nil, reasoningGroups: [], completedToolCallGroupsForAnchor: { _ in [] },
            liveReasoningText: "", reasoningAnchorMessageID: nil, liveToolCalls: [], toolCallAnchorMessageID: nil,
            streamingAssistantMessageID: state.isStreaming ? state.messages.last?.id : nil, liveTokensPerSecond: nil,
            activeStreamRecoveryState: .idle, clarificationPromptID: nil, hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: false, workingRowStartedAt: nil,
            showsScrollToBottomButton: !state.nearBottom, shouldFollowLatestMessage: state.latch.isFollowing,
            isDisclosureSettling: false, latestTranscriptMessageRole: "assistant", isScrolledNearBottom: state.nearBottom,
            activeStreamID: state.isStreaming ? "fixture-stream" : nil, streamingScrollTrigger: state.trigger, transcriptRelayoutScrollToken: 0,
            bottomAnchorID: "bottom", transcriptSpacing: 8, transcriptBottomInsetHeight: 80,
            scrollToBottomButtonBottomPadding: 80, localAttachmentPreviews: [:], listeningMessageID: nil,
            isViewingCachedData: false, hasOlderMessages: true, isLoadingOlderMessages: false,
            isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
            loadAttachmentImage: { _ in nil }, loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil }, loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "layout-test", actionContext: { _, _ in nil },
            shouldRenderMessageRow: { _ in true }, onLoadMessages: {}, onLoadOlderMessages: { false },
            onUpdateScrollMetrics: state.metrics, onFollowEvent: {
                state.latch = ChatScrollPolicy.resolveFollow(current: state.latch, event: $0)
            },
            onDisclosureToggle: {}, turnFolds: .none, terminalReplyRenderIDs: [], expandedTurnKeys: [],
            onToggleTurnFold: { _ in }, onDismissKeyboard: {},
            onScrollToBottom: state.jump, onScrollToLatestTranscriptMessage: state.jump,
            onScrollToLatestContent: { _ in state.jump() },
            onPreviewAttachment: { _, _ in }, onPreviewTranscriptMedia: { _ in }, onAskHermex: { _ in },
            onToggleListening: { _ in }, onRegenerate: { _ in }, onEdit: { _ in }, onFork: { _ in }, onCopy: { _ in }
        )
    }
}
