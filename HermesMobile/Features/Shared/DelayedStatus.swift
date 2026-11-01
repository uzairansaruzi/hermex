import SwiftUI

/// How long a status waits before it shows, and how long it stays once shown,
/// so a brief status never flashes (#1373). The chat's stream recovery chip
/// uses the defaults.
struct DelayedStatusPolicy: Equatable {
    var showAfter: Duration = .milliseconds(400)
    var holdFor: Duration = .milliseconds(400)
}

/// The show-after/hold-for rule for one status, stepped with caller-supplied
/// time; it never sleeps. Each `update` returns the next deadline at which the
/// caller must step again with the same target, or nil when nothing is
/// scheduled.
///
/// - A new status waits `showAfter`; cleared before then, it never shows.
///   Changes between pending statuses keep the first deadline.
/// - A shown status stays at least `holdFor` after it appeared, even if the
///   target clears.
/// - A different status while one is shown or held swaps at once and starts
///   its own hold.
/// - `immediately` skips the show delay, for a status the user must see now.
struct DelayedStatus<Value: Equatable> {
    private(set) var shown: Value?
    /// When the pending target shows; nil unless a target waits to show.
    private var showAt: ContinuousClock.Instant?
    /// The earliest the shown value may hide.
    private var holdUntil: ContinuousClock.Instant?

    mutating func update(
        target: Value?,
        now: ContinuousClock.Instant,
        policy: DelayedStatusPolicy,
        immediately: Bool
    ) -> ContinuousClock.Instant? {
        guard let target else {
            showAt = nil
            if shown != nil, let holdUntil, now < holdUntil {
                return holdUntil
            }
            shown = nil
            holdUntil = nil
            return nil
        }

        if shown == nil, !immediately {
            let deadline = showAt ?? now.advanced(by: policy.showAfter)
            guard now >= deadline else {
                showAt = deadline
                return deadline
            }
        }

        showAt = nil
        if shown != target {
            shown = target
            holdUntil = now.advanced(by: policy.holdFor)
        }
        return nil
    }
}

/// Publishes one `DelayedStatus` for a view. The owner keeps it in `@State`
/// and calls `run` from `.task(id:)` keyed by the target, so a new target or
/// the view going away cancels the old run. Draw it with `DelayedStatusView`.
@MainActor
@Observable
final class DelayedStatusDriver<Value: Equatable> {
    private(set) var shown: Value?

    @ObservationIgnored private var status = DelayedStatus<Value>()
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: @MainActor (ContinuousClock.Instant) async throws -> Void

    /// Tests inject `now` and `sleep` to move the clock on cue.
    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void = { deadline in
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// Steps toward `target` now and at each deadline, sleeping only until the
    /// next one. A cancelled run never writes again. `animation` animates the
    /// shown value's changes, so transitions follow what the user sees rather
    /// than the raw target.
    func run(
        target: Value?,
        policy: DelayedStatusPolicy = DelayedStatusPolicy(),
        immediately: Bool = false,
        animation: Animation? = nil
    ) async {
        guard !Task.isCancelled else { return }
        var deadline = step(target: target, policy: policy, immediately: immediately, animation: animation)
        while let next = deadline {
            do {
                try await sleep(next)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            deadline = step(target: target, policy: policy, immediately: immediately, animation: animation)
        }
    }

    private func step(
        target: Value?,
        policy: DelayedStatusPolicy,
        immediately: Bool,
        animation: Animation?
    ) -> ContinuousClock.Instant? {
        let deadline = status.update(target: target, now: now(), policy: policy, immediately: immediately)
        if status.shown != shown {
            withAnimation(animation) { shown = status.shown }
        }
        return deadline
    }
}

/// Draws a driver's shown status, and nothing while there is none. Reading
/// `shown` here rather than in the parent keeps a delayed show or hide from
/// re-evaluating the parent's body.
struct DelayedStatusView<Value: Equatable, Content: View>: View {
    let driver: DelayedStatusDriver<Value>
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let shown = driver.shown {
            content(shown)
        }
    }
}
