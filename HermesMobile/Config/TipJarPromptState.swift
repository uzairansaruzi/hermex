import Foundation

/// Device-wide preferences: opening a tip link records intent, not a payment.
struct TipJarPromptState {
    let defaults: UserDefaults

    func isEligible(completedResponses: Int, hasSharedImport: Bool, ratingPolicy: RatingPromptPolicy,
                    now: Date = Date()) -> Bool {
        completedResponses >= 25 && !defaults.bool(forKey: TipJar.dismissedKey)
            && !defaults.bool(forKey: TipJar.linkOpenedKey)
            && !hasSharedImport && ratingPolicy.allowsTipCard(at: now)
    }

    func dismiss() {
        defaults.set(true, forKey: TipJar.dismissedKey)
    }

    func recordLinkOpened() {
        defaults.set(true, forKey: TipJar.linkOpenedKey)
        dismiss()
    }
}

/// One welcome per launch, then a short gesture every 3.5 seconds while visible.
/// The card owns the task; there are no frame updates during neutral pauses.
@MainActor
final class TipJarGreetingState {
    static let shared = TipJarGreetingState()
    private var hasGreeted = false

    enum Phase { case neutral, blink, hop, glanceDown, curious, happy }

    /// The view owns cancellation. Each awaited pause must finish successfully and
    /// still belong to an active task before another expression can be displayed.
    func play(
        reduceMotion: Bool,
        wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        display: (Phase) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        display(.neutral)
        let shouldGreet = !hasGreeted
        hasGreeted = true
        guard !reduceMotion else { return }
        do {
            if shouldGreet {
                let steps: [(pause: Duration, phase: Phase)] = [
                    (.milliseconds(250), .blink),
                    (.milliseconds(150), .neutral),
                    (.milliseconds(120), .hop),
                    (.milliseconds(180), .neutral),
                    (.milliseconds(220), .blink),
                    (.milliseconds(150), .neutral)
                ]
                for step in steps {
                    try await wait(step.pause)
                    try Task.checkCancellation()
                    display(step.phase)
                }
            }
            let gestures: [(phase: Phase, hold: Duration)] = [
                (.blink, .milliseconds(180)),
                (.glanceDown, .milliseconds(650)),
                (.curious, .milliseconds(700)),
                (.blink, .milliseconds(180)),
                (.happy, .milliseconds(650)),
                (.glanceDown, .milliseconds(650))
            ]
            var pause = Duration.milliseconds(3500)
            while !Task.isCancelled {
                for gesture in gestures {
                    try await wait(pause)
                    try Task.checkCancellation()
                    display(gesture.phase)
                    try await wait(gesture.hold)
                    try Task.checkCancellation()
                    display(.neutral)
                    // Measure the cadence from one gesture's start to the next.
                    pause = .milliseconds(3500) - gesture.hold
                }
            }
        } catch {
            // Dismissal, navigation, backgrounding or Reduce Motion stops the sequence.
        }
    }
}
