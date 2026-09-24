import Foundation
import Observation

@MainActor @Observable final class BotConversation {
    /// The exact title of a bot's one canonical chat, as Desktop names it.
    static let canonicalTitle = "Bot Chat"
    enum ConnectionState { case disconnected, recovering, connected }
    enum TurnState { case unknown, idle, submitting, running, needsAttention, stopping, uncertain, interrupted }
    struct StopAction: Equatable { let generation: Int; let revision: Int; let runtime: String }
    /// The identity an answer is bound to, captured when the user taps and
    /// revalidated at the socket write so a stale card cannot answer a newer
    /// request or a replaced runtime.
    struct AnswerAction: Equatable { let generation: Int; let runtime: String; let requestID: String }

    struct PromptAction: Equatable {
        let generation: Int; let revision: Int; let runtime: String
        let mode: BotPromptMode; let text: String
        /// Kept apart from `text` so a failed send restores exactly what the
        /// composer held; quotes only become Markdown on the way out.
        var quotes: [ComposerQuote] = []
        var attachmentIDs: [UUID] = []
    }

    private(set) var isUploadingAttachments = false
    private var attachmentUploadTask: Task<String, Error>?
    private(set) var submittingPrompt: BotPromptMode?
    private(set) var unavailablePromptModes: Set<BotPromptMode> = []

    /// Re-read after the profile editor saves, so the title and face do not lie.
    private(set) var profile: BotProfile
    private(set) var mentions: BotMentions
    let connection: BotConnection
    let server: URL
    private(set) var connectionState = ConnectionState.disconnected
    private(set) var turn = TurnState.unknown
    private(set) var messages: [ChatMessage] = []
    private(set) var hasRecentTranscript = false
    @ObservationIgnored private var recentRoot: String?
    @ObservationIgnored private var recentOwner: UUID?
    private(set) var liveMessages: [ChatMessage] = []
    private(set) var errorMessage: String?
    let chatControls = BotChatControls()
    let attachments: BotAttachmentDraft
    private(set) var draft = ""
    /// This connection's skills, read once from `commands.catalog` and kept for
    /// the conversation's life. Empty until the read lands, and after one fails:
    /// the panel simply does not open, and typing and sending never wait on it.
    private(set) var slashSkills: [SkillSlashSuggestion] = []
    private var slashCatalogLoaded = false
    /// Workspace files picked from the composer's `@` panel, so a sent `@path`
    /// draws as the shared composer chip. A conversation is one
    /// server/connection/Profile lifetime, so a path never reaches another bot.
    private(set) var fileChipPaths: Set<String> = []
    /// The `@` panel's rows, owned here rather than by the composer so they
    /// outlive one open panel and die with the conversation.
    @ObservationIgnored let filePathSearch = ComposerFilePathSearch()
    /// Passages the user sent here with Ask Hermex. Separate from `draft` so a
    /// pasted paragraph never turns into a chip and each one is removable.
    private(set) var quotes: [ComposerQuote] = []
    private(set) var uncertainSend = false
    private(set) var uncertainStop = false
    private(set) var root: String?
    /// The canonical root a deep link named, seeded into `root` so the changed-root
    /// rejection below refuses to open the bot's replacement conversation under the
    /// link's identity (#554). Nil for an ordinary open from the inbox.
    private let linkedRoot: String?
    /// Set when that seeded root is not the bot's canonical chat any more, so the
    /// inbox can take the user back with a one-line report.
    private(set) var linkedRootIsStale = false
    private(set) var runtime: String?
    private(set) var sequence = 0
    private(set) var epoch: String?
    private(set) var replayWasReset = false
    private(set) var settledActivity: [BotSettledActivity] = []
    private(set) var liveActivity = BotTurnActivity()
    private(set) var plan: BotPlan?
    /// `status.update` text while the bot works (compacting, compressing); nil once ready.
    private(set) var workStatus: String?
    /// The approval or question from the last snapshot's `pending_approval` /
    /// `pending_clarify`. Snapshot-owned, so an answer given in Desktop clears it
    /// on the next read without the phone polling for it.
    private(set) var blockingRequest: BotPendingRequest?
    /// A legacy credential prompt or Desktop-renderer task, owned by the event stream.
    private(set) var streamRequest: BotStreamRequest?
    /// Nil means a legacy host. An empty array authoritatively clears modern requests.
    private var serverRequests: [BotServerRequest]?
    private var requestRevision = 0
    /// Set while an answer is in flight, to keep the card's controls inert.
    private(set) var answeringRequestID: String?
    /// The verdict on the request currently on screen, if it has one.
    private(set) var requestResolution: BotRequestResolution?
    private var tip: String?
    private var generation = 0
    private var turnRevision = 0
    private var turnStartedAt: Double?
    private var confirmedWorkingStart: Date?
    private var clockRevision = 0
    /// When this phone first saw the current turn, for a host that sends no start time.
    private var turnObservedAt = Date()
    /// Whether the last snapshot's interruption was a host error rather than a stop.
    private var turnFailed = false
    private var snapshotIsBusy: Bool?
    private var snapshotDirty = false
    private var fullSnapshotNeeded = false
    private var refreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isActive = false
    private var shouldRetryConnection = false
    private let reconnectDelay: (Duration) async throws -> Void
    private(set) var isReconnecting = false
    private var stopAcknowledged = false
    private var localOperation = false
    private var hydrated = false
    private let wire: any BotTransport
    let delegatedWork: BotDelegatedWork
    private let historyCache: BotHistoryCache?
    private(set) var historyCacheTask: Task<Void, Never>?
    private let drafts: ChatDraftStore
    /// Nil outside the chat screen and in tests, so only a visible chat drives ActivityKit.
    private let liveActivityFeed: BotLiveActivityFeed?

    init(server: URL, connection: BotConnection, profile: BotProfile, roster: [BotProfile] = [],
         conversation: String? = nil,
         historyCache: BotHistoryCache? = nil, wire: (any BotTransport)? = nil, drafts: ChatDraftStore? = nil,
         attachmentCopies: any ChatDraftAttachmentStoring = ChatDraftAttachmentStore.shared,
         liveActivityFeed: BotLiveActivityFeed? = nil,
         reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let resolvedWire = wire ?? BotClient(connection: connection)
        self.server = server; self.connection = connection; self.profile = profile
        self.linkedRoot = conversation; self.root = conversation
        self.mentions = BotMentions(roster: roster, excluding: profile.id)
        self.reconnectDelay = reconnectDelay
        self.wire = resolvedWire
        self.delegatedWork = BotDelegatedWork(wire: resolvedWire)
        self.historyCache = historyCache
        self.drafts = drafts ?? .shared
        self.liveActivityFeed = liveActivityFeed
        self.attachments = BotAttachmentDraft(key: .bot(server: server, connectionID: connection.id, profile: profile.id),
                                              drafts: drafts ?? .shared, copies: attachmentCopies)
        self.wire.onEvent = { [weak self] event in self?.observe(event) }
        self.wire.onDisconnect = { [weak self] error in self?.disconnected(error) }
        self.delegatedWork.onWorkersChanged = { [weak self] in self?.syncLiveActivity() }
        if case .bot(let recent)? = historyCache?.recent.snapshot(for: recentKey),
           conversation == nil || conversation == recent.root {
            messages = recent.messages; settledActivity = recent.activity
            recentRoot = recent.root
            hasRecentTranscript = !recent.messages.isEmpty || !recent.activity.isEmpty
        }
    }

    private var recentKey: BotRecentTranscripts.Key {
        .bot(server: server, connectionID: connection.id, profile: profile.id)
    }

    /// Freeze visible text on departure; do not retain live controls or tool state.
    private func saveRecentTranscript() {
        guard connectionState == .connected, let root, let recentOwner else { return }
        let snapshot = BotRecentTranscripts.Bot(root: root, messages: messages + liveMessages, activity: settledActivity)
        historyCache?.recent.save(.bot(snapshot), for: recentKey, owner: recentOwner)
    }

    private func discardRecentTranscript(keepingVisibleHistory: Bool = false) {
        historyCache?.recent.remove { $0 == recentKey }
        recentOwner = nil; recentRoot = nil; hasRecentTranscript = false
        if !keepingVisibleHistory { messages = []; settledActivity = []; liveMessages = [] }
    }

    /// Only a current server snapshot can start the transcript clock. Live Activity's
    /// legacy local observation fallback is deliberately not used here.
    var workingRowStartedAt: Date? {
        guard connectionState == .connected, turn == .running,
              !uncertainSend, !uncertainStop else { return nil }
        return confirmedWorkingStart
    }

    /// This conversation as its Live Activity should show it (#489). Counts and tool
    /// names only, plus a reply excerpt the feed drops unless previews are on.
    var liveActivitySnapshot: BotLiveActivitySnapshot {
        let phase: BotLiveActivitySnapshot.Phase
        if connectionState != .connected { phase = .disconnected }
        else {
            switch turn {
            case .running, .stopping, .needsAttention:
                phase = .working(turn: turnStartedAt.map { String($0) } ?? runtime ?? "",
                                 startedAt: turnStartedAt.map(Date.init(timeIntervalSince1970:)) ?? turnObservedAt)
            case .idle: phase = .finished(.complete)
            case .interrupted: phase = .finished(turnFailed ? .failed : .cancelled)
            case .unknown, .submitting, .uncertain: phase = .unknown
            }
        }

        let work: BotLiveActivitySnapshot.Work
        let reply = liveMessages.last { $0.role == "assistant" }?.content ?? ""
        if turn == .needsAttention {
            if case .approval = pendingRequest { work = .waitingForApproval } else { work = .waitingForAnswer }
        } else if let tool = liveActivity.toolCalls.last, !tool.isCompleted { work = .tool(tool.name) }
        else if !reply.isEmpty {
            // The excerpt is a prefix: read only the reply's head on every frame (#676).
            // Leading whitespace never reaches it, so skip that before taking the head.
            let head = String(reply.drop(while: \.isWhitespace).prefix(AgentRunActivitySanitizer.maximumExcerptSourceLength))
            work = .responding(AgentRunActivitySanitizer.responseExcerpt(head))
        }
        else if liveActivity.toolCalls.last != nil { work = .toolDone }
        else if !liveActivity.reasoning.isEmpty { work = .thinking }
        else { work = .starting }

        var chips: [String] = []
        if let plan, !plan.isFinished {
            chips.append(String(localized: "Plan \(min(plan.completedCount + 1, plan.items.count)) of \(plan.items.count)"))
        }
        if delegatedWork.activeCount > 0 { chips.append(String(localized: "\(delegatedWork.activeCount) workers")) }
        if !liveActivity.toolCalls.isEmpty { chips.append(String(localized: "\(liveActivity.toolCalls.count) tools")) }

        return BotLiveActivitySnapshot(
            destination: BotDestination(server: server, connectionID: connection.id, profile: profile.id, conversation: root),
            title: BotProfileAppearance(profile: profile).title, phase: phase, work: work, chips: chips, agentSessionID: tip)
    }

    private func syncLiveActivity() {
        liveActivityFeed?.sync(liveActivitySnapshot, profile: profile)
    }

    /// Push presence names a bot by its live agent session, as the plugin reports it.
    var pushPresence: PushPresence.Viewer? {
        tip.map { PushPresence.Viewer(server: server, sessionID: $0) }
    }

    var artifactContext: BotArtifactContext? {
        guard connectionState == .connected, let tip else { return nil }
        return BotArtifactContext(connectionID: connection.id, profile: profile.id, sessionID: tip, generation: generation)
    }

    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        guard context == artifactContext else { throw BotFailure.stale }
        let data = try await wire.artifactData(path: path, context: context)
        guard context == artifactContext, !Task.isCancelled else { throw BotFailure.stale }
        return data
    }

    var draftKey: ChatDraftKey { .bot(server: server, connectionID: connection.id, profile: profile.id) }
    var maySend: Bool {
        hydrated && connectionState == .connected && [.idle, .interrupted].contains(turn)
            && !localOperation && !uncertainSend && !uncertainStop
    }
    var mayStop: Bool {
        connectionState == .connected && [.running, .needsAttention].contains(turn)
            && !localOperation && !uncertainStop
    }

    var mayGuide: Bool {
        hydrated && connectionState == .connected && [.running, .needsAttention].contains(turn)
            && !localOperation && !uncertainSend && !uncertainStop && answeringRequestID == nil
    }

    func maySubmit(_ mode: BotPromptMode) -> Bool {
        !attachments.isImporting && (attachments.items.isEmpty || mode == .send || mode == .queue)
            && !unavailablePromptModes.contains(mode) && (mode == .send ? maySend : mayGuide)
    }

    func preparePrompt(_ mode: BotPromptMode) -> PromptAction? {
        guard maySubmit(mode), let runtime, hasSendableInput else { return nil }
        return PromptAction(generation: generation, revision: turnRevision, runtime: runtime, mode: mode,
                            text: draft, quotes: quotes, attachmentIDs: attachments.items.map(\.id))
    }

    /// A quote alone is a message: the passage is what the user wants asked about.
    var hasSendableInput: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quotes.isEmpty || !attachments.items.isEmpty
    }

    var mayImportAttachments: Bool { mayEditDraft && connectionState == .connected }

    var mayEditDraft: Bool { hydrated && !localOperation }

    /// The one request blocking this conversation. A clarify or approval wins over
    /// a stream request: it is the outer blocker, and the host resolves the inner
    /// one on its own deadline either way.
    var pendingRequest: BotPendingRequest? {
        let current = serverRequests?.compactMap(\.pending) ?? []
        return current.first { if case .question = $0 { return true }; return false }
            ?? blockingRequest
            ?? current.first { if case .approval = $0 { return true }; return false }
            ?? current.first ?? streamRequest?.pending
    }

    /// True when the user may answer the request on screen.
    var mayAnswer: Bool {
        guard let request = pendingRequest, request.isAnswerable else { return false }
        return mayDispatchAnswer(for: request.requestID)
    }

    /// True when the request on screen can be called off from here. Separate
    /// from `mayAnswer`: a Desktop task is never answerable, but the one kind
    /// with a person in the loop can still be declined rather than waited out.
    var mayDecline: Bool {
        guard case .desktopTask(let task)? = pendingRequest, task.kind.isDeclinable else { return false }
        return mayDispatchAnswer(for: task.requestID)
    }

    /// A resolved or expired request stays inert; an uncertain one is actionable
    /// again once reconnected, because a second deliberate tap is the user's
    /// decision, not an automatic replay.
    private func mayDispatchAnswer(for requestID: String?) -> Bool {
        guard connectionState == .connected, !localOperation, answeringRequestID == nil,
              let id = requestID else { return false }
        if let resolution = requestResolution, resolution.requestID == id { return !resolution.blocksFurtherAnswers }
        return true
    }

    func editDraft(_ text: String) {
        guard mayEditDraft else { return }
        draft = text
        drafts.setDraft(text, for: draftKey)
    }

    /// Reads this connection's skills once it is connected.
    ///
    /// The composer drives this, because its `/` panel is the only thing that
    /// needs them. A failed read is silent and retried the next time the composer
    /// asks; a reply for a conversation that has moved on is dropped.
    func loadSlashCatalog() async {
        guard connectionState == .connected, !slashCatalogLoaded else { return }
        let owner = generation
        guard let reply = try? await request("commands.catalog", [:], owner: owner), generation == owner else { return }
        slashCatalogLoaded = true
        slashSkills = BotSlashCatalog.skills(from: reply)
    }

    /// One query's rows for the composer's `@` panel.
    ///
    /// `complete.path` answers against the live session's working directory and
    /// ranks its own rows, so a disconnected conversation has nothing to ask.
    /// The panel's generation guard drops a reply a newer query replaced.
    func searchFilePaths(_ query: String) async {
        await filePathSearch.search(query) { [weak self] query in
            guard let self else { throw BotFailure.stale }
            return try await self.completeFileMatches(for: query)
        }
    }

    /// Remembers a file the `@` panel inserted, so the composer draws its chip
    /// with the insertion instead of a beat later.
    func recordFileChipReference(_ path: String) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        fileChipPaths.insert(path)
    }

    /// Forgets picked paths and rows because the workspace moved: a path is
    /// only a file inside the workspace it was found in.
    func resetFileReferences() {
        filePathSearch.reset()
        fileChipPaths.removeAll()
    }

    private func completeFileMatches(for query: String) async throws -> [ComposerFilePathSearch.Match] {
        guard connectionState == .connected, let runtime else { throw BotFailure.stale }
        let reply = try await request("complete.path", [
            "word": .string(BotFilePathSearch.word(for: query)),
            "session_id": .string(runtime),
            "profile": .string(profile.id)
        ], owner: generation)
        return BotFilePathSearch.matches(from: reply)
    }

    /// Ask Hermex on a passage selected in the transcript. Durable straight
    /// away, so a passage survives leaving the screen the way typed text does.
    func quotePassage(_ passage: String) {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mayEditDraft, !trimmed.isEmpty else { return }
        quotes.append(ComposerQuote(text: trimmed))
        drafts.setQuotes(quotes, for: draftKey)
    }

    func removeQuote(_ id: UUID) {
        guard mayEditDraft, quotes.contains(where: { $0.id == id }) else { return }
        quotes.removeAll { $0.id == id }
        drafts.setQuotes(quotes, for: draftKey)
    }

    func recover() async {
        suspend()
        isActive = true
        await recoverConnection()
    }

    /// Re-reads this bot's roster row after an edit. A missing row or a lost
    /// connection leaves the current profile in place.
    func refreshProfile() async {
        guard connectionState == .connected else { return }
        let owner = generation
        guard let roster = try? await request("profiles.list", ["include_sessions": .bool(false)], owner: owner),
              let rows = roster["profiles"].list else { return }
        let profiles = rows.compactMap(BotProfile.init)
        mentions = BotMentions(roster: profiles, excluding: profile.id)
        if let fresh = profiles.first(where: { $0.id == profile.id }) { profile = fresh }
    }

    private func recoverConnection() async {
        resetConnection()
        if hasRecentTranscript, historyCache?.recent.snapshot(for: recentKey) == nil {
            // Clear Offline Cache may have run after construction but before entry.
            messages = []; settledActivity = []; recentRoot = nil; hasRecentTranscript = false
        }
        recentOwner = historyCache?.recent.begin(recentKey)
        let owner = generation
        connectionState = .recovering
        errorMessage = nil
        do {
            if !hydrated {
                let saved = await drafts.draft(for: draftKey)
                try check(owner)
                draft = saved?.text ?? ""
                quotes = saved?.quotes ?? []
                uncertainSend = saved?.botSubmissionUncertain ?? false
                await attachments.restore(saved?.attachments ?? [])
                try check(owner)
                hydrated = true
            }
            // Recovered text and attachments are an ordinary editable draft.
            // Clearing this local marker never retries the earlier prompt.
            if uncertainSend { try await releasePromptMarker(owner: owner) }
            try await wire.connect()
            try check(owner)
            let lookup = try await request("session.list", ["profile": .string(profile.id), "title": .string(Self.canonicalTitle), "include_hidden": .bool(true)], owner: owner)
            guard let rows = lookup["sessions"].list else { throw BotFailure.unsupported }
            guard rows.count == 1 else { throw BotFailure.missingChat }
            guard let foundRoot = rows[0]["id"].text, !foundRoot.isEmpty,
                  let foundTip = rows[0]["resolved_id"].text, !foundTip.isEmpty else { throw BotFailure.unsupported }
            // Resume can auto-continue. Reject a changed root before making that call.
            if let root, root != foundRoot {
                // The rejected root is the one a deep link named: report it so the
                // inbox can say so, rather than sitting on an error the user cannot act on.
                if root == linkedRoot { linkedRootIsStale = true }
                throw BotFailure.wrongIdentity
            }
            root = foundRoot; tip = foundTip
            if let recentRoot, recentRoot != foundRoot {
                // An ordinary inbox entry may now point at a replacement Bot Chat.
                // Cached display identity must not make the old root canonical.
                discardRecentTranscript()
                recentOwner = historyCache?.recent.begin(recentKey)
            }
            let first = try await request("session.resume", resumeParams(), owner: owner)
            guard first["session_key"].text == foundTip, let foundRuntime = first["session_id"].text,
                  !foundRuntime.isEmpty, let foundEpoch = wire.replayEpoch else { throw BotFailure.wrongIdentity }
            replayWasReset = epoch != foundEpoch || runtime != foundRuntime
            if replayWasReset { sequence = 0 }
            runtime = foundRuntime; epoch = foundEpoch
            let replayRequestsRevision = requestRevision
            let replay = try await request("session.events.since", ["session_id": .string(foundRuntime), "last_seen": .number(Double(sequence))], owner: owner)
            try reconcileReplay(replay, requestsRevision: replayRequestsRevision)
            let requestsRevision = requestRevision
            let clockRevision = clockRevision
            let current = try await request("session.resume", resumeParams(), owner: owner)
            try applySnapshot(current, full: true, requestsRevision: requestsRevision, clockRevision: clockRevision)
            try check(owner)
            let controlsContext = BotChatControls.Context(connectionID: connection.id, profile: profile.id,
                                                          runtime: foundRuntime, generation: owner)
            await chatControls.connect(controlsContext, wire: wire)
            try check(owner)
            guard connectionState == .recovering, chatControls.context == controlsContext else { throw BotFailure.transport }
            chatControls.snapshot(current["info"], idle: [.idle, .interrupted].contains(turn))
            connectionState = .connected
            hasRecentTranscript = false; recentRoot = nil
            saveRecentTranscript()
            shouldRetryConnection = false
            syncLiveActivity()
            await delegatedWork.connect(.init(connectionID: connection.id, runtime: foundRuntime, generation: owner))
            try check(owner)
            scheduleRefresh()
        } catch {
            guard owner == generation, !Task.isCancelled else { return }
            if let failure = error as? BotFailure, [.missingChat, .wrongIdentity].contains(failure) {
                // An already-open conversation keeps its established read-only
                // history on identity loss. An unverified warm entry does not.
                discardRecentTranscript(keepingVisibleHistory: !hasRecentTranscript)
            }
            disconnected(error)
        }
    }

    private func resumeParams(full: Bool = true) -> [String: BotJSON] {
        var params: [String: BotJSON] = ["profile": .string(profile.id), "session_id": .string(tip ?? ""), "close_on_disconnect": .bool(false)]
        if !full { params["omit_messages"] = .bool(true) }
        return params
    }

    private func check(_ owner: Int) throws {
        guard generation == owner, !Task.isCancelled else { throw BotFailure.stale }
    }

    private func request(_ method: String, _ params: [String: BotJSON], owner: Int, validateDispatch: (() throws -> Void)? = nil) async throws -> BotJSON {
        try check(owner)
        let reply = try await wire.call(method, params, validateDispatch: validateDispatch)
        try check(owner)
        return reply
    }

    private func reconcileReplay(_ reply: BotJSON, requestsRevision: Int) throws {
        guard let latest = reply["latest_seq"].integer, latest >= 0,
              let receivedEpoch = reply["epoch"].text, !receivedEpoch.isEmpty,
              let truncated = reply["truncated"].flag, let events = reply["events"].list else { throw BotFailure.unsupported }
        if epoch != receivedEpoch || truncated || latest < sequence { replayWasReset = true }
        if requestsRevision == requestRevision { restoreServerRequests(reply) }
        var cursor = sequence
        var missed: [BotJSON] = []
        for event in events {
            guard event["session_id"].text == runtime else { throw BotFailure.wrongIdentity }
            guard let next = event["seq"].integer, next > 0, next <= latest else { throw BotFailure.unsupported }
            if next <= cursor { continue }
            if next != cursor + 1 { replayWasReset = true }
            cursor = next
            missed.append(event)
        }
        if cursor < latest { replayWasReset = true }
        epoch = receivedEpoch; sequence = latest
        // Replay never appends text; the full snapshot below owns it. It does rebuild
        // the current turn's activity: every missed event when the sequence was
        // continuous, otherwise only the events after the last `message.start` the
        // ring still holds, which is the whole current turn. Without either, every
        // live row and notice is dropped rather than shown incomplete or stale: a
        // notice whose clear was in the gap has no snapshot state to reconcile it.
        if replayWasReset {
            guard let start = missed.lastIndex(where: { $0["type"].text == "message.start" }) else {
                liveActivity = BotTurnActivity(); return
            }
            missed.removeFirst(start)
        }
        for event in missed {
            let type = event["type"].text ?? ""
            // Legacy credential/Desktop-task prompts have only replay events;
            // modern prompts were restored from open_requests above.
            if applyStreamRequest(type: type, payload: event["payload"]) { continue }
            applyActivity(type: type, payload: event["payload"])
        }
    }

    /// Feeds activity events to the live reducer, plan and work status. Returns
    /// false for event types that carry conversation text or turn state instead.
    @discardableResult
    private func applyActivity(type: String, payload: BotJSON) -> Bool {
        switch type {
        case "message.start":
            clockRevision += 1
            confirmedWorkingStart = nil
            liveActivity = BotTurnActivity(); workStatus = nil; streamRequest = nil
            return false
        case "todo.updated":
            if let next = BotPlan(payload), next.revision >= (plan?.revision ?? 0) { plan = next }
        case "status.update":
            let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            workStatus = payload["kind"].text == "ready" || text.isEmpty ? nil : text
        default:
            // A mutating call notifies observers even when it changes nothing, so
            // `message.delta` and other unconsumed types must not reach the reducer.
            guard BotTurnActivity.handles(type) else { return false }
            return liveActivity.apply(type: type, payload: payload)
        }
        return true
    }

    private func applySnapshot(_ snapshot: BotJSON, full: Bool, settingsRevision: Int? = nil, requestsRevision: Int? = nil,
                               clockRevision: Int) throws {
        defer { syncLiveActivity() }
        guard snapshot["session_id"].text == runtime, snapshot["session_key"].text == tip,
              let running = snapshot["running"].flag, snapshot["hydrating"].flag != true else { throw BotFailure.unsupported }
        if let value = snapshot["info"]["profile_name"].text, value != profile.id { throw BotFailure.wrongIdentity }
        if full {
            guard let history = snapshot["messages"].list, snapshot["messages_omitted"].flag != true else { throw BotFailure.unsupported }
            let projected = BotTranscriptProjection.project(history: history, root: root ?? "")
            messages = projected.messages
            settledActivity = projected.activity
            if let historyCache, let root, let tip {
                historyCacheTask?.cancel()
                let scope = BotHistoryCache.Scope(server: server, connectionID: connection.id)
                let profileID = profile.id
                let profileName = profile.name
                let saved = messages
                let receivedAt = Date()
                historyCacheTask = Task {
                    try? await historyCache.replace(scope: scope, profileID: profileID, profileName: profileName, root: root, tip: tip,
                                                    messages: saved, receivedAt: receivedAt)
                }
            }
        }
        if let next = BotPlan(snapshot["todo_state"]), next.revision >= (plan?.revision ?? 0) { plan = next }
        let inflight = snapshot["inflight"]
        let startedAt = inflight["started_at"].number ?? snapshot["turn_started_at"].number
        if clockRevision == self.clockRevision, running, let startedAt, startedAt.isFinite, startedAt > 0,
           startedAt <= Date().timeIntervalSince1970 {
            confirmedWorkingStart = Date(timeIntervalSince1970: startedAt)
        } else { confirmedWorkingStart = nil }
        if startedAt != turnStartedAt { turnRevision += 1; turnStartedAt = startedAt; turnObservedAt = Date() }
        liveMessages = []
        // The host can list the prompt in `messages` while it is still the
        // in-flight `user`, so the same bubble would draw twice until the turn
        // settles. The settled row wins when it is this turn's prompt; a same-text
        // prompt from an earlier turn (dated before this turn began) does not
        // count, so a repeated message still shows while history lags.
        if let text = inflight["user"].text, !text.isEmpty {
            let display = BotMentions.displayText(text)
            let settled = messages.last
            let sameText = settled?.role == "user" && settled?.content == display
            let fromEarlierTurn = startedAt.map { start in (settled?.timestamp ?? start) < start } ?? false
            if !(sameText && !fromEarlierTurn) {
                liveMessages.append(ChatMessage(role: "user", content: display, timestamp: nil, messageId: "live-user"))
            }
        }
        if let text = inflight["assistant"].text, !text.isEmpty {
            liveMessages.append(ChatMessage(role: "assistant", content: text, timestamp: nil, messageId: "live-assistant"))
        }
        if !running {
            uncertainStop = false; stopAcknowledged = false; workStatus = nil
            streamRequest = nil
            // Only a full snapshot carries the settled rows, so live rows wait for it
            // instead of vanishing on the inflight read that first reports idle.
            if full { liveActivity.clearTurnWork() }
        }
        if requestsRevision == nil || requestsRevision == requestRevision {
            restoreServerRequests(snapshot)
            applyPendingRequest(snapshot)
        }
        // A request the phone cannot address still blocks the bot. Claiming the
        // turn is running would be the lie; attention without a card is the truth.
        let attention = pendingRequest != nil || serverRequests?.isEmpty == false
            || snapshot["pending_approval"] != .null || snapshot["pending_clarify"] != .null
        let continuation = snapshot["auto_continue"] != .null && snapshot["auto_continue"].flag != false
        let queued = snapshot["queued"] != .null
        let busy = running || continuation || queued || attention
        if snapshotIsBusy != busy { turnRevision += 1; snapshotIsBusy = busy }
        if attention { turn = .needsAttention }
        else if uncertainStop && stopAcknowledged { turn = .stopping }
        else if uncertainSend || uncertainStop { turn = .uncertain }
        else if localOperation { /* A snapshot cannot acknowledge a local command. */ }
        else if running || continuation || queued { turn = .running }
        else if inflight["error"] != .null || snapshot["status"].text == "interrupted" {
            turn = .interrupted; turnFailed = inflight["error"] != .null
        }
        else { turn = .idle }
        if settingsRevision == nil || settingsRevision == chatControls.snapshotRevision {
            chatControls.snapshot(snapshot["info"], idle: !busy)
        }
    }

    /// Installs the snapshot's pending approval or question. A clarify outranks an
    /// approval because approvals resolve inside a tool batch while a clarify blocks
    /// the whole turn. A different request id drops the previous request's verdict
    /// so a new card is never born inert.
    private func applyPendingRequest(_ snapshot: BotJSON) {
        let question = serverRequests == nil ? BotQuestionRequest(snapshot["pending_clarify"]).map(BotPendingRequest.question) : nil
        let approval = BotApprovalRequest(snapshot["pending_approval"]).map(BotPendingRequest.approval)
        let next = question ?? approval
        if next?.requestID != blockingRequest?.requestID {
            answeringRequestID = nil
            if requestResolution?.requestID != next?.requestID { requestResolution = nil }
        }
        blockingRequest = next
    }

    private func restoreServerRequests(_ snapshot: BotJSON) {
        // 0.21.2 omits empty open_requests from resume; replay always carries it.
        // Once this socket has established the modern contract, omission clears.
        guard let rows = snapshot["open_requests"].list else {
            if serverRequests != nil { serverRequests = [] }
            return
        }
        serverRequests = rows.compactMap(BotServerRequest.init).filter { $0.sessionID == runtime }
        streamRequest = nil
    }

    private func usesServerRequest(_ action: AnswerAction) -> Bool {
        serverRequests?.contains { $0.pending?.requestID == action.requestID } == true
    }

    /// The proxy gives a definitive ok/expired receipt for both live and restored
    /// requests, unlike a bare JSON-RPC response which has no acknowledgment.
    private func answerServerRequest(_ action: AnswerAction, result: [String: BotJSON]) async throws -> BotJSON {
        let reply = try await request("request.answer", ["id": .string(action.requestID), "result": .object(result)],
                                      owner: action.generation, validateDispatch: answerGuard(action))
        guard ["ok", "expired"].contains(reply["status"].text ?? "") else { throw BotFailure.unsupported }
        return reply
    }

    func send() async {
        guard let action = preparePrompt(.send) else { return }
        await submit(action)
    }

    /// One deliberate action, one write. The durable marker covers every prompt
    /// mode; snapshots and matching history can never acknowledge that write.
    func submit(_ action: PromptAction) async {
        guard action == preparePrompt(action.mode) else { return }
        let owner = action.generation
        let mentionNote = mentions.annotation(for: action.text)
        localOperation = true; submittingPrompt = action.mode
        errorMessage = nil
        defer { if generation == owner { submittingPrompt = nil; localOperation = false } }
        // Persist local copies before upload; an upload cannot start agent work.
        do {
            try await drafts.flush()
            try check(owner)
        } catch {
            guard owner == generation else { return }
            localOperation = false; uncertainSend = false
            drafts.setBotSubmissionUncertain(false, for: draftKey)
            errorMessage = String(localized: "Could not save the draft. Your message was not sent.")
            return
        }
        // Expanding a skill has no effect on the conversation, so it runs before
        // anything durable: a failure here leaves the draft exactly as it was.
        let base: String
        do {
            base = ComposerQuoteMessageFormatter.message(
                text: try await skillText(action, owner: owner) ?? action.text, quotes: action.quotes)
        }
        catch {
            guard owner == generation, !Task.isCancelled else { return }
            errorMessage = String(localized: "Could not start that skill. Your draft is still here.")
            return
        }
        var promptDispatched = false
        do {
            let text: String
            if action.attachmentIDs.isEmpty { text = base }
            else {
                isUploadingAttachments = true
                let task = Task { try await self.attachmentPrompt(action, base: base, owner: owner) }
                attachmentUploadTask = task
                defer {
                    if owner == generation { isUploadingAttachments = false; attachmentUploadTask = nil }
                }
                text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            }
            try check(owner)
            // Only prompt admission can have an unknown outcome. Keep this
            // durable before dispatch, but never hold a draft during upload.
            drafts.setBotSubmissionUncertain(true, for: draftKey)
            try await drafts.flush()
            try check(owner)
            uncertainSend = true
            let reply = try await request(action.mode.method, action.mode.params(runtime: action.runtime, text: text + mentionNote), owner: owner) { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner)
                guard self.connectionState == .connected, self.runtime == action.runtime,
                      self.turnRevision == action.revision else { throw BotFailure.stale }
                promptDispatched = true
            }
            let outcome = action.mode.outcome(reply)
            if outcome == .rejected {
                try await releasePromptMarker(owner: owner)
                localOperation = false
                errorMessage = String(localized: "The bot did not accept this message. Your draft is still here.")
                refreshAfterPrompt()
                return
            }
            guard outcome != .unknown else { throw BotFailure.unsupported }
            drafts.setDraft("", for: draftKey)
            drafts.setQuotes([], for: draftKey)
            drafts.setAttachments([], for: draftKey)
            drafts.setBotSubmissionUncertain(false, for: draftKey)
            try await drafts.flush()
            try check(owner)
            draft = ""; quotes = []; uncertainSend = false
            await attachments.consumed()
            try check(owner)
            localOperation = false
            refreshAfterPrompt()
        } catch {
            guard owner == generation, !Task.isCancelled else { return }
            // Only failures known to precede admission release the draft. A 5000
            // may follow a side effect; an unrecognized success shape is ambiguous.
            let safe = !promptDispatched || error as? BotFailure == .stale || action.mode.definitelyRejected(error)
            if safe {
                do { try await releasePromptMarker(owner: owner) }
                catch { guard owner == generation else { return }; disconnected(error); localOperation = false; return }
            }
            guard owner == generation else { return }
            if !safe {
                // A failed durable clear must leave the original text held too.
                drafts.setAttachments(attachments.items.map(ChatDraftAttachment.init(pending:)), for: draftKey)
                drafts.setDraft(action.text, for: draftKey)
                drafts.setQuotes(action.quotes, for: draftKey)
                drafts.setBotSubmissionUncertain(true, for: draftKey)
                try? await drafts.flush()
                guard owner == generation, !Task.isCancelled else { return }
            }
            localOperation = false
            let needsRecovery: Bool
            if case BotFailure.rejected(let code) = error { needsRecovery = [401, 403, 4001, 4090].contains(code) }
            else { needsRecovery = false }
            if !promptDispatched, !action.attachmentIDs.isEmpty {
                errorMessage = error is CancellationError || error as? BotFailure == .stale
                    ? String(localized: "Upload cancelled. Your message and attachments are still here.")
                    : error.localizedDescription
            } else if action.mode != .send, safe, !needsRecovery {
                if case BotFailure.rejected(let code) = error, [-32601, 4010].contains(code) {
                    // 4010 can be temporary during initialization; do not hide it
                    // permanently. A missing method stays unavailable this lifetime.
                    if code == -32601 { unavailablePromptModes.insert(action.mode) }
                    errorMessage = String(localized: "This action is unavailable for the bot's current work. Your draft is still here.")
                } else {
                    errorMessage = String(localized: "The work changed before this message could be sent. Choose an action again.")
                }
                refreshAfterPrompt()
            } else { disconnected(safe ? error : BotFailure.transport) }
        }
    }

    /// Every returned path is bound to this captured action; partial uploads never
    /// enter another prompt. Uploaded files remain host-owned if Send is cancelled.
    func cancelAttachmentUpload() { attachmentUploadTask?.cancel() }

    /// The message a skill row actually sends, or `nil` when the draft is prose.
    ///
    /// `prompt.submit` never interprets a leading `/`, so a typed `/work fix the
    /// leak` would reach the agent as literal text. The host expands it instead:
    /// `command.dispatch` hands back the invocation body the agent reads, while
    /// the transcript still shows the typed line, because the host projects the
    /// invocation back over the stored message.
    ///
    /// Only a name this connection's catalog reported as a skill is dispatched,
    /// and only a `skill` reply is used. Nothing else runs from here: the gateway
    /// resolves quick, plugin and registry commands ahead of skills, and a quick
    /// command can run a shell command on the host.
    private func skillText(_ action: PromptAction, owner: Int) async throws -> String? {
        guard action.mode.startsTurn,
              let invocation = BotSlashCatalog.invocation(in: action.text),
              SlashSkillFormatter.skill(named: invocation.name, in: slashSkills) != nil
        else { return nil }
        // The cached catalog is a snapshot of the host at connect time. A command
        // added since then would shadow this name, so the decision is made against
        // a fresh read instead — and the panel gets the newer skills for free. The
        // last microseconds of the race cannot be closed from here: the gateway has
        // no skill-only dispatch.
        slashSkills = BotSlashCatalog.skills(from: try await request("commands.catalog", [:], owner: owner))
        guard let skill = SlashSkillFormatter.skill(named: invocation.name, in: slashSkills) else {
            throw BotFailure.unsupported
        }
        let reply = try await request("command.dispatch", [
            "name": .string(skill.name), "arg": .string(invocation.argument),
            "session_id": .string(action.runtime)
        ], owner: owner)
        // Asked for an expansion and did not get one: send nothing rather than
        // fall back to prose the agent would only read literally.
        guard reply["type"].text == "skill", let message = reply["message"].text,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BotFailure.unsupported }
        return message
    }

    private func attachmentPrompt(_ action: PromptAction, base: String, owner: Int) async throws -> String {
        var text = base
        guard !action.attachmentIDs.isEmpty else { return text }
        guard attachments.items.count <= 8,
              attachments.items.reduce(0, { $0 + ($1.size ?? BotAttachmentDraft.maximumFileBytes) }) <= BotAttachmentDraft.maximumTotalBytes
        else { throw BotAttachmentFailure.limit }
        guard let context = artifactContext else { throw BotFailure.stale }
        for item in attachments.items {
            try check(owner)
            guard runtime == action.runtime, turnRevision == action.revision else { throw BotFailure.stale }
            let data = try await attachments.data(for: item)
            try check(owner)
            let reference: String
            if item.isImage {
                let path = try await wire.uploadImage(data: data, filename: item.name, context: context)
                reference = BotAttachmentUpload.imageReference(path: try BotAttachmentUpload.verifiedPath(path))
            } else {
                let params = await BotAttachmentUpload.fileParams(data: data, runtime: action.runtime, filename: item.name, mime: item.mime)
                let reply = try await request("file.attach", params, owner: owner) { [weak self] in
                    guard let self, self.runtime == action.runtime, self.turnRevision == action.revision else { throw BotFailure.stale }
                }
                guard reply["attached"].flag == true, let ref = reply["ref_text"].text, ref.hasPrefix("@file:"),
                      !ref.contains("\n"), !ref.contains("\r") else { throw BotFailure.unsupported }
                _ = try BotAttachmentUpload.verifiedPath(reply["path"].text)
                reference = ref
            }
            try check(owner)
            guard context == artifactContext else { throw BotFailure.stale }
            text += "\n\n" + reference
        }
        return text
    }

    private func releasePromptMarker(owner: Int) async throws {
        drafts.setBotSubmissionUncertain(false, for: draftKey)
        do {
            try await drafts.flush()
            try check(owner)
            uncertainSend = false
        } catch {
            if owner == generation { drafts.setBotSubmissionUncertain(true, for: draftKey) }
            throw error
        }
    }

    private func refreshAfterPrompt() {
        turn = .unknown
        fullSnapshotNeeded = true; snapshotDirty = true; scheduleRefresh()
    }

    func prepareStop() -> StopAction? {
        guard mayStop, let runtime else { return nil }
        return StopAction(generation: generation, revision: turnRevision, runtime: runtime)
    }

    func stop(_ action: StopAction) async {
        guard mayStop, action == prepareStop() else { return }
        let owner = generation
        localOperation = true; uncertainStop = true; turn = .stopping; turnRevision += 1
        let revision = turnRevision
        do {
            _ = try await request("session.interrupt", ["session_id": .string(action.runtime)], owner: owner) { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner)
                guard self.turnRevision == revision, self.runtime == action.runtime else { throw BotFailure.stale }
            }
            localOperation = false
            stopAcknowledged = true
            // Acknowledgement alone is not completion. Snapshot must establish idle.
            snapshotDirty = true; fullSnapshotNeeded = true; scheduleRefresh()
        } catch {
            guard owner == generation, !Task.isCancelled else { return }
            localOperation = false
            if error as? BotFailure == .stale { uncertainStop = false }
            disconnected(error)
        }
    }

    /// Captures what an answer or a decline is validated against, or nil when
    /// the request on screen cannot be acted on right now.
    func prepareAnswer() -> AnswerAction? {
        guard mayAnswer || mayDecline, let runtime, let id = pendingRequest?.requestID else { return nil }
        return AnswerAction(generation: generation, runtime: runtime, requestID: id)
    }

    /// Answers a command approval with one of the choices the host itself offered.
    func respond(_ action: AnswerAction, choice: BotApprovalRequest.Choice) async {
        guard case .approval(let request)? = pendingRequest, request.requestID == action.requestID,
              request.choices.contains(choice), action == prepareAnswer() else { return }
        await deliver(action) {
            let reply = try await self.request("approval.respond", [
                "session_id": .string(action.runtime), "request_id": .string(action.requestID),
                "choice": .string(choice.rawValue)
            ], owner: action.generation, validateDispatch: self.answerGuard(action))
            // `resolved` counts what the host actually unblocked. Zero means the
            // queue no longer held this request: an action failure, not a delivery one.
            return (reply["resolved"].integer ?? 0) > 0 ? .answered : .alreadyResolved
        }
    }

    /// Answers a clarify question. A batch sends one `clarify.respond` per question
    /// id in order; the host locks each answer and the last one releases the turn.
    func answerQuestion(_ action: AnswerAction, _ answers: [BotQuestionAnswer]) async {
        guard case .question(let request)? = pendingRequest, request.requestID == action.requestID,
              !answers.isEmpty, action == prepareAnswer() else { return }
        let offered = Set(request.questions.compactMap(\.wireID))
        guard answers.allSatisfy({ answer in
            answer.questionID.map(offered.contains) ?? !request.isBatch
        }) else { return }
        // Submit every outstanding question in this tap. Skip is a separate,
        // deliberate action; never invent an empty answer for an untouched row.
        if request.isBatch {
            let outstanding = Set(request.questions.filter { !$0.isAnswered }.compactMap(\.wireID))
            guard Set(answers.compactMap(\.questionID)) == outstanding else { return }
        }
        await dispatchAnswers(answers, for: action)
    }

    /// Declines to answer, the way Desktop's cancel does: one unkeyed empty answer
    /// releases the whole request, batch or not. It is a real answer, so it is
    /// deliberate and never automatic.
    func skipQuestion(_ action: AnswerAction) async {
        guard case .question(let request)? = pendingRequest, request.requestID == action.requestID,
              action == prepareAnswer() else { return }
        await dispatchAnswers([BotQuestionAnswer(questionID: nil, text: "")], for: action)
    }

    /// Sends the value the user typed for a `sudo.request` or `secret.request`.
    /// The value is passed straight to the dispatch and never stored on the model,
    /// so nothing retains it once the write completes.
    func answerCredential(_ action: AnswerAction, value: String) async {
        guard case .credential(let request)? = pendingRequest, request.requestID == action.requestID,
              action == prepareAnswer() else { return }
        await deliver(action) {
            let reply = try await self.usesServerRequest(action)
                ? self.answerServerRequest(action, result: ["value": .string(value)])
                : self.request(request.kind.respondMethod, [
                "request_id": .string(action.requestID),
                request.kind.valueKey: .string(value)
            ], owner: action.generation, validateDispatch: self.answerGuard(action))
            // The host tolerates a late answer to a prompt it already dropped and
            // says so rather than erroring; nothing was applied.
            return reply["status"].text == "expired" ? .alreadyResolved : .answered
        }
    }

    /// Declines to supply the value. An empty string is the host's own skip: the
    /// secret tool records a skip and the sudo command is left to fail, which is
    /// the honest outcome and far better than parking the bot until it times out.
    func skipCredential(_ action: AnswerAction) async {
        await answerCredential(action, value: "")
    }

    /// Calls off a Desktop task the phone cannot answer but can decline. The
    /// host reads `declined` as a final no and its tool is told never to re-ask,
    /// so the bot moves on now instead of parking for the full deadline.
    func declineDesktopTask(_ action: AnswerAction) async {
        guard case .desktopTask(let task)? = pendingRequest, task.requestID == action.requestID,
              task.kind.isDeclinable, action == prepareAnswer() else { return }
        await deliver(action) {
            let reply = try await self.usesServerRequest(action)
                ? self.answerServerRequest(action, result: ["value": .string(BotDesktopTaskRequest.declinedResult)])
                : self.request(task.kind.respondMethod, [
                "request_id": .string(action.requestID),
                "result": .string(BotDesktopTaskRequest.declinedResult)
            ], owner: action.generation, validateDispatch: self.answerGuard(action))
            return reply["status"].text == "expired" ? .alreadyResolved : .answered
        }
    }

    private func dispatchAnswers(_ answers: [BotQuestionAnswer], for action: AnswerAction) async {
        let modern = usesServerRequest(action)
        await deliver(action) {
            for answer in answers {
                var params: [String: BotJSON] = [
                    "request_id": .string(action.requestID), "answer": .string(answer.text)
                ]
                if let id = answer.questionID { params["question_id"] = .string(id) }
                let reply: BotJSON
                if modern {
                    if answer.questionID != nil {
                        reply = try await self.request("clarify.lock", params, owner: action.generation,
                                                       validateDispatch: self.answerGuard(action))
                    } else {
                        reply = try await self.answerServerRequest(action, result: ["answer": .string(answer.text)])
                    }
                } else {
                    reply = try await self.request("clarify.respond", params, owner: action.generation,
                                                   validateDispatch: self.answerGuard(action))
                }
                // A late answer to a prompt the host already dropped comes back as
                // `expired`; nothing was locked, so the rest have nothing to lock either.
                if reply["status"].text == "expired" { return .alreadyResolved }
                if modern, answer.questionID != nil {
                    guard reply["status"].text == "ok", let remaining = reply["remaining"].list else {
                        throw BotFailure.unsupported
                    }
                    // Another client may have locked the tail already.
                    if remaining.isEmpty { return .answered }
                    if answer == answers.last { return nil }
                }
            }
            return .answered
        }
    }

    /// Revalidates at the socket write, after any executor delay: the same
    /// connection, the same runtime, and still the same request on screen.
    private func answerGuard(_ action: AnswerAction) -> () throws -> Void {
        { [weak self] in
            guard let self else { throw BotFailure.stale }
            try self.check(action.generation)
            guard self.runtime == action.runtime,
                  self.pendingRequest?.requestID == action.requestID else { throw BotFailure.stale }
        }
    }

    /// Runs one answer dispatch under the rules every request kind shares.
    /// The closure returns the host's verdict, or nil for an incomplete batch
    /// that needs reconciliation. A lost reply leaves the outcome unknown.
    private func deliver(_ action: AnswerAction,
                         _ dispatch: () async throws -> BotRequestResolution.Outcome?) async {
        localOperation = true
        answeringRequestID = action.requestID
        errorMessage = nil
        do {
            let outcome = try await dispatch()
            guard action.generation == generation, !Task.isCancelled else { return }
            localOperation = false; answeringRequestID = nil
            requestResolution = outcome.map { BotRequestResolution(requestID: action.requestID, outcome: $0) }
            // Retire accepted requests immediately, then reconcile with the host.
            // A partially locked batch remains visible until the fresh snapshot.
            if streamRequest?.pending.requestID == action.requestID { streamRequest = nil }
            if outcome != nil { serverRequests?.removeAll { $0.pending?.requestID == action.requestID } }
            requestRevision += 1
            // The host owns what happens next; read the snapshot instead of
            // assuming the turn resumed.
            turnRevision += 1
            turn = .unknown
            fullSnapshotNeeded = true; snapshotDirty = true; scheduleRefresh()
        } catch {
            guard action.generation == generation, !Task.isCancelled else { return }
            localOperation = false; answeringRequestID = nil
            // A stale action is rejected before the write, so nothing is in doubt.
            if error as? BotFailure == .stale { return }
            if case BotFailure.rejected(let code) = error {
                // The host replied over a live socket, so the answer definitively
                // did not take effect and the connection is still usable.
                errorMessage = [401, 403, -32601].contains(code)
                    ? BotFailure.rejected(code).localizedDescription
                    : String(localized: "The bot could not accept that answer. Check this bot in Desktop.")
                return
            }
            requestResolution = BotRequestResolution(requestID: action.requestID, outcome: .uncertain)
            disconnected(error)
        }
    }

    private func observe(_ event: BotJSON) {
        guard connectionState != .disconnected, runtime != nil else { return }
        defer { syncLiveActivity() }
        if let request = BotServerRequest(event) {
            guard request.sessionID == runtime else { return }
            if serverRequests == nil { serverRequests = [] }
            if let index = serverRequests?.firstIndex(where: { $0.id == request.id }) {
                serverRequests?[index] = request
            } else { serverRequests?.append(request) }
            requestRevision += 1
            turnRevision += 1
            if !localOperation { turn = .needsAttention }
            snapshotDirty = true; scheduleRefresh()
            return
        }
        guard event["session_id"].text == runtime else { return }
        guard let next = event["seq"].integer, next > 0 else {
            clockRevision += 1; confirmedWorkingStart = nil
            replayWasReset = true; snapshotDirty = true; fullSnapshotNeeded = true
            turnRevision += 1
            liveActivity = BotTurnActivity(); streamRequest = nil
            serverRequests?.removeAll(); requestRevision += 1
            if !localOperation { turn = .unknown }
            scheduleRefresh(); return
        }
        guard next != sequence else { return }
        let discontinuity = next != sequence + 1
        if discontinuity {
            clockRevision += 1; confirmedWorkingStart = nil
            replayWasReset = true; fullSnapshotNeeded = true; turnRevision += 1
            // Missed events may hold tool rows, a notice's clear or a stream
            // request's expiry; partial or stale state is worse than none.
            liveActivity = BotTurnActivity(); streamRequest = nil
            serverRequests?.removeAll(); requestRevision += 1
            if !localOperation { turn = .unknown }
        }
        sequence = next
        let type = event["type"].text ?? ""
        if ["subagent.spawn_requested", "subagent.start", "subagent.progress",
            "subagent.tool", "subagent.complete"].contains(type) {
            delegatedWork.noteSubagentEvent()
        }
        if ["session.info", "message.start", "message.complete", "session.control.update"].contains(type) {
            chatControls.refresh()
        }
        let streamRequestChanged = applyStreamRequest(type: type, payload: event["payload"])
        // Activity events never change the inflight text, so a continuous stream
        // during known work updates local state without another snapshot read.
        if !streamRequestChanged, applyActivity(type: type, payload: event["payload"]),
           !discontinuity, turn == .running { return }
        if streamRequestChanged
            || ["message.start", "message.complete", "session.info", "error", "approval.request", "clarify.request"].contains(type) {
            turnRevision += 1
            fullSnapshotNeeded = true
            // Current state is pending reconciliation; don't dispatch new work.
            if !localOperation { turn = .unknown }
        }
        if type == "message.delta", !discontinuity, !localOperation, !uncertainSend, !uncertainStop { turn = .running }
        snapshotDirty = true
        scheduleRefresh()
    }

    /// Applies modern cancellation and legacy credential/Desktop-task events.
    /// Returns true when the pending request changed.
    private func applyStreamRequest(type: String, payload: BotJSON) -> Bool {
        if type == "request.cancel", let id = payload["id"].text, !id.isEmpty,
           let method = payload["method"].text, !method.isEmpty {
            if let request = serverRequests?.first(where: { $0.id == id && $0.method == method }) {
                serverRequests?.removeAll { $0.id == id }
                if blockingRequest?.requestID == request.pending?.requestID { blockingRequest = nil }
            }
            // Even an unseen request may be present in an older in-flight snapshot.
            requestRevision += 1
            return true
        }
        if let request = BotStreamRequest.requested(eventType: type, payload: payload) {
            guard streamRequest != request else { return false }
            // A new prompt inherits nothing from the one it replaces.
            answeringRequestID = nil
            if requestResolution?.requestID != request.pending.requestID { requestResolution = nil }
            streamRequest = request
            return true
        }
        if let prefix = BotStreamRequest.expiredPrefix(eventType: type), streamRequest?.eventPrefix == prefix {
            streamRequest = nil
            return true
        }
        return false
    }

    private func scheduleRefresh() {
        guard snapshotDirty, connectionState == .connected, refreshTask == nil else { return }
        let owner = generation
        refreshTask = Task { [weak self] in
            do {
                // Coalesce event bursts. This is active-stream work only, not polling.
                try await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                while self.snapshotDirty {
                    try self.check(owner)
                    self.snapshotDirty = false
                    let full = self.fullSnapshotNeeded
                    self.fullSnapshotNeeded = false
                    let settingsRevision = self.chatControls.snapshotRevision
                    let requestsRevision = self.requestRevision
                    let clockRevision = self.clockRevision
                    let reply = try await self.request("session.resume", self.resumeParams(full: full), owner: owner)
                    try self.applySnapshot(reply, full: full, settingsRevision: settingsRevision,
                                           requestsRevision: requestsRevision, clockRevision: clockRevision)
                    if self.snapshotDirty { try await Task.sleep(for: .milliseconds(250)) }
                }
                self.refreshTask = nil
            } catch {
                guard let self, self.generation == owner, !Task.isCancelled else { return }
                self.refreshTask = nil
                self.disconnected(error)
            }
        }
    }

    private func disconnected(_ error: Error) {
        saveRecentTranscript()
        chatControls.disconnect()
        delegatedWork.disconnect()
        wire.close()
        refreshTask?.cancel(); refreshTask = nil
        // A stream request lives only in the stream, so a lost socket makes its
        // state unknowable. The card goes rather than lying about it.
        streamRequest = nil; serverRequests = nil; answeringRequestID = nil
        connectionState = .disconnected
        turn = uncertainSend || uncertainStop ? .uncertain : .unknown
        turnRevision += 1
        let failure = error as? BotFailure ?? .transport
        switch failure {
        case .transport: shouldRetryConnection = true
        case .rejected(let code): shouldRetryConnection = [408, 429].contains(code) || (500...599).contains(code)
        default: shouldRetryConnection = false
        }
        errorMessage = shouldRetryConnection ? nil : failure.localizedDescription
        syncLiveActivity()
        scheduleReconnect()
    }

    /// Reattach to canonical host state while this screen is active. Commands
    /// remain held; recovery never resends a prompt, answer, stop or setting.
    private func scheduleReconnect() {
        guard isActive, shouldRetryConnection, reconnectTask == nil else { return }
        isReconnecting = true
        let delay = reconnectDelay
        reconnectTask = Task { [weak self] in
            var seconds = 1
            while !Task.isCancelled {
                do { try await delay(.seconds(seconds)) } catch { return }
                guard let self, self.isActive, self.shouldRetryConnection, !Task.isCancelled else { return }
                await self.recoverConnection()
                guard !Task.isCancelled else { return }
                if !self.shouldRetryConnection || self.connectionState == .connected {
                    self.isReconnecting = false; self.reconnectTask = nil
                    return
                }
                seconds = min(seconds * 2, 30)
            }
        }
    }

    func suspend() {
        saveRecentTranscript()
        historyCacheTask?.cancel(); historyCacheTask = nil
        isActive = false; shouldRetryConnection = false; isReconnecting = false
        reconnectTask?.cancel(); reconnectTask = nil
        resetConnection()
        Task { try? await drafts.flush() }
    }

    private func resetConnection() {
        confirmedWorkingStart = nil
        chatControls.disconnect()
        delegatedWork.disconnect()
        attachmentUploadTask?.cancel(); attachmentUploadTask = nil; isUploadingAttachments = false
        attachments.cancelImport()
        generation += 1; turnRevision += 1
        refreshTask?.cancel(); refreshTask = nil
        wire.close()
        localOperation = false; submittingPrompt = nil
        streamRequest = nil; serverRequests = nil; answeringRequestID = nil
        connectionState = .disconnected; turn = .unknown
        syncLiveActivity()
    }
}
