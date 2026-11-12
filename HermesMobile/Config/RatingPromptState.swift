import Foundation

/// Only completed main-app replies count. Later requests require both cooldowns.
struct RatingPromptPolicy {
    static let day: TimeInterval = 24 * 60 * 60

    let firstLaunchDate: Date?
    let completedResponses: Int
    let lastRequestDate: Date?
    let responsesAtLastRequest: Int

    func isEligible(at now: Date) -> Bool {
        guard let firstLaunchDate,
              now.timeIntervalSince(firstLaunchDate) >= 3 * Self.day,
              completedResponses >= 10 else { return false }
        guard let lastRequestDate else { return true }
        return now.timeIntervalSince(lastRequestDate) >= 60 * Self.day
            && completedResponses - responsesAtLastRequest >= 30
    }

    func allowsSessionListCard(at now: Date) -> Bool {
        guard let lastRequestDate else { return true }
        return now.timeIntervalSince(lastRequestDate) >= 7 * Self.day
    }
}

enum RatingPromptMoment {
    case coldLaunch
    case foreground
    case returnedToSessionList
}

/// Persists engagement across servers; launch guards and weak stream owners stay in memory.
@MainActor
final class RatingPromptState {
    static let shared: RatingPromptState = {
        let state = RatingPromptState(defaults: .standard, usage: .shared)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rating-prompt-eligible") {
            state.prepareForTesting()
        }
        #endif
        return state
    }()

    private struct StreamOwner {
        weak var coordinator: (any ChatTurnCoordinating)?
        let server: URL
    }

    private let defaults: UserDefaults
    /// Also counts each completed response for the week's usage report, when reports are allowed.
    private let usage: UsageReports?
    private var streamOwners: [StreamOwner] = []
    private(set) var isFirstLaunch: Bool
    private(set) var cardShownThisLaunch: SessionListCard?

    init(defaults: UserDefaults, now: Date = Date(), usage: UsageReports? = nil) {
        self.defaults = defaults
        self.usage = usage
        isFirstLaunch = defaults.object(forKey: RatingPromptSettings.firstLaunchDateKey) == nil
        if isFirstLaunch {
            defaults.set(now, forKey: RatingPromptSettings.firstLaunchDateKey)
        }
    }

    var policy: RatingPromptPolicy {
        RatingPromptPolicy(
            firstLaunchDate: defaults.object(forKey: RatingPromptSettings.firstLaunchDateKey) as? Date,
            completedResponses: defaults.integer(forKey: TipJar.completedResponseCountKey),
            lastRequestDate: defaults.object(forKey: RatingPromptSettings.lastRequestDateKey) as? Date,
            responsesAtLastRequest: defaults.integer(forKey: RatingPromptSettings.responseCountAtLastRequestKey)
        )
    }

    func recordCompletedResponse() {
        defaults.set(policy.completedResponses + 1, forKey: TipJar.completedResponseCountKey)
        usage?.recordCompletedResponse()
    }

    /// A webui stream or a Hermes chat on `server`; a running turn holds the request back.
    func register(_ coordinator: any ChatTurnCoordinating, server: URL) {
        streamOwners.removeAll { $0.coordinator == nil }
        streamOwners.append(StreamOwner(coordinator: coordinator, server: server))
    }

    func hasActiveStream(on server: URL) -> Bool {
        streamOwners.contains { $0.server == server && $0.coordinator?.activeStreamID != nil }
    }

    // The list checks card eligibility before rating requests and records display here,
    // so dismissing a card cannot allow a rating request, or the other card, later in the
    // same launch.
    func recordCardShown(_ card: SessionListCard) {
        if cardShownThisLaunch == nil { cardShownThisLaunch = card }
    }

    func canRequest(at now: Date = Date()) -> Bool {
        !isFirstLaunch && cardShownThisLaunch == nil && policy.isEligible(at: now)
    }

    /// Check all server sessions, including rows hidden by sidebar filters. Recheck
    /// local ownership and navigation after the await; failure simply skips this moment.
    func requestWhenQuiet(
        moment: RatingPromptMoment,
        server: URL,
        isSessionListVisible: () -> Bool,
        loadSessions: () async throws -> [SessionSummary]?,
        request: () -> Void
    ) async {
        guard moment != .coldLaunch, canRequest(), isSessionListVisible(),
              !hasActiveStream(on: server), !Task.isCancelled else { return }
        do {
            guard let sessions = try await loadSessions(),
                  !Task.isCancelled else { return }
            requestIfEligible(
                moment: moment,
                isSessionListVisible: isSessionListVisible(),
                hasActiveStream: hasActiveStream(on: server)
                    || sessions.contains(where: SessionRowView.isActiveStreaming),
                request: request
            )
        } catch {
            // An optional prompt never turns a connection failure into a user-facing error.
        }
    }

    /// Record the attempt before invoking StoreKit; Apple may choose not to show anything.
    @discardableResult
    func requestIfEligible(
        moment: RatingPromptMoment,
        isSessionListVisible: Bool,
        hasActiveStream: Bool,
        now: Date = Date(),
        request: () -> Void
    ) -> Bool {
        guard moment != .coldLaunch, isSessionListVisible, !hasActiveStream,
              canRequest(at: now) else { return false }
        defaults.set(now, forKey: RatingPromptSettings.lastRequestDateKey)
        defaults.set(policy.completedResponses, forKey: RatingPromptSettings.responseCountAtLastRequestKey)
        request()
        return true
    }

    #if DEBUG
    func reset(now: Date = Date()) {
        defaults.removeObject(forKey: RatingPromptSettings.lastRequestDateKey)
        defaults.removeObject(forKey: RatingPromptSettings.responseCountAtLastRequestKey)
        defaults.removeObject(forKey: TipJar.completedResponseCountKey)
        defaults.set(now, forKey: RatingPromptSettings.firstLaunchDateKey)
        isFirstLaunch = true
        cardShownThisLaunch = nil
    }

    /// Launch-only override for exercising the real navigation and stream guards.
    private func prepareForTesting(now: Date = Date()) {
        reset(now: now.addingTimeInterval(-4 * RatingPromptPolicy.day))
        defaults.set(10, forKey: TipJar.completedResponseCountKey)
        isFirstLaunch = false
    }
    #endif
}
