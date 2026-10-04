import Foundation
import Observation
import SwiftData

/// What a `HermesChatTurnCoordinator` asks of the chat beyond the shared stream delegate:
/// the parts of a Hermes turn a webui stream does not have. `ChatViewModel` conforms.
@MainActor protocol HermesChatTurnDelegate: ChatStreamCoordinatorDelegate {
    /// A turn began: the last turn's live work is archived and the next reply opens a new
    /// assistant row. `prompt` is a queued prompt the host just ran, shown as the turn's
    /// user row; nil when the chat already shows it or the turn has none.
    func hermesTurnDidStart(prompt: String?)
    /// `message.complete`'s reply text: kept when deltas already carried it, appended when not.
    func hermesTurnDidComplete(reply: String)
    /// Replaces the transcript with a full snapshot's history and its in-flight turn.
    func hermesReplaceTranscript(_ transcript: HermesChatTranscript)
    func hermesApplyUsage(_ usage: ContextWindowSnapshot)
    /// The model `session.info` reports: the Profile's default unless the host says otherwise.
    func hermesApplyModel(_ model: String)
    /// Why the session cannot attach, or nil once it has.
    func hermesConnectionDidChange(failure: String?)
    /// `session.create` named the new session's stored key: the draft under `from` moves to `to`.
    func hermesDraftKeyDidChange(from: ChatDraftKey, to: ChatDraftKey)
}

/// A Hermes session the main chat opens: the server, its saved connection and the target.
/// Each value is its own chat, so opening "New Session" twice pushes two.
struct HermesSessionChat: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let connection: BotConnection
    let target: ConversationTarget

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A Hermes session's transcript rebuilt from a full `session.resume`.
struct HermesChatTranscript: Equatable {
    var messages: [ChatMessage]
    var toolCallGroups: [ToolCallGroup]
    var reasoningGroups: [ReasoningGroup]
    /// The running turn's unsaved reply, which the next deltas continue.
    var streamingReply: ChatMessage?
    var title: String?
}

/// Runs a Hermes session's turns in the main chat (#1010). It owns the session's
/// `HermesConversation`, which attaches, replays and reconnects, and reduces the engine's
/// ordered frames onto the chat's `ChatStreamCoordinatorDelegate`, so message building,
/// pacing and run endings are the webui path's. Text is delta-driven; a full snapshot
/// replaces the transcript only on the engine's rebuild signal (a gap, a reset replay, a
/// new runtime). Each prompt, steer, redirect and stop is one `write`, never resent.
///
/// A turn's identity is the stored key and the host's `turn_started_at`, in place of a
/// webui stream id. A turn starts at `message.start`, an accepted send or a running
/// snapshot, and ends once `message.complete` and `session.info {running: false}` have
/// both arrived; a lone `error` ends it at once.
@MainActor @Observable final class HermesChatTurnCoordinator {
    let engine: HermesConversation
    @ObservationIgnored private weak var delegate: (any HermesChatTurnDelegate)?

    private(set) var activeStreamID: String?
    private(set) var activeRunStartedAt: Date?
    private(set) var latestRunEnding: ChatRunEnding?
    private(set) var successfulResponseCompletion: ChatStreamCoordinator.SuccessfulResponseCompletion?
    private(set) var isReplayConnection = false
    /// The prompt the host holds for its next turn: one slot, merged as the host merges
    /// text-only prompts. Restored from the snapshot's `queued`; a Stop discards it.
    private(set) var queuedPrompt: String?
    /// Host requests open on this runtime: an approval, a question, a credential prompt.
    private(set) var openRequestIDs: Set<String> = []

    /// The host's `turn_started_at` for the running turn, once known.
    @ObservationIgnored private var turnStartedAt: Double?
    /// The start a `session.info {running: true}` reported for the turn it opens. Only the
    /// first turn after an attach is sure to get one, so a turn consumes it.
    @ObservationIgnored private var hostTurnStartedAt: Double?
    @ObservationIgnored private var hostRunning = false
    /// How the running turn ended, from `message.complete`, until `session.info` says idle.
    @ObservationIgnored private var pendingEnding: TranscriptTurnRunOutcome.Ending?
    /// The turn began from a send's reply; its own `message.start` is still to come.
    @ObservationIgnored private var awaitingStart = false
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var isSubmittingSend = false
    @ObservationIgnored private var turnsStarted = 0
    /// A live gap asked for a reattach whose snapshot replaces the transcript.
    @ObservationIgnored private var needsRebuild = false
    @ObservationIgnored private var attaching: Task<Void, Never>?
    @ObservationIgnored private var attachGeneration = 0
    /// The host refused the saved sign-in: nothing reattaches on its own until the chat
    /// asks again, so the refused password is not sent again unasked (#884).
    @ObservationIgnored private var refusedSignIn = false
    @ObservationIgnored private var draftKey: ChatDraftKey
    private let isNetworkAvailable: @MainActor () -> Bool

    init(engine: HermesConversation,
         isNetworkAvailable: @escaping @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied }) {
        self.engine = engine
        self.isNetworkAvailable = isNetworkAvailable
        draftKey = engine.target.draftKey(server: engine.server, connectionID: engine.connection.id)
        engine.owner = self
    }

    /// A chat on `target` over the connection's shared gateway socket.
    convenience init(server: URL, connection: BotConnection, target: ConversationTarget) {
        self.init(engine: HermesConversation(server: server, connection: connection, target: target,
                                             wire: BotClient(saved: connection, server: server)))
    }

    /// The composer draft's key: the new-session key until `session.create` names the session.
    var currentDraftKey: ChatDraftKey { draftKey }

    /// Stop asks first only when it would lose something: the host's queued prompt, or a
    /// request (an approval the stop denies).
    var stopNeedsConfirmation: Bool { queuedPrompt != nil || !openRequestIDs.isEmpty }

    /// Attaches the session, creating a new one on the first attach, or joins the attach
    /// already running so a new session is never created twice.
    func activate() async {
        if let attaching { await attaching.value; return }
        // Connected, attaching, or retrying on its own backoff: nothing to start. A failure
        // the engine will not retry is attached again here.
        guard !engine.isActive || (engine.connectionState == .disconnected && !engine.isReconnecting) else { return }
        await startAttach().value
    }

    /// The one attach in flight. Cancelled by leaving, so one that has not begun never does.
    @discardableResult
    private func startAttach() -> Task<Void, Never> {
        attachGeneration += 1
        let generation = attachGeneration
        let task = Task { [weak self, engine] in
            guard !Task.isCancelled else { return }
            await engine.activate()
            guard let self, self.attachGeneration == generation else { return }
            self.attaching = nil
        }
        attaching = task
        return task
    }

    private func cancelAttach() {
        attaching?.cancel(); attaching = nil
        attachGeneration += 1
    }

    /// A prompt that never reached the socket: not attached, or the attach changed first.
    struct NotSent: Error { let underlying: Error }

    /// Sends `text` in `mode` on the attached runtime, attaching first if the chat has not.
    /// Returns what the host said; throws `NotSent` when it never went out, and the
    /// failure itself when its reply was refused or lost. Never resent: after a lost
    /// reply the next snapshot says what happened.
    func submit(_ text: String, mode: BotPromptMode) async throws -> BotPromptOutcome {
        await activate()
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw NotSent(underlying: BotFailure.transport)
        }
        let startsBefore = turnsStarted
        if mode == .send { isSubmittingSend = true }
        defer { if mode == .send { isSubmittingSend = false } }
        var dispatched = false
        let reply: BotJSON
        do {
            reply = try await engine.write(mode.call(runtime: runtime, text: text), attempt: engine.generation,
                                           runtime: runtime) { dispatched = true }
        } catch {
            // A reaped runtime (4001): reattach to the stored key, which reads only.
            if case BotFailure.rejected(4001) = error { reattach() }
            throw dispatched ? error : NotSent(underlying: error)
        }
        let outcome = mode.outcome(reply)
        switch outcome {
        case .started:
            // The turn's own frames can land before this reply; start one only if none did.
            if turnsStarted == startsBefore, activeStreamID == nil {
                beginTurn(startedAt: nil, prompt: nil)
                awaitingStart = true
            }
        case .followUpQueued, .redirectQueued:
            queuedPrompt = queuedPrompt.map { "\($0)\n\n\(text)" } ?? text
        case .guidanceQueued, .redirected, .voiceStopped, .rejected, .unknown:
            break
        }
        return outcome
    }

    /// Stops the running turn (`session.interrupt`); false when there is none or a stop is
    /// already in. The host also discards its queued prompt, withdraws open requests and
    /// denies pending approvals. Idle still waits for the turn's own ending frames.
    func interrupt() async throws -> Bool {
        guard activeStreamID != nil, !stopRequested else { return false }
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.transport }
        stopRequested = true
        do {
            _ = try await engine.write(.sessionInterrupt(sessionID: runtime), attempt: engine.generation, runtime: runtime)
        } catch {
            stopRequested = false
            throw error
        }
        queuedPrompt = nil
        openRequestIDs = []
        return true
    }

    // MARK: Turns

    private func beginTurn(startedAt: Double?, prompt: String?) {
        turnsStarted += 1
        latestRunEnding = nil; successfulResponseCompletion = nil
        pendingEnding = nil; awaitingStart = false; stopRequested = false
        hostRunning = true
        turnStartedAt = startedAt
        activeRunStartedAt = Self.date(startedAt) ?? Date()
        activeStreamID = "hermes:\(engine.storedKey ?? ""):\(startedAt.map { String($0) } ?? UUID().uuidString)"
        hostTurnStartedAt = nil
        delegate?.hermesTurnDidStart(prompt: prompt)
        delegate?.streamCoordinatorDidStartConnection(isReplay: false)
    }

    private func ensureTurn() {
        if activeStreamID == nil { beginTurn(startedAt: hostTurnStartedAt, prompt: nil) }
    }

    /// Ends the running turn the way the webui path ends a stream, so the chat records the
    /// same outcome, haptic and alert.
    private func finish(_ ending: TranscriptTurnRunOutcome.Ending) {
        guard let streamID = activeStreamID else { return }
        latestRunEnding = ChatRunEnding(startedAt: activeRunStartedAt ?? Date(), endedAt: Date(), ending: ending)
        if ending == .completed {
            successfulResponseCompletion = .init(streamID: streamID, needsTranscriptRefresh: false)
            delegate?.streamCoordinatorApplyDone(DoneStreamEvent())
        }
        activeStreamID = nil; activeRunStartedAt = nil
        turnStartedAt = nil; pendingEnding = nil; awaitingStart = false; stopRequested = false
        isReplayConnection = false
        delegate?.streamCoordinatorStreamingAssistantMessageID = nil
        if ending == .completed { delegate?.streamCoordinatorDidCompleteCurrentResponse(needsTranscriptRefresh: false) }
        delegate?.streamCoordinatorFlushPinnedLocalNoticesToTranscript()
        delegate?.streamCoordinatorDidFinishStream()
        delegate?.streamCoordinatorDidResetRecoveryState()
    }

    /// The host's start for the running turn, which can only move it earlier.
    private func adoptStart(_ startedAt: Double) {
        turnStartedAt = startedAt
        guard let date = Self.date(startedAt) else { return }
        activeRunStartedAt = min(activeRunStartedAt ?? date, date)
    }

    /// One event of this runtime, in `seq` order.
    private func apply(_ frame: BotJSON) {
        let payload = frame["payload"]
        switch frame["type"].text ?? "" {
        case "message.start":
            if activeStreamID != nil {
                if awaitingStart { awaitingStart = false; return }
                // A new turn while the last waits on `session.info`: that one is over.
                finish(pendingEnding ?? .completed)
            }
            var prompt: String?
            if !isSubmittingSend { prompt = queuedPrompt; queuedPrompt = nil }
            beginTurn(startedAt: hostTurnStartedAt, prompt: prompt)
        case "message.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return }
            ensureTurn()
            delegate?.streamCoordinatorAppendToken(text)
        case "message.interim":
            ensureTurn()
            delegate?.streamCoordinatorAppendInterimAssistant(InterimAssistantStreamEvent(
                text: payload["text"].text, alreadyStreamed: payload["already_streamed"].flag))
        case "reasoning.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return }
            ensureTurn()
            delegate?.streamCoordinatorAppendReasoning(text)
        case "tool.start":
            ensureTurn()
            delegate?.streamCoordinatorAppendToolCall(Self.toolEvent(payload, completed: false))
        case "tool.complete":
            ensureTurn()
            delegate?.streamCoordinatorCompleteToolCall(Self.toolEvent(payload, completed: true))
        case "session.title":
            // A suggestion for this session's title; the chat shows it and renames nothing.
            if let key = payload["session_id"].text, key != engine.storedKey { return }
            guard let title = payload["title"].text, !title.isEmpty else { return }
            delegate?.streamCoordinatorUpdateTitle(TitleStreamEvent(sessionId: nil, title: title))
        case "session.usage":
            if let usage = Self.contextWindow(payload["usage"]) { delegate?.hermesApplyUsage(usage) }
        case "session.info":
            applyInfo(payload)
        case "message.complete":
            complete(payload)
        case "error":
            if let message = payload["message"].text, !message.isEmpty {
                delegate?.streamCoordinatorDidReceiveErrorMessage(message)
            }
            finish(.failed)
        case "request.cancel":
            if let id = payload["id"].text { openRequestIDs.remove(id) }
        default:
            // `thinking.delta` is spinner text and `reasoning.available` carries the answer
            // itself: neither is reasoning. The working row already says Hermes is working.
            break
        }
    }

    private func applyInfo(_ info: BotJSON) {
        if let model = info["model"].text, !model.isEmpty { delegate?.hermesApplyModel(model) }
        guard let running = info["running"].flag else { return }
        hostRunning = running
        if running {
            let startedAt = info["turn_started_at"].number
            if activeStreamID == nil { hostTurnStartedAt = startedAt }
            else if turnStartedAt == nil, let startedAt { adoptStart(startedAt) }
        } else {
            hostTurnStartedAt = nil
            // A turn begun by a send's reply has not seen its own frames yet, so an idle
            // report then is the one from before it.
            guard pendingEnding != nil || !awaitingStart else { return }
            finish(pendingEnding ?? (stopRequested ? .cancelled : .completed))
        }
    }

    private func complete(_ payload: BotJSON) {
        guard activeStreamID != nil else { return }
        let ending: TranscriptTurnRunOutcome.Ending
        switch payload["status"].text {
        case "interrupted": ending = .cancelled
        case "error": ending = .failed
        default: ending = .completed
        }
        // A failed turn's text is its error unless the host marks it a partial reply.
        if let reply = payload["text"].text, !reply.isEmpty, ending != .failed || payload["partial"].flag == true {
            delegate?.hermesTurnDidComplete(reply: reply)
        }
        if ending == .failed, let message = payload["error"].text ?? payload["text"].text, !message.isEmpty {
            delegate?.streamCoordinatorDidReceiveErrorMessage(message)
        }
        if let usage = Self.contextWindow(payload["usage"]) { delegate?.hermesApplyUsage(usage) }
        pendingEnding = ending
        if !hostRunning { finish(ending) }
    }

    /// Settles the turn against an attach's snapshot, then rebuilds the transcript from it
    /// when frames were lost. Without a rebuild the replay already continued the turn.
    private func reconcile(with snapshot: BotJSON) {
        let running = snapshot["running"].flag ?? snapshot["info"]["running"].flag ?? false
        let startedAt = snapshot["turn_started_at"].number ?? snapshot["inflight"]["started_at"].number
        hostRunning = running
        queuedPrompt = snapshot["queued"]["user"].text.flatMap { $0.isEmpty ? nil : $0 }
        restoreOpenRequests(snapshot["open_requests"])
        if let model = snapshot["info"]["model"].text, !model.isEmpty { delegate?.hermesApplyModel(model) }
        if activeStreamID != nil, !running || (startedAt != nil && turnStartedAt != nil && startedAt != turnStartedAt) {
            // The turn this chat was following ended while it was away.
            let failure = snapshot["inflight"]["error"].text.flatMap { $0.isEmpty ? nil : $0 }
            if let failure { delegate?.streamCoordinatorDidReceiveErrorMessage(failure) }
            finish(pendingEnding ?? (failure != nil ? .failed : stopRequested ? .cancelled : .completed))
        }
        if running, activeStreamID == nil { beginTurn(startedAt: startedAt, prompt: nil) }
        if running, let startedAt, turnStartedAt == nil { adoptStart(startedAt) }
        if engine.replayWasReset || needsRebuild { rebuild(from: snapshot, running: running) }
    }

    /// The transcript from the snapshot's history plus its in-flight turn: the prompt until
    /// the host saves it, and the reply so far, which the next deltas continue. Deltas that
    /// raced the snapshot are deduplicated against that reply.
    private func rebuild(from snapshot: BotJSON, running: Bool) {
        needsRebuild = false
        guard let history = snapshot["messages"].list, snapshot["messages_omitted"].flag != true else { return }
        let root = engine.storedKey ?? ""
        let projected = BotTranscriptProjection.project(history: history, root: root)
        var messages = projected.messages
        let inflight = snapshot["inflight"]
        let startedAt = inflight["started_at"].number ?? snapshot["turn_started_at"].number
        if let prompt = inflight["user"].text, !prompt.isEmpty, !Self.holdsPrompt(prompt, in: messages, startedAt: startedAt) {
            messages.append(ChatMessage(role: "user", content: prompt, timestamp: startedAt, messageId: "\(root)/live-user"))
        }
        var reply: ChatMessage?
        if let text = inflight["assistant"].text, !text.isEmpty {
            let row = ChatMessage(role: "assistant", content: text, timestamp: nil, messageId: "\(root)/live-\(UUID().uuidString)")
            if running { reply = row } else { messages.append(row) }
        }
        let title = snapshot["info"]["title"].text.flatMap { $0.isEmpty ? nil : $0 }
        delegate?.hermesReplaceTranscript(HermesChatTranscript(
            messages: messages,
            toolCallGroups: projected.activity.filter { !$0.toolCalls.isEmpty }.map {
                ToolCallGroup(id: $0.id, anchorMessageID: $0.anchorMessageID, toolCalls: $0.toolCalls)
            },
            reasoningGroups: projected.activity.compactMap { activity in
                activity.reasoning.map { ReasoningGroup(id: activity.id, anchorMessageID: activity.anchorMessageID, text: $0) }
            },
            streamingReply: reply,
            title: title
        ))
        isReplayConnection = reply != nil
    }

    /// Reattaches so the next snapshot replaces the transcript: frames were lost mid-turn.
    private func rebuildAfterGap() {
        needsRebuild = true
        reattach()
    }

    private func reattach() {
        cancelAttach()
        engine.suspend()
        startAttach()
    }

    private func restoreOpenRequests(_ rows: BotJSON) {
        // Resume omits an empty `open_requests`; replay always carries it.
        openRequestIDs = Set((rows.list ?? []).compactMap(BotServerRequest.init)
            .filter { $0.sessionID == engine.runtime }.map(\.id))
    }

    // MARK: Mapping

    /// Whether the snapshot's saved rows already hold the in-flight prompt: the last turn
    /// boundary is dated at or after the turn began, or, undated, carries the same text.
    private static func holdsPrompt(_ prompt: String, in messages: [ChatMessage], startedAt: Double?) -> Bool {
        guard let settled = messages.last(where: BotTranscriptProjection.isTurnBoundary) else { return false }
        guard let startedAt, let stamp = settled.timestamp else { return settled.content == prompt }
        return stamp >= startedAt
    }

    /// A `tool.start` or `tool.complete` as the shared tool row reads it, keyed by `tool_id`.
    private static func toolEvent(_ payload: BotJSON, completed: Bool) -> ToolStreamEvent {
        ToolStreamEvent(
            eventType: completed ? "tool.complete" : "tool.start",
            name: payload["name"].text,
            preview: completed ? BotTurnActivity.resultPreview(payload["result"]) : nil,
            args: payload["args"].argumentDictionary,
            duration: completed ? payload["duration_s"].number : nil,
            isError: nil,
            stableID: payload["tool_id"].text
        )
    }

    /// `usage` as the context indicator reads it; nil without a context window to show.
    static func contextWindow(_ usage: BotJSON) -> ContextWindowSnapshot? {
        guard let used = usage["context_used"].integer, let length = usage["context_max"].integer, length > 0 else { return nil }
        return ContextWindowSnapshot(contextLength: length, thresholdTokens: nil, lastPromptTokens: used,
                                     inputTokens: usage["input"].integer, outputTokens: usage["output"].integer,
                                     estimatedCost: nil)
    }

    /// A host time as a date no later than now, so a skewed clock never counts backwards.
    private static func date(_ seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return min(Date(timeIntervalSince1970: seconds), Date())
    }
}

extension HermesChatTurnCoordinator: ChatTurnCoordinating {
    /// Detached mid-turn: reconnecting, or waiting for the network (#869). Reattaching
    /// reads as checking.
    var recoveryState: ActiveStreamRecoveryState {
        guard activeStreamID != nil, engine.isActive else { return .idle }
        switch engine.connectionState {
        case .connected: return .idle
        case .recovering: return .checking
        case .disconnected: return isNetworkAvailable() ? .reconnecting : .waitingForNetwork
        }
    }
    var liveTokensPerSecond: Double? { nil }
    var hasCompletedCurrentResponse: Bool { false }
    var isConnectionSuspended: Bool { !engine.isActive }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate as? any HermesChatTurnDelegate
    }

    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {}
    func prepareForNewResponse() {}

    /// Leaving or backgrounding drops the socket (#902); the host session keeps running.
    func suspendActiveStreamConnection() {
        cancelAttach()
        engine.suspend()
    }

    func reconnectIfNeeded(modelContext: ModelContext?) async {
        guard !refusedSignIn else { return }
        await activate()
    }

    /// A network that came back retries a waiting reattach now instead of after its backoff.
    func networkPathDidChange(modelContext: ModelContext?) async {
        guard !refusedSignIn, engine.isActive, attaching == nil, engine.connectionState == .disconnected,
              isNetworkAvailable() else { return }
        engine.suspend()
        await startAttach().value
    }

    /// The gateway's ping and call deadlines find a dead socket; nothing to poll here.
    func recoverStaleStreamIfNeeded(now: Date, modelContext: ModelContext?) async {}

    func clearReplayConnection() { isReplayConnection = false }
}

extension HermesChatTurnCoordinator: HermesConversationOwner {
    func conversationDidReset() { openRequestIDs = [] }

    func conversationDidIdentify(root: String) {
        let key = engine.target.draftKey(server: engine.server, connectionID: engine.connection.id)
        guard key != draftKey else { return }
        let previous = draftKey
        draftKey = key
        delegate?.hermesDraftKeyDidChange(from: previous, to: key)
    }

    func conversationDidReplay(_ reply: BotJSON, frames: [BotJSON]) {
        restoreOpenRequests(reply["open_requests"])
        // After lost frames the snapshot that follows rebuilds instead.
        guard !engine.replayWasReset, !needsRebuild else { return }
        frames.forEach(apply)
    }

    func conversationDidReadSnapshot(_ snapshot: BotJSON, runtime: String, attempt: Int) async throws {
        guard engine.isCurrent(snapshot) else { throw BotFailure.unsupported }
        reconcile(with: snapshot)
    }

    func conversationDidConnect(runtime: String, attempt: Int) async throws {
        refusedSignIn = false
        delegate?.hermesConnectionDidChange(failure: nil)
    }

    func conversation(didReceive frame: BotJSON, afterGap: Bool) {
        guard !afterGap else { return rebuildAfterGap() }
        apply(frame)
    }

    func conversationDidLoseFrames() { rebuildAfterGap() }

    func conversation(didReceiveRequest envelope: BotJSON) {
        if let id = envelope["id"].text { openRequestIDs.insert(id) }
    }

    func conversationDidDisconnect(_ failure: BotFailure, retrying: Bool) {
        refusedSignIn = failure == .rejected(401)
        guard !retrying else { return }
        delegate?.hermesConnectionDidChange(failure: BotConnectionAdvice.message(for: failure, address: engine.connection.address))
    }
}
