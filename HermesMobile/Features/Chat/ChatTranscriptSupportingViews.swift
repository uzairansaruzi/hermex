import SwiftUI
import UIKit

struct ChatScrollMetrics: Equatable {
    let distanceFromBottom: CGFloat
    let isUserInteracting: Bool
    /// A scroll with no gesture carried the reader away from the bottom since
    /// the last delivered report; see `ChatScrollPolicy.isScrollingAwayFromBottom`.
    let movedAwayFromBottom: Bool
}

/// Reports the transcript's scroll geometry and the gesture events that drive
/// the follow latch (`ChatScrollPolicy.FollowEvent`). Metrics arrive on every
/// offset or size change; follow events arrive only when a drag begins and when
/// the gesture, including any momentum, has settled.
struct ChatScrollObserver: UIViewRepresentable {
    let isStreaming: Bool
    let scrollPositionController: ChatScrollPositionController?
    let onFollowEvent: @MainActor (ChatScrollPolicy.FollowEvent) -> Void
    let onMetrics: @MainActor (ChatScrollMetrics) -> Void

    init(
        isStreaming: Bool,
        scrollPositionController: ChatScrollPositionController? = nil,
        onFollowEvent: @escaping @MainActor (ChatScrollPolicy.FollowEvent) -> Void = { _ in },
        onMetrics: @escaping @MainActor (ChatScrollMetrics) -> Void
    ) {
        self.isStreaming = isStreaming
        self.scrollPositionController = scrollPositionController
        self.onFollowEvent = onFollowEvent
        self.onMetrics = onMetrics
    }

    private var metricContext: MetricContext {
        MetricContext(isStreaming: isStreaming)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            metricContext: metricContext,
            scrollPositionController: scrollPositionController,
            onFollowEvent: onFollowEvent,
            onMetrics: onMetrics
        )
    }

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.onMetrics = onMetrics
        context.coordinator.onFollowEvent = onFollowEvent
        context.coordinator.scrollPositionController = scrollPositionController
        uiView.coordinator = context.coordinator
        context.coordinator.updateMetricContext(metricContext)

        context.coordinator.attachIfNeeded(from: uiView, delivery: .deferred)
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: Coordinator) {
        uiView.coordinator = nil
        coordinator.detach()
    }

    struct MetricContext: Equatable {
        let isStreaming: Bool
    }

    @MainActor
    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attachIfNeeded(from: self, delivery: .deferred)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attachIfNeeded(from: self, delivery: .deferred)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.reportMetrics(delivery: .deferred)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        enum MetricDelivery {
            case immediate
            case deferred
        }

        var onMetrics: @MainActor (ChatScrollMetrics) -> Void
        var onFollowEvent: @MainActor (ChatScrollPolicy.FollowEvent) -> Void

        private weak var scrollView: UIScrollView?
        private weak var observedPanGesture: UIPanGestureRecognizer?
        private var observations: [NSKeyValueObservation] = []
        private var metricContext: MetricContext
        private var lastMetrics: ChatScrollMetrics?
        private var pendingMetrics: ChatScrollMetrics?
        /// Geometry behind the last report the transcript received. Reports
        /// coalesce per run loop, so the away-from-bottom check compares
        /// delivered states, not every intermediate KVO tick.
        private var deliveredGeometry: ChatScrollPolicy.ScrollGeometry?
        private var pendingGeometry: ChatScrollPolicy.ScrollGeometry?
        private var hasScheduledMetricDelivery = false
        /// True from the first drag movement until the gesture, including any
        /// momentum, comes to rest. Mirrors the "user scroll session" the follow
        /// latch reasons about.
        private var isUserScrollSessionActive = false
        private var settleWorkItem: DispatchWorkItem?
        var scrollPositionController: ChatScrollPositionController? {
            didSet {
                guard oldValue !== scrollPositionController else { return }
                oldValue?.detach()
                if let scrollView {
                    scrollPositionController?.attach(to: scrollView)
                }
            }
        }

        init(
            metricContext: MetricContext,
            scrollPositionController: ChatScrollPositionController?,
            onFollowEvent: @escaping @MainActor (ChatScrollPolicy.FollowEvent) -> Void,
            onMetrics: @escaping @MainActor (ChatScrollMetrics) -> Void
        ) {
            self.metricContext = metricContext
            self.scrollPositionController = scrollPositionController
            self.onFollowEvent = onFollowEvent
            self.onMetrics = onMetrics
        }

        func updateMetricContext(_ newContext: MetricContext) {
            guard metricContext != newContext else { return }

            metricContext = newContext
            lastMetrics = nil
        }

        func attachIfNeeded(from view: UIView, delivery: MetricDelivery) {
            guard let scrollView = enclosingScrollView(for: view) else { return }

            guard scrollView !== self.scrollView else {
                scrollPositionController?.attach(to: scrollView)
                reportMetrics(delivery: delivery)
                return
            }

            observations.removeAll()
            lastMetrics = nil
            deliveredGeometry = nil
            endUserScrollSessionSilently()
            self.scrollView = scrollView
            scrollPositionController?.attach(to: scrollView)

            observedPanGesture?.removeTarget(self, action: nil)
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePanGesture(_:)))
            observedPanGesture = scrollView.panGestureRecognizer

            observations = [
                scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    Self.reportObservedMetrics(for: self)
                },
                scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    Self.reportObservedMetrics(for: self)
                }
            ]

            reportMetrics(delivery: delivery)
        }

        func detach() {
            observations.removeAll()
            observedPanGesture?.removeTarget(self, action: nil)
            observedPanGesture = nil
            endUserScrollSessionSilently()
            scrollPositionController?.detach()
            lastMetrics = nil
            deliveredGeometry = nil
            pendingMetrics = nil
            pendingGeometry = nil
            hasScheduledMetricDelivery = false
            scrollView = nil
        }

        // MARK: Follow latch events

        @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                cancelSettle()
                isUserScrollSessionActive = true
                onFollowEvent(.userScrollBegin)
            case .ended, .cancelled, .failed:
                guard isUserScrollSessionActive, let scrollView else { return }
                // Remember where the finger lifted: streaming growth during the
                // momentum-detection window must not turn a release at the live
                // edge into an opt-out from follow.
                let releaseIsAtBottom = isAtBottom(scrollView)
                scheduleSettle(after: ChatScrollPolicy.dragSettleDelay) { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    // Momentum announced itself; its ticks now own the session.
                    if scrollView.isDecelerating { return }
                    self.finishUserScrollSession(isAtBottom: releaseIsAtBottom)
                }
            default:
                break
            }
        }

        /// Each momentum tick pushes the settle check out; the check that
        /// survives runs once deceleration has stopped moving the content.
        private func trackMomentum(_ scrollView: UIScrollView) {
            guard isUserScrollSessionActive, scrollView.isDecelerating else { return }
            scheduleSettle(after: ChatScrollPolicy.momentumSettleDelay) { [weak self] in
                self?.finishUserScrollSessionIfSettled()
            }
        }

        private func finishUserScrollSessionIfSettled() {
            guard isUserScrollSessionActive, let scrollView else { return }
            // A finger back on the glass either becomes a new drag (pan .began)
            // or lifts without one (pan .failed); both paths re-enter above.
            if scrollView.isDragging || scrollView.isTracking { return }
            if scrollView.isDecelerating {
                scheduleSettle(after: ChatScrollPolicy.momentumSettleDelay) { [weak self] in
                    self?.finishUserScrollSessionIfSettled()
                }
                return
            }
            finishUserScrollSession(isAtBottom: isAtBottom(scrollView))
        }

        private func finishUserScrollSession(isAtBottom: Bool) {
            cancelSettle()
            isUserScrollSessionActive = false
            onFollowEvent(.userScrollEnd(isAtBottom: isAtBottom))
        }

        private func endUserScrollSessionSilently() {
            cancelSettle()
            isUserScrollSessionActive = false
        }

        private func scheduleSettle(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            cancelSettle()
            let workItem = DispatchWorkItem {
                MainActor.assumeIsolated(body)
            }
            settleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func cancelSettle() {
            settleWorkItem?.cancel()
            settleWorkItem = nil
        }

        private func isAtBottom(_ scrollView: UIScrollView) -> Bool {
            guard let distance = distanceFromBottom(of: scrollView) else { return false }
            return ChatScrollPolicy.isAtBottom(distanceFromBottom: distance)
        }

        private func geometry(of scrollView: UIScrollView) -> ChatScrollPolicy.ScrollGeometry? {
            let inset = scrollView.adjustedContentInset
            let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
            guard visibleHeight > 0 else { return nil }

            return ChatScrollPolicy.ScrollGeometry(
                offsetY: scrollView.contentOffset.y + inset.top,
                contentHeight: scrollView.contentSize.height,
                visibleHeight: visibleHeight
            )
        }

        private func distanceFromBottom(of scrollView: UIScrollView) -> CGFloat? {
            geometry(of: scrollView)?.distanceFromBottom
        }

        func reportMetrics(delivery: MetricDelivery) {
            guard let scrollView else { return }
            trackMomentum(scrollView)

            guard let geometry = geometry(of: scrollView) else { return }
            let isUserInteracting = scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating
            // While a disclosure pin holds the offset, a toggled row growing
            // below the reader increases the distance without anyone scrolling.
            let isPinned = scrollPositionController?.isHoldingPosition == true
            let metrics = ChatScrollMetrics(
                distanceFromBottom: geometry.distanceFromBottom,
                isUserInteracting: isUserInteracting,
                movedAwayFromBottom: !isUserInteracting && !isPinned
                    && ChatScrollPolicy.isScrollingAwayFromBottom(previous: deliveredGeometry, current: geometry)
            )
            guard metrics != lastMetrics else { return }

            lastMetrics = metrics

            switch delivery {
            case .immediate:
                deliveredGeometry = geometry
                onMetrics(metrics)
            case .deferred:
                pendingMetrics = metrics
                pendingGeometry = geometry
                guard !hasScheduledMetricDelivery else { return }

                hasScheduledMetricDelivery = true
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let metrics = self.pendingMetrics
                        let geometry = self.pendingGeometry
                        self.pendingMetrics = nil
                        self.pendingGeometry = nil
                        self.hasScheduledMetricDelivery = false
                        guard let metrics, self.lastMetrics == metrics else { return }
                        self.deliveredGeometry = geometry
                        self.onMetrics(metrics)
                    }
                }
            }
        }

        nonisolated private static func reportObservedMetrics(for coordinator: Coordinator?) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak coordinator] in
                    MainActor.assumeIsolated {
                        coordinator?.reportMetrics(delivery: .deferred)
                    }
                }
                return
            }

            MainActor.assumeIsolated {
                coordinator?.reportMetrics(delivery: .deferred)
            }
        }

        private func enclosingScrollView(for view: UIView) -> UIScrollView? {
            var current = view.superview

            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    return scrollView
                }

                current = candidate.superview
            }

            return nil
        }
    }
}

/// Keeps the reader's exact vertical position through a layout change SwiftUI
/// would otherwise move them for. Two cases:
///
/// - **Prepend.** Older rows are inserted above the reader; the offset shifts
///   by the net content-height growth. `ScrollViewProxy.scrollTo(_:anchor:)`
///   can only align a row to a coarse anchor, which loses the gap formerly
///   occupied by the Load Older button and causes a visible hop.
/// - **Hold.** A disclosure toggle grows or shrinks a row below the reader;
///   the offset must not move at all. SwiftUI can re-apply a default anchor on
///   that size change (seen at the exact top after a status-bar scroll); that
///   shows up as an offset change in the same run-loop turn as a size change
///   and is put back. Any other offset change is someone scrolling on purpose
///   (VoiceOver, a hardware keyboard, a follow scroll) and releases the hold.
///
/// The controller snapshots the UIKit scroll geometry, then corrects during
/// the following layout passes for a bounded window. Corrections are
/// deliberately non-animated: they preserve an existing position rather than
/// navigating to a new one. Any user movement releases the hold.
@MainActor
final class ChatScrollPositionController {
    private enum Mode {
        /// Offset follows the net content-height growth.
        case prepend
        /// Offset stays put; SwiftUI-driven offset changes are reverted.
        case hold
    }

    private weak var scrollView: UIScrollView?
    private var mode = Mode.prepend
    /// Set by `capture()`, cleared by anything that replaces the baseline, so
    /// a hold armed while the older-message request is in flight cannot be
    /// mistaken for the prepend capture when the request lands.
    private var hasPrependCapture = false
    private var baselineContentHeight: CGFloat?
    private var baselineOffsetY: CGFloat?
    private var contentSizeObservation: NSKeyValueObservation?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var completionTask: Task<Void, Never>?
    private var quietReleaseTask: Task<Void, Never>?
    private var isApplyingCompensation = false
    /// Set when a hold had to undo an offset SwiftUI applied. SwiftUI's own
    /// notion of the offset is then stale, and lazy rows it believes are
    /// off-screen stop hit-testing until a scroll it performed itself resyncs
    /// it; `resyncAfterHold` is that scroll.
    private var didRevertSwiftUIOffset = false
    private var resyncAfterHold: (() -> Void)?
    /// True from a content-size change until the end of the same run-loop
    /// turn: an offset change in that window is SwiftUI re-anchoring, not a
    /// scroll. `lastObservedContentHeight` covers the offset change UIKit
    /// makes from inside the content-size setter, before that callback runs.
    private var contentSizeChangedThisTurn = false
    private var lastObservedContentHeight: CGFloat?

    var isHoldingPosition: Bool {
        mode == .hold && baselineOffsetY != nil
    }

    func attach(to scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        cancelPreservation()
        self.scrollView = scrollView
    }

    func detach() {
        cancelPreservation()
        scrollView = nil
    }

    @discardableResult
    func capture() -> Bool {
        cancelPreservation()
        guard let scrollView else { return false }

        baselineContentHeight = scrollView.contentSize.height
        baselineOffsetY = scrollView.contentOffset.y
        hasPrependCapture = true
        return true
    }

    /// Arms compensation before SwiftUI performs the prepend layout. Returns
    /// false when the user moved the scroll view while the request was in
    /// flight, or a disclosure hold replaced the capture meanwhile, leaving the
    /// caller free to use its coarse fallback instead of overriding movement it
    /// does not own.
    @discardableResult
    func restoreAfterPrepend() -> Bool {
        guard hasPrependCapture,
              let scrollView,
              let baselineOffsetY,
              baselineContentHeight != nil,
              !scrollView.isDragging,
              !scrollView.isTracking,
              !scrollView.isDecelerating,
              abs(scrollView.contentOffset.y - baselineOffsetY) <= 1
        else {
            cancelPreservation()
            return false
        }

        // Text and attachment layout can settle over several run-loop passes.
        // Keep applying the same net-height correction for a short bounded
        // window, then release ownership back to normal scrolling.
        beginPreservation(mode: .prepend, scrollView: scrollView, window: 1)
        return true
    }

    /// Pins the current offset: a disclosure toggle is about to change a row's
    /// height below the reader. The pin releases once the content size has been
    /// quiet for `ChatScrollPolicy.disclosureHoldQuietPeriod`, or after
    /// `disclosureHoldMaximum` at the latest. No-op while the user is moving the
    /// transcript; their gesture owns the position.
    func holdPosition(resync: @escaping () -> Void) {
        cancelPreservation()
        guard let scrollView,
              !scrollView.isDragging,
              !scrollView.isTracking,
              !scrollView.isDecelerating
        else { return }

        baselineContentHeight = scrollView.contentSize.height
        baselineOffsetY = scrollView.contentOffset.y
        lastObservedContentHeight = scrollView.contentSize.height
        resyncAfterHold = resync
        beginPreservation(mode: .hold, scrollView: scrollView, window: ChatScrollPolicy.disclosureHoldMaximum)
        scheduleQuietRelease()
    }

    /// Hold ran to completion (quiet or capped): let go, then resync SwiftUI
    /// if the hold had to fight it. A hold ended by a gesture or a deliberate
    /// scroll needs no resync; that scroll does it.
    private func finishHold() {
        applyCompensation()
        let resync = Self.shouldResync(
            didRevertSwiftUIOffset: didRevertSwiftUIOffset,
            heldOffsetY: baselineOffsetY,
            minimumOffsetY: scrollView.map { -$0.adjustedContentInset.top }
        ) ? resyncAfterHold : nil
        cancelPreservation()
        resync?()
    }

    /// The resync is a SwiftUI scroll to the transcript's top, so it only
    /// describes the held position when that position is the top. Anchor
    /// re-application has only been seen there (after a status-bar scroll);
    /// anywhere else, leave SwiftUI alone rather than hop.
    nonisolated static func shouldResync(
        didRevertSwiftUIOffset: Bool,
        heldOffsetY: CGFloat?,
        minimumOffsetY: CGFloat?
    ) -> Bool {
        guard didRevertSwiftUIOffset, let heldOffsetY, let minimumOffsetY else { return false }
        return heldOffsetY <= minimumOffsetY + 0.5
    }

    /// Ends a disclosure pin early: the transcript is about to scroll on
    /// purpose (follow, scroll-to-bottom, keyboard). A prepend preservation is
    /// left alone.
    func releaseHold() {
        guard mode == .hold else { return }
        cancelPreservation()
    }

    private func scheduleQuietRelease() {
        quietReleaseTask?.cancel()
        quietReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ChatScrollPolicy.disclosureHoldQuietPeriod))
            guard !Task.isCancelled, let self else { return }
            self.finishHold()
        }
    }

    private func beginPreservation(mode: Mode, scrollView: UIScrollView, window: TimeInterval) {
        self.mode = mode
        completionTask?.cancel()
        quietReleaseTask?.cancel()
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
            Self.handleObservedContentSizeChange(for: self, scrollView: scrollView)
        }
        contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            Self.handleObservedOffsetChange(for: self, scrollView: scrollView)
        }

        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self else { return }
            if mode == .hold {
                self.finishHold()
            } else {
                self.applyCompensation()
                self.cancelPreservation()
            }
        }
    }

    func cancelPreservation() {
        mode = .prepend
        hasPrependCapture = false
        contentSizeObservation = nil
        contentOffsetObservation = nil
        completionTask?.cancel()
        completionTask = nil
        quietReleaseTask?.cancel()
        quietReleaseTask = nil
        didRevertSwiftUIOffset = false
        resyncAfterHold = nil
        contentSizeChangedThisTurn = false
        lastObservedContentHeight = nil
        baselineContentHeight = nil
        baselineOffsetY = nil
        isApplyingCompensation = false
    }

    nonisolated private static func handleObservedContentSizeChange(
        for controller: ChatScrollPositionController?,
        scrollView: UIScrollView
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak controller, weak scrollView] in
                MainActor.assumeIsolated {
                    guard let scrollView else { return }
                    controller?.handleContentSizeChange(scrollView)
                }
            }
            return
        }

        MainActor.assumeIsolated {
            controller?.handleContentSizeChange(scrollView)
        }
    }

    private func handleContentSizeChange(_ scrollView: UIScrollView) {
        // A callback that outlived a detach must not touch the new attachment.
        guard scrollView === self.scrollView else { return }

        applyCompensation()
        if mode == .hold {
            contentSizeChangedThisTurn = true
            lastObservedContentHeight = scrollView.contentSize.height
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.contentSizeChangedThisTurn = false
                }
            }
            scheduleQuietRelease()
        }
    }

    nonisolated private static func handleObservedOffsetChange(
        for controller: ChatScrollPositionController?,
        scrollView: UIScrollView
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak controller, weak scrollView] in
                MainActor.assumeIsolated {
                    guard let scrollView else { return }
                    controller?.handleOffsetChange(scrollView)
                }
            }
            return
        }

        MainActor.assumeIsolated {
            controller?.handleOffsetChange(scrollView)
        }
    }

    /// User movement releases the preservation. In hold mode an offset change
    /// riding on a size change is SwiftUI re-anchoring and is put back; any
    /// other offset change is a deliberate scroll and releases the hold.
    private func handleOffsetChange(_ scrollView: UIScrollView) {
        guard !isApplyingCompensation, scrollView === self.scrollView else { return }

        if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
            cancelPreservation()
        } else if mode == .hold {
            let sizeIsChanging = contentSizeChangedThisTurn
                || scrollView.contentSize.height != lastObservedContentHeight
            if sizeIsChanging {
                applyCompensation()
            } else if let targetY = compensatedOffsetY(in: scrollView),
                      abs(scrollView.contentOffset.y - targetY) > 0.5 {
                cancelPreservation()
            }
        }
    }

    private func compensatedOffsetY(in scrollView: UIScrollView) -> CGFloat? {
        guard let baselineContentHeight, let baselineOffsetY else { return nil }

        return Self.compensatedOffsetY(
            baselineOffsetY: baselineOffsetY,
            contentHeightDelta: mode == .prepend ? scrollView.contentSize.height - baselineContentHeight : 0,
            adjustedInset: scrollView.adjustedContentInset,
            contentSizeHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height
        )
    }

    private func applyCompensation() {
        guard let scrollView, let targetY = compensatedOffsetY(in: scrollView) else { return }
        guard abs(scrollView.contentOffset.y - targetY) > 0.5 else { return }

        if mode == .hold {
            didRevertSwiftUIOffset = true
        }
        isApplyingCompensation = true
        var offset = scrollView.contentOffset
        offset.y = targetY
        scrollView.setContentOffset(offset, animated: false)
        isApplyingCompensation = false
    }

    nonisolated static func compensatedOffsetY(
        baselineOffsetY: CGFloat,
        contentHeightDelta: CGFloat,
        adjustedInset: UIEdgeInsets,
        contentSizeHeight: CGFloat,
        boundsHeight: CGFloat
    ) -> CGFloat {
        let minimumY = -adjustedInset.top
        let maximumY = max(
            minimumY,
            contentSizeHeight - boundsHeight + adjustedInset.bottom
        )
        return min(max(baselineOffsetY + contentHeightDelta, minimumY), maximumY)
    }
}

/// Pins a subtree to left-to-right regardless of the surrounding chat layout
/// direction, so code, math, data tables, tool-call bodies, file paths, and
/// images never render mirrored inside an RTL message (issue #259). A fixed
/// `layoutDirection` also isolates the subtree's bidi resolution from the parent
/// paragraph direction.
///
/// Forcing LTR also changes how the *parent* resolves this view's
/// `.leading`/`.trailing` alignment guides: an LTR child inside an RTL
/// `VStack(alignment: .leading)` reports its leading edge as its physical left,
/// so the RTL parent — which pins `.leading` to its right edge — would hug or push
/// a narrower-than-container child off the wrong side. When the parent is RTL we
/// remap the guides back to the parent's expectation; in LTR (the default) the
/// guide closures return the unmodified values, so it is a no-op.
private struct ForcedLeftToRightModifier: ViewModifier {
    @Environment(\.layoutDirection) private var parentDirection

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, .leftToRight)
            .alignmentGuide(.leading) { dimensions in
                parentDirection == .rightToLeft ? dimensions[.trailing] : dimensions[.leading]
            }
            .alignmentGuide(.trailing) { dimensions in
                parentDirection == .rightToLeft ? dimensions[.leading] : dimensions[.trailing]
            }
    }
}

extension View {
    func forcedLeftToRight() -> some View {
        modifier(ForcedLeftToRightModifier())
    }
}

struct ChatVerticalScrollAxisGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> ChatVerticalScrollAxisGuardView {
        ChatVerticalScrollAxisGuardView()
    }

    func updateUIView(_ uiView: ChatVerticalScrollAxisGuardView, context: Context) {
        // The transcript flips wholesale under the chat RTL toggle (#259); read
        // the resolved direction here so the guard pins the horizontal offset to
        // the layout-direction-aware leading edge (folds in #139).
        uiView.isRightToLeft = context.environment.layoutDirection == .rightToLeft
        uiView.attachToNearestScrollViewIfNeeded()
    }

    static func dismantleUIView(_ uiView: ChatVerticalScrollAxisGuardView, coordinator: ()) {
        uiView.detach()
    }
}

@MainActor
final class ChatVerticalScrollAxisGuardView: UIView {
    private weak var guardedScrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []

    /// Whether the guarded transcript is laid out right-to-left (#259). Drives
    /// which physical edge the horizontal offset rests against; re-clamps on change.
    var isRightToLeft = false {
        didSet {
            guard oldValue != isRightToLeft else { return }
            clampHorizontalOffset()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard superview != nil else {
            detach()
            return
        }

        attachToNearestScrollViewIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachToNearestScrollViewIfNeeded()
    }

    func attachToNearestScrollViewIfNeeded() {
        guard let scrollView = enclosingScrollView() else { return }

        guard scrollView !== guardedScrollView else {
            clampHorizontalOffset()
            return
        }

        observations.removeAll()
        guardedScrollView = scrollView
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true

        observations = [
            scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            },
            scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            },
            // Under RTL the pinned rest offset depends on contentSize.width, so a
            // width change (a wide table/streaming code block loading) must re-clamp
            // immediately instead of waiting for the next offset/bounds change (#259).
            scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            }
        ]

        clampHorizontalOffset()
    }

    func detach() {
        observations.removeAll()
        guardedScrollView = nil
    }

    private func enclosingScrollView() -> UIScrollView? {
        sequence(first: superview, next: { $0?.superview })
            .first { $0 is UIScrollView } as? UIScrollView
    }

    private func clampHorizontalOffset() {
        guard let scrollView = guardedScrollView else { return }

        let pinnedX = Self.pinnedHorizontalOffsetX(
            isRightToLeft: isRightToLeft,
            adjustedInset: scrollView.adjustedContentInset,
            contentSize: scrollView.contentSize,
            boundsSize: scrollView.bounds.size
        )
        guard abs(scrollView.contentOffset.x - pinnedX) > 0.5 else { return }

        var offset = scrollView.contentOffset
        offset.x = pinnedX
        scrollView.setContentOffset(offset, animated: false)
    }

    /// The horizontal content offset the transcript should rest at, pinned to the
    /// layout-direction-aware *leading* edge so the vertical-only transcript never
    /// drifts sideways (#130) under either direction (#139/#259).
    ///
    /// LTR leading is the physical left, so it rests at `-left inset` exactly as
    /// before — this branch is byte-for-byte the prior behavior. RTL leading is
    /// the physical right, so it rests at the content's trailing edge
    /// (`contentSize.width + right inset - viewport width`), clamped to never fall
    /// below the LTR minimum. When the transcript has no horizontal overflow and
    /// no horizontal inset — its normal case — both branches resolve to `0`.
    nonisolated static func pinnedHorizontalOffsetX(
        isRightToLeft: Bool,
        adjustedInset: UIEdgeInsets,
        contentSize: CGSize,
        boundsSize: CGSize
    ) -> CGFloat {
        let leftEdge = -adjustedInset.left
        guard isRightToLeft else { return leftEdge }

        let rightEdge = contentSize.width + adjustedInset.right - boundsSize.width
        return max(leftEdge, rightEdge)
    }

    nonisolated private static func clampObservedHorizontalOffset(for guardView: ChatVerticalScrollAxisGuardView?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak guardView] in
                MainActor.assumeIsolated {
                    guardView?.clampHorizontalOffset()
                }
            }
            return
        }

        MainActor.assumeIsolated {
            guardView?.clampHorizontalOffset()
        }
    }
}

/// Transcript tail row for the active run: three static dots and a
/// "Working for" counter that ticks once a second from the run's start date.
/// The `TimelineView` scopes each tick to this row, so message rows above it
/// are not re-evaluated.
struct ChatWorkingRowView: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 8) {
                dots

                Text("Working for \(ChatWorkingElapsedFormatter.label(startedAt: startedAt, now: context.date))")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                String(
                    localized: "Hermes has been working for \(ChatWorkingElapsedFormatter.spokenLabel(startedAt: startedAt, now: context.date))"
                )
            )
        }
        .padding(.leading, 4)
        .padding(.vertical, 6)
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach([1.0, 0.8, 0.6], id: \.self) { opacity in
                Circle()
                    .fill(.secondary)
                    .opacity(opacity)
                    .frame(width: 4, height: 4)
            }
        }
    }
}

struct BottomComposerMaterialFade: View {
    @Environment(\.colorScheme) private var colorScheme

    let composerHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Rectangle()
                    .fill(.bar)

                if colorScheme == .dark {
                    Rectangle()
                        .fill(Color.black.opacity(0.58))
                }
            }
            .frame(height: max(96, composerHeight + 34))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.18), location: 0.18),
                        .init(color: .black.opacity(0.72), location: 0.46),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct StreamRecoveryStatusView: View {
    let state: ActiveStreamRecoveryState

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .idle:
            return String(localized: "Stream active")
        case .checking:
            return String(localized: "Checking stream")
        case .reconnecting:
            return String(localized: "Reconnecting stream")
        }
    }
}

struct ChatTranscriptLoadingSkeletonView: View {
    private let rows = ChatTranscriptSkeletonRowConfiguration.loadingRows

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(rows) { row in
                    ChatTranscriptLoadingSkeletonRow(configuration: row)
                }

                Color.clear
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.top, 16)
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading messages")
    }
}

private struct ChatTranscriptLoadingSkeletonRow: View {
    let configuration: ChatTranscriptSkeletonRowConfiguration

    var body: some View {
        switch configuration.role {
        case .assistant:
            assistantRow
        case .user:
            userRow
        }
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(configuration.lines) { line in
                skeletonLine(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private var userRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 48)

            VStack(alignment: .trailing, spacing: 8) {
                ForEach(configuration.lines) { line in
                    skeletonLine(line)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemFill))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private func skeletonLine(_ line: ChatTranscriptSkeletonLine) -> some View {
        Text(verbatim: line.text)
            .font(.body)
            .lineLimit(1)
            .frame(maxWidth: line.maxWidth, alignment: configuration.role == .user ? .trailing : .leading)
    }
}

private struct ChatTranscriptSkeletonRowConfiguration: Identifiable {
    enum Role {
        case assistant
        case user
    }

    let id: String
    let role: Role
    let lines: [ChatTranscriptSkeletonLine]

    static let loadingRows: [ChatTranscriptSkeletonRowConfiguration] = [
        ChatTranscriptSkeletonRowConfiguration(
            id: "assistant-intro",
            role: .assistant,
            lines: [
                ChatTranscriptSkeletonLine(id: "a1", text: "Reviewing the latest project context and open tasks.", maxWidth: 320),
                ChatTranscriptSkeletonLine(id: "a2", text: "Checking recent sessions before continuing.", maxWidth: 260)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "user-question",
            role: .user,
            lines: [
                ChatTranscriptSkeletonLine(id: "u1", text: "Summarize the changes from the last run.", maxWidth: 280)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "assistant-response",
            role: .assistant,
            lines: [
                ChatTranscriptSkeletonLine(id: "a3", text: "The current branch has focused UI polish in progress.", maxWidth: 330),
                ChatTranscriptSkeletonLine(id: "a4", text: "Validation is queued after the loading states are updated.", maxWidth: 300),
                ChatTranscriptSkeletonLine(id: "a5", text: "No server changes are required for this slice.", maxWidth: 240)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "user-followup",
            role: .user,
            lines: [
                ChatTranscriptSkeletonLine(id: "u2", text: "Keep the existing empty and error states.", maxWidth: 260)
            ]
        ),
        ChatTranscriptSkeletonRowConfiguration(
            id: "assistant-outro",
            role: .assistant,
            lines: [
                ChatTranscriptSkeletonLine(id: "a6", text: "Using static placeholders that match the transcript rhythm.", maxWidth: 340),
                ChatTranscriptSkeletonLine(id: "a7", text: "Rows are noninteractive while data loads.", maxWidth: 245)
            ]
        )
    ]
}

private struct ChatTranscriptSkeletonLine: Identifiable {
    let id: String
    let text: String
    let maxWidth: CGFloat
}

struct ChatOfflineCacheBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)

            Text("Offline — viewing cached version")
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

struct PinnedLocalNoticeStack: View {
    let notices: [String]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.green)

                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.45), lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notices.joined(separator: "\n"))
    }
}
