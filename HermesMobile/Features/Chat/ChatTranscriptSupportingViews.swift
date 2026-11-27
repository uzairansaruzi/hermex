import SwiftUI
import UIKit

struct ChatScrollMetrics: Equatable {
    let distanceFromBottom: CGFloat
    let isUserInteracting: Bool
    let movedAwayFromBottom: Bool
}

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
        private weak var contentView: UIView?
        private weak var observedPanGesture: UIPanGestureRecognizer?
        private var observations: [NSKeyValueObservation] = []
        private var metricContext: MetricContext
        private var lastMetrics: ChatScrollMetrics?
        private var pendingMetrics: ChatScrollMetrics?
        private var deliveredGeometry: ChatScrollPolicy.ScrollGeometry?
        private var pendingGeometry: ChatScrollPolicy.ScrollGeometry?
        private var hasScheduledMetricDelivery = false
        private var isUserScrollSessionActive = false
        private var settleWorkItem: DispatchWorkItem?
        var scrollPositionController: ChatScrollPositionController? {
            didSet {
                guard oldValue !== scrollPositionController else { return }
                oldValue?.detach()
                if let scrollView {
                    scrollPositionController?.attach(to: scrollView, contentView: contentView)
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
            contentView = view

            guard scrollView !== self.scrollView else {
                scrollPositionController?.attach(to: scrollView, contentView: view)
                reportMetrics(delivery: delivery)
                return
            }

            observations.removeAll()
            lastMetrics = nil
            deliveredGeometry = nil
            endUserScrollSessionSilently()
            self.scrollView = scrollView
            scrollPositionController?.attach(to: scrollView, contentView: view)

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

        @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                cancelSettle()
                isUserScrollSessionActive = true
                onFollowEvent(.userScrollBegin)
            case .ended, .cancelled, .failed:
                guard isUserScrollSessionActive, let scrollView else { return }
                let releaseIsAtBottom = isAtBottom(scrollView)
                scheduleSettle(after: ChatScrollPolicy.dragSettleDelay) { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    if scrollView.isDecelerating { return }
                    self.finishUserScrollSession(isAtBottom: releaseIsAtBottom)
                }
            default:
                break
            }
        }

        private func trackMomentum(_ scrollView: UIScrollView) {
            guard isUserScrollSessionActive, scrollView.isDecelerating else { return }
            scheduleSettle(after: ChatScrollPolicy.momentumSettleDelay) { [weak self] in
                self?.finishUserScrollSessionIfSettled()
            }
        }

        private func finishUserScrollSessionIfSettled() {
            guard isUserScrollSessionActive, let scrollView else { return }
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
            scrollPositionController?.readerSettled()
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

@MainActor final class ChatContinuity: Equatable {
    private(set) var model: ChatViewModel?
    var didLoadMessages = false
    private var viewsOnScreen: [(id: UUID, returnsWaitingSend: (String, HermesWaitingSend.Return) -> Void)] = []
    private var transcriptsOnScreen: [ChatScrollPositionController] = []
    private var lastTranscript: ChatScrollPositionController?

    nonisolated init() {}

    nonisolated static func == (lhs: ChatContinuity, rhs: ChatContinuity) -> Bool { lhs === rhs }

    func viewAppeared(_ view: UUID, model: ChatViewModel,
                      returnsWaitingSend: @escaping (String, HermesWaitingSend.Return) -> Void) {
        viewsOnScreen.removeAll { $0.id == view }
        viewsOnScreen.append((view, returnsWaitingSend))
        self.model = model
        model.onWaitingSendReturned = returnsWaitingSend
    }

    func viewDisappeared(_ view: UUID) -> Bool {
        viewsOnScreen.removeAll { $0.id == view }
        if let staying = viewsOnScreen.last { model?.onWaitingSendReturned = staying.returnsWaitingSend }
        return viewsOnScreen.isEmpty
    }

    func transcriptAppeared(_ controller: ChatScrollPositionController, isFollowing: Bool) {
        let previous = transcriptsOnScreen.last ?? lastTranscript
        if let previous, previous !== controller, !isFollowing, let place = previous.readingPlace {
            controller.restore(place)
        }
        transcriptsOnScreen.append(controller)
        lastTranscript = nil
    }

    func transcriptDisappeared(_ controller: ChatScrollPositionController) {
        transcriptsOnScreen.removeAll { $0 === controller }
        if transcriptsOnScreen.isEmpty { lastTranscript = controller }
    }
}

@MainActor
final class ChatScrollPositionController {
    private enum Mode {
        case prepend
        case hold
        case reflow
    }

    struct Layout: Equatable {
        let contentWidth: CGFloat
        let dynamicTypeSize: DynamicTypeSize
    }

    private weak var scrollView: UIScrollView?
    private weak var contentView: UIView?
    private var mode = Mode.prepend
    private var hasPrependCapture = false
    private var baselineContentHeight: CGFloat?
    private var baselineOffsetY: CGFloat?
    private var contentSizeObservation: NSKeyValueObservation?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var completionTask: Task<Void, Never>?
    private var quietReleaseTask: Task<Void, Never>?
    private var isApplyingCompensation = false
    private var didRevertSwiftUIOffset = false
    private var resyncAfterHold: (() -> Void)?
    private var contentSizeChangedThisTurn = false
    private var lastObservedContentHeight: CGFloat?
    private var rowFrames: [String: CGRect] = [:]
    private var rowFramesLayout: Layout?
    private var reflowPlace: ChatScrollPolicy.ReadingPlace?
    private var undoesSwiftUIAnchors = false
    private var pendingPlace: ChatScrollPolicy.ReadingPlace?
    private var lastPlace: ChatScrollPolicy.ReadingPlace?
    var resyncToTop: (() -> Void)?

    var isHoldingPosition: Bool {
        mode == .hold && baselineOffsetY != nil
    }

    func attach(to scrollView: UIScrollView, contentView: UIView? = nil) {
        self.contentView = contentView ?? self.contentView
        guard scrollView !== self.scrollView else { return }
        cancelPreservation()
        self.scrollView = scrollView
        if let pendingPlace {
            self.pendingPlace = nil
            keep(pendingPlace, in: scrollView, undoesSwiftUIAnchors: true)
        }
    }

    func rowFrameChanged(id: String, frame: CGRect, layout: Layout, isFollowing: Bool) {
        if let previous = rowFramesLayout, previous != layout {
            if mode == .reflow, reflowPlace != nil {
                scheduleQuietRelease()
            } else {
                armReflow(isFollowing: isFollowing)
            }
        }
        rowFramesLayout = layout
        rowFrames[id] = frame
        if mode == .reflow, reflowPlace?.dependsOnFrame(of: id) == true {
            applyCompensation()
            scheduleQuietRelease()
        }
    }

    func forgetRow(id: String) {
        rowFrames[id] = nil
    }

    private func armReflow(isFollowing: Bool) {
        guard !isFollowing,
              baselineOffsetY == nil,
              let scrollView,
              !scrollView.isDragging,
              !scrollView.isTracking,
              !scrollView.isDecelerating,
              let place = place(in: scrollView)
        else { return }

        keep(place, in: scrollView, undoesSwiftUIAnchors: place == .top)
    }

    private func place(in scrollView: UIScrollView) -> ChatScrollPolicy.ReadingPlace? {
        guard !rowFrames.isEmpty else { return nil }
        let topInset = scrollView.adjustedContentInset.top
        let readingLineY = scrollView.contentOffset.y + topInset - contentOriginY(in: scrollView)
        return ChatScrollPolicy.reflowAnchor(
            readingLineY: readingLineY,
            isAtTop: scrollView.contentOffset.y <= -topInset + 0.5,
            rowFrames: rowFrames
        ).map { .row($0) } ?? .top
    }

    private func keep(_ place: ChatScrollPolicy.ReadingPlace, in scrollView: UIScrollView, undoesSwiftUIAnchors: Bool) {
        reflowPlace = place
        lastPlace = place
        self.undoesSwiftUIAnchors = undoesSwiftUIAnchors
        baselineContentHeight = scrollView.contentSize.height
        baselineOffsetY = scrollView.contentOffset.y
        lastObservedContentHeight = scrollView.contentSize.height
        if place == .top { resyncAfterHold = resyncToTop }
        beginPreservation(mode: .reflow, scrollView: scrollView, window: ChatScrollPolicy.disclosureHoldMaximum)
        applyCompensation()
        scheduleQuietRelease()
    }

    var readingPlace: ChatScrollPolicy.ReadingPlace? {
        reflowPlace ?? scrollView.flatMap(place(in:)) ?? lastPlace
    }

    func readerSettled() {
        lastPlace = readingPlace
    }

    func restore(_ place: ChatScrollPolicy.ReadingPlace) {
        lastPlace = place
        guard let scrollView else {
            pendingPlace = place
            return
        }
        keep(place, in: scrollView, undoesSwiftUIAnchors: true)
    }

    private func contentOriginY(in scrollView: UIScrollView) -> CGFloat {
        contentView.map { $0.convert(CGPoint.zero, to: scrollView).y } ?? 0
    }

    func detach() {
        lastPlace = readingPlace
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

        beginPreservation(mode: .prepend, scrollView: scrollView, window: 1)
        return true
    }

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
        undoesSwiftUIAnchors = true
        resyncAfterHold = resync
        beginPreservation(mode: .hold, scrollView: scrollView, window: ChatScrollPolicy.disclosureHoldMaximum)
        scheduleQuietRelease()
    }

    private func finishHold() {
        applyCompensation()
        let minimumOffsetY = scrollView.map { -$0.adjustedContentInset.top }
        let resync = Self.shouldResync(
            didRevertSwiftUIOffset: didRevertSwiftUIOffset,
            heldOffsetY: reflowPlace == .top ? minimumOffsetY : baselineOffsetY,
            minimumOffsetY: minimumOffsetY
        ) ? resyncAfterHold : nil
        cancelPreservation()
        resync?()
    }

    nonisolated static func shouldResync(
        didRevertSwiftUIOffset: Bool,
        heldOffsetY: CGFloat?,
        minimumOffsetY: CGFloat?
    ) -> Bool {
        guard didRevertSwiftUIOffset, let heldOffsetY, let minimumOffsetY else { return false }
        return heldOffsetY <= minimumOffsetY + 0.5
    }

    func releaseHold() {
        guard mode != .prepend else { return }
        cancelPreservation()
    }

    func stopMomentum() {
        scrollView?.stopScrollingAndZooming()
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
            if mode != .prepend {
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
        reflowPlace = nil
        undoesSwiftUIAnchors = false
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
        guard scrollView === self.scrollView else { return }

        applyCompensation()
        if mode != .prepend {
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

    private func handleOffsetChange(_ scrollView: UIScrollView) {
        guard !isApplyingCompensation, scrollView === self.scrollView else { return }

        if scrollView.isDragging || scrollView.isTracking || scrollView.isDecelerating {
            cancelPreservation()
        } else if mode != .prepend {
            let sizeIsChanging = (undoesSwiftUIAnchors && contentSizeChangedThisTurn)
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
        guard let baselineContentHeight, var baselineOffsetY else { return nil }

        switch reflowPlace {
        case .top?:
            baselineOffsetY = -scrollView.adjustedContentInset.top
        case .row(let anchor)?:
            guard let frame = rowFrames[anchor.id] else { return nil }
            baselineOffsetY = ChatScrollPolicy.reflowReadingLineY(anchor: anchor, newFrame: frame)
                + contentOriginY(in: scrollView) - scrollView.adjustedContentInset.top
        case nil:
            break
        }
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

        if undoesSwiftUIAnchors {
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

private struct ForcedLeftToRightModifier: ViewModifier {
    @Environment(\.layoutDirection) private var parentDirection
    let isForced: Bool

    func body(content: Content) -> some View {
        content.environment(\.layoutDirection, isForced ? .leftToRight : parentDirection)
    }
}

extension View {
    func forcedLeftToRight(_ isForced: Bool = true) -> some View {
        modifier(ForcedLeftToRightModifier(isForced: isForced))
    }

    func loadsOnceVisible<ID: Equatable>(id: ID, admit: @escaping (ID) -> Void) -> some View {
        modifier(LoadsOnceVisibleModifier(id: id, admit: admit))
    }
}

private struct LoadsOnceVisibleModifier<ID: Equatable>: ViewModifier {
    let id: ID
    let admit: (ID) -> Void
    @Environment(\.responseSelectionScope) private var selectionScope
    @State private var placement = Placement.unmeasured

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Placement.self) { geometry in
                guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else {
                    return .outsideScrollView
                }
                return .inScrollView(isVisible: viewport.intersects(CGRect(origin: .zero, size: geometry.size)))
            } action: { placement = $0 }
            .onChange(of: isVisible ? Optional(id) : nil, initial: true) { _, visibleID in
                if let visibleID { admit(visibleID) }
            }
    }

    private var isVisible: Bool {
        switch placement {
        case .unmeasured: false
        case .outsideScrollView: selectionScope?.collectsGlyphs ?? true
        case let .inScrollView(isVisible): isVisible
        }
    }

    private enum Placement: Equatable {
        case unmeasured
        case outsideScrollView
        case inScrollView(isVisible: Bool)
    }
}

struct ChatVerticalScrollAxisGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> ChatVerticalScrollAxisGuardView {
        ChatVerticalScrollAxisGuardView()
    }

    func updateUIView(_ uiView: ChatVerticalScrollAxisGuardView, context: Context) {
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

struct ChatWorkingRowView: View {
    let startedAt: Date
    let isCompacting: Bool

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            HStack(spacing: 8) {
                dots

                Text(ChatWorkingRowLabel.text(startedAt: startedAt, now: context.date, isCompacting: isCompacting))
                    .font(AppFont.caption(weight: .medium).monospacedDigit())
                    .foregroundStyle(.appSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ChatWorkingRowLabel.accessibilityLabel(startedAt: startedAt, now: context.date, isCompacting: isCompacting)
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

struct StreamRecoveryStatusView: View {
    let state: ActiveStreamRecoveryState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion || state == .waitingForNetwork {
                ChatRunStatusDot()
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }

            Text(label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.appSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.appMaterial(.regularMaterial), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(.appSeparator).opacity(0.35), lineWidth: 0.5)
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
        case .waitingForNetwork:
            return String(localized: "Waiting for network")
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
            .background(Color(.appFillSecondary))
            .foregroundStyle(.appPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private func skeletonLine(_ line: ChatTranscriptSkeletonLine) -> some View {
        Text(verbatim: line.text)
            .font(AppFont.body())
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
                .font(AppFont.subheadline())
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

struct ChatServerLinkBanner: View {
    let notice: ChatServerLinkNotice
    var onReconnect: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice == .lost ? "bolt.horizontal.circle" : "arrow.triangle.2.circlepath")
                .imageScale(.small)
                .accessibilityHidden(true)

            Text(Self.label(for: notice))
                .font(AppFont.subheadline())
                .fontWeight(.semibold)
                .lineLimit(2)

            Spacer()

            if notice == .lost {
                Button("Reconnect", action: onReconnect)
                    .font(AppFont.subheadline())
                    .buttonStyle(.borderless)
            }
        }
        .foregroundStyle(.red)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
        .accessibilityElement(children: .contain)
    }

    /// The notice to show, or nil while the user has the bar turned off in Settings › Chat.
    static func shownNotice(_ notice: ChatServerLinkNotice?, isEnabled: Bool) -> ChatServerLinkNotice? {
        isEnabled ? notice : nil
    }

    static func label(for notice: ChatServerLinkNotice) -> String {
        switch notice {
        case .connecting: String(localized: "Connecting to the server…")
        case .lost: String(localized: "Not connected to the server. Reconnecting…")
        }
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

                    Text(Self.plainText(notice))
                        .font(AppFont.footnote())
                        .foregroundStyle(.appPrimary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(.appMaterial(.ultraThinMaterial))
                .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
                        .stroke(Color(.appSeparator).opacity(0.45), lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notices.map(Self.plainText).joined(separator: "\n"))
    }

    static func plainText(_ notice: String) -> String {
        notice.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("```") }
            .joined(separator: "\n")
    }
}

struct HostNoticeRow: View {
    let notice: HermesHostNotices.Notice
    let waitingCount: Int
    let dismiss: () -> Void
    @State private var showsDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            message
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(waitingCount > 0 ? Text("\(waitingCount) more") : Text(verbatim: ""))

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(.appSecondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.appMaterial(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color(.appSeparator).opacity(0.45), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .alert(Text(verbatim: notice.text), isPresented: $showsDetail) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: notice.detail ?? "")
        }
    }

    @ViewBuilder
    private var message: some View {
        let text = Text(notice.linkedText)
            .font(AppFont.footnote())
            .foregroundStyle(.appPrimary)
            .lineLimit(notice.detail == nil ? 6 : 2)
            .fixedSize(horizontal: false, vertical: true)
        if notice.detail != nil {
            text
                .contentShape(Rectangle())
                .onTapGesture { showsDetail = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text("Details")) { showsDetail = true }
        } else {
            text
        }
    }

    private var symbol: String {
        switch notice.level {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch notice.level {
        case .info: Color(.appTextSecondary)
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }

    private var accessibilityLabel: Text {
        switch notice.level {
        case .info: Text("Notice: \(notice.text)")
        case .warning: Text("Warning: \(notice.text)")
        case .error: Text("Error: \(notice.text)")
        case .success: Text("Success: \(notice.text)")
        }
    }
}

enum HiddenPromptCharacters {
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B, 0x2060, 0xFEFF, 0xE0000...0xE007F: true
        default: false
        }
    }

    static func contains(in text: String) -> Bool {
        text.unicodeScalars.contains(where: isHidden)
    }

    static func removing(from text: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.lazy.filter { !isHidden($0) })
        return String(kept)
    }
}

extension ImportedTextOrigin {
    var cantOpenTitle: Text {
        switch self {
        case .shortcut: Text("Shortcut Can’t Open")
        case .troubleshooting: Text("Troubleshooting Can’t Open")
        }
    }
}

struct WaitingShortcutText {
    let openNext: () -> Void
    let discard: () -> Void
}

struct ShortcutTextNotice: View {
    let origin: ImportedTextOrigin?
    let hasHiddenCharacters: Bool
    let canUndoRemoval: Bool
    let removeHiddenCharacters: () -> Void
    let undoRemoval: () -> Void
    let waiting: WaitingShortcutText?
    let dismiss: () -> Void

    private var isWarning: Bool { origin != nil && hasHiddenCharacters }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isWarning ? Color.orange : Color(.appTextSecondary))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                if let origin {
                    Group {
                        switch (origin, hasHiddenCharacters) {
                        case (.shortcut, true):
                            Text("Added from Shortcuts with hidden characters. They can change how the text reads to the agent. Review before sending.")
                        case (.shortcut, false):
                            Text("Added from Shortcuts. Review before sending.")
                        case (.troubleshooting, true):
                            Text("Added from Troubleshooting with hidden characters. They can change how the text reads to the agent. Review before sending.")
                        case (.troubleshooting, false):
                            Text("Added from Troubleshooting. Review before sending.")
                        }
                    }
                    .font(AppFont.footnote())
                    .foregroundStyle(.appPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    if hasHiddenCharacters {
                        Button("Remove Hidden Characters", action: removeHiddenCharacters)
                            .font(AppFont.footnote(weight: .semibold))
                    } else if canUndoRemoval {
                        Button("Undo", action: undoRemoval)
                            .font(AppFont.footnote(weight: .semibold))
                    }
                }
                if let waiting {
                    Text("Another text is waiting.")
                        .font(AppFont.footnote())
                        .foregroundStyle(origin != nil ? .appSecondary : .appPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button("Open Next", action: waiting.openNext)
                        Button("Discard", role: .destructive, action: waiting.discard)
                    }
                    .font(AppFont.footnote(weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if origin != nil {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(.appSecondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .background(.appMaterial(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color(.appSeparator).opacity(0.45), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}
