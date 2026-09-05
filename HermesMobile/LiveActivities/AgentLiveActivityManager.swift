import ActivityKit
import Foundation
import OSLog

private let liveActivityReconcilerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "LiveActivityReconciler"
)

enum AgentLiveActivityEvent: Equatable {
    case sessionTitle(String)
    case token(String)
    case interimAssistant(String)
    case clearResponseExcerpt
    case reasoning(String)
    case toolStarted(name: String?)
    case toolCompleted
    case waitingForApproval
    case waitingForClarification
}

/// A persisted Live Activity left over from a previous launch that this manager
/// isn't currently driving — a reconciliation candidate (#246). Carries the bits
/// the reconciler needs to decide whether a "response complete" notification is
/// still worth firing: the run's session and when it last advanced (#248).
struct OrphanedLiveActivity: Equatable {
    let streamID: String
    let sessionID: String
    let updatedAt: Date
}

@MainActor
protocol AgentLiveActivityManaging: AnyObject {
    /// `startedAt` is when the *run* began, not when the widget was created: the
    /// coordinator passes the server-seeded run start so the widget's system
    /// elapsed timer counts the same span as the in-app "Working for" label
    /// (#406). Callers without a seeded start pass `Date()`.
    func start(sessionID: String, sessionTitle: String, streamID: String?, startedAt: Date)
    func update(_ event: AgentLiveActivityEvent)
    func markStale()
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?)
    /// Persisted Live Activities left over from a previous launch that this manager
    /// isn't currently driving — reconciliation candidates (#246).
    func orphanedActivities() -> [OrphanedLiveActivity]
    /// End a persisted activity this manager isn't tracking in memory (e.g. the
    /// app was terminated mid-run and relaunched), matched by streamID (#246).
    /// Returns `true` only if it actually transitioned a still-running activity to
    /// final — the reconciler uses that to avoid firing a duplicate notification
    /// for a completion another path already finalized (#248).
    @discardableResult
    func endOrphanedActivity(streamID: String, status: AgentRunActivityStatus, activity: String) async -> Bool
}

extension AgentLiveActivityManaging {
    // Defaults so test spies and non-ActivityKit conformers don't have to care
    // about reconciliation; the real manager overrides both.
    func orphanedActivities() -> [OrphanedLiveActivity] { [] }
    @discardableResult
    func endOrphanedActivity(streamID: String, status: AgentRunActivityStatus, activity: String) async -> Bool { false }
}

@MainActor
final class AgentLiveActivityManager: AgentLiveActivityManaging {
    static let shared = AgentLiveActivityManager()

    private let minimumUpdateInterval: TimeInterval
    private var activity: Activity<AgentRunActivityAttributes>?
    private var currentState: AgentRunActivityAttributes.ContentState?
    private var currentSessionID: String?
    private var currentStreamID: String?
    // StreamID of the run whose SSE is live in THIS process right now: set when the
    // coordinator (re)connects (`start`), cleared the moment it suspends/hits trouble
    // (`markStale`) or finalizes (`end`/`reset`). The orphan reconciler skips it so a
    // server status poll that briefly reports "inactive" — the window between the
    // server finishing and the on-device `.done` arriving — can't finalize a stream
    // the foreground coordinator still owns. A terminated run starts from a fresh
    // singleton (nothing tracked), so the #246 orphan fix is unaffected. (PR #266 #3)
    private(set) var activeConnectedStreamID: String?
    private var rawResponseText = ""
    private var lastSentUpdateAt: Date?
    private var pendingUpdateTask: Task<Void, Never>?
    private var updateGeneration = 0
    private var lifecycleGeneration = 0

    init(minimumUpdateInterval: TimeInterval = 1.5) {
        self.minimumUpdateInterval = minimumUpdateInterval
    }

    func start(sessionID: String, sessionTitle: String, streamID: String?, startedAt: Date = Date()) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        let normalizedStreamID = AgentLiveActivityReusePolicy.normalizedStreamID(streamID)
        // A live SSE connection now owns this stream's completion (PR #266 #3).
        activeConnectedStreamID = normalizedStreamID

        if currentSessionID == normalizedSessionID,
           currentStreamID == normalizedStreamID,
           currentState?.isFinal == false {
            updateCurrentState { state in
                AgentRunActivityAttributes.ContentState(
                    sessionID: state.sessionID,
                    sessionTitle: state.sessionTitle,
                    status: state.status,
                    currentActivity: state.currentActivity,
                    responseExcerpt: state.responseExcerpt,
                    startedAt: state.startedAt,
                    updatedAt: Date(),
                    isStale: false,
                    isFinal: false,
                    errorSummary: nil
                )
            }
            return
        }

        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        rawResponseText = ""
        currentSessionID = normalizedSessionID
        currentStreamID = normalizedStreamID
        let state = AgentRunActivityStateReducer.initialState(
            sessionID: normalizedSessionID,
            sessionTitle: sessionTitle,
            startedAt: startedAt
        )
        currentState = state
        lastSentUpdateAt = nil
        let lifecycle = nextLifecycleGeneration()
        _ = nextUpdateGeneration()

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activity = nil
            return
        }

        Task { [weak self, lifecycle] in
            await self?.requestOrUpdateActivity(
                sessionID: normalizedSessionID,
                streamID: normalizedStreamID,
                sessionTitle: state.sessionTitle,
                state: state,
                lifecycle: lifecycle
            )
        }
    }

    func update(_ event: AgentLiveActivityEvent) {
        guard currentState != nil else { return }

        switch event {
        case .sessionTitle(let title):
            updateCurrentState { state in
                AgentRunActivityStateReducer.updatingSessionTitle(title, state: state)
            }
        case .token(let text):
            guard !text.isEmpty else { return }
            rawResponseText += text
            updateCurrentState(immediate: false) { state in
                AgentRunActivityStateReducer.settingInterimAssistant(rawResponseText, on: state)
            }
        case .interimAssistant(let text):
            let excerpt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excerpt.isEmpty else { return }
            rawResponseText = rawResponseText.isEmpty ? excerpt : rawResponseText
            updateCurrentState { state in
                AgentRunActivityStateReducer.settingInterimAssistant(excerpt, on: state)
            }
        case .clearResponseExcerpt:
            rawResponseText = ""
            updateCurrentState { state in
                AgentRunActivityStateReducer.clearingResponseExcerpt(state: state)
            }
        case .reasoning(let text):
            updateCurrentState { state in
                AgentRunActivityStateReducer.reasoning(text, state: state)
            }
        case .toolStarted(let name):
            updateCurrentState { state in
                AgentRunActivityStateReducer.toolStarted(name: name, state: state)
            }
        case .toolCompleted:
            updateCurrentState { state in
                AgentRunActivityStateReducer.toolCompleted(state: state)
            }
        case .waitingForApproval:
            updateCurrentState { state in
                AgentRunActivityStateReducer.waitingForApproval(state: state)
            }
        case .waitingForClarification:
            updateCurrentState { state in
                AgentRunActivityStateReducer.waitingForClarification(state: state)
            }
        }
    }

    func markStale() {
        // Suspended / troubled: the live SSE no longer owns completion, so the
        // stream is eligible for server-truth reconciliation again (PR #266 #3).
        activeConnectedStreamID = nil
        guard currentState?.isFinal == false else { return }

        updateCurrentState { state in
            AgentRunActivityStateReducer.stale(state: state)
        }
    }

    func end(status: AgentRunActivityStatus, activity activityLine: String, errorSummary: String? = nil) {
        // The run is finalizing — drop the live-connection claim (PR #266 #3).
        activeConnectedStreamID = nil
        guard let currentState else { return }

        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil

        let finalState = AgentRunActivityStateReducer.final(
            status: status,
            activity: activityLine,
            state: currentState,
            errorSummary: errorSummary
        )
        self.currentState = finalState
        let endingActivity = activity
        let endingSessionID = currentSessionID
        let lifecycle = nextLifecycleGeneration()
        _ = nextUpdateGeneration()
        activity = nil

        Task { [weak self, endingActivity, lifecycle] in
            await self?.endActivity(
                endingActivity,
                with: finalState,
                status: status,
                endingSessionID: endingSessionID,
                lifecycle: lifecycle
            )
        }
    }

    func orphanedActivities() -> [OrphanedLiveActivity] {
        let all = Activity<AgentRunActivityAttributes>.activities
        // Every non-final persisted activity is a candidate. We deliberately do
        // NOT exclude `currentStreamID` here: that in-memory flag goes stale when
        // a run ends without the manager being told (e.g. the app froze in the
        // background and came back with the stream untracked), which left the
        // activity stuck on "running" with nothing to finalize it (#246). The
        // caller gates purely on the server's status instead, which is ground
        // truth — a genuinely live run reports active=true and is left alone.
        let result: [OrphanedLiveActivity] = all.compactMap { activity in
            guard let streamID = AgentLiveActivityReusePolicy.normalizedStreamID(activity.attributes.streamID) else {
                return nil
            }
            let state = activity.content.state
            guard state.isFinal == false else { return nil }
            // Skip a stream whose SSE is live in this process right now: the
            // foreground coordinator owns its completion and a transient server
            // "inactive" must not let us finalize it early (mirrors the
            // refreshTranscriptIfCompleted safety net). Cleared on suspend/end, so
            // a genuinely stuck orphan is never excluded here. (PR #266 #3)
            guard streamID != activeConnectedStreamID else { return nil }
            return OrphanedLiveActivity(
                streamID: streamID,
                sessionID: state.sessionID,
                updatedAt: state.updatedAt
            )
        }
        return result
    }

    @discardableResult
    func endOrphanedActivity(
        streamID: String,
        status: AgentRunActivityStatus,
        activity activityLine: String
    ) async -> Bool {
        guard let normalized = AgentLiveActivityReusePolicy.normalizedStreamID(streamID) else { return false }

        var didEndRunningActivity = false
        for persisted in Activity<AgentRunActivityAttributes>.activities
        where AgentLiveActivityReusePolicy.normalizedStreamID(persisted.attributes.streamID) == normalized {
            guard persisted.content.state.isFinal == false else { continue }

            let finalState = AgentRunActivityStateReducer.final(
                status: status,
                activity: activityLine,
                state: persisted.content.state
            )
            // `end(content:)` sets the final content directly and there is no
            // intervening render delay here, so a preceding `update` is redundant
            // (PR #266 review).
            await persisted.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: dismissalPolicy(for: status)
            )
            didEndRunningActivity = true
        }

        // Clear stale in-memory tracking if this was the stream the manager still
        // thought it was driving, so a new run in the same session starts clean.
        if normalized == currentStreamID {
            reset()
        }

        return didEndRunningActivity
    }

    private func requestOrUpdateActivity(
        sessionID: String,
        streamID: String?,
        sessionTitle: String,
        state: AgentRunActivityAttributes.ContentState,
        lifecycle: Int
    ) async {
        guard lifecycle == lifecycleGeneration else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        do {
            let existingActivities = Activity<AgentRunActivityAttributes>.activities
            let reusableActivity = existingActivities.first { existing in
                AgentLiveActivityReusePolicy.canReuseActivity(
                    existingSessionID: existing.attributes.sessionID,
                    existingStreamID: existing.attributes.streamID,
                    requestedSessionID: sessionID,
                    requestedStreamID: streamID
                )
            }

            for staleActivity in existingActivities {
                if let reusableActivity, staleActivity.id == reusableActivity.id {
                    continue
                }

                await staleActivity.end(nil, dismissalPolicy: .immediate)
            }
            guard lifecycle == lifecycleGeneration else { return }

            if let existing = reusableActivity {
                activity = existing
                let latestState = currentState ?? state
                await existing.update(
                    ActivityContent(state: latestState, staleDate: staleDate(for: latestState))
                )
                lastSentUpdateAt = Date()
                return
            }

            let attributes = AgentRunActivityAttributes(
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                streamID: streamID,
                startedAt: state.startedAt
            )
            let requestedActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate(for: state)),
                pushType: nil
            )
            guard lifecycle == lifecycleGeneration else { return }
            activity = requestedActivity
            if let latestState = currentState, latestState != state {
                await requestedActivity.update(
                    ActivityContent(state: latestState, staleDate: staleDate(for: latestState))
                )
            }
            lastSentUpdateAt = Date()
        } catch {
            activity = nil
        }
    }

    private func updateCurrentState(
        immediate: Bool = true,
        _ transform: (AgentRunActivityAttributes.ContentState) -> AgentRunActivityAttributes.ContentState
    ) {
        guard let currentState else { return }

        let updatedState = transform(currentState)
        self.currentState = updatedState

        guard activity != nil else { return }
        scheduleUpdate(updatedState, immediate: immediate)
    }

    private func scheduleUpdate(
        _ state: AgentRunActivityAttributes.ContentState,
        immediate: Bool
    ) {
        let now = Date()
        if immediate || lastSentUpdateAt == nil || now.timeIntervalSince(lastSentUpdateAt!) >= minimumUpdateInterval {
            pendingUpdateTask?.cancel()
            pendingUpdateTask = nil
            let generation = nextUpdateGeneration()
            Task { [weak self, generation] in
                await self?.sendUpdate(state, staleDate: self?.staleDate(for: state), generation: generation)
            }
            return
        }

        guard pendingUpdateTask == nil else { return }

        let delay = max(0, minimumUpdateInterval - now.timeIntervalSince(lastSentUpdateAt!))
        pendingUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self, !Task.isCancelled, let currentState = self.currentState else { return }
                self.pendingUpdateTask = nil
                let generation = self.nextUpdateGeneration()
                Task { [weak self, generation] in
                    await self?.sendUpdate(
                        currentState,
                        staleDate: self?.staleDate(for: currentState),
                        generation: generation
                    )
                }
            }
        }
    }

    private func sendUpdate(
        _ state: AgentRunActivityAttributes.ContentState,
        staleDate: Date?,
        generation: Int
    ) async {
        guard generation == updateGeneration else { return }
        guard let activity else { return }

        await activity.update(ActivityContent(state: state, staleDate: staleDate))
        lastSentUpdateAt = Date()
    }

    private func endActivity(
        _ endingActivity: Activity<AgentRunActivityAttributes>?,
        with finalState: AgentRunActivityAttributes.ContentState,
        status: AgentRunActivityStatus,
        endingSessionID: String?,
        lifecycle: Int
    ) async {
        guard let endingActivity else {
            resetIfStillCurrent(endingSessionID: endingSessionID, finalState: finalState)
            return
        }

        let policy = dismissalPolicy(for: status)

        await endingActivity.update(ActivityContent(state: finalState, staleDate: nil))
        if status == .complete {
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        guard lifecycle == lifecycleGeneration else {
            await endingActivity.end(nil, dismissalPolicy: .immediate)
            return
        }

        await endingActivity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: policy
        )
        resetIfStillCurrent(endingSessionID: endingSessionID, finalState: finalState)
    }

    private func dismissalPolicy(for status: AgentRunActivityStatus) -> ActivityUIDismissalPolicy {
        switch status {
        case .complete:
            .after(Date().addingTimeInterval(300))
        case .failed, .cancelled:
            .after(Date().addingTimeInterval(30))
        default:
            .default
        }
    }

    private func staleDate(for state: AgentRunActivityAttributes.ContentState) -> Date? {
        // #246: keep the widget looking current longer so a suspended run doesn't
        // get the dimmed "stale" treatment within seconds. The system-rendered
        // elapsed timer keeps ticking regardless of this window.
        state.isFinal ? nil : Date().addingTimeInterval(state.isStale ? 90 : 300)
    }

    private func reset() {
        activity = nil
        currentState = nil
        currentSessionID = nil
        currentStreamID = nil
        activeConnectedStreamID = nil
        rawResponseText = ""
        lastSentUpdateAt = nil
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        _ = nextLifecycleGeneration()
        _ = nextUpdateGeneration()
    }

    private func nextUpdateGeneration() -> Int {
        updateGeneration += 1
        return updateGeneration
    }

    private func nextLifecycleGeneration() -> Int {
        lifecycleGeneration += 1
        return lifecycleGeneration
    }

    private func resetIfStillCurrent(
        endingSessionID: String?,
        finalState: AgentRunActivityAttributes.ContentState
    ) {
        guard currentSessionID == endingSessionID,
              currentState == finalState else {
            return
        }

        reset()
    }
}

// MARK: - Orphaned Live Activity reconciliation (#246)

/// Ends Live Activities left over from a previous app launch whose runs the
/// server reports as no longer active. This closes the "app was terminated while
/// locked, the run finished, and the Live Activity is stuck on running" leak:
/// nothing else reconciles persisted activities the in-memory coordinator never
/// knew about. Streams still active server-side are left untouched for the normal
/// reconnect path to adopt.
@MainActor
enum LiveActivityReconciler {
    /// How recently a run must have completed for the cold-launch reconciler to
    /// still fire a "response complete" notification for it. Matches the 300s
    /// non-stale `staleDate` window the widget uses (#248): an older completion is
    /// finalized silently — the user has long since moved on.
    /// `nonisolated` so it can serve as a default argument (evaluated off the main
    /// actor) without a Swift-6 isolation warning; it's an immutable `Double`.
    nonisolated static let recentCompletionWindow: TimeInterval = 300

    /// The final status + localized widget line a reconciled orphan should be
    /// ended with, derived from the server journal's `terminal_state` (#267).
    struct ReconciledOutcome: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
    }

    /// Maps the server run-journal `terminal_state` to the outcome we finalize a
    /// reconciled orphan with (#267 — owner-decided table on the issue). Reuses
    /// the existing localized completion lines, so there is no new copy.
    ///
    /// The default arm — missing / `"unknown"` / `"running"` / any value we don't
    /// yet recognize — keeps the pre-#267 `.complete` fallback, so an unmapped
    /// state can never mislabel a genuine completion as a failure. Load-bearing
    /// case: the server reports a silently-dropped run (neither active nor
    /// terminal) as `"lost-worker-bookkeeping"`, which must finalize as `.failed`.
    nonisolated static func reconciledOutcome(forTerminalState terminalState: String?) -> ReconciledOutcome {
        switch terminalState {
        case "completed":
            return ReconciledOutcome(status: .complete, activity: String(localized: "Response complete"))
        case "errored", "interrupted-by-crash", "lost-worker-bookkeeping":
            return ReconciledOutcome(status: .failed, activity: String(localized: "Response failed"))
        case "interrupted-by-user":
            return ReconciledOutcome(status: .cancelled, activity: String(localized: "Response cancelled"))
        default:
            return ReconciledOutcome(status: .complete, activity: String(localized: "Response complete"))
        }
    }

    /// Production entry point: reconcile every orphaned activity against the
    /// logged-in server's stream status.
    ///
    /// `notifiesOnCompletion` is true only for the cold-launch pass: a relaunched
    /// process means every orphan's run finished while the app was *not* active, so
    /// a recent one is worth a "response complete" notification (#248). The
    /// foreground pass passes false — the in-session completion paths own
    /// notifications while the app is alive, so reconciling there must stay silent.
    static func reconcileOrphanedActivities(
        server: URL,
        notifiesOnCompletion: Bool,
        preferenceEnabled: Bool,
        now: Date = Date(),
        manager: (any AgentLiveActivityManaging)? = nil
    ) async {
        let manager = manager ?? AgentLiveActivityManager.shared
        let orphans = manager.orphanedActivities()
        guard !orphans.isEmpty else { return }
        liveActivityReconcilerLogger.notice("Checking \(orphans.count, privacy: .public) persisted Live Activity(ies) against server status")

        let client = APIClient(baseURL: server)
        await reconcileOrphanedActivities(
            orphans: orphans,
            now: now,
            notifiesOnCompletion: notifiesOnCompletion,
            streamStatus: { streamID in
                try? await client.chatStreamStatus(streamID: streamID)
            },
            endOrphan: { orphan, outcome in
                liveActivityReconcilerLogger.notice("Ending orphaned Live Activity \(orphan.streamID, privacy: .public) — server reports the run is over (\(outcome.status.rawValue, privacy: .public))")
                // #267: finalize each orphan with its real outcome, mapped from the
                // server journal's `terminal_state`, so a run that failed silently
                // or was cancelled no longer shows "Response complete" on the
                // auto-dismissing widget.
                return await manager.endOrphanedActivity(
                    streamID: orphan.streamID,
                    status: outcome.status,
                    activity: outcome.activity
                )
            },
            notify: { orphan in
                liveActivityReconcilerLogger.notice("Notifying response complete for reconciled Live Activity \(orphan.streamID, privacy: .public)")
                // The run completed while the app was *not* active (it was
                // terminated); the recency check in the core stands in for "you
                // weren't watching", so this path always passes sceneIsActive: false.
                // #267: the core only calls `notify` for an orphan that mapped to
                // `.complete`, so this is always a genuine completion — a silently
                // failed run is finalized silently and no longer mis-notifies.
                await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
                    sessionID: orphan.sessionID.isEmpty ? nil : orphan.sessionID,
                    preferenceEnabled: preferenceEnabled,
                    completedNormally: true,
                    sceneIsActive: false
                )
            }
        )
    }

    /// Testable core. For each orphaned stream, fetch its server status; only a
    /// definitive inactive status (the run is over) ends the activity, finalized
    /// with the outcome mapped from the journal's `terminal_state` (#267). A failed
    /// status check (`nil` response) or a still-active stream is left alone, so a
    /// transient error or a live run can never cut an activity short.
    ///
    /// A "response complete" notification fires only when (a) this is the notifying
    /// (cold-launch) pass, (b) the orphan mapped to `.complete` — a failed or
    /// cancelled run is finalized silently (#267), (c) `endOrphan` reports it
    /// actually ended a still-running activity — so a completion another path
    /// already finalized can't double-fire (#248) — and (d) the run finished within
    /// `recencyWindow`.
    static func reconcileOrphanedActivities(
        orphans: [OrphanedLiveActivity],
        now: Date,
        notifiesOnCompletion: Bool,
        recencyWindow: TimeInterval = recentCompletionWindow,
        streamStatus: (String) async -> ChatStreamStatusResponse?,
        endOrphan: (OrphanedLiveActivity, ReconciledOutcome) async -> Bool,
        notify: (OrphanedLiveActivity) async -> Void
    ) async {
        for orphan in orphans {
            // `active == false` is the only signal that ends the orphan: a `nil`
            // response (check failed) or a missing/`true` `active` flag falls
            // through the guard and leaves the activity untouched.
            guard let status = await streamStatus(orphan.streamID), status.active == false else { continue }
            let outcome = reconciledOutcome(forTerminalState: status.journal?.terminalState)
            let didEnd = await endOrphan(orphan, outcome)
            guard notifiesOnCompletion, didEnd, outcome.status == .complete else { continue }
            let age = now.timeIntervalSince(orphan.updatedAt)
            guard age >= 0, age <= recencyWindow else { continue }
            await notify(orphan)
        }
    }
}
