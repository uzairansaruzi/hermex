import SwiftUI
import UIKit

/// Stable identifiers `HermexPopoverMenu` exposes for verification and accessibility, following the
/// same pattern as `HermexDialogPresentation`.
enum HermexPopoverMenuPresentation {
    static let overlayHostAccessibilityIdentifier = "hermex-popover-menu-overlay-host"
    static let surfaceAccessibilityIdentifier = "hermex-popover-menu-surface"
}

/// Component-local geometry and motion constants — no new design-system tokens. `safeAreaMargin`,
/// `anchorGap`, `preferredWidth`, and `minimumRowHeight` also drive the pure `HermexPopoverPlacement`
/// resolver; `motionOffset` is the directional entry/exit distance from the implementation plan.
enum HermexPopoverMenuMetrics {
    static let safeAreaMargin: CGFloat = 12
    static let anchorGap: CGFloat = 8
    static let preferredWidth: CGFloat = 280
    static let minimumRowHeight: CGFloat = 44
    static let motionOffset: CGFloat = 4
    /// The shell padding around the compact list, replacing the spacing
    /// `HermexList.Style.compactOverlay` used to own before its own row inset and scroll-content
    /// margin collapsed to zero (see `HermexListCompactOverlayMetrics`).
    static let contentPadding: CGFloat = HermesSpacing.s16
}

/// Estimates how tall the menu would like to be if every row rendered fully, so
/// `HermexPopoverPlacement` starts from a realistic budget instead of `actions.count *
/// minimumRowHeight` — which undercounts the real 48pt `ListItem` content plus
/// `HermexList.Style.compactOverlay`'s own row insets and scroll-content margin, and left short
/// menus clipping/scrolling unnecessarily. A pure, testable function rather than an actual
/// measurement pass: `HermexPopoverPlacement` still clamps the result to whatever the anchor's
/// safe-area geometry allows, and `HermexList` keeps scrolling internally when real rendered rows
/// (which can grow taller than this estimate, e.g. a wrapped multiline title) don't fit.
enum HermexPopoverMenuContentSizing {
    /// One row's estimated height: `ListItem`'s own minimum content height plus
    /// `HermexList.Style.compactOverlay`'s row insets, scaled for `dynamicTypeSize` the same way
    /// `AppFont` scales text — via `UIFontMetrics` against the equivalent `UIContentSizeCategory`
    /// — so accessibility text sizes ask for meaningfully more room, not a fixed constant.
    static func estimatedRowHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let baseRowHeight = ListItemMetrics.minHeight + HermexListCompactOverlayMetrics.rowVerticalInset * 2
        let traitCollection = UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.appFontContentSizeCategory)
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: baseRowHeight, compatibleWith: traitCollection)
    }

    static func preferredContentHeight(actionCount: Int, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        CGFloat(actionCount) * estimatedRowHeight(for: dynamicTypeSize)
            + HermexPopoverMenuMetrics.contentPadding * 2
    }
}

/// Whether a `HermexPopoverMenuAction` reads as an ordinary or a destructive row. Destructive rows
/// still carry a textual accessibility hint — the meaning never relies on color alone.
enum HermexPopoverMenuActionRole {
    case standard
    case destructive
}

/// One simple action row: a title, an optional leading symbol, enabled/disabled state, a
/// standard/destructive role, and exactly one action closure — nothing beyond this.
struct HermexPopoverMenuAction: Identifiable {
    let id: AnyHashable
    let title: LocalizedStringKey
    let systemImage: String?
    let isEnabled: Bool
    let role: HermexPopoverMenuActionRole
    let action: @MainActor () -> Void

    init(
        id: AnyHashable,
        title: LocalizedStringKey,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        role: HermexPopoverMenuActionRole = .standard,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.role = role
        self.action = action
    }
}

/// Where `HermexPopoverMenu` renders relative to its trigger. A pure function of its inputs:
/// prefers below, flips above when below doesn't fit, clamps horizontally inside the safe-area
/// margin, and bounds the height so `HermexList` scrolls internally when neither side fits.
struct HermexPopoverPlacement: Equatable {
    enum Edge: Equatable {
        case above
        case below
    }

    let edge: Edge
    let frame: CGRect

    static func resolve(
        anchor: CGRect,
        preferredSize: CGSize,
        containerBounds: CGRect,
        safeAreaInsets: UIEdgeInsets
    ) -> HermexPopoverPlacement {
        let margin = HermexPopoverMenuMetrics.safeAreaMargin
        let gap = HermexPopoverMenuMetrics.anchorGap
        let minimumHeight = HermexPopoverMenuMetrics.minimumRowHeight

        let safeLeft = containerBounds.minX + safeAreaInsets.left + margin
        let safeRight = containerBounds.maxX - safeAreaInsets.right - margin
        let safeTop = containerBounds.minY + safeAreaInsets.top + margin
        let safeBottom = containerBounds.maxY - safeAreaInsets.bottom - margin

        let availableWidth = max(minimumHeight, safeRight - safeLeft)
        let width = min(preferredSize.width, availableWidth)
        let x = min(max(anchor.minX, safeLeft), max(safeLeft, safeRight - width))

        let spaceBelow = safeBottom - (anchor.maxY + gap)
        let spaceAbove = (anchor.minY - gap) - safeTop

        // When neither side fully fits, bound the height to whatever that side's safe-area space
        // actually allows — never below 0, and never inflated up to `minimumHeight` past the real
        // available space. `minimumHeight` is a per-ROW floor `HermexList` already guarantees
        // (`HermexListCompactOverlayMetrics.minimumRowHeight`, applied via
        // `defaultMinListRowHeight`); it is not a floor on the whole scroll viewport. A viewport
        // smaller than one row is still valid — `HermexList` scrolls internally to reach it — while
        // forcing the viewport itself up to 44pt regardless of available space pushed the surface's
        // frame past the safe area entirely.
        let edge: Edge
        let height: CGFloat
        if spaceBelow >= preferredSize.height {
            edge = .below
            height = preferredSize.height
        } else if spaceAbove >= preferredSize.height {
            edge = .above
            height = preferredSize.height
        } else if spaceBelow >= spaceAbove {
            edge = .below
            height = min(preferredSize.height, max(spaceBelow, 0))
        } else {
            edge = .above
            height = min(preferredSize.height, max(spaceAbove, 0))
        }

        let y: CGFloat
        switch edge {
        case .below:
            y = anchor.maxY + gap
        case .above:
            y = anchor.minY - gap - height
        }

        return HermexPopoverPlacement(edge: edge, frame: CGRect(x: x, y: y, width: width, height: height))
    }
}

extension View {
    /// Presents a fully custom, trigger-anchored `HermexPopoverMenu` above this view through the
    /// shared same-window overlay host — never a native `Menu`, context menu, or `.popover`.
    /// Attach this directly to the trigger: the modifier measures its frame in window coordinates
    /// and restores accessibility focus to it once the menu closes. `accessibilityLabel` is
    /// required — there is no generic hidden default such as "Actions".
    func hermexPopoverMenu(
        isPresented: Binding<Bool>,
        accessibilityLabel: Text,
        actions: [HermexPopoverMenuAction]
    ) -> some View {
        modifier(HermexPopoverMenuPresentationModifier(
            isPresented: isPresented,
            accessibilityLabel: accessibilityLabel,
            actions: actions
        ))
    }
}

/// Owns mount state, trigger anchor measurement, and trigger accessibility-focus restoration.
/// Mirrors `HermexDialogPresentationModifier`'s mount/caller-binding split so exit can finish
/// before the host actually unmounts.
private struct HermexPopoverMenuPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let accessibilityLabel: Text
    let actions: [HermexPopoverMenuAction]

    @AccessibilityFocusState private var triggerIsFocused: Bool
    @State private var isMounted = false
    @State private var anchorFrame: CGRect?

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($triggerIsFocused)
            .background {
                HermexPopoverTriggerAnchorReader { frame in
                    anchorFrame = frame
                    guard frame == nil, isMounted else { return }
                    // The anchor disappeared (the trigger left the hierarchy): there is nothing
                    // left to anchor to, so drop straight to hidden rather than animate an exit
                    // against a gone anchor.
                    isMounted = false
                    isPresented = false
                }
            }
            .background {
                if let anchorFrame {
                    HermexSameWindowOverlay(
                        isPresented: isMounted,
                        bounds: .root,
                        accessibilityIdentifier: HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier
                    ) {
                        HermexPopoverMenu(
                            anchor: anchorFrame,
                            accessibilityLabel: accessibilityLabel,
                            actions: actions,
                            ownerRequestsDismissal: !isPresented,
                            onExitCompleted: { pendingAction in
                                isMounted = false
                                isPresented = false
                                triggerIsFocused = true
                                pendingAction?()
                            }
                        )
                    }
                }
            }
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented { isMounted = true }
            }
            .onDisappear {
                isMounted = false
            }
    }
}

/// Measures the trigger's frame in the current `UIWindow`'s coordinate space — the same space
/// `HermexSameWindowOverlay` mounts into. Reacts to `layoutSubviews`/`didMoveToWindow` only, no
/// polling; reports `nil` once detached from a window.
private struct HermexPopoverTriggerAnchorReader: UIViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onFrameChange = onFrameChange
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        uiView.onFrameChange = onFrameChange
        // Scrolling an ancestor can move this view in window space without laying it out.
        // Re-measure when presentation updates, after SwiftUI's current update has finished.
        uiView.setNeedsLayout()
    }

    final class AnchorView: UIView {
        var onFrameChange: ((CGRect?) -> Void)?
        private var lastReportedFrame: CGRect?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFrame()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFrame()
        }

        private func reportFrame() {
            guard let window else {
                guard lastReportedFrame != nil else { return }
                lastReportedFrame = nil
                onFrameChange?(nil)
                return
            }
            let frame = convert(bounds, to: window)
            guard frame != lastReportedFrame else { return }
            lastReportedFrame = frame
            onFrameChange?(frame)
        }
    }
}

/// Measures the same-window host's own bounds, converted to that window's coordinate space, plus
/// that window's safe-area insets — the container geometry `HermexPopoverPlacement.resolve` clamps
/// against. Shares the same window the trigger anchor reader measures.
private struct HermexPopoverContainerGeometryReader: UIViewRepresentable {
    let onGeometryChange: (CGRect, UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> GeometryView {
        let view = GeometryView()
        view.onGeometryChange = onGeometryChange
        return view
    }

    func updateUIView(_ uiView: GeometryView, context: Context) {
        uiView.onGeometryChange = onGeometryChange
    }

    final class GeometryView: UIView {
        var onGeometryChange: ((CGRect, UIEdgeInsets) -> Void)?
        private var lastFrame: CGRect?
        private var lastInsets: UIEdgeInsets?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportGeometry()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportGeometry()
        }

        private func reportGeometry() {
            guard let window else { return }
            let frame = convert(bounds, to: window)
            let insets = window.safeAreaInsets
            guard frame != lastFrame || insets != lastInsets else { return }
            lastFrame = frame
            lastInsets = insets
            onGeometryChange?(frame, insets)
        }
    }
}

/// A fully custom, trigger-anchored floating menu: a clear full-screen hit layer that dismisses on
/// outside tap (never dimmed, unlike `HermexDialog`'s scrim), and a compact `HermexList`-backed
/// action list, mounted through `HermexSameWindowOverlay`. Owns its own `HermexOverlayLifecycle`
/// exactly like `HermexDialog`.
struct HermexPopoverMenu: View {
    let anchor: CGRect
    let accessibilityLabel: Text
    let actions: [HermexPopoverMenuAction]
    /// `true` while the presenting caller wants this menu gone (`isPresented == false`).
    let ownerRequestsDismissal: Bool
    /// Called once, after exit visually completes, with the one deferred action to run (or `nil`
    /// for a plain dismissal, outside tap, or Escape).
    let onExitCompleted: ((@MainActor () -> Void)?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var focusedActionID: AnyHashable?
    @State private var lifecycle = HermexOverlayLifecycle()
    @State private var isVisible = false
    @State private var transitionTask: Task<Void, Never>?
    @State private var containerBounds: CGRect = .zero
    @State private var safeAreaInsets: UIEdgeInsets = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            menuSurface
        }
        .background {
            HermexPopoverContainerGeometryReader { frame, insets in
                containerBounds = frame
                safeAreaInsets = insets
                presentIfReady()
            }
        }
        .onAppear(perform: presentIfReady)
        .onChange(of: ownerRequestsDismissal) { _, requested in
            if requested {
                requestDismissal(after: nil)
            } else if lifecycle.phase == .dismissing {
                present()
            }
        }
        .onDisappear {
            transitionTask?.cancel()
            transitionTask = nil
            lifecycle.cancelOwner()
        }
    }

    private var placement: HermexPopoverPlacement {
        HermexPopoverPlacement.resolve(
            anchor: anchor,
            preferredSize: preferredSize,
            containerBounds: containerBounds,
            safeAreaInsets: safeAreaInsets
        )
    }

    /// `placement.frame` is in window coordinates, but `.position` expects the parent's *local*
    /// space; the root view need not sit at `(0, 0)` in its window, so this re-expresses the center
    /// relative to `containerBounds`'s own origin.
    private var localCenter: CGPoint {
        CGPoint(
            x: placement.frame.midX - containerBounds.origin.x,
            y: placement.frame.midY - containerBounds.origin.y
        )
    }

    private var preferredSize: CGSize {
        CGSize(
            width: HermexPopoverMenuMetrics.preferredWidth,
            height: HermexPopoverMenuContentSizing.preferredContentHeight(
                actionCount: actions.count,
                dynamicTypeSize: dynamicTypeSize
            )
        )
    }

    private var backdrop: some View {
        Color.clear
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { requestDismissal(after: nil) }
            .accessibilityHidden(true)
    }

    private var menuSurface: some View {
        // Keep the card's layout and semantics separate from List's UIKit-backed collection.
        // Escape is also installed on each action row, where VoiceOver focus actually lands.
        VStack(spacing: 0) {
            HermexList(style: .compactOverlay) {
                ForEach(actions) { action in
                    row(for: action)
                }
            }
        }
        .padding(HermexPopoverMenuMetrics.contentPadding)
        .frame(width: placement.frame.width, height: placement.frame.height)
        .hermexCardSurface(.glass, cornerRadius: HermesRadius.card)
        .hermesShadow(.popover)
        .position(localCenter)
        .offset(y: isVisible ? 0 : entryOffset)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(lifecycle.phase == .presented)
        .animation(
            reduceMotion ? nil : (lifecycle.phase == .presented ? HermesMotion.animation(for: HermesMotion.Bundle.contentReposition) : nil),
            value: placement
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(.escape) { requestDismissal(after: nil) }
        .accessibilityIdentifier(HermexPopoverMenuPresentation.surfaceAccessibilityIdentifier)
        .overlay {
            // Hardware Escape, the same way HermexDialog's close button carries this shortcut.
            Button(action: { requestDismissal(after: nil) }) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .disabled(lifecycle.phase != .presented)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var entryOffset: CGFloat {
        placement.edge == .below ? -HermexPopoverMenuMetrics.motionOffset : HermexPopoverMenuMetrics.motionOffset
    }

    @ViewBuilder
    private func row(for action: HermexPopoverMenuAction) -> some View {
        let item = ListItem(
            title: Text(action.title),
            titleLineLimit: dynamicTypeSize.isAccessibilitySize ? 3 : 1,
            state: ListItemState(isDisabled: !action.isEnabled),
            contentInset: .none,
            action: { activate(action) },
            leading: { icon(for: action) }
        )
        .accessibilityFocused($focusedActionID, equals: action.id)
        .accessibilityAction(.escape) { requestDismissal(after: nil) }
        .accessibilityIdentifier("hermex-popover-menu-action-\(String(describing: action.id))")

        switch action.role {
        case .standard:
            item
        case .destructive:
            item.accessibilityHint(Text("Destructive action"))
        }
    }

    @ViewBuilder
    private func icon(for action: HermexPopoverMenuAction) -> some View {
        if let systemImage = action.systemImage {
            Image(systemName: systemImage)
                .font(.system(size: HermesIconSize.small, weight: .semibold))
                .foregroundStyle(action.role == .destructive ? Color.red : Color.primary)
                .frame(width: HermesIconSize.large, height: HermesIconSize.large)
                .accessibilityHidden(true)
        }
    }

    private func activate(_ action: HermexPopoverMenuAction) {
        guard action.isEnabled else { return }
        requestDismissal(after: action.action)
    }

    /// Gates entry on real same-window container geometry: `.onAppear` and the container geometry
    /// reader's first real report race, and starting `present()` while `containerBounds` is still
    /// `.zero` let `contentReposition`'s placement animation travel from that zero-sized initial
    /// frame once the real bounds arrive, instead of the intended small directional
    /// `motionOffset`. Presenting only once real geometry exists, and only from `.hidden`, keeps
    /// this idempotent against both callers without presenting twice.
    private func presentIfReady() {
        guard containerBounds.width > 0, containerBounds.height > 0 else { return }
        guard lifecycle.phase == .hidden else { return }
        present()
    }

    private func present() {
        // A rejected request (duplicate open, or a re-open while a deferred action is still
        // dismissing) must leave any active transition task alone, so an in-flight exit — and the
        // action deferred on it — finishes undisturbed instead of being cancelled out from under it.
        // A re-open while dismissing with a deferred action is queued, not dropped: see
        // `finishExit(generation:)`, which resumes entry here once that exit completes.
        guard let generation = lifecycle.beginPresentation() else { return }
        beginEntry(generation: generation)
    }

    private func beginEntry(generation: Int) {
        transitionTask?.cancel()
        guard !reduceMotion else {
            isVisible = true
            _ = lifecycle.completePresentation(generation: generation)
            focusFirstEnabledAction()
            return
        }
        withAnimation(HermesMotion.animation(for: HermesMotion.Bundle.overlayEnter)) {
            isVisible = true
        }
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(HermesMotion.Bundle.overlayEnter.duration * 1_000)))
            guard !Task.isCancelled, lifecycle.completePresentation(generation: generation) else { return }
            focusFirstEnabledAction()
        }
    }

    private func requestDismissal(after action: (@MainActor () -> Void)?) {
        guard let generation = lifecycle.beginDismissal(after: action) else { return }
        transitionTask?.cancel()
        guard !reduceMotion else {
            isVisible = false
            finishExit(generation: generation)
            return
        }
        withAnimation(HermesMotion.animation(for: HermesMotion.Bundle.overlayExit)) {
            isVisible = false
        }
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(HermesMotion.Bundle.overlayExit.duration * 1_000)))
            guard !Task.isCancelled else { return }
            finishExit(generation: generation)
        }
    }

    private func finishExit(generation: Int) {
        switch lifecycle.completeDismissal(generation: generation) {
        case .notCurrent:
            return
        case .completed(let action, let reopened):
            guard let reopened else {
                onExitCompleted(action)
                return
            }
            // A reopen was queued while this action-bearing exit was in flight: run the deferred
            // action once, then resume entry on the same mounted surface instead of routing through
            // `onExitCompleted`, which would unmount the host and write the caller's binding false.
            action?()
            beginEntry(generation: reopened)
        }
    }

    private func focusFirstEnabledAction() {
        focusedActionID = actions.first(where: { $0.isEnabled })?.id
    }
}
