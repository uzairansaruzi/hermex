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
    /// Replaces the transcript with the settled history and the in-flight turn.
    func hermesReplaceTranscript(_ transcript: HermesChatTranscript)
    /// Puts an older page of settled history in front (#1047). The rows on screen and the
    /// running turn stay as they are.
    func hermesPrependHistory(_ transcript: HermesChatTranscript)
    /// A history read failed with `error`: the transcript keeps what it shows, and the chat says
    /// why in `message` (#1047), or, with nothing on screen and the host out of reach, shows the
    /// offline cache's copy (#1054).
    func hermesHistoryDidFail(_ error: Error, message: String)
    /// An attach failed with `error`; the engine may be retrying. A host it can't reach shows
    /// the offline cache's copy (#1054).
    func hermesAttachDidFail(_ error: Error)
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
    /// `session.info` named another working folder or terminal backend, such as after a Move to
    /// Project: every `@path` found in the old one no longer means anything (#1113).
    func hermesWorkspaceDidChange()
}

/// A Hermes session the main chat opens: the server, its saved connection and the target.
/// Each value is its own chat, so opening "New Session" twice pushes two.
struct HermesSessionChat: Hashable, Identifiable {
    let id = UUID()
    let server: URL
    let connection: BotConnection
    let target: ConversationTarget
    /// The session the row this chat opened from names as its parent (`parent_session_id`): the
    /// chat asks the host whether it is a branch of it, for its "Forked from" row (#1051). Nil
    /// asks nothing.
    var parentKey: String? = nil

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A Hermes session's transcript: its settled history from REST pages (#1047), and the
/// in-flight turn a `session.resume` reports.
struct HermesChatTranscript: Equatable {
    /// The settled rows, each with the host's `rowID`.
    var messages: [ChatMessage]
    var toolCallGroups: [ToolCallGroup]
    var reasoningGroups: [ReasoningGroup]
    var compaction: HermesCompaction?
    /// Earlier pages remain on the host.
    var hasOlder = false
    /// The in-flight turn's rows the host has not saved: its prompt, and the reply of a turn
    /// that ended while away.
    var live: [ChatMessage] = []
    /// The running turn's unsaved reply, which the next deltas continue.
    var streamingReply: ChatMessage?
    var title: String?
    /// What the last newest read covered, for the offline cache (#1054).
    var newestCoverage: HermesNewestCoverage?
}

/// Runs a Hermes session's turns in the main chat (#1010). It owns the session's
/// `HermesConversation`, which attaches, replays and reconnects, and reduces the engine's
/// ordered frames onto the chat's `ChatStreamCoordinatorDelegate`, so message building,
/// pacing and run endings are the webui path's. Text is delta-driven. Settled history comes
/// from REST transcript pages (#1047), 100 rows at a time, newest first: an attach's rebuild
/// signal (a gap, a reset replay, a new runtime) re-reads the newest rows, back to the rows
/// held, and lays the snapshot's in-flight turn after them, and a turn the host saved in full
/// re-reads them so its rows take their durable ids. The engine drops repeated frames by
/// `seq`, so appends never deduplicate by text. Each prompt, steer, redirect and stop is one
/// `write`, never resent; a Send or Queue uploads its staged files first (#1012). The host's
/// requests (approvals, questions, sudo and secret prompts) are `requests` (#1011); the goal,
/// `/btw` and `/background` are `sideTasks` (#1013); its model and Profile chips are
/// `settings` (#1015); its host's slash commands are `slashCommands` (#1036). Edit,
/// Regenerate, `/retry` and `/undo` cut the host's history (`rewind`, `undo`; #1049), and
/// `/compress` compacts it (`compress`; #1050).
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
    /// The last title `session.info` reported, so a repeat leaves the header alone.
    @ObservationIgnored private var infoTitle: String?
    /// The session's working folder, as the latest `session.info` or attach reports it.
    /// `/clear` starts its new chat there (#1050); Files reads it (#1112). A Move to Project
    /// changes it.
    private(set) var cwd: String?
    /// The terminal backend the session runs commands on (`local`, `docker`, …), as the same
    /// reports name it (#1112).
    private(set) var terminalBackend: String?
    /// The session's model and provider, as the latest `session.info` or attach reports them:
    /// `/clear`'s new chat takes it while the model chip has no choice to offer (#1050).
    @ObservationIgnored private(set) var reportedModel: HermesCall.Model?
    /// A `/compress` the compute host answered `pending`: its `status.update {kind:
    /// "compacted"}` re-reads the history, and until then a rebuild starts it again (#1050).
    @ObservationIgnored private var compactionPending = false
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
    /// The settled history read so far (#1047).
    @ObservationIgnored private var history = HermesTranscriptHistory()
    /// Why the last newest read failed, until one succeeds.
    @ObservationIgnored private var historyFailure: Error?
    /// `turnsStarted` when the history last took the newest rows: a turn since then saved rows
    /// it does not hold, which shift every older page.
    @ObservationIgnored private var historyTurns = 0
    /// The running turn's rows as `message.complete`'s `persisted_turn` names them, when the
    /// host saved all of them.
    @ObservationIgnored private var savedTurn: SavedTurn?
    @ObservationIgnored private var historyRefresh: Task<Void, Never>?
    /// Sends between their call and the host's answer: a page must not replace the
    /// transcript under a prompt the chat already shows.
    @ObservationIgnored private var submitsInFlight = 0
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

    /// A branch's row is no longer in the history, so it can't be counted to (#1051).
    struct BranchRowGone: Error {}
    /// The session continues an earlier one, a legacy compression segment or a reset
    /// continuation, so the host counts that one's rows first, which this chat never reads,
    /// and a fork could not end at a row (#1051).
    struct BranchContinuesEarlierSession: Error {}

    /// The rows the host saved for a turn, from `message.complete`'s `persisted_turn`.
    struct SavedTurn: Equatable {
        let promptRowID: Int?
        let replyRowID: Int
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
        submitsInFlight += 1
        defer { submitsInFlight -= 1 }
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
    /// detached, and for a result that lands after a reattach or a cancel. `limit` caps a
    /// preview at 25 MB; a MEDIA file's export passes nil for the whole file (#1112).
    func attachmentData(path: String, limit: Int? = BotArtifactBuffer.maximumBytes) async throws -> Data {
        guard engine.connectionState == .connected, let key = engine.storedKey else { throw BotFailure.stale }
        let attempt = engine.generation
        let context = BotArtifactContext(connectionID: engine.connection.id, profile: engine.target.profile,
                                         sessionID: key, generation: attempt)
        let data = try await engine.wire.artifactData(path: path, context: context, limit: limit)
        try engine.check(attempt)
        return data
    }

    /// This chat's working folder on its host (#1112), once the session has a stored key and
    /// `session.info` has named its folder; nil before.
    var workspace: HermesWorkspaceContext? {
        guard let cwd, let key = engine.storedKey else { return nil }
        return HermesWorkspaceContext(server: engine.server, profile: engine.target.profile, storedKey: key,
                                      cwd: cwd, terminalBackend: terminalBackend)
    }

    /// `workspace`'s files, on this chat's connection, whatever its backend: MEDIA references
    /// read through it, and Files and file links only on a local backend
    /// (`HermesWorkspaceContext.isLocal`).
    var workspaceFiles: HermesWorkspaceFileClient? {
        guard let workspace, let http = (engine.wire as? BotClient)?.http else { return nil }
        return HermesWorkspaceFileClient(context: workspace, http: http)
    }

    /// The repository holding `workspace` (#1114), on this chat's connection, its commit messages
    /// written on this chat's model and its writes owned by this chat (#1115,
    /// `gitWriteDispatch`). `showsCachedData` is the screen's cached-data state, which also stops
    /// a write. Git reads it only on a local backend, as Files does.
    func workspaceGit(showsCachedData: @escaping @MainActor @Sendable () -> Bool) -> HermesGitClient? {
        guard let workspace, let http = (engine.wire as? BotClient)?.http else { return nil }
        return HermesGitClient(context: workspace, http: http, writeMessage: { [weak self] diff, recent, avoid in
            guard let self else { throw BotFailure.stale }
            return try await self.commitMessage(diff: diff, recent: recent, avoid: avoid)
        }, writeOwner: { [weak self] in
            guard let self else { throw BotFailure.stale }
            return try self.gitWriteDispatch(in: workspace, showsCachedData: showsCachedData)
        })
    }

    /// `HermesGitClient.WriteOwner` for a repository client made for `workspace`: the check a
    /// write's requests run as they go out, run once now. It throws `.turnRunning` while a turn
    /// runs or a message is being sent, and `.stale` once the screen shows cached data, the chat
    /// reattached since the write began, or its folder is no longer `workspace`.
    private func gitWriteDispatch(in workspace: HermesWorkspaceContext,
                                  showsCachedData: @escaping @MainActor @Sendable () -> Bool) throws -> HermesGitClient.Dispatch {
        let attempt = engine.generation
        let check: HermesGitClient.Dispatch = { [weak self] in
            guard let self, self.engine.generation == attempt, self.workspace == workspace, !showsCachedData() else {
                throw BotFailure.stale
            }
            guard self.isIdle else { throw HermesGitRefusal.turnRunning }
        }
        try check()
        return check
    }

    /// A commit message for `diff` from the host's one-shot model call, on the attached runtime's
    /// model. Throws `.stale` while detached, and for a reply that lands after a reattach.
    func commitMessage(diff: String, recent: String, avoid: String?) async throws -> String {
        guard engine.connectionState == .connected else { throw BotFailure.stale }
        let reply = try await engine.request(.commitMessage(diff: diff, recentCommits: recent, avoid: avoid,
                                                            sessionID: engine.runtime, profile: engine.target.profile),
                                             attempt: engine.generation)
        return reply["text"].text ?? ""
    }

    /// One query's rows for the composer's `@` panel and its `@path` check (#1113), as Bot Chat
    /// asks them: `complete.path` on the attached runtime, which completes against the
    /// session's working folder and ranks and caps its own rows. Throws `.stale` while
    /// detached, and for a reply that lands after a reattach; an unanswered one fails only
    /// itself, never the chat's connection.
    func completeFilePaths(_ query: String) async throws -> [ComposerFilePathSearch.Match] {
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.stale }
        let reply = try await engine.request(.completePath(word: BotFilePathSearch.word(for: query), sessionID: runtime,
                                                           profile: engine.target.profile, timesOutLocally: true),
                                             attempt: engine.generation)
        return BotFilePathSearch.matches(from: reply)
    }

    /// Keys this session's thumbnails in the process-wide `TranscriptImageCache`: its
    /// connection, Profile and stored key, so no other connection, Profile or session
    /// ever shows them.
    var attachmentCacheNamespace: String {
        "hermes|\(engine.connection.id.uuidString)|\(engine.target.profile)|\(engine.storedKey ?? "")"
    }

    /// A reply spoken by the host in this session's Profile's voice, for Listen (#1072).
    func speech(for text: String) async throws -> Data {
        try await engine.wire.speech(text: text, profile: engine.target.profile)
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

    // MARK: Rewinds

    /// Edit, Regenerate and `/retry` (#1049): one `prompt.submit` that cuts the transcript
    /// before the saved prompt `rowID` and starts the turn again with `text`
    /// (`HermesCall.promptRewind`). Sent once and never queued: a busy host refuses it (4009).
    /// Once the host takes it, the history drops that row and every row after it, and the
    /// turn starts as a send's does; its end re-reads the newest rows. Throws `NotSent` when it
    /// never went out, the host's refusal as `BotSettingFailure`, and any other failure when
    /// its reply was lost or unreadable, which only the next snapshot can settle.
    func rewind(before rowID: Int, text: String) async throws {
        submitsInFlight += 1
        defer { submitsInFlight -= 1 }
        await activate()
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw NotSent(underlying: BotFailure.transport)
        }
        let startsBefore = turnsStarted
        isSubmittingSend = true
        defer { isSubmittingSend = false }
        let reply = try await writeOnce(.promptRewind(sessionID: runtime, text: text, beforeRowID: rowID), runtime: runtime)
        // A cut only ever starts a turn; any other reply is a shape this build can't read.
        guard reply["status"].text == "streaming" else { throw BotFailure.unsupported }
        history.cut(before: rowID)
        // The turn's own frames can land before this reply; start one only if none did.
        if turnsStarted == startsBefore, activeStreamID == nil {
            beginTurn(startedAt: nil, prompt: nil)
            awaitingStart = true
        }
        requests.promptAccepted()
    }

    /// `/undo` (#1049): `session.undo` removes the session's last exchange, then the newest
    /// rows are read again and replace the transcript. A host with nothing to undo removes
    /// nothing, and nothing is read. Throws as `rewind` does, and throws the read's failure
    /// when the host removed the exchange but the chat still shows it.
    func undo() async throws {
        await activate()
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw NotSent(underlying: BotFailure.transport)
        }
        let attempt = engine.generation
        let reply = try await writeOnce(.sessionUndo(runtime: runtime), runtime: runtime)
        guard reply["removed"].integer != 0 else { return }
        await readNewestRows(attempt: attempt)
        guard attempt == engine.generation, isIdle else { return }
        if let historyFailure { throw historyFailure }
        delegate?.hermesReplaceTranscript(historyTranscript())
    }

    /// What `/compress` did (#1050).
    enum Compression: Equatable {
        /// The host compacted the history, and the newest page replaced the transcript. The
        /// summary's headline and token line, when the host sent them.
        case compacted(headline: String?, tokenLine: String?)
        /// Nothing was removed: the summary would not have shrunk it, it was aborted, another
        /// compressor holds the session's lock, or the compute host is still at it. The host's
        /// words, when it sent any.
        case unchanged(String?)
    }

    /// `/compress` and `/compact` (#1050): `session.compress` on the runtime, with the Profile
    /// and any `focus`. Once the host removed rows, the history starts again from the newest
    /// page, since the compaction archived or re-numbered every row held, and that page
    /// replaces the transcript, compaction card included; Load earlier reaches the rest. A
    /// rotated stored key in the reply's `info` is adopted first. Sent once; a busy host
    /// refuses it (4009). Throws as `rewind` does; after a lost or unreadable answer the next
    /// attach, now or once the chat is back, reads the history from the newest page and
    /// rebuilds, since the host may have compacted it.
    func compress(focus: String?) async throws -> Compression {
        await activate()
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw NotSent(underlying: BotFailure.transport)
        }
        let attempt = engine.generation
        let reply: BotJSON
        do {
            reply = try await writeOnce(.sessionCompress(runtime: runtime, focus: focus, profile: engine.target.profile),
                                        runtime: runtime)
        } catch {
            if !(error is NotSent || error is BotSettingFailure) { forgetHistoryUntilRebuild() }
            throw error
        }
        engine.adoptStoredKey(reply["info"]["stored_session_id"].text)
        let summary = reply["summary"]
        let reason = [reply["message"], summary["note"], summary["headline"]].lazy.compactMap(Self.words).first
        switch reply["status"].text {
        case "compressed" where reply["removed"].integer != 0:
            break
        case "compressed", "aborted":
            return .unchanged(reason)
        case "pending":
            compactionPending = true
            return .unchanged(reason)
        case nil where reply["lock_held"].flag == true:
            return .unchanged(reason)
        default:
            forgetHistoryUntilRebuild()
            throw BotFailure.unsupported
        }
        let compacted = Compression.compacted(headline: Self.words(summary["headline"]), tokenLine: Self.words(summary["token_line"]))
        guard attempt == engine.generation else { return compacted }
        compactionPending = false
        historyRefresh?.cancel()
        history = HermesTranscriptHistory()
        await showCompactedHistory(attempt: attempt)
        return compacted
    }

    /// Reads the newest page into a history started again, and shows it in place of the
    /// transcript, compaction card included, if the chat is still idle on the same attach.
    private func showCompactedHistory(attempt: Int) async {
        await readNewestRows(attempt: attempt)
        guard attempt == engine.generation, isIdle else { return }
        if let historyFailure {
            reportHistoryFailure(historyFailure)
        } else {
            delegate?.hermesReplaceTranscript(historyTranscript())
        }
    }

    /// The compute host finished a `/compress` it answered `pending` to: the history starts
    /// again from the newest page, shown now if idle, or taken by the running turn's end.
    private func pendingCompactionDidFinish() {
        compactionPending = false
        historyRefresh?.cancel()
        history = HermesTranscriptHistory()
        let attempt = engine.generation
        historyRefresh = Task { [weak self] in await self?.showCompactedHistory(attempt: attempt) }
    }

    /// A compaction whose answer was lost may have archived or re-numbered every row held, so
    /// merging the newest page into them could show turns twice: the history starts again,
    /// and the next attach reads the newest page and rebuilds the transcript from it, whether
    /// the lost answer's recovery reattaches now or the chat already left.
    private func forgetHistoryUntilRebuild() {
        historyRefresh?.cancel()
        history = HermesTranscriptHistory()
        needsRebuild = true
    }

    /// A reply's text, or nil when it is missing or blank.
    private static func words(_ value: BotJSON) -> String? {
        value.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    // MARK: Branches

    /// Fork From Here, `/branch` and `/fork` (#1051): `session.branch` on the runtime, sent once,
    /// and the new session's stored key. Through `rowID`, the branch keeps the history up to that
    /// saved row. The host counts from the first row of the session's whole lineage, and this
    /// chat's pages hold only its own rows, so a session whose own row continues another
    /// (`HermesBranchParent.standsAlone`) is refused; otherwise every older page is read first
    /// and counted (`HermesBranchCount`). Without it, the branch copies the whole history, under
    /// `name` when given. This chat's history is unchanged. Throws `NotSent` when it never went
    /// out, `BranchRowGone` for a row the history no longer holds,
    /// `BranchContinuesEarlierSession`, and the host's refusal as `BotSettingFailure`.
    func branch(through rowID: Int?, name: String?) async throws -> String {
        await activate()
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw NotSent(underlying: BotFailure.transport)
        }
        var count: Int?
        if let rowID {
            let own: BotJSON?
            do {
                guard let key = engine.storedKey else { throw BotFailure.transport }
                own = try await engine.wire.sessionRow(key: key, profile: engine.target.profile)
            } catch {
                throw NotSent(underlying: error)
            }
            guard let own else { throw BranchRowGone() }
            guard HermesBranchParent.standsAlone(own) else { throw BranchContinuesEarlierSession() }
            // A page that adds nothing has the newest rows read again first, so one may stall.
            var stalled = false
            while history.hasOlder {
                let held = history.rows.count
                _ = await loadOlderHistory()
                guard history.rows.count > held || !history.hasOlder || !stalled else { throw NotSent(underlying: BotFailure.transport) }
                stalled = history.rows.count == held
            }
            guard let through = HermesBranchCount.count(through: rowID, in: history.rows) else { throw BranchRowGone() }
            count = through
        }
        let reply = try await writeOnce(.sessionBranch(runtime: runtime, name: name, count: count), runtime: runtime)
        guard let key = reply["stored_session_id"].text, !key.isEmpty else { throw BotFailure.unsupported }
        return key
    }

    /// One history write on `runtime`, sent once. Throws `NotSent` when it never went out; a
    /// reaped runtime (4001) also reattaches.
    private func writeOnce(_ call: HermesCall, runtime: String) async throws -> BotJSON {
        var dispatched = false
        do {
            return try await engine.write(call, attempt: engine.generation, runtime: runtime) { dispatched = true }
        } catch {
            if HermesChatSideTasks.isReaped(error) { reattach() }
            throw dispatched ? error : NotSent(underlying: error)
        }
    }

    // MARK: Turns

    private func beginTurn(startedAt: Double?, prompt: String?) {
        turnsStarted += 1
        latestRunEnding = nil; successfulResponseCompletion = nil
        pendingEnding = nil; awaitingStart = false; stopRequested = false
        savedTurn = nil
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
        if let savedTurn {
            self.savedTurn = nil
            refreshHistory(after: savedTurn)
        }
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
        case "status.update":
            // The compute host's late answer to a `pending` compaction (#1050).
            if compactionPending, payload["kind"].text == "compacted" { pendingCompactionDidFinish() }
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
        // A legacy compaction, `/compress` or mid-turn, moves the session to a new key (#1050).
        engine.adoptStoredKey(info["stored_session_id"].text)
        noteInfo(info)
        // A rename on this runtime (`/title`, #1048) reports the new title here.
        if let title = info["title"].text, !title.isEmpty, title != infoTitle {
            infoTitle = title
            applyTitle(title)
        }
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
        // Only a receipt for the whole turn retires its streamed rows (`persisted_turn`, 0.21.5).
        let receipt = payload["persisted_turn"]
        if receipt["complete"].flag == true, let reply = receipt["final_assistant_row_id"].integer {
            savedTurn = SavedTurn(promptRowID: receipt["user_row_id"].integer, replyRowID: reply)
        }
        if ending == .cancelled {
            // A stop from any client discards the host's queued prompt and withdraws its
            // requests, so a receipt for this chat's queued prompt would never send.
            queuedPrompt = nil
            requests.withdrawAll()
        }
        pendingEnding = ending
        if !hostRunning { finish(ending) }
    }

    /// Keeps the working folder, terminal backend and model a `session.info` or a snapshot's
    /// `info` reports. An unchanged folder or backend is not written again, so a repeated
    /// report invalidates nothing; a changed one tells the chat, which drops its `@path` chips.
    private func noteInfo(_ info: BotJSON) {
        let folder = Self.words(info["cwd"]).flatMap { $0 == cwd ? nil : $0 }
        let backend = Self.words(info["terminal_backend"]).flatMap { $0 == terminalBackend ? nil : $0 }
        if let folder { cwd = folder }
        if let backend { terminalBackend = backend }
        if folder != nil || backend != nil { delegate?.hermesWorkspaceDidChange() }
        if let model = Self.words(info["model"]), let provider = Self.words(info["provider"]) {
            reportedModel = HermesCall.Model(id: model, provider: provider)
        }
    }

    /// Settles the turn against an attach's snapshot, then rebuilds the transcript from the
    /// history and it when frames were lost. Without a rebuild the replay already continued
    /// the turn.
    private func reconcile(with snapshot: BotJSON) {
        let running = snapshot["running"].flag ?? snapshot["info"]["running"].flag ?? false
        let startedAt = snapshot["turn_started_at"].number ?? snapshot["inflight"]["started_at"].number
        hostRunning = running
        queuedPrompt = snapshot["queued"]["user"].text.flatMap { $0.isEmpty ? nil : $0 }
        requests.didReadSnapshot(snapshot)
        if let model = snapshot["info"]["model"].text, !model.isEmpty { delegate?.hermesApplyModel(model) }
        noteInfo(snapshot["info"])
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

    /// The transcript from the settled history plus the snapshot's in-flight turn: the prompt
    /// until the host saves it, and the reply so far, which the next deltas continue. Held
    /// deltas that reply already holds are dropped when the engine releases them.
    private func rebuild(from snapshot: BotJSON, running: Bool) {
        needsRebuild = false
        let root = engine.storedKey ?? ""
        var transcript = historyTranscript()
        let inflight = snapshot["inflight"]
        let startedAt = inflight["started_at"].number ?? snapshot["turn_started_at"].number
        if let text = inflight["user"].text, !text.isEmpty {
            let prompt = Self.displayed(ChatMessage(role: "user", content: text, timestamp: startedAt, messageId: "\(root)/live-user"))
            if !Self.holdsPrompt(prompt, in: transcript.messages, startedAt: startedAt) { transcript.live.append(prompt) }
        }
        if let text = inflight["assistant"].text, !text.isEmpty {
            let row = ChatMessage(role: "assistant", content: text, timestamp: nil, messageId: "\(root)/live-\(UUID().uuidString)")
            if running { transcript.streamingReply = row } else { transcript.live.append(row) }
            deltasInRebuild = Self.heldDeltas(heldFrames, after: engine.sequence, alreadyIn: text, following: replayedReply)
        }
        transcript.title = snapshot["info"]["title"].text.flatMap { $0.isEmpty ? nil : $0 }
        delegate?.hermesReplaceTranscript(transcript)
    }

    // MARK: History

    /// The settled history as the chat shows it.
    private func historyTranscript() -> HermesChatTranscript {
        let projected = HermesTranscriptProjection.project(history.rows, root: engine.storedKey ?? "")
        return HermesChatTranscript(messages: projected.messages.map(Self.displayed), toolCallGroups: projected.toolCallGroups,
                                    reasoningGroups: projected.reasoningGroups, compaction: projected.compaction,
                                    hasOlder: history.hasOlder, newestCoverage: history.newestCoverage)
    }

    /// One transcript page from `offset` under the attach `attempt` began. A session the host
    /// keeps no rows for yet, such as a new one, has none.
    private func page(at offset: Int, attempt: Int) async throws -> [BotJSON] {
        try engine.check(attempt)
        guard let key = engine.storedKey else { throw BotFailure.stale }
        let rows = try await engine.wire.sessionMessages(key, profile: engine.target.profile, offset: offset)
        try engine.check(attempt)
        return rows ?? []
    }

    /// The newest rows, oldest first: pages read back from the newest until one reaches the
    /// rows held, so a turn of more than a page leaves no hole between them, or reaches the first
    /// row (`reachedStart`), at most `newestPageLimit` of them.
    private func newestRows(attempt: Int) async throws -> (rows: [BotJSON], reachedStart: Bool) {
        var rows: [BotJSON] = []
        for _ in 0..<Self.newestPageLimit {
            let page = try await self.page(at: rows.count, attempt: attempt)
            rows = page + rows
            if page.count < HermesREST.transcriptPageSize { return (rows, true) }
            if history.reaches(page) { break }
        }
        return (rows, false)
    }

    /// How many pages a newest read goes back for the rows held; past it, the history starts
    /// again from the newest rows.
    private static let newestPageLimit = 5

    /// Neither a turn nor a send is under way, so the transcript can take the newest rows.
    private var isIdle: Bool { activeStreamID == nil && submitsInFlight == 0 }

    /// Takes the newest rows into the history, which now holds every row the host saved for the
    /// turns `turns` counts. A failure keeps the rows held, and the chat shows it once
    /// connected; a read the attach outlived reports nothing.
    private func readNewestRows(attempt: Int) async {
        let turns = turnsStarted
        do {
            let fresh = try await newestRows(attempt: attempt)
            history.mergeNewest(fresh.rows, reachedStart: fresh.reachedStart)
            historyTurns = turns
            historyFailure = nil
        } catch {
            guard attempt == engine.generation, !Task.isCancelled else { return }
            historyFailure = error
        }
    }

    /// The rows the host saved for a turn take their durable ids and full tool output: the
    /// newest rows are read again and replace the transcript in place. It applies only if the
    /// chat is still idle on the same attach, nothing is going out, and the rows read hold the
    /// turn's; otherwise the next newest read brings them.
    private func refreshHistory(after turn: SavedTurn) {
        let attempt = engine.generation, turns = turnsStarted
        historyRefresh?.cancel()
        historyRefresh = Task { [weak self] in
            guard let fresh = try? await self?.newestRows(attempt: attempt), let self,
                  attempt == self.engine.generation, turns == self.turnsStarted, self.isIdle else { return }
            var merged = self.history
            merged.mergeNewest(fresh.rows, reachedStart: fresh.reachedStart)
            guard merged.holds(turn.replyRowID), turn.promptRowID.map(merged.holds) != false else { return }
            self.history = merged
            self.historyTurns = turns
            self.historyFailure = nil
            self.delegate?.hermesReplaceTranscript(self.historyTranscript())
        }
    }

    /// Puts the page before the oldest row held in front (#1047), and says whether it added
    /// rows. A turn since the newest rows were taken shifted every older page by the rows it
    /// saved, so the newest rows are read first: taken while idle, so the turn's rows take
    /// their ids, or only counted while a turn runs, whose rows show as they stream. So are
    /// they after a page that added nothing (rows the chat never heard of, such as another
    /// client's, shifted it). A failed
    /// read says why in the chat; one that lands after the history moved, or after the attach
    /// changed, is dropped.
    func loadOlderHistory() async -> Bool {
        guard history.hasOlder, engine.connectionState == .connected else { return false }
        let attempt = engine.generation, turns = turnsStarted
        do {
            if historyTurns != turns || !isIdle || history.needsRecount {
                let fresh = try await newestRows(attempt: attempt)
                if turns == turnsStarted, isIdle {
                    history.mergeNewest(fresh.rows, reachedStart: fresh.reachedStart)
                    historyTurns = turns
                    historyFailure = nil
                    delegate?.hermesReplaceTranscript(historyTranscript())
                    guard history.hasOlder else { return false }
                } else if !history.countNewer(in: fresh.rows) {
                    return false
                }
            }
            let offset = history.nextOffset
            let page = try await self.page(at: offset, attempt: attempt)
            guard offset == history.nextOffset else { return false }
            let added = history.prependOlder(page)
            delegate?.hermesPrependHistory(historyTranscript())
            return added
        } catch {
            if attempt == engine.generation, !Task.isCancelled {
                reportHistoryFailure(error)
            }
            return false
        }
    }

    /// After a failed history read, the chat's retry reads the newest rows again and lays the
    /// history out anew. Only while idle, so no running turn's rows are replaced.
    func retryHistoryIfFailed() async {
        guard historyFailure != nil, engine.connectionState == .connected, activeStreamID == nil else { return }
        let attempt = engine.generation
        await readNewestRows(attempt: attempt)
        guard attempt == engine.generation, isIdle else { return }
        if let historyFailure {
            reportHistoryFailure(historyFailure)
        } else {
            delegate?.hermesReplaceTranscript(historyTranscript())
        }
    }

    /// A newest read failed and none has succeeded since.
    var hasHistoryFailure: Bool { historyFailure != nil }

    /// Tells the chat a history read failed, with the connection's advice.
    private func reportHistoryFailure(_ error: Error) {
        delegate?.hermesHistoryDidFail(error, message: BotConnectionAdvice.message(for: error, address: engine.connection.address))
    }

    /// Reattaches so the next attach re-reads the newest rows and rebuilds the transcript:
    /// frames were lost mid-turn.
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
            turnDuration: message.turnDuration, rowID: message.rowID, isCompacted: message.isCompacted
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

    /// The settled history comes from REST pages (#1047), so the snapshot is live state only.
    var readsSnapshotHistory: Bool { false }

    /// A rebuild reads the newest history rows first, while the engine still holds the frames.
    func conversationDidReadSnapshot(_ snapshot: BotJSON, runtime: String, attempt: Int) async throws {
        guard engine.isCurrent(snapshot) else { throw BotFailure.unsupported }
        if engine.replayWasReset || needsRebuild {
            // A pending compaction may have finished among the frames lost.
            if compactionPending { history = HermesTranscriptHistory() }
            await readNewestRows(attempt: attempt)
        }
        try engine.check(attempt)
        reconcile(with: snapshot)
    }

    /// An attach that failed before any newest read succeeded makes the next one read and
    /// rebuild: one that failed after the host named the runtime leaves the next attach, on
    /// the same runtime, no lost frames to rebuild for, and the history would go unread.
    func conversationDidFailToAttach(_ error: Error) {
        if history.newestCoverage == nil { needsRebuild = true }
        delegate?.hermesAttachDidFail(error)
    }

    func conversationDidConnect(runtime: String, attempt: Int) async throws {
        // The engine released the held frames just before this.
        heldFrames = []; deltasInRebuild = []; replayedReply = ""
        refusedSignIn = false
        delegate?.hermesConnectionDidChange(failure: nil)
        if let historyFailure {
            reportHistoryFailure(historyFailure)
        }
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
