import SwiftUI

/// How `HermexDialog`'s footer arranges its caller-supplied actions: side by side or stacked. The
/// caller always chooses explicitly — the component never infers layout from action count or
/// width.
enum HermexDialogFooterAxis {
    case horizontal
    case vertical
}

/// Stable identifiers `HermexDialog` exposes for verification and accessibility, following the same
/// pattern as `HermexAttachmentPickerPresentation`.
enum HermexDialogPresentation {
    static let overlayHostAccessibilityIdentifier = "hermex-dialog-overlay-host"
    static let closeButtonAccessibilityLabel = String(localized: "Close dialog")
    static let closeButtonAccessibilityIdentifier = "hermex-dialog-close-button"
    static let surfaceAccessibilityIdentifier = "hermex-dialog-surface"
}

private enum HermexDialogMetrics {
    static let maxWidth: CGFloat = 420
    static let outerPadding: CGFloat = HermesSpacing.s24
    static let contentPadding: CGFloat = HermesSpacing.s20
    static let contentSpacing: CGFloat = HermesSpacing.s16
    static let headerSpacing: CGFloat = HermesSpacing.s12
    static let footerSpacing: CGFloat = HermesSpacing.s12
    static let closeButtonDimension: CGFloat = 44
    static let scrimOpacity: Double = 0.4
}

extension View {
    /// Presents a fully custom, always-centered `HermexDialog` above this view through the shared
    /// same-window overlay host — never `.alert`, `.sheet`, or another native presentation wrapper.
    /// The dimmed backdrop never dismisses it; only the standard close button, accessibility
    /// Escape, a footer action, or the caller setting `isPresented` to `false` can. Attach this to
    /// the presenting trigger: the modifier restores accessibility focus to it once the dialog
    /// closes.
    func hermexDialog<Header: View, DialogContent: View, Footer: View>(
        isPresented: Binding<Bool>,
        footerAxis: HermexDialogFooterAxis = .horizontal,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> DialogContent,
        @ViewBuilder footer: @escaping (HermexOverlayActionContext) -> Footer
    ) -> some View {
        modifier(HermexDialogPresentationModifier(
            isPresented: isPresented,
            footerAxis: footerAxis,
            header: header,
            dialogContent: content,
            footer: footer
        ))
    }
}

/// Owns mount state and trigger accessibility-focus restoration; `HermexDialog` owns the visible
/// surface and its own presentation lifecycle. Mount state stays separate from the caller's
/// `isPresented` so exit can finish — and the caller's binding can be written back — before the
/// host actually unmounts.
private struct HermexDialogPresentationModifier<Header: View, DialogContent: View, Footer: View>: ViewModifier {
    @Binding var isPresented: Bool
    let footerAxis: HermexDialogFooterAxis
    let header: () -> Header
    let dialogContent: () -> DialogContent
    let footer: (HermexOverlayActionContext) -> Footer

    @AccessibilityFocusState private var triggerIsFocused: Bool
    @State private var isMounted = false

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($triggerIsFocused)
            .background {
                HermexSameWindowOverlay(
                    isPresented: isMounted,
                    bounds: .root,
                    accessibilityIdentifier: HermexDialogPresentation.overlayHostAccessibilityIdentifier
                ) {
                    HermexDialog(
                        ownerRequestsDismissal: !isPresented,
                        footerAxis: footerAxis,
                        header: header,
                        content: dialogContent,
                        footer: footer,
                        onExitCompleted: { pendingAction in
                            isMounted = false
                            isPresented = false
                            triggerIsFocused = true
                            pendingAction?()
                        }
                    )
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

/// A fully custom, centered modal: a non-dismissible dimmed backdrop, a header/close row, generic
/// body content, and a caller-oriented footer, mounted through `HermexSameWindowOverlay` instead of
/// any native presentation. Owns its own `HermexOverlayLifecycle` — entry/exit motion, exactly-once
/// dismissal/action completion, and disabling input outside `.presented`.
struct HermexDialog<Header: View, DialogContent: View, Footer: View>: View {
    /// `true` while the presenting caller wants this dialog gone (`isPresented == false`). Driving
    /// dismissal through a value, rather than letting the caller unmount directly, lets exit finish
    /// before the host actually tears down.
    let ownerRequestsDismissal: Bool
    let footerAxis: HermexDialogFooterAxis
    let header: () -> Header
    let content: () -> DialogContent
    let footer: (HermexOverlayActionContext) -> Footer
    /// Called once, after exit visually completes, with the one deferred action to run (or `nil`
    /// for a plain dismissal).
    let onExitCompleted: ((@MainActor () -> Void)?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingIsFocused: Bool
    @State private var lifecycle = HermexOverlayLifecycle()
    @State private var isVisible = false
    @State private var transitionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            backdrop
            surface
        }
        .onAppear(perform: present)
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

    private var backdrop: some View {
        Color.black.opacity(isVisible ? HermexDialogMetrics.scrimOpacity : 0)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            // The Dialog's dimmed backdrop never dismisses it — this gesture exists only to
            // consume touches so they cannot pass through to whatever sits underneath.
            .onTapGesture {}
            .accessibilityHidden(true)
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: HermexDialogMetrics.contentSpacing) {
            HStack(alignment: .center, spacing: HermexDialogMetrics.headerSpacing) {
                header()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(3)
                    .accessibilityFocused($headingIsFocused)
                Spacer(minLength: HermexDialogMetrics.headerSpacing)
                closeButton
                    .accessibilitySortPriority(0)
            }
            content()
                .accessibilitySortPriority(2)
            footerLayout
                .accessibilitySortPriority(1)
        }
        .padding(HermexDialogMetrics.contentPadding)
        .frame(maxWidth: HermexDialogMetrics.maxWidth)
        .hermexCardSurface(.glass, cornerRadius: HermesRadius.prominent)
        .hermesShadow(.overlay)
        .padding(HermexDialogMetrics.outerPadding)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(reduceMotion ? 1 : (isVisible ? 1 : HermesMotion.Properties.scaleEnter))
        .allowsHitTesting(lifecycle.phase == .presented)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { requestDismissal(after: nil) }
        .accessibilityIdentifier(HermexDialogPresentation.surfaceAccessibilityIdentifier)
    }

    @ViewBuilder
    private var footerLayout: some View {
        switch footerAxis {
        case .horizontal:
            HStack(spacing: HermexDialogMetrics.footerSpacing) {
                Spacer(minLength: 0)
                footer(actionContext)
            }
        case .vertical:
            VStack(spacing: HermexDialogMetrics.footerSpacing) { footer(actionContext) }
        }
    }

    private var actionContext: HermexOverlayActionContext {
        HermexOverlayActionContext { action in requestDismissal(after: action) }
    }

    private var closeButton: some View {
        HermexButton(
            content: .icon("xmark", accessibilityLabel: HermexDialogPresentation.closeButtonAccessibilityLabel),
            size: .extraSmall,
            emphasis: .neutral,
            isGlass: true
        ) {
            requestDismissal(after: nil)
        }
        .frame(minWidth: HermexDialogMetrics.closeButtonDimension, minHeight: HermexDialogMetrics.closeButtonDimension)
        .contentShape(Rectangle())
        .keyboardShortcut(.cancelAction)
        .disabled(lifecycle.phase != .presented)
        .accessibilityLabel(HermexDialogPresentation.closeButtonAccessibilityLabel)
        .accessibilityIdentifier(HermexDialogPresentation.closeButtonAccessibilityIdentifier)
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
            headingIsFocused = true
            return
        }
        withAnimation(HermesMotion.animation(for: HermesMotion.Bundle.overlayEnter)) {
            isVisible = true
        }
        transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(HermesMotion.Bundle.overlayEnter.duration * 1_000)))
            guard !Task.isCancelled, lifecycle.completePresentation(generation: generation) else { return }
            headingIsFocused = true
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
}
