import Foundation

/// The generation-based presentation lifecycle shared by every custom same-window overlay
/// (`HermexDialog`, and later `HermexPopoverMenu`). A generation identifies one present/dismiss
/// cycle: every *accepted* `beginPresentation()` call starts a new generation, and every completion
/// call must name the generation it is completing so a stale, superseded, or cancelled transition can
/// never finish, hide a newer presentation, or run a second time.
@MainActor
struct HermexOverlayLifecycle {
    enum Phase: Equatable {
        case hidden
        case entering
        case presented
        case dismissing
    }

    /// The outcome of `completeDismissal(generation:)`. `notCurrent` carries nothing, so this
    /// distinguishes "reject — do not unmount" from "accept". `completed` always hands back the one
    /// deferred action (`nil` for a plain dismissal) for the caller to run exactly once. `reopened`
    /// is `nil` unless a `beginPresentation()` call was queued while this action-bearing dismissal was
    /// in flight (see `beginPresentation()`); when non-`nil`, it is the fresh generation the lifecycle
    /// has already entered `.entering` with, and the caller must resume the same mounted surface with
    /// a new entry transition instead of unmounting.
    enum DismissalCompletion {
        case notCurrent
        case completed(action: (@MainActor () -> Void)?, reopened: Int?)
    }

    private(set) var phase: Phase = .hidden
    private(set) var generation = 0
    private var pendingAction: (@MainActor () -> Void)?
    /// `true` only while a `beginPresentation()` request has been queued against an action-bearing
    /// dismissal that is still in flight (see `beginPresentation()`). Consumed — and either honored or
    /// cancelled — by `completeDismissal(generation:)`/`beginDismissal(after:)`; never survives past
    /// its originating `.dismissing` transition.
    private var reopenQueued = false

    /// Starts a new presentation. Returns the generation the caller must complete against, or `nil`
    /// when the request is rejected — a caller that receives `nil` must leave any active transition
    /// task running rather than cancelling it, so an in-flight exit (and whatever action is deferred
    /// on it) completes undisturbed. Rejected while already `.entering` or `.presented`: a duplicate
    /// open request is a no-op. Rejected while `.dismissing` with a deferred action pending — but
    /// never dropped: the request is recorded as a queued reopen, so once that exit's action runs,
    /// `completeDismissal(generation:)` hands back a fresh generation already in `.entering` instead
    /// of settling into `.hidden`. Accepted from `.hidden`, and accepted as a supersede from
    /// `.dismissing` when no action is deferred — re-opening a plain (action-less) dismissal cancels
    /// it and starts fresh, preserving the existing reopen behavior for that case. Either accepted
    /// path advances the generation (invalidating any prior transition's completions), drops any
    /// stale pending action and queued reopen, and enters `.entering`.
    mutating func beginPresentation() -> Int? {
        switch phase {
        case .entering, .presented:
            return nil
        case .dismissing where pendingAction != nil:
            reopenQueued = true
            return nil
        case .hidden, .dismissing:
            generation += 1
            pendingAction = nil
            reopenQueued = false
            phase = .entering
            return generation
        }
    }

    /// Completes entry into `.presented`. Succeeds only when `generation` still names the current
    /// `.entering` transition — a stale or superseded call is a no-op.
    mutating func completePresentation(generation: Int) -> Bool {
        guard phase == .entering, generation == self.generation else { return false }
        phase = .presented
        return true
    }

    /// Requests dismissal, optionally deferring one action to run only after exit completes.
    /// An enabled footer/menu action (`action != nil`) is only accepted from `.presented`, matching
    /// the approved contract that an action never fires from anything but a fully interactive
    /// surface. A plain dismiss request (`action == nil`) is also accepted from `.entering`,
    /// cancelling pending entry work and proceeding straight to dismissal. While already
    /// `.dismissing`, a plain request cancels a queued reopen if one is pending — the original
    /// exit's own deferred action still completes exactly once, it just no longer reopens — and is
    /// otherwise, like any other request while `.dismissing`, ignored, so a second close/action can
    /// never replace or duplicate the first accepted one. Returns the generation to complete
    /// against, or `nil` if rejected (including the queued-reopen-cancelled case, which has no new
    /// transition to complete).
    mutating func beginDismissal(after action: (@MainActor () -> Void)? = nil) -> Int? {
        switch phase {
        case .entering where action == nil:
            pendingAction = nil
            reopenQueued = false
            phase = .dismissing
            return generation
        case .presented:
            pendingAction = action
            reopenQueued = false
            phase = .dismissing
            return generation
        case .dismissing where action == nil && reopenQueued:
            reopenQueued = false
            return nil
        default:
            return nil
        }
    }

    /// Completes dismissal. Succeeds only when `generation` still names the current `.dismissing`
    /// transition, atomically clearing and returning any pending action so the caller can run it
    /// exactly once, after the surface has visually left. When a reopen was queued against this exit
    /// (see `beginPresentation()`) and never cancelled, this settles into a fresh `.entering`
    /// generation instead of `.hidden`, and hands that generation back as `reopened` so the caller
    /// can resume the same mounted surface with a new entry transition — the action still ran first,
    /// exactly once, on the way there. Otherwise this settles into `.hidden` as before.
    mutating func completeDismissal(generation: Int) -> DismissalCompletion {
        guard phase == .dismissing, generation == self.generation else { return .notCurrent }
        let action = pendingAction
        pendingAction = nil
        guard reopenQueued else {
            phase = .hidden
            return .completed(action: action, reopened: nil)
        }
        reopenQueued = false
        self.generation += 1
        phase = .entering
        return .completed(action: action, reopened: self.generation)
    }

    /// The presentation's owner (the presenting view) is going away. Invalidates the current
    /// generation and drops any pending action and queued reopen so neither can ever escape after
    /// its owner disappears, then returns to `.hidden`.
    mutating func cancelOwner() {
        generation += 1
        pendingAction = nil
        reopenQueued = false
        phase = .hidden
    }
}

/// Handed to a caller's footer/menu-action content so it can request dismissal through the owning
/// surface's lifecycle instead of managing presentation state itself. `dismiss()` is a plain close;
/// `dismissAfter(_:)` defers exactly one action, which the surface runs only once its exit
/// animation completes (see `HermexOverlayLifecycle.beginDismissal(after:)`).
struct HermexOverlayActionContext {
    private let requestDismissal: ((@MainActor () -> Void)?) -> Void

    init(requestDismissal: @escaping ((@MainActor () -> Void)?) -> Void) {
        self.requestDismissal = requestDismissal
    }

    func dismiss() {
        requestDismissal(nil)
    }

    func dismissAfter(_ action: @escaping @MainActor () -> Void) {
        requestDismissal(action)
    }
}
