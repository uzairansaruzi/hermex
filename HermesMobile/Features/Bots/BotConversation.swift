import Foundation
import Observation

@MainActor @Observable final class BotConversation {
    /// The exact title of a bot's one canonical chat, as Desktop names it.
    static let canonicalTitle = "Bot Chat"
    enum ConnectionState { case disconnected, recovering, connected }
    enum TurnState { case unknown, idle, submitting, running, needsAttention, stopping, uncertain, interrupted }
    /// What the Bot Chat title face shows for the current turn (#757). Waiting and failed
    /// override the pinned expression, since a pin is only the resting face; every other
    /// surface keeps the pin. Only `.working` moves beyond a blink.
    enum TitleFace {
        case resting, working, waiting, failed

        /// The eyes that replace the pinned expression, or nil to keep it.
        var expression: BotAvatarExpression? {
            switch self {
            case .waiting: return .curious
            case .failed: return .sad
            case .resting, .working: return nil
            }
        }

        /// The motion for an active scene: only work sways (from `beatStart`); every other
        /// face just blinks, so a pending approval never runs the 15 fps beat.
        func motion(beatStart: Date) -> BotFaceMotion {
            self == .working ? .working(since: beatStart) : .idle
        }

        /// What VoiceOver adds after the bot's name; nil when the face shows no state.
        var accessibilityValue: String? {
            switch self {
            case .waiting: return String(localized: "Needs attention")
            case .failed: return String(localized: "Turn failed")
            case .resting, .working: return nil
            }
        }
    }
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
    /// The settled row that opened the running turn (its prompt or delegation
    /// delivery), once the host has persisted it into `messages`; nil while the
    /// prompt is only live or none is in flight. The live prompt row draws
    /// only when this is nil.
    private(set) var activePromptMessageID: String?
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
    private(set) var settledActivity: [BotSettledActivity] = [] {
        didSet { settledActivityByAnchor = Dictionary(grouping: settledActivity, by: \.anchorMessageID) }
    }
    /// `settledActivity` grouped by the message each block precedes (nil: after
    /// the last), rebuilt on every assignment so the transcript body looks a
    /// row's activity up instead of scanning the whole history per message.
    private(set) var settledActivityByAnchor: [String?: [BotSettledActivity]] = [:]
    private(set) var liveActivity = BotTurnActivity()
    private(set) var plan: BotPlan?
    /// The transient status line while the bot works: `status.update` text
    /// (compacting, compressing) or the latest `thinking.delta` spinner text.
    /// Replaced, never appended; nil once ready or when the turn settles.
    private(set) var workStatus: String?
    /// The approval from the last snapshot's `pending_approval`. Snapshot-owned,
    /// so an answer given in Desktop clears it on the next read without the phone
    /// polling for it.
    private(set) var blockingRequest: BotPendingRequest?
    /// Server requests for this runtime, live or restored from `open_requests`.
    private var serverRequests: [BotServerRequest] = []
    /// The open `manage_connections` operation, live or restored from
    /// `pending_connection`. Cleared by its settled frame, a snapshot without
    /// the field, or a disconnect; reconnecting restores it from the host.
    private(set) var connectionOperation: BotConnectionOperation?
    /// The last operation seen settling, so an older in-flight frame or snapshot
    /// never brings its card back.
    private var settledConnectionID: String?
    private var requestRevision = 0
    /// Set while an answer is in flight, to keep the card's controls inert.
    private(set) var answeringRequestID: String?
    /// The verdict on the request currently on screen, if it has one.
    private(set) var requestResolution: BotRequestResolution?
    /// The last action the host confirmed, for the chat view's haptic.
    private(set) var feedback: BotFeedback?
    /// Rows with a `message.react` in flight. Their footer controls stay inert
    /// and `react` drops any other Tapback for them until the reply, so a late
    /// reply never overwrites a newer choice.
    private(set) var reactingRowIDs: Set<Int> = []
    /// Reaction lists the host sent (a `message.react` reply or a live
    /// `message.reaction`), by row, stamped with `reactionRevision`. A full
    /// snapshot requested before a list arrived may have read the older one,
    /// so it keeps these rows' newer lists; a later snapshot drops them.
    @ObservationIgnored private var reactionPatches: [Int: (revision: Int, reactions: JSONValue)] = [:]
    @ObservationIgnored private var reactionRevision = 0
    /// On once a snapshot shows the turn busy, so the snapshot that settles it
    /// idle plays one completion. A Stop, an interruption, a new runtime and
    /// `suspend()` turn it off: a stopped turn, one that ended while the app was
    /// away, or one lost with its runtime plays none.
    @ObservationIgnored private var completionArmed = false
    private var tip: String?
    private var generation = 0
    private var turnRevision = 0
    /// The host's start time for the current turn, in Unix seconds; the only
    /// date the live prompt has until the turn settles.
    private(set) var turnStartedAt: Double?
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
        if !keepingVisibleHistory { messages = []; settledActivity = []; liveMessages = []; activePromptMessageID = nil }
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

    /// Waiting covers any blocking request, including one the phone cannot read. Failed
    /// lasts while the host keeps the turn's error, so it survives reopening the chat and
    /// clears on the next send; a user Stop rests. A disconnect resets `turn`, so it rests too.
    var titleFace: TitleFace {
        switch turn {
        case .needsAttention: return .waiting
        case .interrupted: return turnFailed ? .failed : .resting
        case .running, .stopping: return .working
        case .unknown, .idle, .submitting, .uncertain: return .resting
        }
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

    /// The one request blocking this conversation, in order: a question, the
    /// snapshot's approval, a server-request approval, any other server request
    /// (a credential prompt or a Desktop task such as `vault.*`), then an open
    /// connection operation.
    var pendingRequest: BotPendingRequest? {
        let current = serverRequests.compactMap(\.pending)
        return current.first { if case .question = $0 { return true }; return false }
            ?? blockingRequest
            ?? current.first { if case .approval = $0 { return true }; return false }
            ?? current.first
            ?? connectionOperation.map(BotPendingRequest.connection)
    }

    /// True when the user may answer the request on screen.
    var mayAnswer: Bool {
        guard let request = pendingRequest, request.isAnswerable else { return false }
        return mayDispatchAnswer(for: request.requestID)
    }

    /// True when the request on screen can be skipped from here. Separate from
    /// `mayAnswer`: a Desktop task is never answerable, but the kinds with a
    /// person in the loop can still be declined rather than waited out.
    var mayDecline: Bool {
        guard case .desktopTask(let task)? = pendingRequest, task.kind.needsSomeoneAtTheMac else { return false }
        return mayDispatchAnswer(for: task.requestID)
    }

    /// A resolved or expired request stays inert; an uncertain one is actionable
    /// again once reconnected, because a second deliberate tap is the user's
    /// decision, not an automatic replay.
    private func mayDispatchAnswer(for id: String) -> Bool {
        guard connectionState == .connected, !localOperation, answeringRequestID == nil else { return false }
        if let resolution = requestResolution, resolution.requestID == id { return !resolution.blocksFurtherAnswers }
        return true
    }

    func editDraft(_ text: String) {
        guard mayEditDraft else { return }
        draft = text
        drafts.setDraft(text, for: draftKey)
    }

    /// A tapped quick-reply chip. It fills an empty draft and never sends: Send
    /// stays the user's second, deliberate tap. A draft already started is left alone.
    func applyQuickReply(_ reply: BotQuickReply) {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editDraft(reply.text)
    }

    /// Reads this connection's skills once it is connected.
    ///
    /// The composer drives this, because its `/` panel is the only thing that
    /// needs them. A failed read is silent and retried the next time the composer
    /// asks; a reply for a conversation that has moved on is dropped.
    func loadSlashCatalog() async {
        guard connectionState == .connected, !slashCatalogLoaded, let runtime else { return }
        let owner = generation
        guard let reply = try? await request("commands.catalog", ["session_id": .string(runtime)], owner: owner),
              generation == owner else { return }
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

    /// Whether the settled row can take a Tapback now. Live rows have no
    /// `rowID`, and a chat still reconnecting shows its rows read-only.
    func mayReact(to message: ChatMessage) -> Bool {
        guard connectionState == .connected, runtime != nil, let rowID = message.rowID else { return false }
        return !reactingRowIDs.contains(rowID)
    }

    /// Sets your Tapback on one settled row, or clears it with nil. Picking
    /// the emoji you already have also clears it: the host toggles a repeat,
    /// so the phone always sends the intent (null) rather than the emoji again.
    /// Not optimistic: the row changes only from the host's reply, which lists
    /// the row's reactions in full. A rejected call leaves the row as it was
    /// and says so; a lost reply is never resent, and the next full snapshot
    /// shows what the host kept.
    func react(to message: ChatMessage, emoji: String?) async {
        guard mayReact(to: message), let rowID = message.rowID, let runtime,
              let current = messages.first(where: { $0.rowID == rowID }) else { return }
        let mine = current.botReactions.first { $0.author == .user }?.emoji
        let intent = emoji == mine ? nil : emoji
        guard intent != nil || mine != nil else { return }
        let owner = generation
        reactingRowIDs.insert(rowID)
        defer { if generation == owner { reactingRowIDs.remove(rowID) } }
        do {
            let reply = try await request("message.react", [
                "session_id": .string(runtime), "row_id": .number(Double(rowID)),
                "emoji": intent.map(BotJSON.string) ?? .null
            ], owner: owner) { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner)
                guard self.runtime == runtime else { throw BotFailure.stale }
            }
            guard reply["row_id"].integer == rowID, reply["reactions"].list != nil else { throw BotFailure.unsupported }
            applyReactions(rowID: rowID, reply["reactions"])
        } catch {
            guard generation == owner, !Task.isCancelled, error as? BotFailure != .stale else { return }
            if case BotFailure.rejected = error {
                // The host answered over a live socket: nothing changed.
            } else if error as? BotFailure == .unsupported {
                // An unreadable reply: the write may have landed. Re-read, never resend.
                fullSnapshotNeeded = true; snapshotDirty = true; scheduleRefresh()
            } else {
                disconnected(error)
            }
            errorMessage = String(localized: "Could not update the reaction.")
        }
    }

    /// Puts the host's reaction list on the row it names; an unknown row is ignored.
    /// With `author`, only that author's entries are taken and the row keeps the
    /// rest: the agent's live event is written on another host thread and can
    /// land after a newer `message.react` reply, so it must not replace yours.
    private func applyReactions(rowID: Int?, _ reactions: BotJSON, author: BotReaction.Author? = nil) {
        guard let rowID, case .array(let incoming) = reactions.jsonValue,
              let index = messages.firstIndex(where: { $0.rowID == rowID }) else { return }
        var list = incoming
        if let author {
            func isTheirs(_ entry: JSONValue) -> Bool {
                guard case .object(let fields) = entry, case .string(let name)? = fields["author"] else { return false }
                return name == author.rawValue
            }
            let kept: [JSONValue]
            if case .array(let current)? = messages[index].displayMetadata?["reactions"] { kept = current } else { kept = [] }
            list = kept.filter { !isTheirs($0) } + incoming.filter(isTheirs)
        }
        reactionRevision += 1
        reactionPatches[rowID] = (reactionRevision, .array(list))
        messages[index] = messages[index].replacingBotReactions(.array(list))
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
            // A new runtime did not inherit the old turn, so its idle is no completion.
            if runtime != foundRuntime { completionArmed = false }
            if replayWasReset { sequence = 0 }
            runtime = foundRuntime; epoch = foundEpoch
            let replayRequestsRevision = requestRevision
            let replay = try await request("session.events.since", ["session_id": .string(foundRuntime), "last_seen": .number(Double(sequence))], owner: owner)
            try reconcileReplay(replay, requestsRevision: replayRequestsRevision)
            let requestsRevision = requestRevision
            let clockRevision = clockRevision
            let reactionRevision = reactionRevision
            let current = try await request("session.resume", resumeParams(), owner: owner)
            try applySnapshot(current, full: true, requestsRevision: requestsRevision, clockRevision: clockRevision,
                              reactionRevision: reactionRevision)
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
        // Requests were restored from open_requests above; replay rebuilds activity
        // and the connection card, which the full snapshot below then confirms.
        for event in missed {
            let type = event["type"].text ?? ""
            if !applyConnectionEvent(type: type, payload: event["payload"]) {
                applyActivity(type: type, payload: event["payload"])
            }
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
            liveActivity = BotTurnActivity(); workStatus = nil
            return false
        case "todo.updated":
            if let next = BotPlan(payload), next.revision >= (plan?.revision ?? 0) { plan = next }
        case "status.update":
            let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            workStatus = payload["kind"].text == "ready" || text.isEmpty ? nil : text
        case "thinking.delta":
            // Spinner rewrites ("pondering…"), not reasoning: each frame replaces
            // the last, and an empty one clears it.
            let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            workStatus = text.isEmpty ? nil : text
        case "reasoning.available":
            // It carried the final answer text live, so it is not reasoning; the
            // settled snapshot shows the real reasoning. Consumed so it never
            // triggers a snapshot read.
            break
        default:
            // A mutating call notifies observers even when it changes nothing, so
            // `message.delta` and other unconsumed types must not reach the reducer.
            guard BotTurnActivity.handles(type) else { return false }
            return liveActivity.apply(type: type, payload: payload)
        }
        return true
    }

    private func applySnapshot(_ snapshot: BotJSON, full: Bool, settingsRevision: Int? = nil, requestsRevision: Int? = nil,
                               clockRevision: Int, reactionRevision: Int) throws {
        defer { syncLiveActivity() }
        guard snapshot["session_id"].text == runtime, snapshot["session_key"].text == tip,
              let running = snapshot["running"].flag, snapshot["hydrating"].flag != true else { throw BotFailure.unsupported }
        if let value = snapshot["info"]["profile_name"].text, value != profile.id { throw BotFailure.wrongIdentity }
        if full {
            guard let history = snapshot["messages"].list, snapshot["messages_omitted"].flag != true else { throw BotFailure.unsupported }
            let projected = BotTranscriptProjection.project(history: history, root: root ?? "")
            reactionPatches = reactionPatches.filter { $0.value.revision > reactionRevision }
            messages = reactionPatches.isEmpty ? projected.messages : projected.messages.map { message in
                guard let rowID = message.rowID, let patch = reactionPatches[rowID] else { return message }
                return message.replacingBotReactions(patch.reactions)
            }
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
        var activePrompt: String?
        // The host saves the running turn's opening row (a prompt, or a
        // delegation delivery) and each step after it mid-turn, so `messages`
        // can list it while it is still the in-flight `user`. The settled row
        // wins when the last turn boundary (steers ride inside a turn) is dated
        // at or after this turn began: the host stamps it after starting the
        // turn. Text can't decide: a slash skill's row shows its invocation,
        // not the expanded prompt in flight. Only an undated row falls back to
        // the text, so a repeated message from an earlier turn still shows
        // while history lags.
        if let text = inflight["user"].text, !text.isEmpty {
            let display = BotMentions.displayText(text)
            let settled = messages.last(where: BotTranscriptProjection.isTurnBoundary)
            let isThisTurn = settled.map { row in
                guard let start = startedAt, let stamp = row.timestamp else { return row.content == display }
                return stamp >= start
            } ?? false
            if let settled, isThisTurn {
                activePrompt = settled.id
            } else {
                liveMessages.append(ChatMessage(role: "user", content: display, timestamp: nil, messageId: "live-user"))
            }
        }
        activePromptMessageID = activePrompt
        if let text = inflight["assistant"].text, !text.isEmpty {
            liveMessages.append(ChatMessage(role: "assistant", content: text, timestamp: nil, messageId: "live-assistant"))
        }
        // Read before the idle branch below clears it: a turn with a Stop in
        // flight is never the one that completes.
        let stopping = uncertainStop || stopAcknowledged
        if !running {
            uncertainStop = false; stopAcknowledged = false; workStatus = nil
            // Only a full snapshot carries the settled rows, so live rows wait for it
            // instead of vanishing on the inflight read that first reports idle.
            if full { liveActivity.clearTurnWork() }
        }
        if requestsRevision == nil || requestsRevision == requestRevision {
            restoreServerRequests(snapshot)
            applyPendingRequest(snapshot)
            restoreConnectionOperation(snapshot)
        }
        // A request the phone cannot address still blocks the bot. Claiming the
        // turn is running would be the lie; attention without a card is the truth.
        // A `pending_connection` this build cannot read is one of those.
        let attention = pendingRequest != nil || !serverRequests.isEmpty
            || snapshot["pending_approval"] != .null || snapshot["pending_connection"] != .null
        let continuation = snapshot["auto_continue"] != .null && snapshot["auto_continue"].flag != false
        let queued = snapshot["queued"] != .null
        let busy = running || continuation || queued || attention
        if snapshotIsBusy != busy { turnRevision += 1; snapshotIsBusy = busy }
        if stopping { completionArmed = false } else if busy { completionArmed = true }
        if attention { turn = .needsAttention }
        else if uncertainStop && stopAcknowledged { turn = .stopping }
        else if uncertainSend || uncertainStop { turn = .uncertain }
        else if localOperation { /* A snapshot cannot acknowledge a local command. */ }
        else if running || continuation || queued { turn = .running }
        else if inflight["error"] != .null || snapshot["status"].text == "interrupted" {
            turn = .interrupted; turnFailed = inflight["error"] != .null
            completionArmed = false
        }
        else {
            turn = .idle
            // Only this snapshot edge completes a turn; events and replay never do,
            // so a duplicate or replayed frame cannot play it twice.
            if completionArmed { completionArmed = false; emit(.turnCompleted) }
        }
        if settingsRevision == nil || settingsRevision == chatControls.snapshotRevision {
            chatControls.snapshot(snapshot["info"], idle: !busy)
        }
    }

    /// Installs the snapshot's pending approval. A different request id drops the
    /// previous request's verdict so a new card is never born inert.
    private func applyPendingRequest(_ snapshot: BotJSON) {
        let next = BotApprovalRequest(snapshot["pending_approval"]).map(BotPendingRequest.approval)
        if next?.requestID != blockingRequest?.requestID {
            answeringRequestID = nil
            if requestResolution?.requestID != next?.requestID { requestResolution = nil }
        }
        blockingRequest = next
    }

    private func restoreServerRequests(_ snapshot: BotJSON) {
        // Resume omits an empty open_requests; replay always carries it.
        let rows = snapshot["open_requests"].list ?? []
        serverRequests = rows.compactMap(BotServerRequest.init).filter { $0.sessionID == runtime }
    }

    /// Resume omits `pending_connection` when no operation is open, so a missing
    /// or unreadable field clears the card.
    private func restoreConnectionOperation(_ snapshot: BotJSON) {
        guard let frame = BotConnectionOperation(snapshot["pending_connection"]) else {
            connectionOperation = nil; return
        }
        applyConnection(frame, opens: true)
    }

    /// Applies `connection.request` and `connection.update`. Returns false for
    /// every other event type.
    private func applyConnectionEvent(type: String, payload: BotJSON) -> Bool {
        guard type == "connection.request" || type == "connection.update" else { return false }
        if let frame = BotConnectionOperation(payload) { applyConnection(frame, opens: type == "connection.request") }
        return true
    }

    /// A frame of the held operation replaces it when newer; a frame that opens
    /// an operation replaces whatever was held. The settled frame closes it.
    private func applyConnection(_ frame: BotConnectionOperation, opens: Bool) {
        guard frame.opID != settledConnectionID else { return }
        let next: BotConnectionOperation
        if let held = connectionOperation, held.opID == frame.opID { next = held.applying(frame) }
        else if opens { next = frame }
        else { return }
        if next.isSettled { closeConnectionOperation(next.opID) } else { connectionOperation = next }
    }

    private func closeConnectionOperation(_ opID: String) {
        settledConnectionID = opID
        if connectionOperation?.opID == opID { connectionOperation = nil }
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
            if action.mode == .steer || action.mode == .queue, let operation = connectionOperation {
                try await continueConnection(operation.opID, runtime: action.runtime, owner: owner)
            }
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
            // A voice-stop phrase is taken but starts no turn, so it is not a send.
            if outcome != .voiceStopped { emit(.sent) }
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

    /// Releases an open connection operation before a Guide or Queue message, as
    /// Desktop does, so the message does not wait behind the blocked tool until
    /// the deadline. A host rejection (most often: it already settled) lets the
    /// message go anyway. A lost reply fails the send before the prompt is
    /// dispatched, and nothing is retried.
    private func continueConnection(_ opID: String, runtime: String, owner: Int) async throws {
        do {
            let reply = try await request("connection.respond", [
                "session_id": .string(runtime), "op_id": .string(opID),
                "result": BotConnectionOperation.Answer.continueWithout.result
            ], owner: owner) { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner)
                guard self.connectionState == .connected, self.runtime == runtime else { throw BotFailure.stale }
            }
            if reply["settled"].flag == true { closeConnectionOperation(opID) }
        } catch BotFailure.rejected {}
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
        slashSkills = BotSlashCatalog.skills(from: try await request(
            "commands.catalog", ["session_id": .string(action.runtime)], owner: owner))
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
        completionArmed = false
        let revision = turnRevision
        do {
            _ = try await request("session.interrupt", ["session_id": .string(action.runtime)], owner: owner) { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner)
                guard self.turnRevision == revision, self.runtime == action.runtime else { throw BotFailure.stale }
            }
            localOperation = false
            stopAcknowledged = true
            emit(.stopped)
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
        await deliver(action, confirming: .approved(choice)) {
            let reply = try await self.request("approval.respond", [
                "session_id": .string(action.runtime), "request_id": .string(action.requestID),
                "choice": .string(choice.rawValue)
            ], owner: action.generation, validateDispatch: self.answerGuard(action))
            // `resolved` counts what the host actually unblocked. Zero means the
            // queue no longer held this request: an action failure, not a delivery one.
            return (reply["resolved"].integer ?? 0) > 0 ? .answered : .alreadyResolved
        }
    }

    /// Answers a clarify question. A batch sends one `clarify.lock` per question
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

    /// Sends the value the user typed for a `sudo` or `secret` request.
    /// The value is passed straight to the dispatch and never stored on the model,
    /// so nothing retains it once the write completes.
    func answerCredential(_ action: AnswerAction, value: String) async {
        guard case .credential(let request)? = pendingRequest, request.requestID == action.requestID,
              action == prepareAnswer() else { return }
        await deliver(action, confirming: .answered) {
            let reply = try await self.answerServerRequest(action, result: ["value": .string(value)])
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

    /// Skips a `vault.*` prompt the phone cannot answer. An empty `value` is the
    /// host's own "declined", so the bot moves on now instead of waiting for
    /// someone at the Mac.
    func declineDesktopTask(_ action: AnswerAction) async {
        guard case .desktopTask(let task)? = pendingRequest, task.requestID == action.requestID,
              task.kind.needsSomeoneAtTheMac, action == prepareAnswer() else { return }
        await deliver(action, confirming: .declined) {
            let reply = try await self.answerServerRequest(action, result: ["value": .string("")])
            return reply["status"].text == "expired" ? .alreadyResolved : .answered
        }
    }

    private func dispatchAnswers(_ answers: [BotQuestionAnswer], for action: AnswerAction) async {
        await deliver(action, confirming: .answered) {
            for answer in answers {
                let reply: BotJSON
                if let id = answer.questionID {
                    reply = try await self.request("clarify.lock", [
                        "request_id": .string(action.requestID), "question_id": .string(id), "answer": .string(answer.text)
                    ], owner: action.generation, validateDispatch: self.answerGuard(action))
                } else {
                    reply = try await self.answerServerRequest(action, result: ["answer": .string(answer.text)])
                }
                // A late answer to a prompt the host already dropped comes back as
                // `expired`; nothing was locked, so the rest have nothing to lock either.
                if reply["status"].text == "expired" { return .alreadyResolved }
                if answer.questionID != nil {
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

    /// Answers one row of the connection card, or Continue. Captured like every
    /// answer and never retried. The operation stays open until the host says it
    /// settled: its update frames move the rows, and a Skip that leaves other rows
    /// open leaves the bot waiting. `4004` means the operation had already settled.
    func respondToConnection(_ action: AnswerAction, _ answer: BotConnectionOperation.Answer) async {
        guard case .connection(let operation)? = pendingRequest, operation.opID == action.requestID,
              answer.isOffered(by: operation), action == prepareAnswer() else { return }
        localOperation = true
        answeringRequestID = action.requestID
        errorMessage = nil
        do {
            let reply = try await request("connection.respond", [
                "session_id": .string(action.runtime), "op_id": .string(action.requestID), "result": answer.result
            ], owner: action.generation, validateDispatch: answerGuard(action))
            guard reply["status"].text == "ok", let settled = reply["settled"].flag else { throw BotFailure.unsupported }
            guard action.generation == generation, !Task.isCancelled else { return }
            localOperation = false; answeringRequestID = nil
            requestRevision += 1
            if settled {
                closeConnectionOperation(action.requestID)
                // The host owns what happens next; read it instead of assuming.
                turnRevision += 1; turn = .unknown; fullSnapshotNeeded = true
            }
            snapshotDirty = true; scheduleRefresh()
        } catch {
            guard action.generation == generation, !Task.isCancelled else { return }
            localOperation = false; answeringRequestID = nil
            if error as? BotFailure == .stale { return }
            if case BotFailure.rejected(let code) = error {
                // The host replied over a live socket, so nothing it refused took effect.
                if code == 4004 {
                    requestResolution = BotRequestResolution(requestID: action.requestID, outcome: .alreadyResolved)
                    fullSnapshotNeeded = true
                } else {
                    errorMessage = [401, 403, -32601].contains(code)
                        ? BotFailure.rejected(code).localizedDescription
                        : String(localized: "The bot could not accept that answer. Check this bot in Desktop.")
                }
                // A refused move usually means the row changed first; show where it is now.
                requestRevision += 1
                snapshotDirty = true; scheduleRefresh()
                return
            }
            requestResolution = BotRequestResolution(requestID: action.requestID, outcome: .uncertain)
            disconnected(error)
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
    /// `event` is published only when the host says it took the answer.
    private func deliver(_ action: AnswerAction, confirming event: BotFeedback.Event,
                         _ dispatch: () async throws -> BotRequestResolution.Outcome?) async {
        localOperation = true
        answeringRequestID = action.requestID
        errorMessage = nil
        do {
            let outcome = try await dispatch()
            guard action.generation == generation, !Task.isCancelled else { return }
            localOperation = false; answeringRequestID = nil
            requestResolution = outcome.map { BotRequestResolution(requestID: action.requestID, outcome: $0) }
            if outcome == .answered { emit(event) }
            // Retire accepted requests immediately, then reconcile with the host.
            // A partially locked batch remains visible until the fresh snapshot.
            if outcome != nil { serverRequests.removeAll { $0.pending?.requestID == action.requestID } }
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

    private func emit(_ event: BotFeedback.Event) {
        feedback = BotFeedback(event, after: feedback)
    }

    private func observe(_ event: BotJSON) {
        guard connectionState != .disconnected, runtime != nil else { return }
        defer { syncLiveActivity() }
        if let request = BotServerRequest(event) {
            guard request.sessionID == runtime else { return }
            if let index = serverRequests.firstIndex(where: { $0.id == request.id }) {
                serverRequests[index] = request
            } else { serverRequests.append(request) }
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
            liveActivity = BotTurnActivity()
            serverRequests.removeAll(); requestRevision += 1
            if !localOperation { turn = .unknown }
            scheduleRefresh(); return
        }
        guard next != sequence else { return }
        let discontinuity = next != sequence + 1
        if discontinuity {
            clockRevision += 1; confirmedWorkingStart = nil
            replayWasReset = true; fullSnapshotNeeded = true; turnRevision += 1
            // Missed events may hold tool rows, a notice's clear or a request's
            // cancellation; partial or stale state is worse than none.
            liveActivity = BotTurnActivity()
            serverRequests.removeAll(); requestRevision += 1
            if !localOperation { turn = .unknown }
        }
        sequence = next
        let type = event["type"].text ?? ""
        // A newer frame than any snapshot already in flight, like a live request.
        if applyConnectionEvent(type: type, payload: event["payload"]) { requestRevision += 1 }
        // The agent's `react_to_message` tool paints its Tapback live; only the
        // agent's entry is taken from the payload, so it changes nothing else.
        if type == "message.reaction" {
            applyReactions(rowID: event["payload"]["row_id"].integer, event["payload"]["reactions"], author: .agent)
            if !discontinuity { return }
        }
        if ["subagent.spawn_requested", "subagent.start", "subagent.progress",
            "subagent.tool", "subagent.complete"].contains(type) {
            delegatedWork.noteSubagentEvent()
        }
        if ["session.info", "message.start", "message.complete", "session.control.update"].contains(type) {
            chatControls.refresh()
        }
        let requestCancelled = applyRequestCancel(type: type, payload: event["payload"])
        // Activity events never change the inflight text, so a continuous stream
        // during known work updates local state without another snapshot read.
        if !requestCancelled, applyActivity(type: type, payload: event["payload"]),
           !discontinuity, turn == .running { return }
        if requestCancelled
            || ["message.start", "message.complete", "session.info", "error", "connection.request"].contains(type) {
            turnRevision += 1
            fullSnapshotNeeded = true
            // Current state is pending reconciliation; don't dispatch new work.
            if !localOperation { turn = .unknown }
        }
        if type == "message.delta", !discontinuity, !localOperation, !uncertainSend, !uncertainStop { turn = .running }
        snapshotDirty = true
        scheduleRefresh()
    }

    /// Applies `request.cancel`, which withdraws only the matching envelope.
    /// Returns true when it was one.
    private func applyRequestCancel(type: String, payload: BotJSON) -> Bool {
        guard type == "request.cancel", let id = payload["id"].text, !id.isEmpty,
              let method = payload["method"].text, !method.isEmpty else { return false }
        if let request = serverRequests.first(where: { $0.id == id && $0.method == method }) {
            serverRequests.removeAll { $0.id == id }
            if blockingRequest?.requestID == request.pending?.requestID { blockingRequest = nil }
        }
        // Even an unseen request may be present in an older in-flight snapshot.
        requestRevision += 1
        return true
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
                    let reactionRevision = self.reactionRevision
                    let reply = try await self.request("session.resume", self.resumeParams(full: full), owner: owner)
                    try self.applySnapshot(reply, full: full, settingsRevision: settingsRevision,
                                           requestsRevision: requestsRevision, clockRevision: clockRevision,
                                           reactionRevision: reactionRevision)
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
        // Reconnecting restores the host's current requests from open_requests
        // and pending_connection.
        serverRequests = []; connectionOperation = nil; answeringRequestID = nil
        connectionState = .disconnected
        turn = uncertainSend || uncertainStop ? .uncertain : .unknown
        turnRevision += 1
        let failure = error as? BotFailure ?? .transport
        switch failure {
        case .transport: shouldRetryConnection = true
        case .rejected(let code): shouldRetryConnection = [408, 429].contains(code) || (500...599).contains(code)
        default: shouldRetryConnection = false
        }
        errorMessage = shouldRetryConnection ? nil : BotConnectionAdvice.message(for: failure, address: connection.address)
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
        completionArmed = false
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
        serverRequests = []; connectionOperation = nil; answeringRequestID = nil
        reactingRowIDs = []; reactionPatches = [:]
        connectionState = .disconnected; turn = .unknown
        syncLiveActivity()
    }
}
