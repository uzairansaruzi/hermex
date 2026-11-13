import Foundation

/// The prompt cards that share the slot at the top of the session list.
enum SessionListCard: CaseIterable {
    /// Asks once whether to send usage reports (#1662), and again when the report gains fields.
    case usageReports
    case tip, star

    /// The card to show. At most one per launch: once a card has shown, the others wait for a
    /// later launch. When several are eligible, the first in `allCases` wins.
    static func choose(eligible: Set<SessionListCard>, shownThisLaunch: SessionListCard?) -> SessionListCard? {
        if let shownThisLaunch { return eligible.contains(shownThisLaunch) ? shownThisLaunch : nil }
        return allCases.first(where: eligible.contains)
    }

    /// The card a session list shows now, on the device's standard defaults. The caller passes
    /// the stored counter, dismissed releases and usage report answers from its `@AppStorage`,
    /// so reading them subscribes its view and an answer hides a card at once.
    @MainActor
    static func current(completedResponses: Int, tipDismissedRelease: String?, starDismissedRelease: String?,
                        usageReportConsent: UsageReportConsent, forcesUsageReportsCard: Bool = false,
                        hasSharedImport: Bool) -> SessionListCard? {
        #if DEBUG
        // Settings › Developer: skip every guard while the question is unanswered.
        if forcesUsageReportsCard, usageReportConsent.question() != nil { return .usageReports }
        #endif
        let ratingPolicy = RatingPromptState.shared.policy
        func isEligible(_ card: SessionListCard, dismissedRelease: String?) -> Bool {
            let state = SessionListCardState(card: card, defaults: .standard)
            return dismissedRelease != state.release && state.isEligible(
                completedResponses: completedResponses, hasSharedImport: hasSharedImport, ratingPolicy: ratingPolicy
            )
        }
        var eligible = Set<SessionListCard>()
        if usageReportsEligible(question: usageReportConsent.question(), completedResponses: completedResponses,
                                hasSharedImport: hasSharedImport, ratingPolicy: ratingPolicy) {
            eligible.insert(.usageReports)
        }
        if isEligible(.tip, dismissedRelease: tipDismissedRelease) { eligible.insert(.tip) }
        if isEligible(.star, dismissedRelease: starDismissedRelease) { eligible.insert(.star) }
        return choose(eligible: eligible, shownThisLaunch: RatingPromptState.shared.cardShownThisLaunch)
    }

    /// `current` on the stored values, for a check outside a view's body, such as a rating
    /// request recording the card the list shows.
    @MainActor
    static func current(hasSharedImport: Bool) -> SessionListCard? {
        let defaults = UserDefaults.standard
        return current(completedResponses: defaults.integer(forKey: TipJar.completedResponseCountKey),
                       tipDismissedRelease: defaults.string(forKey: TipJar.dismissedReleaseKey),
                       starDismissedRelease: defaults.string(forKey: GitHubStar.dismissedReleaseKey),
                       usageReportConsent: UsageReports.shared.consent,
                       forcesUsageReportsCard: defaults.bool(forKey: UsageReports.Keys.debugForcesCard),
                       hasSharedImport: hasSharedImport)
    }

    /// The usage reports card waits for 5 completed responses and an unanswered question, under
    /// the same share and rating guards as the other cards. It has no X: only an answer hides it.
    static func usageReportsEligible(question: UsageReportConsent.Question?, completedResponses: Int,
                                     hasSharedImport: Bool, ratingPolicy: RatingPromptPolicy, now: Date = Date()) -> Bool {
        question != nil && completedResponses >= Self.usageReports.minimumResponses && !hasSharedImport && ratingPolicy.allowsSessionListCard(at: now)
    }

    fileprivate var minimumResponses: Int {
        switch self {
        case .usageReports: return 5
        case .tip: return 25
        case .star: return 15
        }
    }

    /// The tip and star cards' stored answers; the usage reports card keeps its own in `UsageReports`.
    fileprivate var promptKeys: (dismissedRelease: String, linkOpened: String)? {
        switch self {
        case .usageReports: return nil
        case .tip: return (TipJar.dismissedReleaseKey, TipJar.linkOpenedKey)
        case .star: return (GitHubStar.dismissedReleaseKey, GitHubStar.linkOpenedKey)
        }
    }
}

/// The tip or star card's device-wide preferences: opening its link records intent (not a
/// payment or a star, which the app cannot see) and hides the card for good. "Not now" hides it
/// until the next feature release.
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
        guard let keys = card.promptKeys else { return false }
        return completedResponses >= card.minimumResponses
            && defaults.string(forKey: keys.dismissedRelease) != release
            && !defaults.bool(forKey: keys.linkOpened)
            && !hasSharedImport && ratingPolicy.allowsSessionListCard(at: now)
    }

    func dismiss() {
        guard let keys = card.promptKeys else { return }
        defaults.set(release, forKey: keys.dismissedRelease)
    }

    /// Settings › About's rows call this directly; the card's own button goes through
    /// `openLinkFromCard`, which also tallies it.
    func recordLinkOpened() {
        guard let keys = card.promptKeys else { return }
        defaults.set(true, forKey: keys.linkOpened)
        dismiss()
    }

    /// The card's own button: hides it for good and tallies `link_opened`, not `dismissed`.
    @MainActor
    func openLinkFromCard(usage: UsageReports? = nil) {
        recordLinkOpened()
        (usage ?? .shared).record(card, \.linkOpened)
    }

    /// The card's X.
    @MainActor
    func dismissFromCard(usage: UsageReports? = nil) {
        dismiss()
        (usage ?? .shared).record(card, \.dismissed)
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
