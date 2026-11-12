import Foundation

/// The prompt cards that share the slot at the top of the session list.
enum SessionListCard {
    case tip, star

    /// The card to show. At most one per launch: once a card has shown, the other waits for
    /// a later launch, and the tip card wins when both are eligible.
    static func choose(tipEligible: Bool, starEligible: Bool, shownThisLaunch: SessionListCard?) -> SessionListCard? {
        switch shownThisLaunch {
        case .tip: return tipEligible ? .tip : nil
        case .star: return starEligible ? .star : nil
        case nil: return tipEligible ? .tip : starEligible ? .star : nil
        }
    }

    /// The card a session list shows now, on the device's standard defaults. The caller passes
    /// the stored counter and dismissed releases from its `@AppStorage`, so reading them
    /// subscribes its view and "Not now" hides a card at once.
    @MainActor
    static func current(completedResponses: Int, tipDismissedRelease: String?, starDismissedRelease: String?,
                        hasSharedImport: Bool) -> SessionListCard? {
        let ratingPolicy = RatingPromptState.shared.policy
        func isEligible(_ card: SessionListCard, dismissedRelease: String?) -> Bool {
            let state = SessionListCardState(card: card, defaults: .standard)
            return dismissedRelease != state.release && state.isEligible(
                completedResponses: completedResponses, hasSharedImport: hasSharedImport, ratingPolicy: ratingPolicy
            )
        }
        return choose(
            tipEligible: isEligible(.tip, dismissedRelease: tipDismissedRelease),
            starEligible: isEligible(.star, dismissedRelease: starDismissedRelease),
            shownThisLaunch: RatingPromptState.shared.cardShownThisLaunch
        )
    }

    /// `current` on the stored values, for a check outside a view's body, such as a rating
    /// request recording the card the list shows.
    @MainActor
    static func current(hasSharedImport: Bool) -> SessionListCard? {
        let defaults = UserDefaults.standard
        return current(completedResponses: defaults.integer(forKey: TipJar.completedResponseCountKey),
                       tipDismissedRelease: defaults.string(forKey: TipJar.dismissedReleaseKey),
                       starDismissedRelease: defaults.string(forKey: GitHubStar.dismissedReleaseKey),
                       hasSharedImport: hasSharedImport)
    }

    fileprivate var minimumResponses: Int {
        switch self {
        case .tip: return 25
        case .star: return 15
        }
    }

    var dismissedReleaseKey: String {
        switch self {
        case .tip: return TipJar.dismissedReleaseKey
        case .star: return GitHubStar.dismissedReleaseKey
        }
    }

    fileprivate var linkOpenedKey: String {
        switch self {
        case .tip: return TipJar.linkOpenedKey
        case .star: return GitHubStar.linkOpenedKey
        }
    }
}

/// One card's device-wide preferences: opening its link records intent (not a payment or a
/// star, which the app cannot see) and hides the card for good. "Not now" hides it until the
/// next feature release.
struct SessionListCardState {
    let card: SessionListCard
    let defaults: UserDefaults
    /// The installed marketing version; tests inject one.
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// Major.minor, so a patch update never brings a dismissed card back.
    var release: String {
        appVersion.split(separator: ".").prefix(2).joined(separator: ".")
    }

    func isEligible(completedResponses: Int, hasSharedImport: Bool, ratingPolicy: RatingPromptPolicy,
                    now: Date = Date()) -> Bool {
        completedResponses >= card.minimumResponses
            && defaults.string(forKey: card.dismissedReleaseKey) != release
            && !defaults.bool(forKey: card.linkOpenedKey)
            && !hasSharedImport && ratingPolicy.allowsSessionListCard(at: now)
    }

    func dismiss() {
        defaults.set(release, forKey: card.dismissedReleaseKey)
    }

    func recordLinkOpened() {
        defaults.set(true, forKey: card.linkOpenedKey)
        dismiss()
    }
}

/// One welcome per launch, then a short gesture every 3.5 seconds while visible. Whichever
/// session list card is showing owns the task; there are no frame updates during neutral pauses.
@MainActor
final class SessionListCardGreeting {
    static let shared = SessionListCardGreeting()
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
