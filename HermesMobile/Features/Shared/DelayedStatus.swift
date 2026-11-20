import SwiftUI

struct DelayedStatusPolicy: Equatable {
    var showAfter: Duration = .milliseconds(400)
    var holdFor: Duration = .milliseconds(400)
}

struct DelayedStatus<Value: Equatable> {
    private(set) var shown: Value?
    private var showAt: ContinuousClock.Instant?
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

@MainActor
@Observable
final class DelayedStatusDriver<Value: Equatable> {
    private(set) var shown: Value?

    @ObservationIgnored private var status = DelayedStatus<Value>()
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: @MainActor (ContinuousClock.Instant) async throws -> Void

    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void = { deadline in
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

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

struct DelayedStatusView<Value: Equatable, Content: View>: View {
    let driver: DelayedStatusDriver<Value>
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let shown = driver.shown {
            content(shown)
        }
    }
}
