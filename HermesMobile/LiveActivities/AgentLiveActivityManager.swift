import ActivityKit
import Foundation
import OSLog
import UIKit

private let liveActivityReconcilerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "LiveActivityReconciler"
)

enum AgentLiveActivityTapPolicy {
    static func shouldDismiss(requestedID: String?, activityID: String,
                              isFinal: Bool, activityState: ActivityState) -> Bool {
        guard let requestedID, !requestedID.isEmpty, requestedID == activityID else { return false }
        return isFinal || activityState == .ended
    }
}

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
    case responding
    case workSummary([String])
}

struct OrphanedLiveActivity: Equatable {
    let streamID: String
    let sessionID: String
    let sessionTitle: String
    let updatedAt: Date
    let server: URL?
}

struct AgentRunActivityPushTarget: Equatable {
    let server: URL
    let sessionID: String
}

extension AgentRunActivityAttributes {
    var pushTarget: AgentRunActivityPushTarget? {
        if let bot {
            guard let sessionID = bot.pushSessionID,
                  let destination = HermesDeepLink.botDestination(from: bot.destinationURL) else { return nil }
            return AgentRunActivityPushTarget(server: destination.server, sessionID: sessionID)
        }
        guard let server else { return nil }
        if let pushSessionID { return AgentRunActivityPushTarget(server: server, sessionID: pushSessionID) }
        return isHermesSession ? nil : AgentRunActivityPushTarget(server: server, sessionID: sessionID)
    }

    var isHermesSession: Bool { bot == nil && sessionID.hasPrefix(AgentRunTapTarget.hermesSessionPrefix) }

    var hermesProfile: String? {
        guard isHermesSession else { return nil }
        return sessionID.dropFirst(AgentRunTapTarget.hermesSessionPrefix.count)
            .split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    var hermesSessionKeys: Set<String> {
        guard isHermesSession else { return [] }
        let named = sessionID.dropFirst(AgentRunTapTarget.hermesSessionPrefix.count)
            .split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
        return Set([pushSessionID, named].compactMap { $0 }.filter { !$0.isEmpty })
    }
}

enum AgentLiveActivityAlertPolicy {
    static func alerts(previous: AgentRunActivityStatus, next: AgentRunActivityStatus,
                       canReceivePush: Bool, appIsActive: Bool) -> Bool {
        next != previous && (next == .waitingForApproval || next == .waitingForClarification)
            && !canReceivePush && !appIsActive
    }

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
    func keepingCounts(from shown: Self) -> Self {
        guard chips == nil else { return self }
        var kept = self
        kept.chips = shown.chips
        return kept
    }
}

@MainActor
protocol AgentLiveActivityManaging: AnyObject {
    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date)
    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date)
    func startSession(sessionID: String, server: URL, destinationURL: URL?, pushSessionID: String,
                      sessionTitle: String, turn: String, startedAt: Date)
    func movePushSession(to key: String)
    var drivenSessionID: String? { get }
    func update(_ event: AgentLiveActivityEvent)
    func markStale()
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?)
    func orphanedActivities() -> [OrphanedLiveActivity]
    @discardableResult
    func endOrphanedActivity(streamID: String, status: AgentRunActivityStatus, activity: String) async -> Bool
}

extension AgentLiveActivityManaging {
    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date) {}
    func startSession(sessionID: String, server: URL, destinationURL: URL?, pushSessionID: String,
                      sessionTitle: String, turn: String, startedAt: Date) {}
    func movePushSession(to key: String) {}
    var drivenSessionID: String? { nil }
    func orphanedActivities() -> [OrphanedLiveActivity] { [] }
    @discardableResult
    func endOrphanedActivity(streamID: String, status: AgentRunActivityStatus, activity: String) async -> Bool { false }
}

@MainActor
final class AgentLiveActivityManager: AgentLiveActivityManaging {
    static let shared = AgentLiveActivityManager(pushKeys: LiveActivityPushKeys(defaults: .standard))

    private let minimumUpdateInterval: TimeInterval
    private var activity: Activity<AgentRunActivityAttributes>?
    private var currentState: AgentRunActivityAttributes.ContentState?
    private var currentSessionID: String?
    private var currentStreamID: String?
    private var currentServer: URL?
    private var drivenPushSessionID: String?
    private var drivenPushServer: URL?
    private let pushKeys: LiveActivityPushKeys
    private(set) var activeConnectedStreamID: String?
    private var rawResponseText = ""
    private var lastSentUpdateAt: Date?
    private var pendingUpdateTask: Task<Void, Never>?
    private var updateGeneration = 0
    private var pendingAlertStatus: AgentRunActivityStatus?
    private var lifecycleGeneration = 0
    private var pushTokenTask: Task<Void, Never>?
    private var pushStateTask: Task<Void, Never>?
    private var pushOwner: String?
    private var pushHandoffTask: Task<Void, Never>?
    private let injectedPushRegistrar: PushActivityRegistrar?
    private var pushRegistrar: PushActivityRegistrar? { injectedPushRegistrar ?? PushRegistrar.shared?.activities }
    private let pushHandoffLimit: Duration = .seconds(10)

    init(minimumUpdateInterval: TimeInterval = 1.5, pushKeys: LiveActivityPushKeys = LiveActivityPushKeys(defaults: nil),
         pushRegistrar: PushActivityRegistrar? = nil) {
        self.minimumUpdateInterval = minimumUpdateInterval
        self.pushKeys = pushKeys
        self.injectedPushRegistrar = pushRegistrar
    }

    func start(sessionID: String, server: URL, sessionTitle: String, streamID: String?, startedAt: Date = Date()) {
        start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: streamID, startedAt: startedAt,
              bot: nil, server: server)
    }

    func startBot(_ bot: AgentRunActivityBot, title: String, turn: String, startedAt: Date) {
        start(sessionID: bot.key, sessionTitle: title, streamID: bot.streamID(turn: turn), startedAt: startedAt,
              bot: bot, server: nil)
    }

    func startSession(sessionID: String, server: URL, destinationURL: URL?, pushSessionID: String,
                      sessionTitle: String, turn: String, startedAt: Date) {
        start(sessionID: sessionID, sessionTitle: sessionTitle, streamID: turn, startedAt: startedAt,
              bot: nil, server: server, destinationURL: destinationURL, pushSessionID: pushSessionID)
    }

    func movePushSession(to key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, currentState?.isFinal == false, key != drivenPushSessionID else { return }
        drivenPushSessionID = key
        rememberPushKey()
        guard let activity, pushOwner == activity.id, let token = activity.pushToken,
              let server = activity.attributes.pushTarget?.server, let registrar = pushRegistrar else { return }
        let owner = activity.id
        Task { [weak self] in
            guard self?.pushOwner == owner, self?.drivenPushSessionID == key else { return }
            await registrar.register(owner: owner, server: server, sessionID: key, token: Self.hex(token))
        }
    }

    var drivenSessionID: String? {
        currentState?.isFinal == false ? currentSessionID : nil
    }

    private var drivenPushIdentity: LiveActivityPushKeys.Identity? {
        guard let drivenPushServer, let currentSessionID else { return nil }
        return LiveActivityPushKeys.Identity(server: drivenPushServer, sessionID: currentSessionID,
                                             streamID: currentStreamID)
    }

    private func rememberPushKey() {
        guard let identity = drivenPushIdentity else { return }
        pushKeys.record(drivenPushSessionID, for: identity)
    }

    private func drives(_ attributes: AgentRunActivityAttributes) -> Bool {
        drivenSessionID == attributes.sessionID
            && currentStreamID == AgentLiveActivityReusePolicy.normalizedStreamID(attributes.streamID)
    }

    private func start(sessionID: String, sessionTitle: String, streamID: String?, startedAt: Date,
                       bot: AgentRunActivityBot?, server: URL?, destinationURL: URL? = nil,
                       pushSessionID: String? = nil) {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else { return }
        cancelPushHandoff()
        let normalizedStreamID = AgentLiveActivityReusePolicy.normalizedStreamID(streamID)
        activeConnectedStreamID = normalizedStreamID

        if currentSessionID == normalizedSessionID,
           currentStreamID == normalizedStreamID,
           currentState?.isFinal == false,
           activity?.activityState != .ended, activity?.activityState != .dismissed,
           currentServer == server,
           activity?.attributes.bot?.pushSessionID == bot?.pushSessionID {
            if let pushSessionID {
                drivenPushSessionID = pushSessionID
                rememberPushKey()
            }
            if let activity { observePush(activity) }
            updateCurrentState { state in
                AgentRunActivityAttributes.ContentState(
                    sessionID: state.sessionID,
                    sessionTitle: state.sessionTitle,
                    status: state.status,
                    currentActivity: state.currentActivity,
                    responseExcerpt: state.responseExcerpt,
                    startedAt: min(state.startedAt, startedAt),
                    updatedAt: Date(),
                    isStale: false,
                    isFinal: false,
                    errorSummary: nil
                )
            }
            return
        }

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
        drivenPushSessionID = pushSessionID ?? bot?.pushSessionID
        drivenPushServer = server ?? bot.flatMap { HermesDeepLink.botDestination(from: $0.destinationURL)?.server }
        rememberPushKey()
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
                destinationURL: destinationURL,
                pushSessionID: pushSessionID,
                state: state,
                lifecycle: lifecycle
            )
        }
    }

    func currentStateForTesting() -> AgentRunActivityAttributes.ContentState? {
        currentState
    }

    var drivenPushSessionIDForTesting: String? { drivenPushSessionID }

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
            let limit = AgentRunActivitySanitizer.maximumExcerptSourceLength
            if rawResponseText.utf8.count < limit {
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
        activeConnectedStreamID = nil
        guard currentState?.isFinal == false else { return }
        if let pushOwner, let registrar = pushRegistrar,
           let attributes = activity?.attributes, canReceivePush(attributes) {
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
            Task { @MainActor in
                self?.cancelPushHandoff()
                endBackgroundTask()
            }
        }
        guard backgroundTask != .invalid else {
            updateCurrentState { state in AgentRunActivityStateReducer.stale(state: state) }
            return
        }
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
        let result: [OrphanedLiveActivity] = all.compactMap { activity in
            guard activity.attributes.bot == nil, !activity.attributes.isHermesSession else { return nil }
            guard let streamID = AgentLiveActivityReusePolicy.normalizedStreamID(activity.attributes.streamID) else {
                return nil
            }
            let state = activity.content.state
            guard state.isFinal == false else { return nil }
            guard streamID != activeConnectedStreamID else { return nil }
            return OrphanedLiveActivity(
                streamID: streamID,
                sessionID: state.sessionID,
                sessionTitle: state.sessionTitle,
                updatedAt: state.updatedAt,
                server: activity.attributes.server
            )
        }
        return result
    }

    struct HermesRunCheck {
        let server: URL
        let runningKeys: @MainActor (String) async -> Set<String>?
    }

    func settleActivitiesFromPreviousLaunch(checking hermes: HermesRunCheck? = nil) async {
        let persisted = Activity<AgentRunActivityAttributes>.activities
        pushKeys.prune(keeping: Set(persisted.compactMap { LiveActivityPushKeys.Identity(of: $0.attributes) }
            + [drivenPushIdentity].compactMap { $0 }))
        func find(_ id: String) -> Activity<AgentRunActivityAttributes>? {
            Activity<AgentRunActivityAttributes>.activities.first { $0.id == id }
        }
        await settle(
            persisted.filter { $0.id != activity?.id }.map {
                leftover(id: $0.id, attributes: $0.attributes, isFinished: Self.isFinished($0))
            },
            checking: hermes,
            isFinished: { find($0).map(Self.isFinished) },
            adopt: { leftover in
                guard let persisted = find(leftover.id),
                      restoreOwnership(attributes: persisted.attributes, state: persisted.content.state) else { return false }
                activity = persisted
                observePush(persisted)
                return true
            },
            end: { leftover, action in
                guard let persisted = find(leftover.id) else { return }
                if action == .endComplete {
                    await finishPersisted(persisted, status: .complete, activity: String(localized: "Response complete"))
                } else {
                    await persisted.end(nil, dismissalPolicy: .immediate)
                }
            },
            reclaimed: { leftover in
                if let persisted = find(leftover.id), activity?.id == persisted.id { observePush(persisted) }
            }
        )
    }

    func endFinishedRuns(checking hermes: HermesRunCheck?) async {
        guard let hermes else { return }
        let held = activeConnectedStreamID == nil && currentState?.isFinal == false ? activity?.id : nil
        let lifecycle = lifecycleGeneration, generation = updateGeneration, pushKey = drivenPushSessionID
        let response = String(localized: "Response complete")
        func find(_ id: String) -> Activity<AgentRunActivityAttributes>? {
            Activity<AgentRunActivityAttributes>.activities.first { $0.id == id }
        }
        await endFinished(
            Activity<AgentRunActivityAttributes>.activities
                .filter { !Self.isFinished($0) && ($0.id != activity?.id || $0.id == held) }
                .map { leftover(id: $0.id, attributes: $0.attributes, isFinished: false) },
            held: held, checking: hermes,
            endHeld: {
                guard activity?.id == held, lifecycleGeneration == lifecycle, updateGeneration == generation,
                      drivenPushSessionID == pushKey, activeConnectedStreamID == nil else { return }
                end(status: .complete, activity: response)
            },
            end: { leftover in
                @MainActor func unowned() -> Activity<AgentRunActivityAttributes>? {
                    guard let persisted = find(leftover.id), !Self.isFinished(persisted), activity?.id != leftover.id,
                          !drives(leftover.attributes) else { return nil }
                    return persisted
                }
                guard let persisted = unowned() else { return }
                await retirePush(persisted)
                guard unowned() != nil else { return }
                await finishPersisted(persisted, status: .complete, activity: response)
                forgetPushKey(owner: leftover.id, attributes: leftover.attributes)
            }
        )
    }

    func endFinished(_ leftovers: [LeftoverLiveActivity], held: String?, checking hermes: HermesRunCheck,
                     endHeld: () -> Void, end: (LeftoverLiveActivity) async -> Void) async {
        let actions = await LeftoverLiveActivitySettlement.actions(
            for: leftovers, isPaired: { isPaired($0) }, hermesServer: hermes.server,
            runningKeys: { await hermes.runningKeys($0) }
        )
        for (leftover, action) in zip(leftovers, actions) where action == .endComplete {
            if leftover.id == held { endHeld() } else { await end(leftover) }
        }
    }

    func settle(_ leftovers: [LeftoverLiveActivity], checking hermes: HermesRunCheck?,
                isFinished: (String) -> Bool?,
                adopt: (LeftoverLiveActivity) -> Bool,
                end: (LeftoverLiveActivity, LeftoverLiveActivityAction) async -> Void,
                reclaimed: (LeftoverLiveActivity) -> Void = { _ in }) async {
        let actions = await LeftoverLiveActivitySettlement.actions(
            for: leftovers, isPaired: { isPaired($0) }, hermesServer: hermes?.server,
            runningKeys: { await hermes?.runningKeys($0) }
        )
        func unchanged(_ snapshot: LeftoverLiveActivity) -> Bool {
            guard activity?.id != snapshot.id, !drives(snapshot.attributes),
                  let finished = isFinished(snapshot.id) else { return false }
            return finished == snapshot.isFinished
                && pushKeys.pushTarget(for: snapshot.attributes)?.sessionID == snapshot.pushSessionID
        }
        for (leftover, action) in zip(leftovers, actions) {
            guard action != .keep, unchanged(leftover) else { continue }
            switch action {
            case .keep:
                continue
            case .retire:
                await retireRoute(owner: leftover.id, attributes: leftover.attributes)
                forgetPushKey(owner: leftover.id, attributes: leftover.attributes)
            case .adopt where adopt(leftover):
                continue
            case .adopt, .end, .endComplete:
                await retireRoute(owner: leftover.id, attributes: leftover.attributes)
                guard unchanged(leftover) else {
                    reclaimed(leftover)
                    continue
                }
                await end(leftover, action)
                forgetPushKey(owner: leftover.id, attributes: leftover.attributes)
            }
        }
    }

    func leftover(id: String, attributes: AgentRunActivityAttributes, isFinished: Bool) -> LeftoverLiveActivity {
        LeftoverLiveActivity(id: id, attributes: attributes, isFinished: isFinished,
                             pushSessionID: pushKeys.pushTarget(for: attributes)?.sessionID)
    }

    private static func isFinished(_ persisted: Activity<AgentRunActivityAttributes>) -> Bool {
        persisted.activityState == .ended || persisted.activityState == .dismissed || persisted.content.state.isFinal
    }

    @discardableResult
    func restoreOwnership(attributes: AgentRunActivityAttributes,
                          state: AgentRunActivityAttributes.ContentState) -> Bool {
        guard currentSessionID == nil, attributes.bot != nil || attributes.isHermesSession, !state.isFinal else { return false }
        currentSessionID = attributes.sessionID
        currentStreamID = AgentLiveActivityReusePolicy.normalizedStreamID(attributes.streamID)
        currentServer = attributes.server
        drivenPushServer = attributes.pushTarget?.server
        drivenPushSessionID = pushKeys.pushTarget(for: attributes)?.sessionID
        currentState = state.presented(attributes: attributes, systemIsStale: false)
        rawResponseText = currentState?.responseExcerpt ?? ""
        lastSentUpdateAt = state.updatedAt
        _ = nextLifecycleGeneration()
        _ = nextUpdateGeneration()
        return true
    }

    func dismissFinishedActivity(from url: URL) async {
        guard let requestedID = AgentRunTapTarget.activityID(from: url),
              let tapped = Activity<AgentRunActivityAttributes>.activities.first(where: {
                  AgentLiveActivityTapPolicy.shouldDismiss(
                    requestedID: requestedID, activityID: $0.id,
                    isFinal: $0.content.state.isFinal, activityState: $0.activityState
                  )
              }) else { return }
        let lifecycle = lifecycleGeneration
        await tapped.end(nil, dismissalPolicy: .immediate)
        if lifecycleGeneration == lifecycle, activity?.id == tapped.id {
            reset()
        }
        await retirePush(tapped)
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
            await endPersisted(persisted, status: status, activity: activityLine)
            didEndRunningActivity = true
        }

        if normalized == currentStreamID {
            reset()
        }

        return didEndRunningActivity
    }

    private func endPersisted(_ persisted: Activity<AgentRunActivityAttributes>,
                              status: AgentRunActivityStatus, activity activityLine: String) async {
        await retirePush(persisted)
        await finishPersisted(persisted, status: status, activity: activityLine)
    }

    private func finishPersisted(_ persisted: Activity<AgentRunActivityAttributes>,
                                 status: AgentRunActivityStatus, activity activityLine: String) async {
        let finalState = Self.keepingRelayCounts(AgentRunActivityStateReducer.final(
            status: status,
            activity: activityLine,
            state: persisted.content.state
        ), on: persisted)
        await persisted.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: dismissalPolicy(for: status))
    }

    private func requestOrUpdateActivity(
        sessionID: String,
        streamID: String?,
        sessionTitle: String,
        bot: AgentRunActivityBot?,
        server: URL?,
        destinationURL: URL?,
        pushSessionID: String?,
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
                    ActivityContent(state: latestState, staleDate: staleDate(for: latestState)),
                    alertConfiguration: firstWriteAlert(shown: existing.content.state.status,
                                                        latest: latestState, on: existing)
                )
                lastSentUpdateAt = Date()
                return
            }

            let wantsPushToken = bot != nil || server.map(isPaired) == true
            let attributes = AgentRunActivityAttributes(
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                streamID: streamID,
                startedAt: state.startedAt,
                bot: bot,
                server: server,
                destinationURL: destinationURL,
                pushSessionID: pushSessionID,
                requestedPush: wantsPushToken ? true : nil
            )
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
            UsageReports.shared.record(.liveActivity)
            observePush(requestedActivity)
            if let latestState = currentState, latestState != state {
                await requestedActivity.update(
                    ActivityContent(state: latestState, staleDate: staleDate(for: latestState)),
                    alertConfiguration: firstWriteAlert(shown: state.status, latest: latestState,
                                                        on: requestedActivity)
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
        scheduleUpdate(updatedState, immediate: immediate || pendingAlertStatus != nil)
    }

    private func firstWriteAlert(
        shown: AgentRunActivityStatus,
        latest: AgentRunActivityAttributes.ContentState,
        on activity: Activity<AgentRunActivityAttributes>
    ) -> AlertConfiguration? {
        guard AgentLiveActivityAlertPolicy.alerts(
            previous: shown, next: latest.status,
            canReceivePush: canReceivePush(activity.attributes),
            appIsActive: UIApplication.shared.applicationState == .active
        ) else { return nil }
        return Self.alert(for: latest.status, title: latest.sessionTitle)
    }

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
        let shownState = Self.keepingRelayCounts(finalState, on: endingActivity)

        await endingActivity.update(ActivityContent(state: shownState, staleDate: nil))
        if status == .complete {
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        guard lifecycle == lifecycleGeneration else {
            await endingActivity.end(nil, dismissalPolicy: .immediate)
            return
        }

        await endingActivity.end(
            ActivityContent(state: shownState, staleDate: nil),
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
        if state.isFinal { return nil }
        if let pushOwner, pushRegistrar?.isRegistered(pushOwner) == true {
            return Date().addingTimeInterval(15 * 60)
        }
        return Date().addingTimeInterval(state.isStale ? 90 : 300)
    }

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
        guard let target = pushKeys.pushTarget(for: observed.attributes), let registrar = pushRegistrar,
              observed.attributes.bot != nil || isPaired(target.server) else { return }
        pushTokenTask?.cancel()
        pushStateTask?.cancel()
        pushOwner = observed.id
        pushTokenTask = Task { [weak self] in
            @MainActor func forward(_ token: Data) async {
                guard !Task.isCancelled else { return }
                let moved = self?.activity?.id == observed.id ? self?.drivenPushSessionID : nil
                await registrar.register(owner: observed.id, server: target.server, sessionID: moved ?? target.sessionID,
                                         token: Self.hex(token))
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

    private static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    private func retirePush(_ retiring: Activity<AgentRunActivityAttributes>) async {
        if pushOwner == retiring.id {
            pushTokenTask?.cancel()
            pushStateTask?.cancel()
            pushTokenTask = nil
            pushStateTask = nil
            pushOwner = nil
        }
        await retireRoute(owner: retiring.id, attributes: retiring.attributes)
        if retiring.activityState == .ended || retiring.activityState == .dismissed {
            pushKeys.forget(retiring.attributes)
        } else {
            forgetPushKey(owner: retiring.id, attributes: retiring.attributes)
        }
    }

    private func retireRoute(owner: String, attributes: AgentRunActivityAttributes) async {
        let target = pushKeys.pushTarget(for: attributes)
        await pushRegistrar?.retire(owner: owner, server: target?.server, sessionID: target?.sessionID)
    }

    private func forgetPushKey(owner: String, attributes: AgentRunActivityAttributes) {
        guard activity?.id != owner, !drives(attributes) else { return }
        pushKeys.forget(attributes)
    }

    private func reset() {
        cancelPushHandoff()
        activity = nil
        currentState = nil
        currentSessionID = nil
        currentStreamID = nil
        currentServer = nil
        drivenPushSessionID = nil
        drivenPushServer = nil
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

@MainActor
enum LiveActivityReconciler {
    nonisolated static let recentCompletionWindow: TimeInterval = 300

    struct ReconciledOutcome: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
    }

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
            server: server,
            now: now,
            notifiesOnCompletion: notifiesOnCompletion,
            streamStatus: { streamID in
                try? await client.chatStreamStatus(streamID: streamID)
            },
            endOrphan: { orphan, outcome in
                liveActivityReconcilerLogger.notice("Ending orphaned Live Activity \(orphan.streamID, privacy: .public) — server reports the run is over (\(outcome.status.rawValue, privacy: .public))")
                return await manager.endOrphanedActivity(
                    streamID: orphan.streamID,
                    status: outcome.status,
                    activity: outcome.activity
                )
            },
            notify: { orphan, outcome in
                liveActivityReconcilerLogger.notice("Notifying run ended for reconciled Live Activity \(orphan.streamID, privacy: .public)")
                await ResponseCompletionNotificationService.scheduleRunEndedIfAllowed(
                    outcome,
                    sessionID: orphan.sessionID,
                    title: orphan.sessionTitle,
                    server: server,
                    preferenceEnabled: preferenceEnabled,
                    sceneIsActive: false
                )
            }
        )
    }

    static func reconcileOrphanedActivities(
        orphans: [OrphanedLiveActivity],
        server: URL,
        now: Date,
        notifiesOnCompletion: Bool,
        recencyWindow: TimeInterval = recentCompletionWindow,
        streamStatus: (String) async -> ChatStreamStatusResponse?,
        endOrphan: (OrphanedLiveActivity, ReconciledOutcome) async -> Bool,
        notify: (OrphanedLiveActivity, ResponseCompletionOutcome) async -> Void
    ) async {
        for orphan in orphans {
            guard let status = await streamStatus(orphan.streamID), status.active == false else { continue }
            let outcome = reconciledOutcome(forTerminalState: status.journal?.terminalState)
            let didEnd = await endOrphan(orphan, outcome)
            guard notifiesOnCompletion, didEnd, let alertOutcome = ResponseCompletionOutcome(outcome.status),
                  orphan.server == server else { continue }
            let age = now.timeIntervalSince(orphan.updatedAt)
            guard age >= 0, age <= recencyWindow else { continue }
            await notify(orphan, alertOutcome)
        }
    }
}

struct LeftoverLiveActivity {
    let id: String
    let attributes: AgentRunActivityAttributes
    let isFinished: Bool
    var pushSessionID: String? = nil
}

enum LeftoverLiveActivityAction: Equatable {
    case adopt
    case keep
    case retire
    case end
    case endComplete
}

@MainActor enum LeftoverLiveActivitySettlement {
    static func runningKeys(_ items: [BotJSON]) -> Set<String> {
        Set(items.compactMap { item in
            guard let key = item["session_key"].text, !key.isEmpty, item["status"].text != "idle" else { return nil }
            return key
        })
    }

    static func actions(for leftovers: [LeftoverLiveActivity], isPaired: (URL) -> Bool, hermesServer: URL?,
                        runningKeys: (String) async -> Set<String>?) async -> [LeftoverLiveActivityAction] {
        let paired = leftovers.map { leftover in
            leftover.attributes.pushTarget.map { isPaired($0.server) } == true
                && (leftover.attributes.bot != nil || leftover.attributes.requestedPush == true)
        }
        let keys = leftovers.map { $0.attributes.hermesSessionKeys.union([$0.pushSessionID].compactMap { $0 }) }
        let profiles: [String?] = leftovers.indices.map { index in
            let attributes = leftovers[index].attributes
            guard !leftovers[index].isFinished, !keys[index].isEmpty, hermesServer != nil,
                  attributes.server == hermesServer else { return nil }
            return attributes.hermesProfile
        }
        var running: [String: Set<String>] = [:]
        for profile in Set(profiles.compactMap { $0 }) { running[profile] = await runningKeys(profile) }
        return leftovers.indices.map { index in
            let leftover = leftovers[index]
            if leftover.attributes.bot != nil { return !leftover.isFinished && paired[index] ? .adopt : .end }
            if leftover.isFinished { return .retire }
            guard leftover.attributes.isHermesSession else { return .keep }
            if let profile = profiles[index], let live = running[profile], keys[index].isDisjoint(with: live) {
                return .endComplete
            }
            return paired[index] ? .adopt : .keep
        }
    }
}

final class LiveActivityPushKeys {
    struct Identity: Hashable {
        let server: URL
        let sessionID: String
        let streamID: String?

        init(server: URL, sessionID: String, streamID: String?) {
            self.server = server
            self.sessionID = sessionID
            self.streamID = AgentLiveActivityReusePolicy.normalizedStreamID(streamID)
        }

        init?(of attributes: AgentRunActivityAttributes) {
            guard let target = attributes.pushTarget else { return nil }
            self.init(server: target.server, sessionID: attributes.sessionID, streamID: attributes.streamID)
        }

        fileprivate var storageKey: String { [server.absoluteString, sessionID, streamID ?? ""].joined(separator: "\n") }
    }

    private static let defaultsKey = "liveActivityPushKeys"
    private let defaults: UserDefaults?
    private var memory: [String: String] = [:]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    private var entries: [String: String] {
        guard let defaults else { return memory }
        return defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func store(_ entries: [String: String]) {
        guard let defaults else {
            memory = entries
            return
        }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(entries, forKey: Self.defaultsKey)
        }
    }

    func pushTarget(for attributes: AgentRunActivityAttributes) -> AgentRunActivityPushTarget? {
        guard let target = attributes.pushTarget, let identity = Identity(of: attributes),
              let moved = entries[identity.storageKey] else { return attributes.pushTarget }
        return AgentRunActivityPushTarget(server: target.server, sessionID: moved)
    }

    func record(_ key: String?, for identity: Identity) {
        var entries = entries
        guard entries[identity.storageKey] != key else { return }
        entries[identity.storageKey] = key
        store(entries)
    }

    func forget(_ attributes: AgentRunActivityAttributes) {
        guard let identity = Identity(of: attributes) else { return }
        record(nil, for: identity)
    }

    func prune(keeping identities: Set<Identity>) {
        let entries = entries
        let kept = Set(identities.map(\.storageKey))
        let pruned = entries.filter { kept.contains($0.key) }
        if pruned.count != entries.count { store(pruned) }
    }
}
