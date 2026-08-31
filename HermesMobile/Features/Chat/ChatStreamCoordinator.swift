import Foundation
import Observation
import OSLog
import SwiftData

private let chatStreamCoordinatorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ChatStreamCoordinator"
)

struct ChatStreamCoordinatorTiming: Equatable {
    let checkingInterval: TimeInterval
    let reconnectInterval: TimeInterval
    let runningToolReconnectInterval: TimeInterval
    let statusPollCooldown: TimeInterval
    // Transport quieter than this is treated as provably alive; must sit above
    // the server's ~5s SSE heartbeat cadence and below reconnectInterval (#227).
    let transportFreshInterval: TimeInterval

    static let standard = ChatStreamCoordinatorTiming(
        checkingInterval: 5,
        reconnectInterval: 18,
        runningToolReconnectInterval: 25,
        statusPollCooldown: 4,
        transportFreshInterval: 12
    )
}

struct ChatStreamLoadPreparation: Equatable {
    let activeStreamIDBeforeLoad: String?
    let shouldPrepareSuspendedStreamResume: Bool
}

@MainActor
protocol ChatStreamCoordinatorDelegate: AnyObject {
    var streamCoordinatorSessionID: String? { get }
    var streamCoordinatorDisplayTitle: String { get }
    var streamCoordinatorHasRunningLiveToolCall: Bool { get }
    var streamCoordinatorHasPendingPrompt: Bool { get }
    var streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser: Bool { get }
    var streamCoordinatorStreamingAssistantMessageID: String? { get set }

    func streamCoordinatorLoadMessages(modelContext: ModelContext?) async
    func streamCoordinatorLatestAssistantMessageID() -> String?
    func streamCoordinatorStartAuxiliaryMonitoring()
    func streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: Bool)
    func streamCoordinatorSaveSnapshotIfNeeded()
    @discardableResult
    func streamCoordinatorRestoreSnapshotIfAvailable(streamID: String) -> String?
    func streamCoordinatorRemoveSnapshot(streamID: String?)
    func streamCoordinatorFlushPinnedLocalNoticesToTranscript()
    func streamCoordinatorDrainQueuedSlashMessageIfIdle()
    func streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
    func streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: Bool)
    func streamCoordinatorDidFinishStream()
    func streamCoordinatorDidReceiveErrorMessage(_ message: String)
    func streamCoordinatorDidReceiveRecoveryError(_ error: Error)
    func streamCoordinatorDidConfirmRecovery()
    func streamCoordinatorDidStartConnection(isReplay: Bool)
    func streamCoordinatorDidResetRecoveryState()

    @discardableResult
    func streamCoordinatorAppendToken(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendInterimAssistant(_ payload: InterimAssistantStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorAppendReasoning(_ text: String) -> Bool
    @discardableResult
    func streamCoordinatorAppendToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorCompleteToolCall(_ payload: ToolStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorUpdateTitle(_ payload: TitleStreamEvent) -> Bool
    @discardableResult
    func streamCoordinatorApplyDone(_ payload: DoneStreamEvent) -> Bool
    func streamCoordinatorApplyApprovalUpdate(_ update: ApprovalPendingResponse)
    func streamCoordinatorApplyClarificationUpdate(_ update: ClarificationPendingResponse)
    @discardableResult
    func streamCoordinatorEnqueuePendingSteerLeftover(_ text: String) -> Bool
}

@MainActor
@Observable
final class ChatStreamCoordinator {
    @ObservationIgnored private weak var delegate: (any ChatStreamCoordinatorDelegate)?
    private let client: APIClient
    private let streamClient: SSEStreamingClient
    private let liveActivityManager: any AgentLiveActivityManaging
    private let timing: ChatStreamCoordinatorTiming
    private var showsLiveActivityResponseExcerpts: Bool

    private(set) var activeStreamID: String?
    private(set) var recoveryState: ActiveStreamRecoveryState = .idle
    private(set) var isConnectionSuspended = false
    private(set) var hasCompletedCurrentResponse = false
    /// Terminal-content fence (#288 review): set when the response completes and
    /// NOT cleared by finishStream, so content queued after `done → streamEnd`
    /// still cannot reach the transcript. Cleared only by the next run start /
    /// new-response preparation / session load.
    @ObservationIgnored private var isTerminalContentFenceActive = false
    /// Per-run one-shot teardown owner. The first caller of finishStream owns
    /// teardown; later terminal events are ignored so delegate finish, snapshot
    /// cleanup, queue drain, and title-refresh side effects cannot repeat.
    /// Reset wherever the content fence disarms.
    @ObservationIgnored private var isTransportFinished = false
    @ObservationIgnored private(set) var lastEventID: String?
    @ObservationIgnored private(set) var lastProgressDate: Date?
    @ObservationIgnored private(set) var lastTransportActivityDate: Date?
    private(set) var liveTokensPerSecond: Double?
    @ObservationIgnored private var lastRecoveryStatusCheckDate: Date?
    private(set) var isReplayConnection = false
    // Foreground activation and view appearance can both request recovery for the
    // same suspended stream. Share one recovery task so callers cannot duplicate
    // status checks or transcript loads. Identity and generation fence late work
    // from a replacement run.
    private var reconnectTask: (
        id: UUID,
        streamID: String,
        runGeneration: Int,
        modelContext: ModelContext?,
        task: Task<Void, Never>
    )?
    private var reconnectTranscriptLoadTaskID: UUID?
    // Bumped whenever the active run starts or finalizes. Captured before an async
    // transcript load so a concurrent cancel/completion during the load can't be
    // double-finalized (PR #266 review #2).
    private var runGeneration = 0

    init(
        client: APIClient,
        streamClient: SSEStreamingClient,
        liveActivityManager: any AgentLiveActivityManaging,
        showsLiveActivityResponseExcerpts: Bool,
        timing: ChatStreamCoordinatorTiming = .standard
    ) {
        self.client = client
        self.streamClient = streamClient
        self.liveActivityManager = liveActivityManager
        self.showsLiveActivityResponseExcerpts = showsLiveActivityResponseExcerpts
        self.timing = timing
    }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityResponseExcerpts != shows else { return }

        showsLiveActivityResponseExcerpts = shows
        if !shows, activeStreamID != nil {
            liveActivityManager.update(.clearResponseExcerpt)
        }
    }

    func prepareForNewResponse() {
        hasCompletedCurrentResponse = false
        isTerminalContentFenceActive = false
        isTransportFinished = false
        isConnectionSuspended = false
        setLiveTokensPerSecondIfChanged(nil)
        invalidateReconnectTask()
    }

    func isTerminalFenceActiveForTesting() -> Bool {
        isTerminalContentFenceActive
    }

    func isTransportFinishedForTesting() -> Bool {
        isTransportFinished
    }

    func start(
        streamID: String,
        replayAfterSeq: Int? = nil,
        recoveryState: ActiveStreamRecoveryState = .idle
    ) {
        hasCompletedCurrentResponse = false
        isTerminalContentFenceActive = false
        isTransportFinished = false
        setLiveTokensPerSecondIfChanged(nil)
        runGeneration &+= 1
        invalidateReconnectTask()
        activeStreamID = streamID
        isConnectionSuspended = false
        if replayAfterSeq == nil {
            lastEventID = nil
        }

        markConnectionStarted(
            isReplay: replayAfterSeq != nil,
            recoveryState: recoveryState
        )
        startLiveActivity(streamID: streamID)
        streamClient.start(
            url: client.chatStreamURL(
                streamID: streamID,
                replayAfterSeq: replayAfterSeq
            )
        ) { [weak self] event in
            self?.handle(event)
        }
        delegate?.streamCoordinatorStartAuxiliaryMonitoring()
    }

    func cancelActiveStream() async throws -> ChatCancelResponse? {
        guard let activeStreamID else { return nil }

        let response = try await client.cancelChat(streamID: activeStreamID)
        guard self.activeStreamID == activeStreamID else { return response }
        guard response.ok != false else { return response }

        liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
        finishStream()
        return response
    }

    func suspendActiveStreamConnection() {
        guard activeStreamID != nil, !hasCompletedCurrentResponse, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
    }

    func prepareForSessionLoad() -> ChatStreamLoadPreparation {
        setLiveTokensPerSecondIfChanged(nil)
        let activeStreamIDBeforeLoad = activeStreamID
        if activeStreamIDBeforeLoad != nil, !hasCompletedCurrentResponse {
            delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        }

        return ChatStreamLoadPreparation(
            activeStreamIDBeforeLoad: activeStreamIDBeforeLoad,
            shouldPrepareSuspendedStreamResume: activeStreamID == nil || isConnectionSuspended
        )
    }

    func shouldPreserveLocalOptimisticMessages(
        for preparation: ChatStreamLoadPreparation,
        loadedActiveStreamID: String?
    ) -> Bool {
        guard let activeStreamIDBeforeLoad = preparation.activeStreamIDBeforeLoad else {
            return false
        }

        // A same-stream `start()` (foreground reconnect / replay) bumps
        // `runGeneration` without replacing the server run. Stream identity is
        // the successor fence; generation would treat that restart as a new
        // authority and drop the uncached optimistic row.
        guard activeStreamID == activeStreamIDBeforeLoad else {
            return false
        }

        let loadedActiveStreamID = loadedActiveStreamID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return loadedActiveStreamID == activeStreamIDBeforeLoad
    }

    func reconcileSessionLoad(
        loadedActiveStreamID rawLoadedActiveStreamID: String?,
        preparation: ChatStreamLoadPreparation,
        usedCacheFallback: Bool
    ) {
        hasCompletedCurrentResponse = false
        isTerminalContentFenceActive = false
        isTransportFinished = false
        setLiveTokensPerSecondIfChanged(nil)
        defer { invalidateReconnectTaskIfItDoesNotMatchCurrentStream() }

        if usedCacheFallback {
            activeStreamID = nil
            isConnectionSuspended = false
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            resetRecoveryState()
            return
        }

        let loadedActiveStreamID = rawLoadedActiveStreamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparation.shouldPrepareSuspendedStreamResume {
            delegate?.streamCoordinatorStreamingAssistantMessageID = nil
            if let streamID = loadedActiveStreamID, !streamID.isEmpty {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                isConnectionSuspended = true
                restoreSnapshotIfAvailable(streamID: streamID)
            } else {
                activeStreamID = nil
                isConnectionSuspended = false
                resetRecoveryState()
            }
        } else {
            let streamID = loadedActiveStreamID?.isEmpty == false
                ? loadedActiveStreamID
                : preparation.activeStreamIDBeforeLoad
            if let streamID {
                activeStreamID = streamID
                delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                restoreSnapshotIfAvailable(streamID: streamID)
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
            }
            isConnectionSuspended = false
        }
    }

    func reconnectIfNeeded(modelContext: ModelContext? = nil) async {
        guard let activeStreamID, isConnectionSuspended else { return }
        if var reconnectTask {
            if reconnectTask.modelContext == nil, let modelContext {
                reconnectTask.modelContext = modelContext
                self.reconnectTask = reconnectTask
            }
            await reconnectTask.task.value
            return
        }

        let reconnectTaskID = UUID()
        let reconnectGeneration = runGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performReconnectIfNeeded(
                reconnectTaskID: reconnectTaskID,
                streamID: activeStreamID,
                runGeneration: reconnectGeneration
            )
            guard self.reconnectTask?.id == reconnectTaskID else { return }
            self.reconnectTask = nil
        }
        reconnectTask = (
            id: reconnectTaskID,
            streamID: activeStreamID,
            runGeneration: reconnectGeneration,
            modelContext: modelContext,
            task: task
        )
        await task.value
    }

    private func performReconnectIfNeeded(
        reconnectTaskID: UUID,
        streamID: String,
        runGeneration: Int
    ) async {
        guard reconnectTaskIsCurrent(
            reconnectTaskID: reconnectTaskID,
            streamID: streamID,
            runGeneration: runGeneration
        ) else { return }

        do {
            let response = try await client.chatStreamStatus(streamID: streamID)
            guard reconnectTaskIsCurrent(
                reconnectTaskID: reconnectTaskID,
                streamID: streamID,
                runGeneration: runGeneration
            ) else { return }
            delegate?.streamCoordinatorDidConfirmRecovery()

            if response.active == true {
                let completedLoad = await loadMessagesForReconnect(reconnectTaskID: reconnectTaskID)
                guard completedLoad,
                      reconnectTaskIsCurrent(
                          reconnectTaskID: reconnectTaskID,
                          streamID: streamID,
                          runGeneration: runGeneration
                      )
                else { return }

                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    restoreSnapshotIfAvailable(streamID: streamID)
                }
                if delegate?.streamCoordinatorStreamingAssistantMessageID == nil {
                    delegate?.streamCoordinatorStreamingAssistantMessageID = delegate?.streamCoordinatorLatestAssistantMessageID()
                }
                isConnectionSuspended = false
                start(streamID: streamID)
            } else if response.replayAvailable == true {
                guard reconnectTaskIsCurrent(
                    reconnectTaskID: reconnectTaskID,
                    streamID: streamID,
                    runGeneration: runGeneration
                ) else { return }
                let replayAfterSeq = Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0
                isConnectionSuspended = false
                start(streamID: streamID, replayAfterSeq: replayAfterSeq)
            } else {
                let completedLoad = await loadMessagesForReconnect(reconnectTaskID: reconnectTaskID)
                guard completedLoad,
                      reconnectTaskOwnsFinalization(
                          reconnectTaskID: reconnectTaskID,
                          streamID: streamID,
                          runGeneration: runGeneration
                      ),
                      canFinalizeRunAfterLoad(streamID: streamID, capturedGeneration: runGeneration)
                else { return }

                // #246: the server reports the run is over. Finalize it (and end
                // the Live Activity) instead of re-arming and leaving it dangling
                // on "running" when no assistant reply surfaced.
                finalizeInactiveStream(streamID: streamID)
            }
        } catch {
            if (error as? APIError)?.indicatesMissingStream == true,
               reconnectTaskIsCurrent(
                   reconnectTaskID: reconnectTaskID,
                   streamID: streamID,
                   runGeneration: runGeneration
               ) {
                let completedLoad = await loadMessagesForReconnect(reconnectTaskID: reconnectTaskID)
                guard completedLoad,
                      reconnectTaskOwnsFinalization(
                          reconnectTaskID: reconnectTaskID,
                          streamID: streamID,
                          runGeneration: runGeneration
                      ),
                      canFinalizeRunAfterLoad(streamID: streamID, capturedGeneration: runGeneration)
                else { return }
                finalizeInactiveStream(streamID: streamID)
                return
            }
            guard reconnectTaskIsCurrent(
                reconnectTaskID: reconnectTaskID,
                streamID: streamID,
                runGeneration: runGeneration
            ) else { return }
            delegate?.streamCoordinatorDidReceiveRecoveryError(error)
        }
    }

    func refreshTranscriptIfCompleted(
        streamID expectedStreamID: String,
        modelContext: ModelContext? = nil
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
            delegate?.streamCoordinatorDidConfirmRecovery()
            guard response.active == false else { return }

            await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
            // Bail if a concurrent completion/cancel/new run finalized or replaced
            // this run during the load (see canFinalizeRunAfterLoad).
            guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation) else { return }

            guard delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true else {
                // Foreground safety net: the live SSE is still connected and owns
                // completion, so a status poll that briefly reports inactive must
                // not finalize the run — keep waiting for the real `.done`. (This
                // is why #246's finalize-on-reopen fix deliberately excludes this
                // path; see finalizeInactiveStream.)
                activeStreamID = expectedStreamID
                isConnectionSuspended = false
                return
            }

            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: expectedStreamID)
        } catch {
            // This is a foreground safety net. The primary SSE path owns visible
            // stream errors; a failed status poll should not interrupt it.
            chatStreamCoordinatorLogger.warning(
                "Active stream status refresh failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )
        }
    }

    func recoverStaleStreamIfNeeded(
        now: Date = Date(),
        modelContext: ModelContext? = nil
    ) async {
        guard let activeStreamID,
              !isConnectionSuspended,
              !hasCompletedCurrentResponse
        else {
            setRecoveryStateIfChanged(.idle)
            return
        }

        guard delegate?.streamCoordinatorHasPendingPrompt != true else {
            setRecoveryStateIfChanged(.idle)
            return
        }

        let reconnectInterval = delegate?.streamCoordinatorHasRunningLiveToolCall == true
            ? timing.runningToolReconnectInterval
            : timing.reconnectInterval
        guard let lastProgressDate else {
            guard let lastTransportActivityDate,
                  now.timeIntervalSince(lastTransportActivityDate) >= reconnectInterval
            else {
                setRecoveryStateIfChanged(.idle)
                return
            }

            setRecoveryStateIfChanged(.checking)
            lastRecoveryStatusCheckDate = now
            await recoverStaleStream(
                streamID: activeStreamID,
                forceReconnect: true,
                modelContext: modelContext
            )
            return
        }

        let elapsed = now.timeIntervalSince(lastProgressDate)
        guard elapsed >= timing.checkingInterval else {
            setRecoveryStateIfChanged(.idle)
            return
        }

        let transportElapsed = now.timeIntervalSince(lastTransportActivityDate ?? lastProgressDate)
        guard transportElapsed >= timing.transportFreshInterval else {
            // #227: heartbeats prove the connection is alive during a
            // semantically quiet window (model thinking / slow tool call), so
            // stay idle and skip status polls. A genuinely silent transport
            // still escalates below once past transportFreshInterval.
            setRecoveryStateIfChanged(.idle)
            return
        }

        setRecoveryStateIfChanged(.checking)
        let shouldForceReconnect = transportElapsed >= reconnectInterval
        guard shouldForceReconnect || shouldPollStatus(now: now) else { return }

        lastRecoveryStatusCheckDate = now
        await recoverStaleStream(
            streamID: activeStreamID,
            forceReconnect: shouldForceReconnect,
            modelContext: modelContext
        )
    }

    func markProgress(now: Date = Date()) {
        delegate?.streamCoordinatorDidConfirmRecovery()
        lastProgressDate = now
        lastTransportActivityDate = now
        lastRecoveryStatusCheckDate = nil
        setRecoveryStateIfChanged(.idle)
    }

    func clearReplayConnection() {
        isReplayConnection = false
    }

    nonisolated static func runJournalReplayAfterSeq(from eventID: String?) -> Int? {
        guard let eventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventID.isEmpty
        else {
            return nil
        }

        let sequenceText: Substring
        if let delimiterIndex = eventID.lastIndex(of: ":") {
            sequenceText = eventID[eventID.index(after: delimiterIndex)...]
        } else {
            sequenceText = Substring(eventID)
        }

        guard let sequence = Int(sequenceText) else {
            return nil
        }

        return max(0, sequence)
    }

    private func handle(_ event: SSEEvent) {
        // Terminal-content fence (#288): once the response has completed, late
        // content must never reach the transcript. The fence survives streamEnd
        // (finishStream resets hasCompletedCurrentResponse but not the fence),
        // closing the done → streamEnd → token ordering. Title and metering are
        // session metadata and still pass; a settled completion is never
        // re-ended by late error/cancel (#288 review).
        if isTerminalContentFenceActive {
            switch event {
            case .title(let payload):
                if delegate?.streamCoordinatorUpdateTitle(payload) == true {
                    markProgress()
                }
                return
            case .metering(let payload):
                guard payload.sessionId == nil || payload.sessionId == delegate?.streamCoordinatorSessionID else {
                    return
                }
                setLiveTokensPerSecondIfChanged(payload.displayableTokensPerSecond)
                return
            case .done:
                // Duplicate done after completion — already finalized; ignore.
                return
            case .heartbeat, .ignored:
                break
            case .transportError, .cancelled, .error, .streamEnd:
                // Settled completion wins: tear down exactly once without
                // publishing a second Live Activity end or repeating delegate
                // finish/drain/title-refresh side effects. transportError after
                // done must still finish (snapshot cleanup, queued-slash drain,
                // completed-title refresh) — it previously fell through to the
                // pre-change handleTransportError path (PR #295 re-gate).
                finishStream()
                return
            case .token, .interimAssistant, .reasoning, .toolStarted, .toolCompleted,
                 .approvalPending, .clarificationPending, .pendingSteerLeftover:
                return
            }
        }

        lastEventID = streamClient.lastEventID ?? lastEventID
        lastTransportActivityDate = Date()

        switch event {
        case .token(let text):
            if showsLiveActivityResponseExcerpts {
                liveActivityManager.update(.token(text))
            }
            if delegate?.streamCoordinatorAppendToken(text) == true {
                markProgress()
            }
        case .interimAssistant(let payload):
            if showsLiveActivityResponseExcerpts,
               payload.alreadyStreamed != true,
               let text = payload.text {
                liveActivityManager.update(.interimAssistant(text))
            }
            if delegate?.streamCoordinatorAppendInterimAssistant(payload) == true {
                markProgress()
            }
        case .reasoning(let text):
            liveActivityManager.update(.reasoning(text))
            if delegate?.streamCoordinatorAppendReasoning(text) == true {
                markProgress()
            }
        case .toolStarted(let payload):
            liveActivityManager.update(.toolStarted(name: payload.name))
            if delegate?.streamCoordinatorAppendToolCall(payload) == true {
                markProgress()
            }
        case .toolCompleted(let payload):
            liveActivityManager.update(.toolCompleted)
            if delegate?.streamCoordinatorCompleteToolCall(payload) == true {
                markProgress()
            }
        case .title(let payload):
            if delegate?.streamCoordinatorUpdateTitle(payload) == true {
                markProgress()
            }
        case .metering(let payload):
            guard payload.sessionId == nil || payload.sessionId == delegate?.streamCoordinatorSessionID else {
                break
            }
            setLiveTokensPerSecondIfChanged(payload.displayableTokensPerSecond)
        case .done(let payload):
            let hasCompletedTranscript = delegate?.streamCoordinatorApplyDone(payload) == true
            completeCurrentResponse(needsTranscriptRefresh: !hasCompletedTranscript)
        case .approvalPending(let update):
            liveActivityManager.update(.waitingForApproval)
            delegate?.streamCoordinatorApplyApprovalUpdate(update)
            markProgress()
        case .clarificationPending(let update):
            liveActivityManager.update(.waitingForClarification)
            delegate?.streamCoordinatorApplyClarificationUpdate(update)
            markProgress()
        case .pendingSteerLeftover(let text):
            if delegate?.streamCoordinatorEnqueuePendingSteerLeftover(text) == true {
                markProgress()
            }
        case .streamEnd:
            if !hasCompletedCurrentResponse {
                liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
            }
            finishStream()
        case .cancelled:
            liveActivityManager.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
            finishStream()
        case .error(let message):
            if !hasCompletedCurrentResponse {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
            finishStream()
        case .transportError(let message):
            handleTransportError(message)
        case .heartbeat:
            delegate?.streamCoordinatorDidConfirmRecovery()
            // #227: a heartbeat proves the transport is alive without carrying
            // semantic progress — drop an already-shown "Checking stream" state
            // immediately. Never demote .reconnecting; that chip is owned by
            // the reconnect flow until real progress lands.
            if recoveryState == .checking {
                setRecoveryStateIfChanged(.idle)
            }
        case .ignored:
            break
        }
    }

    private func handleTransportError(_ message: String) {
        setLiveTokensPerSecondIfChanged(nil)
        guard activeStreamID != nil, !hasCompletedCurrentResponse else {
            if !hasCompletedCurrentResponse {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            finishStream()
            return
        }

        guard !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        isConnectionSuspended = true
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)

        Task { @MainActor [weak self] in
            await self?.reconnectIfNeeded()
        }
    }

    private func shouldPollStatus(now: Date) -> Bool {
        guard let lastRecoveryStatusCheckDate else { return true }

        return now.timeIntervalSince(lastRecoveryStatusCheckDate) >= timing.statusPollCooldown
    }

    private func recoverStaleStream(
        streamID expectedStreamID: String,
        forceReconnect: Bool,
        modelContext: ModelContext?
    ) async {
        guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
        let generation = runGeneration

        do {
            let response = try await client.chatStreamStatus(streamID: expectedStreamID)
            guard activeStreamID == expectedStreamID, !isConnectionSuspended else { return }
            delegate?.streamCoordinatorDidConfirmRecovery()

            if response.active == false {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                // Same generation/clobber guard as the reconnect and refresh paths;
                // the extra `!isConnectionSuspended` keeps the reconnect path owning
                // a stream that was suspended mid-load. (PR #266 review #3)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }

                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // PR #238 review: recoveryState was set to .checking before this
            // await. If it changed mid-flight (a heartbeat or real progress
            // demoted it to .idle), the transport just proved itself alive —
            // don't resurrect the chip or churn a live connection; the next
            // recovery tick re-evaluates from scratch.
            guard recoveryState == .checking, forceReconnect else { return }

            reconnectStaleStream(
                streamID: expectedStreamID,
                usesReplay: response.replayAvailable == true
            )
        } catch {
            chatStreamCoordinatorLogger.warning(
                "Stale stream recovery status check failed category=\(APIError.privacySafeLogCategory(for: error), privacy: .public)"
            )

            if (error as? APIError)?.indicatesMissingStream == true,
               activeStreamID == expectedStreamID,
               !isConnectionSuspended {
                await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
                guard canFinalizeRunAfterLoad(streamID: expectedStreamID, capturedGeneration: generation),
                      !isConnectionSuspended else { return }
                finalizeInactiveStream(streamID: expectedStreamID)
                return
            }

            // Same mid-flight demotion guard as the success path (PR #238
            // review): only a still-.checking state may escalate.
            guard recoveryState == .checking,
                  forceReconnect,
                  activeStreamID == expectedStreamID,
                  !isConnectionSuspended
            else { return }

            reconnectStaleStream(streamID: expectedStreamID, usesReplay: true)
        }
    }

    private func reconnectStaleStream(streamID: String, usesReplay: Bool) {
        guard activeStreamID == streamID, !isConnectionSuspended else { return }

        lastEventID = streamClient.lastEventID ?? lastEventID
        let replayAfterSeq = usesReplay ? Self.runJournalReplayAfterSeq(from: lastEventID) ?? 0 : nil
        delegate?.streamCoordinatorSaveSnapshotIfNeeded()
        liveActivityManager.markStale()
        setRecoveryStateIfChanged(.reconnecting)
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        start(
            streamID: streamID,
            replayAfterSeq: replayAfterSeq,
            recoveryState: .reconnecting
        )
    }

    private func completeCurrentResponse(needsTranscriptRefresh: Bool) {
        runGeneration &+= 1
        invalidateReconnectTask()
        liveActivityManager.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: activeStreamID)
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        activeStreamID = nil
        lastEventID = nil
        setLiveTokensPerSecondIfChanged(nil)
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = true
        isTerminalContentFenceActive = true
        delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: needsTranscriptRefresh)
        resetRecoveryState()
    }

    private func completeResponseFromRefreshedTranscriptAndFinishStream(streamID completedStreamID: String?) {
        completeCurrentResponse(needsTranscriptRefresh: false)
        delegate?.streamCoordinatorRemoveSnapshot(streamID: completedStreamID)
        finishStream()
    }

    /// Whether `self` may still finalize the run captured before an awaited
    /// transcript load. Returns false (bail) when a concurrent completion / cancel
    /// / new run bumped the generation — finalizing would double-finalize — or when
    /// a *different* run is now active — finalizing would clobber the newer stream.
    /// A run reconciled to `nil` during the load still passes: it should be
    /// finalized from the refreshed transcript so its Live Activity can't dangle on
    /// "running" (#246). Shared by all three post-load finalize paths
    /// (reconnect-after-suspend, foreground refresh, stale recovery) so they stay in
    /// lockstep — recoverStaleStream previously used a stricter, hand-rolled guard.
    /// (PR #266 review #3)
    private func canFinalizeRunAfterLoad(streamID: String, capturedGeneration: Int) -> Bool {
        guard runGeneration == capturedGeneration else { return false }
        return activeStreamID == nil || activeStreamID == streamID
    }

    /// The server reports this stream is no longer active. Complete from the
    /// just-refreshed transcript when an assistant reply surfaced, otherwise
    /// finalize as failed. Either branch ends the Live Activity, so it can never
    /// dangle on "running" after the run is over (#246). Shared by the two paths
    /// with no live SSE behind them — reconnect-after-suspend and stale recovery.
    /// The foreground transcript-refresh safety net deliberately keeps waiting
    /// instead, because its live SSE still owns completion.
    private func finalizeInactiveStream(streamID: String?) {
        if delegate?.streamCoordinatorLatestServerLoadHadAssistantResponseAfterLatestUser == true {
            completeResponseFromRefreshedTranscriptAndFinishStream(streamID: streamID)
        } else {
            liveActivityManager.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
            finishStream()
        }
    }

    private func finishStream() {
        guard !isTransportFinished else { return }
        isTransportFinished = true
        runGeneration &+= 1
        invalidateReconnectTask()
        let completedNormally = hasCompletedCurrentResponse
        let finishedStreamID = activeStreamID
        streamClient.stop()
        delegate?.streamCoordinatorStopAuxiliaryMonitoring(clearPrompt: true)
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorRemoveSnapshot(streamID: finishedStreamID)
        activeStreamID = nil
        lastEventID = nil
        setLiveTokensPerSecondIfChanged(nil)
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        hasCompletedCurrentResponse = false
        delegate?.streamCoordinatorDidFinishStream()
        isConnectionSuspended = false
        resetRecoveryState()
        delegate?.streamCoordinatorDrainQueuedSlashMessageIfIdle()
        if completedNormally {
            delegate?.streamCoordinatorRefreshCompletedResponseTitleIfNeeded()
        }
    }

    private func markConnectionStarted(
        isReplay: Bool,
        recoveryState: ActiveStreamRecoveryState
    ) {
        let startedAt = Date()
        lastProgressDate = isReplay ? startedAt : nil
        lastTransportActivityDate = startedAt
        lastRecoveryStatusCheckDate = nil
        setRecoveryStateIfChanged(recoveryState)
        isReplayConnection = isReplay
        delegate?.streamCoordinatorDidStartConnection(isReplay: isReplay)
    }

    private func loadMessagesForReconnect(reconnectTaskID: UUID) async -> Bool {
        while reconnectTask?.id == reconnectTaskID {
            let modelContext = recoveryModelContext(for: reconnectTaskID)
            reconnectTranscriptLoadTaskID = reconnectTaskID
            await delegate?.streamCoordinatorLoadMessages(modelContext: modelContext)
            guard reconnectTranscriptLoadTaskID == reconnectTaskID else { return false }

            // The transport-error path can begin recovery without persistence
            // access. If a foreground caller supplied it while that nil-context
            // load was in flight, repeat the shared load once so optimistic
            // messages and the cache participate in reconciliation.
            if modelContext == nil, recoveryModelContext(for: reconnectTaskID) != nil {
                continue
            }

            reconnectTranscriptLoadTaskID = nil
            return true
        }
        return false
    }

    private func reconnectTaskIsCurrent(
        reconnectTaskID: UUID,
        streamID: String,
        runGeneration: Int
    ) -> Bool {
        guard !Task.isCancelled,
              let reconnectTask,
              reconnectTask.id == reconnectTaskID,
              reconnectTask.streamID == streamID,
              reconnectTask.runGeneration == runGeneration,
              self.runGeneration == runGeneration,
              activeStreamID == streamID,
              isConnectionSuspended
        else { return false }
        return true
    }

    private func reconnectTaskOwnsFinalization(
        reconnectTaskID: UUID,
        streamID: String,
        runGeneration: Int
    ) -> Bool {
        guard !Task.isCancelled,
              let reconnectTask,
              reconnectTask.id == reconnectTaskID,
              reconnectTask.streamID == streamID,
              reconnectTask.runGeneration == runGeneration,
              self.runGeneration == runGeneration
        else { return false }
        return activeStreamID == streamID || activeStreamID == nil
    }

    private func recoveryModelContext(for reconnectTaskID: UUID) -> ModelContext? {
        guard reconnectTask?.id == reconnectTaskID else { return nil }
        return reconnectTask?.modelContext
    }

    private func invalidateReconnectTask() {
        let task = reconnectTask?.task
        reconnectTask = nil
        reconnectTranscriptLoadTaskID = nil
        task?.cancel()
    }

    private func invalidateReconnectTaskIfItDoesNotMatchCurrentStream() {
        guard let reconnectTask,
              reconnectTask.runGeneration == runGeneration
        else {
            invalidateReconnectTask()
            return
        }

        if activeStreamID == nil, reconnectTranscriptLoadTaskID == reconnectTask.id {
            return
        }

        guard isConnectionSuspended, activeStreamID == reconnectTask.streamID else {
            invalidateReconnectTask()
            return
        }
    }

    private func setRecoveryStateIfChanged(_ next: ActiveStreamRecoveryState) {
        guard recoveryState != next else { return }
        recoveryState = next
    }

    private func setLiveTokensPerSecondIfChanged(_ next: Double?) {
        guard liveTokensPerSecond != next else { return }
        liveTokensPerSecond = next
    }

    private func resetRecoveryState() {
        setRecoveryStateIfChanged(.idle)
        lastProgressDate = nil
        lastTransportActivityDate = nil
        lastRecoveryStatusCheckDate = nil
        isReplayConnection = false
        delegate?.streamCoordinatorDidResetRecoveryState()
    }

    private func startLiveActivity(streamID: String) {
        guard let sessionID = delegate?.streamCoordinatorSessionID else { return }

        liveActivityManager.start(
            sessionID: sessionID,
            sessionTitle: delegate?.streamCoordinatorDisplayTitle ?? String(localized: "Untitled Session"),
            streamID: streamID
        )
    }

    private func restoreSnapshotIfAvailable(streamID: String) {
        guard lastEventID == nil else {
            _ = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID)
            return
        }

        lastEventID = delegate?.streamCoordinatorRestoreSnapshotIfAvailable(streamID: streamID) ?? lastEventID
    }
}
