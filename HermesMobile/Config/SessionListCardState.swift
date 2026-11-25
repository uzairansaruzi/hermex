import Foundation

enum SessionListCard: CaseIterable {
    case pluginUpdate
    case usageReports
    case tip, star

    static func choose(eligible: Set<SessionListCard>, shownThisLaunch: SessionListCard?) -> SessionListCard? {
        if eligible.contains(.pluginUpdate) { return .pluginUpdate }
        if let shownThisLaunch { return eligible.contains(shownThisLaunch) ? shownThisLaunch : nil }
        return allCases.first(where: eligible.contains)
    }

    @MainActor
    static func current(completedResponses: Int, tipDismissedRelease: String?, starDismissedRelease: String?,
                        usageReportConsent: UsageReportConsent, forcesUsageReportsCard: Bool = false,
                        offersPluginUpdate: Bool = false, hasSharedImport: Bool) -> SessionListCard? {
        #if DEBUG
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
        if offersPluginUpdate, !hasSharedImport { eligible.insert(.pluginUpdate) }
        if usageReportsEligible(question: usageReportConsent.question(), completedResponses: completedResponses,
                                hasSharedImport: hasSharedImport, ratingPolicy: ratingPolicy) {
            eligible.insert(.usageReports)
        }
        if isEligible(.tip, dismissedRelease: tipDismissedRelease) { eligible.insert(.tip) }
        if isEligible(.star, dismissedRelease: starDismissedRelease) { eligible.insert(.star) }
        return choose(eligible: eligible, shownThisLaunch: RatingPromptState.shared.cardShownThisLaunch)
    }

    @MainActor
    static func current(pluginUpdateServer: URL?, hasSharedImport: Bool) -> SessionListCard? {
        let defaults = UserDefaults.standard
        return current(completedResponses: defaults.integer(forKey: TipJar.completedResponseCountKey),
                       tipDismissedRelease: defaults.string(forKey: TipJar.dismissedReleaseKey),
                       starDismissedRelease: defaults.string(forKey: GitHubStar.dismissedReleaseKey),
                       usageReportConsent: UsageReports.shared.consent,
                       forcesUsageReportsCard: defaults.bool(forKey: UsageReports.Keys.debugForcesCard),
                       offersPluginUpdate: pluginUpdateServer.flatMap { HermexPushUpdateOffers.shared.cardOffer(for: $0) } != nil,
                       hasSharedImport: hasSharedImport)
    }

    static func usageReportsEligible(question: UsageReportConsent.Question?, completedResponses: Int,
                                     hasSharedImport: Bool, ratingPolicy: RatingPromptPolicy, now: Date = Date()) -> Bool {
        question != nil && completedResponses >= Self.usageReports.minimumResponses && !hasSharedImport && ratingPolicy.allowsSessionListCard(at: now)
    }

    fileprivate var minimumResponses: Int {
        switch self {
        case .pluginUpdate: return 0
        case .usageReports: return 5
        case .tip: return 25
        case .star: return 15
        }
    }

    fileprivate var promptKeys: (dismissedRelease: String, linkOpened: String)? {
        switch self {
        case .pluginUpdate, .usageReports: return nil
        case .tip: return (TipJar.dismissedReleaseKey, TipJar.linkOpenedKey)
        case .star: return (GitHubStar.dismissedReleaseKey, GitHubStar.linkOpenedKey)
        }
    }
}

struct SessionListCardState {
    let card: SessionListCard
    let defaults: UserDefaults
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

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

    func recordLinkOpened() {
        guard let keys = card.promptKeys else { return }
        defaults.set(true, forKey: keys.linkOpened)
        dismiss()
    }

    @MainActor
    func openLinkFromCard(usage: UsageReports? = nil, now: Date = Date()) {
        recordLinkOpened()
        (usage ?? .shared).record(card, \.linkOpened, now: now)
    }

    @MainActor
    func dismissFromCard(usage: UsageReports? = nil) {
        dismiss()
        (usage ?? .shared).record(card, \.dismissed)
    }
}

@MainActor
final class SessionListCardGreeting {
    static let shared = SessionListCardGreeting()
    private var hasGreeted = false

    enum Phase { case neutral, blink, hop, glanceDown, curious, happy }

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
                    pause = .milliseconds(3500) - gesture.hold
                }
            }
        } catch {
        }
    }
}
