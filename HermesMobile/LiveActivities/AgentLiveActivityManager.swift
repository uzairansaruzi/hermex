import ActivityKit
import Foundation
import OSLog
import UIKit

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
    /// The reply is being written, with no text attached: the status moves on even
    /// when previews are off (#489).
    case responding
    /// A bot's bounded work summary chips (#489). Counts only, never reply text.
    case workSummary([String])
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

/// Where the relay delivers an activity's pushes: the paired server, and the agent
/// session ID the plugin reports progress under.
struct AgentRunActivityPushTarget: Equatable {
    let server: URL
    let sessionID: String
}

extension AgentRunActivityAttributes {
    /// A bot resolves its target from its destination and stored agent session ID. A
    /// webui run uses its own session ID, which webui also gives the agent (#566).
    /// Nil when the activity cannot be pushed, such as one from an older build.
    var pushTarget: AgentRunActivityPushTarget? {
        guard let bot else { return server.map { AgentRunActivityPushTarget(server: $0, sessionID: sessionID) } }
        guard let sessionID = bot.pushSessionID,
              let destination = HermesDeepLink.botDestination(from: bot.destinationURL) else { return nil }
        return AgentRunActivityPushTarget(server: destination.server, sessionID: sessionID)
    }
}

/// Whether a local write should alert: only when the run first stops for an approval or
/// an answer, the app is not in the foreground, and the relay does not drive the activity.
/// A paired server's relay banners approvals and questions itself (#740), so alerting
/// here too would buzz twice; a repeated waiting event keeps the status and stays silent.
enum AgentLiveActivityAlertPolicy {
    static func alerts(previous: AgentRunActivityStatus, next: AgentRunActivityStatus,
                       canReceivePush: Bool, appIsActive: Bool) -> Bool {
        next != previous && (next == .waitingForApproval || next == .waitingForClarification)
            && !canReceivePush && !appIsActive
    }

    /// The ask still owed an alert after a write: a newly entered ask, or one an earlier
    /// write raised that no send has delivered yet. A newer write can supersede the send
    /// that carried the alert (a Bot feed writes its chips in the same tick), so the alert
    /// waits for whichever send lands; leaving that ask drops it.
    static func pending(_ pending: AgentRunActivityStatus?, previous: AgentRunActivityStatus,
                        next: AgentRunActivityStatus, canReceivePush: Bool,
                        appIsActive: Bool) -> AgentRunActivityStatus? {
        if alerts(previous: previous, next: next, canReceivePush: canReceivePush, appIsActive: appIsActive) {
            return next
        }
        return next == pending && !canReceivePush && !appIsActive ? pending : nil
    }
}

extension AgentRunActivityAttributes.ContentState {
    /// This state with `shown`'s counts when it has none of its own: the app's local
    /// reducers never count a webui run's tools, the relay does (#644).
    func keepingCounts(from shown: Self) -> Self {
        guard chips == nil else { return self }
        var kept = self
        kept.chips = shown.chips
        return kept
    }
}

@MainActor
protocol AgentLiveActivityManaging: AnyObject {
    /// `startedAt` is when the *run* began, not when the widget was created: the
    /// coordinator passes the server-seeded run start so the widget's system
    /// elapsed timer counts the same span as the in-app "Working for" label
    /// (#406). Callers without a seeded start pass `Date()`. `server` is the configured
    /// server the run belongs to; a server paired for push lets the relay keep the
    /// activity fresh after the app suspends (#566).
    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date)
    /// Starts or re-adopts a bot's activity for one turn (#489). `turn` names the turn,
    /// so a reconnect inside it reuses the activity and the next turn gets a new one.
    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date)
    /// The session id, or a bot's `key`, of the unfinished activity this manager is
    /// driving. The Bot feed checks it before every stale or end call, so it never
    /// touches an activity a webui run or another bot has since taken over.
    var drivenSessionID: String? { get }
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
    // Defaults so webui-only test spies don't have to care about bots.
    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date) {}
    var drivenSessionID: String? { nil }
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
    /// The configured server of the webui run being driven; nil for a bot.
    private var currentServer: URL?
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
    /// The ask the next delivered write alerts for (#740); see `AgentLiveActivityAlertPolicy.pending`.
    private var pendingAlertStatus: AgentRunActivityStatus?
    private var lifecycleGeneration = 0
    private var pushTokenTask: Task<Void, Never>?
    private var pushStateTask: Task<Void, Never>?
    private var pushOwner: String?
    private var pushHandoffTask: Task<Void, Never>?
    private var pushRegistrar: PushActivityRegistrar? { PushRegistrar.shared?.activities }
    /// How long a suspending app waits for the relay to confirm an activity it is handing off.
    private let pushHandoffLimit: Duration = .seconds(10)

    init(minimumUpdateInterval: TimeInterval = 1.5) {
        self.minimumUpdateInterval = minimumUpdateInterval
    }

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date = Date()) {
        start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID, startedAt: startedAt,
              bot: nil, server: server)
    }

    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date) {
        start(sessionID: bot.key, sessionTitle: title, streamID: bot.streamID(turn: turn), startedAt: startedAt,
              bot: bot, server: nil)
    }

    var drivenSessionID: String? {
        currentState?.isFinal == false ? currentSessionID : nil
    }

    private func start(sessionID: String, sessionTitle: String, streamID: String?, startedAt: Date,
                       bot: AgentRunActivityBot?, server: URL?) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        cancelPushHandoff()
        let normalizedStreamID = AgentLiveActivityReusePolicy.normalizedStreamID(streamID)
        // A live SSE connection now owns this stream's completion (PR #266 #3).
        activeConnectedStreamID = normalizedStreamID

        if currentSessionID == normalizedSessionID,
           currentStreamID == normalizedStreamID,
           currentState?.isFinal == false,
           activity?.activityState != .ended, activity?.activityState != .dismissed,
           currentServer == server,
           activity?.attributes.bot?.pushSessionID == bot?.pushSessionID {
            if let activity { observePush(activity) }
            updateCurrentState { state in
                AgentRunActivityAttributes.ContentState(
                    sessionID: state.sessionID,
                    sessionTitle: state.sessionTitle,
                    status: state.status,
                    currentActivity: state.currentActivity,
                    responseExcerpt: state.responseExcerpt,
                    // Earliest known start wins: the reused activity may have been
                    // started from a discovery stamp before the coordinator learned
                    // the server's earlier `pending_started_at`, and the widget timer
                    // must not run behind the in-app one.
                    startedAt: min(state.startedAt, startedAt),
                    updatedAt: Date(),
                    isStale: false,
                    isFinal: false,
                    errorSummary: nil
                )
            }
            return
        }

        // Detach synchronously: feed updates for the new owner must never reach
        // the previous owner's activity while its asynchronous cleanup runs.
        activity = nil
        pushTokenTask?.cancel()
        pushStateTask?.cancel()
        pushOwner = nil
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingAlertStatus = nil
        rawResponseText = ""
        currentSessionID = normalizedSessionID
        currentStreamID = normalizedStreamID
        currentServer = server
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
                bot: bot,
                server: server,
                state: state,
                lifecycle: lifecycle
            )
        }
    }

    /// Test seam: the ActivityKit-backed activity is unreachable in unit tests, so
    /// the reducer state it mirrors is how tests observe `start`/`update` results.
    func currentStateForTesting() -> AgentRunActivityAttributes.ContentState? {
        currentState
    }

    /// Test seam: how many state writes asked to skip the update throttle.
    private(set) var immediateWriteCountForTesting = 0

    func update(_ event: AgentLiveActivityEvent) {
        guard currentState != nil else { return }

        switch event {
        case .sessionTitle(let title):
            updateCurrentState { state in
                AgentRunActivityStateReducer.updatingSessionTitle(title, state: state)
            }
        case .token(let text):
            guard !text.isEmpty else { return }
            // Once the buffer covers the excerpt prefix, more tokens cannot change the
            // excerpt; they only matter to put "Writing response" back after a
            // reasoning, tool, or stale write replaced it.
            let limit = AgentRunActivitySanitizer.maximumExcerptSourceLength
            if rawResponseText.utf8.count < limit {
                // Leading whitespace never reaches the excerpt; skipping it means a full
                // buffer always yields one. Clipping keeps one huge token from blowing the bound.
                let piece = rawResponseText.isEmpty ? text.drop(while: \.isWhitespace) : Substring(text)
                guard !piece.isEmpty else { return }
                rawResponseText += piece.prefix(limit)
            } else if let state = currentState, state.status == .responding, !state.isStale, !state.isFinal,
                      state.currentActivity == String(localized: "Writing response") {
                return
            }
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
            // The Lock Screen only says "Thinking": entering it (or leaving stale) is
            // immediate, and repeats join the throttle instead of one write per event.
            let alreadyShown = currentState?.status == .thinking && currentState?.isStale == false
            updateCurrentState(immediate: !alreadyShown) { state in
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
        case .responding:
            guard currentState?.status != .responding else { return }
            updateCurrentState { state in
                AgentRunActivityStateReducer.responding(state: state)
            }
        case .workSummary(let chips):
            let sanitized = AgentRunActivitySanitizer.chips(chips)
            guard currentState?.chips ?? [] != sanitized else { return }
            currentState?.chips = sanitized
            updateCurrentState(immediate: false) { $0 }
        }
    }

    func markStale() {
        // Suspended / troubled: the live SSE no longer owns completion, so the
        // stream is eligible for server-truth reconciliation again (PR #266 #3).
        activeConnectedStreamID = nil
        guard currentState?.isFinal == false else { return }
        if let pushOwner, let registrar = pushRegistrar,
           let attributes = activity?.attributes, canReceivePush(attributes) {
            // Stop queued foreground writes; the relay owns freshness once it confirms.
            pendingUpdateTask?.cancel()
            pendingUpdateTask = nil
            let generation = nextUpdateGeneration()
            if !registrar.isRegistered(pushOwner) {
                awaitPushHandoff(owner: pushOwner, registrar: registrar, generation: generation)
            }
            return
        }

        updateCurrentState { state in
            AgentRunActivityStateReducer.stale(state: state)
        }
    }

    /// The live connection dropped while the relay registration was still in flight,
    /// usually because the user left the app right after sending (#635). Keep the last
    /// state and stay awake until the registration settles, so a handoff that lands a
    /// moment later never leaves "Not connected" on a run the relay now drives. Only a
    /// failed or stalled registration marks the activity stale; any newer write wins.
    private func awaitPushHandoff(owner: String, registrar: PushActivityRegistrar, generation: Int) {
        cancelPushHandoff()
        let lifecycle = lifecycleGeneration
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        let endBackgroundTask = {
            guard backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Hermes Live Activity handoff") { [weak self] in
            // Out of background time: stop waiting, which falls back to the stale state.
            Task { @MainActor in
                self?.cancelPushHandoff()
                endBackgroundTask()
            }
        }
        guard backgroundTask != .invalid else {
            // No background time to wait in, so the relay cannot confirm before suspension.
            updateCurrentState { state in AgentRunActivityStateReducer.stale(state: state) }
            return
        }
        // Cancellation ends the wait early; the generation checks below decide whether a
        // newer write superseded it (no stale write) or background time ran out (write it).
        pushHandoffTask = Task { [weak self, pushHandoffLimit] in
            defer { endBackgroundTask() }
            let registered = await registrar.awaitRegistration(owner, limit: pushHandoffLimit)
            guard let self, !registered, updateGeneration == generation,
                  lifecycleGeneration == lifecycle, pushOwner == owner,
                  let state = currentState, !state.isFinal else { return }
            var stale = AgentRunActivityStateReducer.stale(state: state)
            stale.chips = state.chips
            currentState = stale
            await sendUpdate(stale, staleDate: staleDate(for: stale), generation: nextUpdateGeneration())
        }
    }

    private func cancelPushHandoff() {
        pushHandoffTask?.cancel()
        pushHandoffTask = nil
    }

    func end(status: AgentRunActivityStatus, activity activityLine: String, errorSummary: String? = nil) {
        // The run is finalizing — drop the live-connection claim (PR #266 #3).
        activeConnectedStreamID = nil
        guard let currentState else { return }

        cancelPushHandoff()
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingAlertStatus = nil

        var finalState = AgentRunActivityStateReducer.final(
            status: status,
            activity: activityLine,
            state: currentState,
            errorSummary: errorSummary
        )
        finalState.chips = currentState.chips
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
            // A bot's activity has no webui stream to ask about (#489).
            guard activity.attributes.bot == nil else { return nil }
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

    /// Cold launch adopts paired push activities without resuming a Bot session.
    /// Legacy/unpaired bot activities still have no background source of truth. A webui
    /// activity the relay already finished must not keep holding its session's banners,
    /// so its registration retires; a running one is left to the server-status
    /// reconciler (#566).
    func settleActivitiesFromPreviousLaunch() async {
        for persisted in Activity<AgentRunActivityAttributes>.activities where persisted.id != activity?.id {
            guard persisted.attributes.bot != nil else {
                if persisted.activityState == .ended || persisted.activityState == .dismissed
                    || persisted.content.state.isFinal {
                    await retirePush(persisted)
                }
                continue
            }
            if canReceivePush(persisted.attributes),
               persisted.activityState != .ended, persisted.activityState != .dismissed,
               restoreBotOwnership(attributes: persisted.attributes, state: persisted.content.state) {
                activity = persisted
                observePush(persisted)
            } else {
                await retirePush(persisted)
                await persisted.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Restores the feed's ownership before observing a surviving push activity.
    /// Only one activity can own the manager; duplicates and final states retire.
    @discardableResult
    func restoreBotOwnership(attributes: AgentRunActivityAttributes,
                             state: AgentRunActivityAttributes.ContentState) -> Bool {
        guard currentSessionID == nil, attributes.bot != nil, !state.isFinal else { return false }
        currentSessionID = attributes.sessionID
        currentStreamID = AgentLiveActivityReusePolicy.normalizedStreamID(attributes.streamID)
        currentServer = attributes.server
        currentState = state.presented(attributes: attributes, systemIsStale: false)
        rawResponseText = currentState?.responseExcerpt ?? ""
        lastSentUpdateAt = state.updatedAt
        _ = nextLifecycleGeneration()
        _ = nextUpdateGeneration()
        return true
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

            let finalState = Self.keepingRelayCounts(AgentRunActivityStateReducer.final(
                status: status,
                activity: activityLine,
                state: persisted.content.state
            ), on: persisted)
            // The run is over, so the relay must stop holding this session's banners.
            await retirePush(persisted)
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
        bot: AgentRunActivityBot?,
        server: URL?,
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
                existing.activityState != .ended && existing.activityState != .dismissed
                && existing.attributes.bot?.pushSessionID == bot?.pushSessionID
                && existing.attributes.server == server
                && AgentLiveActivityReusePolicy.canReuseActivity(
                    existingSessionID: existing.attributes.sessionID,
                    existingStreamID: existing.attributes.streamID,
                    requestedSessionID: sessionID,
                    requestedStreamID: streamID
                )
            }

            for staleActivity in existingActivities {
                guard lifecycle == lifecycleGeneration else { return }
                if let reusableActivity, staleActivity.id == reusableActivity.id {
                    continue
                }

                await retirePush(staleActivity)
                guard lifecycle == lifecycleGeneration else { return }
                await staleActivity.end(nil, dismissalPolicy: .immediate)
            }
            guard lifecycle == lifecycleGeneration else { return }

            if let existing = reusableActivity {
                activity = existing
                observePush(existing)
                let latestState = Self.keepingRelayCounts(currentState ?? state, on: existing)
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
                startedAt: state.startedAt,
                bot: bot,
                server: server
            )
            // Every bot asks for a token; a webui run asks only when its server is
            // paired, so webui-only users see no change (#566).
            let wantsPushToken = bot != nil || server.map(isPaired) == true
            let requestedActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate(for: state)),
                pushType: wantsPushToken ? .token : nil
            )
            guard lifecycle == lifecycleGeneration else {
                await requestedActivity.end(nil, dismissalPolicy: .immediate)
                return
            }
            activity = requestedActivity
            observePush(requestedActivity)
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

        // The reducers rebuild the state field by field; a bot's chips ride along.
        var updatedState = transform(currentState)
        updatedState.chips = currentState.chips
        self.currentState = updatedState
        if immediate { immediateWriteCountForTesting += 1 }

        guard let activity else { return }
        pendingAlertStatus = AgentLiveActivityAlertPolicy.pending(
            pendingAlertStatus, previous: currentState.status, next: updatedState.status,
            canReceivePush: canReceivePush(activity.attributes),
            appIsActive: UIApplication.shared.applicationState == .active
        )
        // An owed alert skips the throttle so the user hears about the ask at once.
        scheduleUpdate(updatedState, immediate: immediate || pendingAlertStatus != nil)
    }

    /// The system alert for a run that stopped on `status`, titled with the session (#740).
    private static func alert(for status: AgentRunActivityStatus, title: String) -> AlertConfiguration {
        let body: LocalizedStringResource = status == .waitingForApproval
            ? "Waiting for approval" : "Needs clarification"
        return AlertConfiguration(title: "\(title)", body: body, sound: .default)
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

        let state = Self.keepingRelayCounts(state, on: activity)
        // The first write that actually lands delivers the owed alert, once.
        let alert = pendingAlertStatus.map { Self.alert(for: $0, title: state.sessionTitle) }
        pendingAlertStatus = nil
        await activity.update(ActivityContent(state: state, staleDate: staleDate), alertConfiguration: alert)
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

        await retirePush(endingActivity)
        let policy = dismissalPolicy(for: status)
        let finalState = Self.keepingRelayCounts(finalState, on: endingActivity)

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
        if state.isFinal { return nil }
        if let pushOwner, pushRegistrar?.isRegistered(pushOwner) == true {
            return Date().addingTimeInterval(15 * 60)
        }
        return Date().addingTimeInterval(state.isStale ? 90 : 300)
    }

    /// A webui run's counts come only from the relay (#644), so a local write keeps the
    /// count the activity already shows rather than dropping it. A bot's feed owns its chips.
    private static func keepingRelayCounts(_ state: AgentRunActivityAttributes.ContentState,
                                           on shown: Activity<AgentRunActivityAttributes>) -> AgentRunActivityAttributes.ContentState {
        shown.attributes.bot == nil ? state.keepingCounts(from: shown.content.state) : state
    }

    private func canReceivePush(_ attributes: AgentRunActivityAttributes) -> Bool {
        attributes.pushTarget.map { isPaired($0.server) } == true
    }

    private func isPaired(_ server: URL) -> Bool {
        PushRegistrar.shared?.pairing(for: server)?.registeredToken != nil
    }

    private func observePush(_ observed: Activity<AgentRunActivityAttributes>) {
        // A webui run on an unpaired server has no token to forward; leave it local-only.
        guard let target = observed.attributes.pushTarget, let registrar = pushRegistrar,
              observed.attributes.bot != nil || isPaired(target.server) else { return }
        pushTokenTask?.cancel()
        pushStateTask?.cancel()
        pushOwner = observed.id
        pushTokenTask = Task { [weak self] in
            func forward(_ token: Data) async {
                guard !Task.isCancelled else { return }
                await registrar.register(owner: observed.id, server: target.server, sessionID: target.sessionID,
                                         token: token.map { String(format: "%02x", $0) }.joined())
            }
            if let token = observed.pushToken { await forward(token) }
            for await token in observed.pushTokenUpdates {
                guard !Task.isCancelled, self?.pushOwner == observed.id else { return }
                await forward(token)
            }
        }
        let lifecycle = lifecycleGeneration
        pushStateTask = Task { [weak self] in
            for await state in observed.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended || state == .dismissed {
                    await self?.retirePush(observed)
                    if self?.lifecycleGeneration == lifecycle, self?.activity?.id == observed.id { self?.reset() }
                    return
                }
            }
        }
    }

    private func retirePush(_ retiring: Activity<AgentRunActivityAttributes>) async {
        if pushOwner == retiring.id {
            pushTokenTask?.cancel()
            pushStateTask?.cancel()
            pushTokenTask = nil
            pushStateTask = nil
            pushOwner = nil
        }
        let target = retiring.attributes.pushTarget
        await pushRegistrar?.retire(owner: retiring.id, server: target?.server, sessionID: target?.sessionID)
    }

    private func reset() {
        cancelPushHandoff()
        activity = nil
        currentState = nil
        currentSessionID = nil
        currentStreamID = nil
        currentServer = nil
        activeConnectedStreamID = nil
        rawResponseText = ""
        lastSentUpdateAt = nil
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        pendingAlertStatus = nil
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
                    sceneIsActive: false,
                    server: server
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
