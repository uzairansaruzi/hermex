import SwiftUI
import XCTest
@testable import HermesMobile

final class ChatScrollPolicyTests: XCTestCase {
    func testCompletionJumpRemembersReaderTakeoverAfterFollowingRearms() {
        var run = ChatCompletionScrollPolicy()
        run.begin(streamID: "run", isFollowing: true)
        run.observe(.userScrollBegin)
        run.observe(.reset)
        XCTAssertFalse(run.consumeCompletion(streamID: "run", enabled: true))
    }

    func testBackgroundCompletionWaitsForActiveSceneAndStillHonorsReaderOwnership() {
        var run = ChatCompletionScrollPolicy()
        run.begin(streamID: "background", isFollowing: true)
        XCTAssertFalse(run.consumeCompletion(streamID: "background", enabled: true, sceneIsActive: false))
        XCTAssertTrue(run.consumeCompletion(streamID: "background", enabled: true, sceneIsActive: true))
        XCTAssertFalse(run.consumeCompletion(streamID: "background", enabled: true, sceneIsActive: true))

        run.begin(streamID: "reading", isFollowing: true)
        XCTAssertFalse(run.consumeCompletion(streamID: "reading", enabled: true, sceneIsActive: false))
        run.readerDidInteract()
        XCTAssertFalse(run.consumeCompletion(streamID: "reading", enabled: true, sceneIsActive: true))
    }

    func testCompletionJumpConsumesOnlyOwnedRunOnce() {
        var run = ChatCompletionScrollPolicy()
        run.begin(streamID: "run", isFollowing: true)
        XCTAssertFalse(run.consumeCompletion(streamID: "stale", enabled: true))
        XCTAssertTrue(run.consumeCompletion(streamID: "run", enabled: true))
        XCTAssertFalse(run.consumeCompletion(streamID: "run", enabled: true))
    }

    func testCompletionDefaultAndReaderAlreadyAboveDoNotJump() {
        var run = ChatCompletionScrollPolicy()
        run.begin(streamID: "default", isFollowing: true)
        XCTAssertFalse(run.consumeCompletion(streamID: "default", enabled: false))
        run.begin(streamID: "reading", isFollowing: false)
        XCTAssertFalse(run.consumeCompletion(streamID: "reading", enabled: true))
    }

    func testReattachmentCannotEraseReaderOwnershipAndNewRunReplacesPendingCompletion() {
        var run = ChatCompletionScrollPolicy()
        run.begin(streamID: "run", isFollowing: true)
        run.observe(.contentScrolled(isAtBottom: false, isUserScrolling: false, movedAwayFromBottom: true))
        run.begin(streamID: "run", isFollowing: true)
        XCTAssertFalse(run.consumeCompletion(streamID: "run", enabled: true))
        run.begin(streamID: "next", isFollowing: true)
        XCTAssertFalse(run.consumeCompletion(streamID: "run", enabled: true))
        XCTAssertTrue(run.consumeCompletion(streamID: "next", enabled: true))
    }

    func testCompletionTargetsStableFinalRowAndNeverPriorOrInterimReply() {
        func row(_ index: Int, _ role: String, _ renderID: String) -> TranscriptMessage {
            TranscriptMessage(loadedIndex: index, renderID: renderID, anchorID: "anchor-\(index)",
                              message: ChatMessage(role: role, content: "body", timestamp: nil, messageId: "server-\(index)"))
        }
        let prior = row(0, "assistant", "prior")
        let user = row(1, "user", "user")
        let interim = row(2, "assistant", "interim")
        let final = row(3, "assistant", "stable-final")
        XCTAssertNil(ChatCompletionScrollPolicy.finalResponseRenderID(
            in: [prior, user, interim], terminalReplyRenderIDs: ["prior"]
        ))
        XCTAssertEqual(ChatCompletionScrollPolicy.finalResponseRenderID(
            in: [prior, user, interim, final], terminalReplyRenderIDs: ["prior", "stable-final"]
        ), "stable-final")
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

    func testExplicitResetSurvivesLateDragSettlement() {
        let latch = reduce(Latch(), .userScrollBegin, .reset, .userScrollEnd(isAtBottom: false))
        XCTAssertTrue(latch.isFollowing)
        XCTAssertFalse(latch.ignoresCoastingGesture)
    }

    func testExplicitResetSurvivesCoastingMomentum() {
        let coasting = reduce(
            Latch(),
            .userScrollBegin,
            .reset,
            .contentScrolled(isAtBottom: false, isUserScrolling: true)
        )
        XCTAssertTrue(coasting.isFollowing)

        let settled = reduce(coasting, .userScrollEnd(isAtBottom: false))
        XCTAssertTrue(settled.isFollowing)
        XCTAssertFalse(settled.ignoresCoastingGesture)
        XCTAssertFalse(reduce(settled, .contentScrolled(isAtBottom: false, isUserScrolling: true)).isFollowing)
    }

    func testOnlyAStreamingSendThatAddsARowJumpsAReaderToTheEnd() {
        XCTAssertFalse(ChatScrollPolicy.streamingSendReArmsFollow(.queue))
        XCTAssertTrue(ChatScrollPolicy.streamingSendReArmsFollow(.steer))
    }

    func testNewDragAfterResetTurnsFollowOff() {
        let latch = reduce(Latch(), .reset, .userScrollBegin)
        XCTAssertFalse(latch.isFollowing)
        XCTAssertFalse(latch.ignoresCoastingGesture)
    }

    func testMomentumEndDecidesFromWhereItSettled() {
        XCTAssertFalse(follow(false, .userScrollEnd(isAtBottom: false)))
        XCTAssertTrue(follow(false, .userScrollEnd(isAtBottom: true)))
    }

    func testLayoutGrowthWhileOffNeverReArms() {
        XCTAssertFalse(follow(false, .contentScrolled(isAtBottom: false, isUserScrolling: false)))
    }

    func testLayoutGrowthWhileFollowingStaysOn() {
        XCTAssertTrue(follow(true, .contentScrolled(isAtBottom: false, isUserScrolling: false)))
    }

    func testNonGestureScrollThatLandsAtBottomFromNearbyReArms() {
        XCTAssertTrue(follow(false, .contentScrolled(isAtBottom: true, isUserScrolling: false, wasNearBottom: true)))
    }

    func testTransientBottomFromFarAboveDoesNotReArm() {
        XCTAssertFalse(follow(false, .contentScrolled(isAtBottom: true, isUserScrolling: false, wasNearBottom: false)))
    }

    func testScrollAwayFromBottomWithoutGestureTurnsFollowOff() {
        XCTAssertFalse(follow(true, .contentScrolled(isAtBottom: false, isUserScrolling: false, movedAwayFromBottom: true)))
    }

    func testExplicitResetSurvivesCoastingMomentumAwayFromBottom() {
        let latch = reduce(
            Latch(),
            .userScrollBegin,
            .reset,
            .contentScrolled(isAtBottom: false, isUserScrolling: true, movedAwayFromBottom: true)
        )
        XCTAssertTrue(latch.isFollowing)
    }

    private typealias Geometry = ChatScrollPolicy.ScrollGeometry

    func testDistanceGrowingPastStreamingThresholdIsAScrollAway() {
        let atBottom = Geometry(offsetY: 4300, contentHeight: 5000, visibleHeight: 700)
        let carriedAway = Geometry(offsetY: 3200, contentHeight: 5200, visibleHeight: 700)
        XCTAssertTrue(ChatScrollPolicy.isScrollingAwayFromBottom(previous: atBottom, current: carriedAway))
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(previous: nil, current: carriedAway))
    }

    func testJitterViewportAndFollowScrollsAreNotScrollAways() {
        let atBottom = Geometry(offsetY: 4300, contentHeight: 5000, visibleHeight: 700)
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: atBottom,
            current: Geometry(offsetY: 4300, contentHeight: 5150, visibleHeight: 700)
        ))
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: atBottom,
            current: Geometry(offsetY: 4300, contentHeight: 5000, visibleHeight: 400)
        ))
        let farAway = Geometry(offsetY: 1000, contentHeight: 5000, visibleHeight: 700)
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: farAway,
            current: Geometry(offsetY: 2000, contentHeight: 5000, visibleHeight: 700)
        ))
        XCTAssertFalse(ChatScrollPolicy.isScrollingAwayFromBottom(
            previous: atBottom,
            current: Geometry(offsetY: 4700, contentHeight: 5400, visibleHeight: 700)
        ))
    }

    func testLiveGestureWinsEvenAtBottom() {
        XCTAssertFalse(follow(true, .contentScrolled(isAtBottom: true, isUserScrolling: true)))
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

    func testReflowKeepsTheReadingLineAtTheSameShareOfItsRow() throws {
        let frames = [
            "prompt": CGRect(x: 0, y: 0, width: 358, height: 100),
            "reply": CGRect(x: 0, y: 108, width: 358, height: 200)
        ]
        let anchor = try XCTUnwrap(ChatScrollPolicy.reflowAnchor(readingLineY: 188, isAtTop: false, rowFrames: frames))
        XCTAssertEqual(anchor.id, "reply")

        let rewrapped = CGRect(x: 0, y: 300, width: 300, height: 400)
        XCTAssertEqual(ChatScrollPolicy.reflowReadingLineY(anchor: anchor, newFrame: rewrapped), 460, accuracy: 0.001)
    }

    func testReflowAnchorIsNilAtTheTopAndAboveTheFirstRow() {
        let frames = ["reply": CGRect(x: 0, y: 16, width: 358, height: 200)]
        XCTAssertNil(ChatScrollPolicy.reflowAnchor(readingLineY: 40, isAtTop: true, rowFrames: frames))
        XCTAssertNil(ChatScrollPolicy.reflowAnchor(readingLineY: 10, isAtTop: false, rowFrames: frames))
    }

    func testTheScreensOwnResultWinsEvenForAWebLink() {
        let decision = TranscriptLinkRouter.decision(for: URL(string: "https://example.com")!, hostResult: .handled)
        guard case .host = decision else { return XCTFail("Expected the screen's result, got \(decision)") }
    }

    func testAnotherLinkTheScreenLeavesGoesToTheSystem() {
        let decision = TranscriptLinkRouter.decision(for: URL(string: "mailto:someone@example.com")!, hostResult: nil)
        guard case .system = decision else { return XCTFail("Expected the system, got \(decision)") }
    }

    @MainActor
    func testTappingAWebLinkTheScreenLeavesOpensItInTheInAppBrowser() {
        let router = TranscriptLinkRouter()
        let link = URL(string: "https://example.com/docs")!
        var opened: URL?
        router.handler = { _ in nil }
        router.openInAppBrowser = { opened = $0 }

        router.openURL(link)

        XCTAssertEqual(opened, link)
    }
}

@MainActor
final class ChatTranscriptEnvironmentStabilityTests: XCTestCase {
    func testDisclosureReadersSkipOwnerPassesAndRunTheLatestHandler() throws {
        let probe = EnvironmentStabilityProbe()
        let window = host(DisclosureOwner(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }

        advance(probe, window: window, passes: 3)

        XCTAssertEqual(probe.ownerPasses, 4, "The owner must re-run on each tick for this to test anything")
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
        XCTAssertLessThanOrEqual(probe.readerPasses, 2)
        try XCTUnwrap(probe.openURL)(URL(string: "https://example.com/file.swift")!)
        XCTAssertEqual(probe.handledTick, 3)
    }

    func testLinkReadersSkipOwnerPassesWhileTheKeyboardIsUp() throws {
        let keyboard = try showKeyboard()
        defer { keyboard.endEditing(true); keyboard.isHidden = true }
        let probe = EnvironmentStabilityProbe()
        let window = host(LinkOwner(probe: probe))
        defer { window.isHidden = true; window.rootViewController = nil }

        advance(probe, window: window, passes: 3)

        XCTAssertEqual(probe.ownerPasses, 4, "The owner must re-run on each tick for this to test anything")
        XCTAssertLessThanOrEqual(probe.readerPasses, 2)
    }

    func testHandlersThatCaptureTheOwnerDoNotOutliveIt() {
        let released = expectation(description: "The owner's state is released with its screen")
        autoreleasepool {
            let window = host(SelfCapturingOwner(onRelease: released.fulfill))
            window.isHidden = true
            window.rootViewController = nil
        }
        wait(for: [released], timeout: 2)
    }

    private func showKeyboard() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let field = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        window.addSubview(field)
        window.makeKeyAndVisible()
        let shown = XCTNSNotificationExpectation(name: UIResponder.keyboardDidShowNotification)
        field.becomeFirstResponder()
        wait(for: [shown], timeout: 10)
        return window
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

    private func open(_ url: URL) -> OpenURLAction.Result? {
        toggles += 1
        return nil
    }
}

@MainActor
final class StreamingFollowTriggerTests: XCTestCase {
    func testBumpsFireTheScrollWithoutReRunningTheOwner() {
        let probe = FollowTriggerProbe()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = UIHostingController(rootView: FollowTriggerOwner(probe: probe))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }

        for _ in 0..<3 {
            probe.trigger += 1
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
        }

        XCTAssertEqual(probe.fires, 3)
        XCTAssertEqual(probe.ownerPasses, 1)
    }
}

@Observable
private final class FollowTriggerProbe {
    var trigger = 0
    @ObservationIgnored var ownerPasses = 0
    @ObservationIgnored var fires = 0
}

private struct FollowTriggerOwner: View {
    let probe: FollowTriggerProbe

    var body: some View {
        probe.ownerPasses += 1
        return Color.clear.background {
            StreamingFollowTrigger(trigger: { probe.trigger }) { probe.fires += 1 }
        }
    }
}
