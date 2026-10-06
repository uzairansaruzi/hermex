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
    /// The host accepted a new session's first prompt: the draft under `from` moves to the
    /// session's key `to`.
    func hermesDraftKeyDidChange(from: ChatDraftKey, to: ChatDraftKey)
    /// The host refused an answer to one of its requests, or a bypass change (#1011).
    func hermesRequestDidFail(_ message: String)
    /// A `/background` task's card changed: started, finished, or its result unavailable (#1013).
    func hermesBackgroundDidChange(_ task: HermesBackgroundTask)
    /// The session's goal, as its control snapshot reports it; nil once cleared (#1013).
    func hermesGoalDidChange(_ goal: SubmittedGoal?)
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
/// new runtime). The engine drops repeated frames by `seq`, so appends never deduplicate
/// by text. Each prompt, steer, redirect and stop is one `write`, never resent; a Send or
/// Queue uploads its staged files first (#1012). The host's requests (approvals,
/// questions, sudo and secret prompts) are `requests` (#1011); the goal, `/btw` and
/// `/background` are `sideTasks` (#1013); its model and Profile chips are `settings` (#1015);
/// its host's slash commands are `slashCommands` (#1036).
///
/// A turn's identity is the stored key and the host's `turn_started_at`, in place of a
/// webui stream id. A turn starts at `message.start`, an accepted send or a running
/// snapshot, and ends once `message.complete` and `session.info {running: false}` have
/// both arrived. An `error` before the turn's `message.start` ends it at once; after it,
/// an `error` with no completion ends it failed when the host settles.
///
/// Each turn drives the shared Live Activity at the same points (#1014), under the interim
/// key `hermes:<profile>:<stored key>`, with no push and no tap destination until #706.
@MainActor @Observable final class HermesChatTurnCoordinator {
    let engine: HermesConversation
    @ObservationIgnored private weak var delegate: (any HermesChatTurnDelegate)?

    private(set) var activeStreamID: String?
    private(set) var activeRunStartedAt: Date?
    private(set) var latestRunEnding: ChatRunEnding?
    private(set) var successfulResponseCompletion: ChatStreamCoordinator.SuccessfulResponseCompletion?
    /// The prompt the host holds for its next turn: one slot, merged as the host merges
    /// text-only prompts. Restored from the snapshot's `queued`; a Stop discards it.
    private(set) var queuedPrompt: String?
    /// Host requests open on this runtime (#1011): an approval, a question, a credential prompt.
    let requests: HermesChatRequests
    /// The session's goal, `/btw` question and `/background` tasks (#1013).
    let sideTasks: HermesChatSideTasks
    /// The composer's model and Profile chips (#1015).
    let settings: HermesChatSettings
    /// The host's slash commands, for the composer's panel and send path (#1036).
    let slashCommands: HermesSlashCommands

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
    /// This runtime's frames the engine held during the attach, in arrival order.
    @ObservationIgnored private var heldFrames: [BotJSON] = []
    /// The running reply's text a rebuilding attach's replay carried, up to its
    /// `latest_seq`: the snapshot's reply holds it, just before any deltas that raced it.
    @ObservationIgnored private var replayedReply = ""
    /// The `seq`s of held deltas a rebuilt reply already holds: dropped on release.
    @ObservationIgnored private var deltasInRebuild: Set<Int> = []
    /// The host accepted a prompt on this chat; until then a new session's draft keeps the
    /// new-session key.
    @ObservationIgnored private var promptAccepted = false
    @ObservationIgnored private var attaching: Task<Void, Never>?
    @ObservationIgnored private var attachGeneration = 0
    /// The host refused the saved sign-in: nothing reattaches on its own until the chat
    /// asks again, so the refused password is not sent again unasked (#884).
    @ObservationIgnored private var refusedSignIn = false
    @ObservationIgnored private var draftKey: ChatDraftKey
    private let isNetworkAvailable: @MainActor () -> Bool
    /// The shared Live Activity manager this chat's turns drive (#1014); nil drives none.
    @ObservationIgnored private let liveActivities: (any AgentLiveActivityManaging)?
    /// The running turn's activity: its session key and stream id, the host's
    /// `turn_started_at`, or this chat's own id when the turn began without one. Kept for
    /// the turn, so a reattach adopts the same activity.
    @ObservationIgnored private var liveActivity: (sessionID: String, streamID: String)?
    @ObservationIgnored private var showsLiveActivityExcerpts = false
    /// The waiting state last shown for the open requests, so each change is written once.
    @ObservationIgnored private var shownWaiting: AgentLiveActivityEvent?

    init(engine: HermesConversation, liveActivities: (any AgentLiveActivityManaging)? = nil,
         isNetworkAvailable: @escaping @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied }) {
        self.engine = engine
        self.liveActivities = liveActivities
        self.isNetworkAvailable = isNetworkAvailable
        requests = HermesChatRequests(engine: engine)
        sideTasks = HermesChatSideTasks(engine: engine)
        settings = HermesChatSettings(engine: engine)
        slashCommands = HermesSlashCommands(engine: engine)
        draftKey = engine.target.draftKey(server: engine.server, connectionID: engine.connection.id)
        engine.owner = self
        requests.onOpenChange = { [weak self] in self?.syncLiveActivityWaiting() }
        requests.onFailure = { [weak self] in self?.delegate?.hermesRequestDidFail($0) }
        requests.onNeedsReattach = { [weak self] in self?.reattach() }
        sideTasks.onNeedsReattach = { [weak self] in self?.reattach() }
        slashCommands.onNeedsReattach = { [weak self] in self?.reattach() }
        sideTasks.onBackgroundChange = { [weak self] in self?.delegate?.hermesBackgroundDidChange($0) }
        sideTasks.onGoalChange = { [weak self] in self?.delegate?.hermesGoalDidChange($0) }
    }

    /// A chat on `target` over the connection's shared gateway socket, driving the app's
    /// Live Activity.
    convenience init(server: URL, connection: BotConnection, target: ConversationTarget) {
        self.init(engine: HermesConversation(server: server, connection: connection, target: target,
                                             wire: BotClient(saved: connection, server: server)),
                  liveActivities: AgentLiveActivityManager.shared)
    }

    /// The composer draft's key: a new session's stays the new-session key until the host
    /// accepts its first prompt.
    var currentDraftKey: ChatDraftKey { draftKey }

    /// Stop asks first only when it would lose something: the host's queued prompt, or a
    /// request (an approval the stop denies).
    var stopNeedsConfirmation: Bool { queuedPrompt != nil || requests.isWaiting }

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

    /// A prompt that never reached the socket: not attached, the attach changed first, or
    /// one of its files failed to upload or was cancelled (`duringUpload`).
    struct NotSent: Error {
        let underlying: Error
        var duringUpload = false
    }

    /// A staged file a Send or Queue uploads ahead of its prompt (#1012). Its local copy is
    /// read only then.
    struct OutgoingAttachment {
        let name: String
        let mime: String
        let isImage: Bool
        let data: () async throws -> Data
    }

    /// A send is uploading its files; `cancelAttachmentUpload()` stops it.
    private(set) var isUploadingAttachments = false
    @ObservationIgnored private var attachmentUpload: Task<[String], Error>?

    /// Sends `text` in `mode` on the attached runtime, attaching first if the chat has not.
    /// `attachments` (Send and Queue only) upload first on that attach and runtime, and
    /// their references follow the text; `beforePrompt` runs after the last upload, just
    /// before the prompt goes out. Returns what the host said; throws `NotSent` when it
    /// never went out, and the failure itself when its reply was refused or lost. Never
    /// resent: after a lost reply the next snapshot says what happened.
    func submit(_ text: String, mode: BotPromptMode, attachments: [OutgoingAttachment] = [],
                beforePrompt: () async throws -> Void = {}) async throws -> BotPromptOutcome {
        await activate()
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw NotSent(underlying: BotFailure.transport)
        }
        // Only a fresh turn takes files (`docs/agents/bots.md`); the chat never offers more.
        guard attachments.isEmpty || mode.startsTurn else { throw NotSent(underlying: BotFailure.unsupported) }
        let attempt = engine.generation
        let references: [String]
        do {
            references = try await upload(attachments, runtime: runtime, attempt: attempt)
        } catch {
            throw NotSent(underlying: error, duringUpload: true)
        }
        do { try await beforePrompt() } catch { throw NotSent(underlying: error) }
        let prompt = ([text] + references).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let startsBefore = turnsStarted
        if mode == .send { isSubmittingSend = true }
        // As in Bot Chat, a stop withdrawal while Stop & send is in flight is this phone's doing.
        if mode == .redirect { requests.isStoppingHere = true }
        defer {
            if mode == .send { isSubmittingSend = false }
            if mode == .redirect { requests.isStoppingHere = false }
        }
        var dispatched = false
        let reply: BotJSON
        do {
            reply = try await engine.write(mode.call(runtime: runtime, text: prompt), attempt: attempt,
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
            queuedPrompt = queuedPrompt.map { "\($0)\n\n\(prompt)" } ?? prompt
        case .guidanceQueued, .redirected, .voiceStopped:
            // None of these withdraws a request: a redirect while a tool waits on one only
            // steers, and a stop phrase ends voice mode. The host's `request.cancel` says
            // what it withdrew.
            break
        case .rejected, .unknown:
            return outcome
        }
        requests.promptAccepted()
        acceptPrompt()
        return outcome
    }

    /// Uploads a send's files in order on the attach and runtime it captured, as Bot Chat
    /// does (`docs/agents/bots.md` § attachments), and returns their references: an
    /// image's vision-tool line pair after image-upload, a document's `file.attach`
    /// `ref_text` verbatim. The first failure, a cancel or a reattach ends it, so a
    /// partial set is never submitted. Files already stored stay on the host.
    private func upload(_ attachments: [OutgoingAttachment], runtime: String, attempt: Int) async throws -> [String] {
        guard !attachments.isEmpty else { return [] }
        guard let key = engine.storedKey else { throw BotFailure.stale }
        let context = BotArtifactContext(connectionID: engine.connection.id, profile: engine.target.profile,
                                         sessionID: key, generation: attempt)
        let task = Task { [engine] in
            var references: [String] = []
            for attachment in attachments {
                try engine.check(attempt)
                let data = try await attachment.data()
                try engine.check(attempt)
                if attachment.isImage {
                    let path = try await engine.wire.uploadImage(data: data, filename: attachment.name, context: context)
                    references.append(BotAttachmentUpload.imageReference(path: try BotAttachmentUpload.verifiedPath(path)))
                } else {
                    let call = await BotAttachmentUpload.fileAttach(data: data, runtime: runtime,
                                                                    filename: attachment.name, mime: attachment.mime)
                    let reply = try await engine.write(call, attempt: attempt, runtime: runtime)
                    guard reply["attached"].flag == true, let ref = reply["ref_text"].text, ref.hasPrefix("@file:"),
                          !ref.contains("\n"), !ref.contains("\r") else { throw BotFailure.unsupported }
                    _ = try BotAttachmentUpload.verifiedPath(reply["path"].text)
                    references.append(ref)
                }
            }
            try engine.check(attempt)
            return references
        }
        attachmentUpload = task
        isUploadingAttachments = true
        defer { attachmentUpload = nil; isUploadingAttachments = false }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            // However the cancelled request ended (a `URLError`, a stale check), it was a cancel.
            throw task.isCancelled ? CancellationError() : error
        }
    }

    /// Stops a send's uploads: its prompt is not submitted, and the draft keeps its files.
    func cancelAttachmentUpload() { attachmentUpload?.cancel() }

    /// A sent file's bytes from the host, by the path its chip keeps (#1030), for the chip's
    /// thumbnail and preview. Downloads through this attach as Bot Chat does
    /// (`HermesREST.downloadArtifact` with the session's Profile and stored key), so the
    /// host resolves a relative `@file:` path against the session. Throws `.stale` while
    /// detached, and for a result that lands after a reattach or a cancel.
    func attachmentData(path: String) async throws -> Data {
        guard engine.connectionState == .connected, let key = engine.storedKey else { throw BotFailure.stale }
        let attempt = engine.generation
        let context = BotArtifactContext(connectionID: engine.connection.id, profile: engine.target.profile,
                                         sessionID: key, generation: attempt)
        let data = try await engine.wire.artifactData(path: path, context: context)
        try engine.check(attempt)
        return data
    }

    /// Keys this session's thumbnails in the process-wide `TranscriptImageCache`: its
    /// connection, Profile and stored key, so no other connection, Profile or session
    /// ever shows them.
    var attachmentCacheNamespace: String {
        "hermes|\(engine.connection.id.uuidString)|\(engine.target.profile)|\(engine.storedKey ?? "")"
    }

    /// A prompt's answer was lost or unreadable: reattach and rebuild, so the snapshot shows
    /// whether it ran (#508). Nothing is resent. A chat already left attaches when it reopens.
    func recoverAfterLostAnswer() {
        guard engine.isActive else { return }
        rebuildAfterGap()
    }

    /// The host's first accepted prompt moves a new session's draft to the session's key.
    /// Before that it keeps the new-session key: the host keeps no row for a session with
    /// no prompt and reaps it, and nothing reopens it, so a draft typed before leaving
    /// waits for the next New Session.
    private func acceptPrompt() {
        guard !promptAccepted else { return }
        promptAccepted = true
        let key = engine.target.draftKey(server: engine.server, connectionID: engine.connection.id)
        guard key != draftKey else { return }
        let previous = draftKey
        draftKey = key
        delegate?.hermesDraftKeyDidChange(from: previous, to: key)
    }

    /// Stops the running turn (`session.interrupt`); false when there is none or a stop is
    /// already in. The host also discards its queued prompt, withdraws open requests and
    /// denies pending approvals. Idle still waits for the turn's own ending frames.
    func interrupt() async throws -> Bool {
        guard activeStreamID != nil, !stopRequested else { return false }
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.transport }
        stopRequested = true
        requests.isStoppingHere = true
        defer { requests.isStoppingHere = false }
        do {
            _ = try await engine.write(.sessionInterrupt(sessionID: runtime), attempt: engine.generation, runtime: runtime)
        } catch {
            stopRequested = false
            throw error
        }
        queuedPrompt = nil
        requests.withdrawAll()
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
        liveActivity = engine.storedKey.map { key in
            (sessionID: "\(AgentRunTapTarget.hermesSessionPrefix)\(engine.target.profile):\(key)",
             streamID: startedAt.map { String($0) } ?? UUID().uuidString)
        }
        startLiveActivity()
    }

    private func ensureTurn() {
        if activeStreamID == nil { beginTurn(startedAt: hostTurnStartedAt, prompt: nil) }
    }

    /// Ends the running turn the way the webui path ends a stream, so the chat records the
    /// same outcome, haptic and alert.
    private func finish(_ ending: TranscriptTurnRunOutcome.Ending) {
        guard let streamID = activeStreamID else { return }
        endLiveActivity(ending)
        liveActivity = nil
        latestRunEnding = ChatRunEnding(startedAt: activeRunStartedAt ?? Date(), endedAt: Date(), ending: ending)
        if ending == .completed {
            successfulResponseCompletion = .init(streamID: streamID, needsTranscriptRefresh: false)
            delegate?.streamCoordinatorApplyDone(DoneStreamEvent())
        }
        activeStreamID = nil; activeRunStartedAt = nil
        turnStartedAt = nil; pendingEnding = nil; awaitingStart = false; stopRequested = false
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

    /// The session's title from the host: the chat shows it, and so does the turn's activity.
    private func applyTitle(_ title: String) {
        guard delegate?.streamCoordinatorUpdateTitle(TitleStreamEvent(sessionId: nil, title: title)) == true,
              let shown = delegate?.streamCoordinatorDisplayTitle else { return }
        drivenLiveActivity?.update(.sessionTitle(shown))
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
            if let seq = frame["seq"].integer, deltasInRebuild.remove(seq) != nil { return }
            guard let text = payload["text"].text, !text.isEmpty else { return }
            ensureTurn()
            // With excerpts off the status still moves on to writing, off a wait the user
            // answered, as in Bot Chat (#489).
            drivenLiveActivity?.update(showsLiveActivityExcerpts ? .token(text) : .responding)
            delegate?.streamCoordinatorAppendToken(text)
        case "message.interim":
            ensureTurn()
            let interim = InterimAssistantStreamEvent(text: payload["text"].text, alreadyStreamed: payload["already_streamed"].flag)
            if showsLiveActivityExcerpts, interim.alreadyStreamed != true, let text = interim.text {
                drivenLiveActivity?.update(.interimAssistant(text))
            }
            delegate?.streamCoordinatorAppendInterimAssistant(interim)
        case "reasoning.delta":
            guard let text = payload["text"].text, !text.isEmpty else { return }
            ensureTurn()
            drivenLiveActivity?.update(.reasoning(text))
            delegate?.streamCoordinatorAppendReasoning(text)
        case "tool.start":
            ensureTurn()
            let tool = Self.toolEvent(payload, completed: false)
            drivenLiveActivity?.update(.toolStarted(name: tool.name))
            delegate?.streamCoordinatorAppendToolCall(tool)
        case "tool.complete":
            ensureTurn()
            drivenLiveActivity?.update(.toolCompleted)
            delegate?.streamCoordinatorCompleteToolCall(Self.toolEvent(payload, completed: true))
        case "session.title":
            // A suggestion for this session's title; the chat shows it and renames nothing.
            if let key = payload["session_id"].text, key != engine.storedKey { return }
            guard let title = payload["title"].text, !title.isEmpty else { return }
            applyTitle(title)
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
            // After the turn's own `message.start` an error can be a warning the turn goes on
            // past, such as a model switch that failed, and the host always settles the turn
            // with `session.info {running: false}`: it fails then unless a completion came.
            // Before it, as when the host refuses the turn, nothing else follows.
            if activeStreamID != nil, !awaitingStart {
                pendingEnding = pendingEnding ?? .failed
            } else {
                finish(.failed)
            }
        case "request.cancel":
            requests.cancel(payload)
        case "btw.complete", "background.complete", "session.control.update":
            sideTasks.receive(frame)
        default:
            // `thinking.delta` is spinner text and `reasoning.available` carries the answer
            // itself: neither is reasoning. The working row already says Hermes is working.
            break
        }
    }

    private func applyInfo(_ info: BotJSON) {
        if let model = info["model"].text, !model.isEmpty { delegate?.hermesApplyModel(model) }
        requests.applyBypass(info)
        settings.apply(info: info, idle: info["running"].flag.map { !$0 } ?? !hostRunning)
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
        if ending == .cancelled {
            // A stop from any client discards the host's queued prompt and withdraws its
            // requests, so a receipt for this chat's queued prompt would never send.
            queuedPrompt = nil
            requests.withdrawAll()
        }
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
        requests.didReadSnapshot(snapshot)
        if let model = snapshot["info"]["model"].text, !model.isEmpty { delegate?.hermesApplyModel(model) }
        // Ahead of the turn below, so its Live Activity starts under the session's title.
        if let title = snapshot["info"]["title"].text, !title.isEmpty { applyTitle(title) }
        if activeStreamID != nil, !running || (startedAt != nil && turnStartedAt != nil && startedAt != turnStartedAt) {
            // The turn this chat was following ended while it was away.
            let failure = snapshot["inflight"]["error"].text.flatMap { $0.isEmpty ? nil : $0 }
            if let failure { delegate?.streamCoordinatorDidReceiveErrorMessage(failure) }
            finish(pendingEnding ?? (failure != nil ? .failed : stopRequested ? .cancelled : .completed))
        }
        let continuing = running && activeStreamID != nil
        if running, activeStreamID == nil { beginTurn(startedAt: startedAt, prompt: nil) }
        if running, let startedAt, turnStartedAt == nil { adoptStart(startedAt) }
        // The same turn after a reattach: adopt its activity again, which is current once more.
        if continuing { startLiveActivity() }
        if engine.replayWasReset || needsRebuild { rebuild(from: snapshot, running: running) }
    }

    /// The transcript from the snapshot's history plus its in-flight turn: the prompt until
    /// the host saves it, and the reply so far, which the next deltas continue. Held deltas
    /// that reply already holds are dropped when the engine releases them.
    private func rebuild(from snapshot: BotJSON, running: Bool) {
        needsRebuild = false
        guard let history = snapshot["messages"].list, snapshot["messages_omitted"].flag != true else { return }
        let root = engine.storedKey ?? ""
        let projected = BotTranscriptProjection.project(history: history, root: root)
        var messages = projected.messages.map(Self.displayed)
        let inflight = snapshot["inflight"]
        let startedAt = inflight["started_at"].number ?? snapshot["turn_started_at"].number
        if let text = inflight["user"].text, !text.isEmpty {
            let prompt = Self.displayed(ChatMessage(role: "user", content: text, timestamp: startedAt, messageId: "\(root)/live-user"))
            if !Self.holdsPrompt(prompt, in: messages, startedAt: startedAt) { messages.append(prompt) }
        }
        var reply: ChatMessage?
        if let text = inflight["assistant"].text, !text.isEmpty {
            let row = ChatMessage(role: "assistant", content: text, timestamp: nil, messageId: "\(root)/live-\(UUID().uuidString)")
            if running { reply = row } else { messages.append(row) }
            deltasInRebuild = Self.heldDeltas(heldFrames, after: engine.sequence, alreadyIn: text, following: replayedReply)
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
    }

    /// Reattaches so the next snapshot replaces the transcript: frames were lost mid-turn.
    private func rebuildAfterGap() {
        needsRebuild = true
        reattach()
    }

    private func reattach() {
        requests.willLeave()
        cancelAttach()
        engine.suspend()
        startAttach()
    }

    // MARK: Live Activity

    /// The manager while it still drives this turn's activity. One a webui run or a bot took
    /// over is never touched, as in Bot Chat (`BotLiveActivityFeed`).
    private var drivenLiveActivity: (any AgentLiveActivityManaging)? {
        guard let liveActivities, let id = liveActivity?.sessionID, liveActivities.drivenSessionID == id else { return nil }
        return liveActivities
    }

    /// Starts the turn's activity, or adopts it again: the manager reuses the activity of the
    /// same session key and stream id. An open request then shows as waiting.
    private func startLiveActivity() {
        guard let liveActivities, let liveActivity else { return }
        liveActivities.start(sessionID: liveActivity.sessionID, server: engine.server,
                             sessionTitle: delegate?.streamCoordinatorDisplayTitle ?? String(localized: "Untitled Session"),
                             streamID: liveActivity.streamID, startedAt: activeRunStartedAt ?? Date())
        shownWaiting = nil
        syncLiveActivityWaiting()
    }

    /// Shows the open requests as waiting, once per change: an approval on screen as an
    /// approval, any other request as a question, as Bot Chat does. Answering moves nothing;
    /// the turn's next work does.
    private func syncLiveActivityWaiting() {
        let waiting: AgentLiveActivityEvent?
        if !requests.isWaiting { waiting = nil }
        else if case .approval? = requests.onScreen { waiting = .waitingForApproval }
        else { waiting = .waitingForClarification }
        guard waiting != shownWaiting else { return }
        shownWaiting = waiting
        if let waiting { drivenLiveActivity?.update(waiting) }
    }

    private func endLiveActivity(_ ending: TranscriptTurnRunOutcome.Ending) {
        switch ending {
        case .completed:
            drivenLiveActivity?.end(status: .complete, activity: String(localized: "Response complete"), errorSummary: nil)
        case .cancelled:
            drivenLiveActivity?.end(status: .cancelled, activity: String(localized: "Response cancelled"), errorSummary: nil)
        case .failed:
            drivenLiveActivity?.end(status: .failed, activity: String(localized: "Response failed"), errorSummary: nil)
        }
    }

    // MARK: Mapping

    /// The held deltas, after the replay's `sequence`, that a snapshot's reply text already
    /// holds. The host appends each delta to the in-flight reply before it emits the frame,
    /// so deltas emitted while the snapshot was read are in its text and held too. They are
    /// the turn's first held deltas, before any `message.start`, and match whole: the
    /// longest run of them that, after `replayed` (the reply text the replay carried), ends
    /// the reply. The snapshot has no `seq`, so only text that repeats itself across that
    /// boundary stays ambiguous.
    private static func heldDeltas(_ held: [BotJSON], after sequence: Int, alreadyIn reply: String,
                                   following replayed: String) -> Set<Int> {
        var cursor = sequence, joined = replayed, run: [Int] = [], matched: [Int] = []
        for frame in held {
            guard let seq = frame["seq"].integer, seq > cursor else { continue }
            cursor = seq
            let type = frame["type"].text
            if type == "message.start" { break }
            guard type == "message.delta", let text = frame["payload"]["text"].text, !text.isEmpty else { continue }
            joined += text
            guard joined.utf8.count <= reply.utf8.count else { break }
            run.append(seq)
            if reply.utf8.suffix(joined.utf8.count).elementsEqual(joined.utf8) { matched = run }
        }
        return Set(matched)
    }

    /// The reply text a run of frames ends with: its deltas after the last `message.start`.
    private static func replyText(_ frames: [BotJSON]) -> String {
        let start = frames.lastIndex { $0["type"].text == "message.start" }.map { $0 + 1 } ?? frames.startIndex
        return frames[start...].reduce(into: "") { text, frame in
            if frame["type"].text == "message.delta" { text += frame["payload"]["text"].text ?? "" }
        }
    }

    /// Whether the snapshot's saved rows already hold the in-flight prompt: the last turn
    /// boundary is dated at or after the turn began, or, undated, shows the same.
    private static func holdsPrompt(_ prompt: ChatMessage, in messages: [ChatMessage], startedAt: Double?) -> Bool {
        guard let settled = messages.last(where: BotTranscriptProjection.isTurnBoundary) else { return false }
        guard let startedAt, let stamp = settled.timestamp else {
            return settled.content == prompt.content && settled.attachments == prompt.attachments
        }
        return stamp >= startedAt
    }

    /// A user row as a Hermes session's transcript shows it (#1012): the reference lines a
    /// Hermex send appends become chips and the host's context footer goes
    /// (`MessageAttachment.hermesReferences`), so the text shows no host path. Each chip
    /// keeps the path it names for `attachmentData` (#1030); chips show only their name.
    /// Every other row is returned as it is. Bot Chat reads the rule itself.
    static func displayed(_ message: ChatMessage) -> ChatMessage {
        guard message.role == "user", let content = message.content else { return message }
        let shown = MessageAttachment.hermesReferences(in: content)
        guard shown.text != content || !shown.attachments.isEmpty else { return message }
        let chips = shown.attachments
        return ChatMessage(
            role: message.role, content: shown.text, timestamp: message.timestamp, messageId: message.messageId,
            name: message.name, toolCallId: message.toolCallId, toolUseId: message.toolUseId,
            toolCalls: message.toolCalls, contentParts: message.contentParts, reasoning: message.reasoning,
            attachments: chips.isEmpty ? message.attachments : (message.attachments ?? []) + chips,
            displayKind: message.displayKind, displayMetadata: message.displayMetadata, turnTps: message.turnTps,
            turnDuration: message.turnDuration, rowID: message.rowID
        )
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
    /// Never: the engine drops repeated frames by `seq`, and a rebuild drops the held deltas
    /// its snapshot holds, so the webui text matcher stays off.
    var isReplayConnection: Bool { false }

    func attach(delegate: any ChatStreamCoordinatorDelegate) {
        self.delegate = delegate as? any HermesChatTurnDelegate
    }

    /// Reply text reaches the Live Activity only while excerpts are on; turning them off
    /// clears what it shows.
    func setShowsLiveActivityResponseExcerpts(_ shows: Bool) {
        guard showsLiveActivityExcerpts != shows else { return }
        showsLiveActivityExcerpts = shows
        if !shows { drivenLiveActivity?.update(.clearResponseExcerpt) }
    }

    func prepareForNewResponse() {}

    /// Leaving or backgrounding drops the socket (#902); the host session keeps running, and
    /// its activity is no longer current until a reattach adopts it.
    func suspendActiveStreamConnection() {
        drivenLiveActivity?.markStale()
        requests.willLeave()
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

    func clearReplayConnection() {}
}

extension HermesChatTurnCoordinator: HermesConversationOwner {
    func conversationDidReset() {
        requests.reset()
        settings.disconnect()
        heldFrames = []; deltasInRebuild = []; replayedReply = ""
    }

    func conversationWillReplay(newRuntime: Bool) {
        requests.willReplay()
    }

    func conversationDidReplay(_ reply: BotJSON, frames: [BotJSON]) {
        requests.didReplay(reply, frames: frames)
        defer { requests.willReadSnapshot() }
        let lostFrames = engine.replayWasReset || needsRebuild
        sideTasks.didReplay(frames, lostFrames: lostFrames)
        // After lost frames the snapshot that follows rebuilds instead, and what the replay
        // carried of the running reply places the deltas that raced it.
        guard !lostFrames else {
            replayedReply = Self.replyText(frames)
            return
        }
        frames.forEach(apply)
    }

    func conversationDidReadSnapshot(_ snapshot: BotJSON, runtime: String, attempt: Int) async throws {
        guard engine.isCurrent(snapshot) else { throw BotFailure.unsupported }
        reconcile(with: snapshot)
    }

    func conversationDidConnect(runtime: String, attempt: Int) async throws {
        // The engine released the held frames just before this.
        heldFrames = []; deltasInRebuild = []; replayedReply = ""
        refusedSignIn = false
        delegate?.hermesConnectionDidChange(failure: nil)
        sideTasks.didConnect(runtime: runtime, attempt: attempt)
        // Off the attach's path: the chips and the `/` panel fill in once their catalogs answer.
        Task { [settings] in await settings.connect(runtime: runtime, attempt: attempt) }
        Task { [slashCommands] in await slashCommands.connect(runtime: runtime, attempt: attempt) }
    }

    func conversation(didReceive frame: BotJSON, afterGap: Bool) {
        guard !afterGap else {
            // A side frame needs no order: it applies before the rebuild the gap asks for.
            sideTasks.receive(frame)
            return rebuildAfterGap()
        }
        apply(frame)
    }

    func conversationDidLoseFrames() { rebuildAfterGap() }

    /// Frames past the engine's hold are lost, and the release rebuilds again. A held
    /// `request.cancel` is newer than the `open_requests` the attach is reading.
    func conversation(didHold frame: BotJSON) {
        if heldFrames.count < HermesConversation.heldFrameLimit { heldFrames.append(frame) }
        if frame["type"].text == "request.cancel" { requests.holdCancel() }
    }

    func conversation(didReceiveRequest envelope: BotJSON) {
        requests.receive(envelope)
    }

    func conversationWillDisconnect() {
        requests.willLeave()
    }

    func conversationDidDisconnect(_ failure: BotFailure, retrying: Bool) {
        drivenLiveActivity?.markStale()
        refusedSignIn = failure == .rejected(401)
        guard !retrying else { return }
        delegate?.hermesConnectionDidChange(failure: BotConnectionAdvice.message(for: failure, address: engine.connection.address))
    }
}
