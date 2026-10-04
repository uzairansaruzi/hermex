import Foundation
import Observation
import OSLog

/// Which session a `HermesConversation` attaches to. Every target names its Profile,
/// which goes on every call.
enum ConversationTarget: Hashable, Sendable {
    /// The Profile's one Bot Chat, looked up by its exact title on every attach. A root
    /// that changed since the last attach is refused before resume. Bot Chats are created
    /// only by `BotCreator`.
    case canonicalChat(profile: String)
    /// A stored session by its stored key. No title lookup.
    case session(profile: String, key: String)
    /// A session `session.create` makes on the first attach. It becomes `.session` once the
    /// host names its stored key, so a reattach resumes it instead of creating another.
    case new(profile: String)

    var profile: String {
        switch self {
        case .canonicalChat(let profile), .session(let profile, _), .new(let profile): return profile
        }
    }

    /// The composer draft's key, which its attachments share. A Bot Chat keeps the key it
    /// has always had, so no saved draft moves.
    func draftKey(server: URL, connectionID: UUID) -> ChatDraftKey {
        switch self {
        case .canonicalChat(let profile): return .bot(server: server, connectionID: connectionID, profile: profile)
        case .session(let profile, let key):
            return .hermesSession(server: server, connectionID: connectionID, profile: profile, key: key)
        case .new(let profile): return .hermesSession(server: server, connectionID: connectionID, profile: profile, key: nil)
        }
    }

    /// The key of the transcript kept for a warm return; nil for a session not created yet.
    /// A Bot Chat keeps the key it has always had.
    func recentKey(server: URL, connectionID: UUID) -> BotRecentTranscripts.Key? {
        switch self {
        case .canonicalChat(let profile): return .bot(server: server, connectionID: connectionID, profile: profile)
        case .session(let profile, let key): return .session(server: server, connectionID: connectionID, profile: profile, key: key)
        case .new: return nil
        }
    }

    /// The Profile whose entry in `BotHistoryCache`'s search index this conversation
    /// replaces. Nil for sessions: the index has one entry per Profile, and a hit opens
    /// that Profile's Bot Chat.
    var historyIndexProfile: String? {
        if case .canonicalChat(let profile) = self { return profile }
        return nil
    }
}

/// What a `HermesConversation` asks of the screen model that owns it. The engine calls
/// these in order on the main actor; an async one that throws ends the attach as a failure.
/// The owner renders: Bot Chat rebuilds its text from snapshots, a Hermes session reduces
/// the frames' deltas. The owner also restores open requests (`open_requests`) from the
/// replay reply and the snapshot, since which cards are on screen, and whether a newer
/// request or answer arrived while a read was in flight, is screen state.
@MainActor protocol HermesConversationOwner: AnyObject {
    /// A new attach or `suspend()` cleared the connection. Drop what belonged to it.
    func conversationDidReset()
    /// Before connecting: restore local state, such as the draft. `attempt` is the attach's generation.
    func conversationWillAttach(_ attempt: Int) async throws
    /// The attach found the session's root: the Bot Chat's canonical root, or the session's key.
    /// After `session.create`, `target` is already `.session`, so its keys exist from here.
    /// The owner moves anything saved under the `.new` target's keys, such as the draft, once
    /// it belongs to the session: the Sessions owner waits for the first accepted prompt.
    func conversationDidIdentify(root: String)
    /// The identity resume reached `runtime`; the replay is next. `newRuntime` when it is
    /// not the runtime the last attach reached, so no turn carried over.
    func conversationWillReplay(newRuntime: Bool)
    /// The `session.events.since` reply and the events after the cursor, in order. When
    /// `replayWasReset` some were lost: rebuild from the snapshot that follows.
    func conversationDidReplay(_ reply: BotJSON, frames: [BotJSON])
    /// The attach's one full `session.resume`, transcript included.
    func conversationDidReadSnapshot(_ snapshot: BotJSON, runtime: String, attempt: Int) async throws
    /// Connected, with the frames held while attaching applied.
    func conversationDidConnect(runtime: String, attempt: Int) async throws
    /// The attach failed with `error`; `disconnect` follows.
    func conversationDidFailToAttach(_ error: Error)
    /// One of this runtime's frames, in `seq` order with duplicates dropped. `afterGap`
    /// when frames before it were lost: the rebuild signal, and `replayWasReset` is set.
    func conversation(didReceive frame: BotJSON, afterGap: Bool)
    /// Frames were lost with none to apply: one came without a `seq`, or more arrived
    /// while attaching than the hold keeps. Rebuild from a full snapshot.
    func conversationDidLoseFrames()
    /// A frame held while attaching; it is handed over once connected.
    func conversation(didHold frame: BotJSON)
    /// A host request envelope (a string `id`) for this runtime. Never sequenced or held.
    func conversation(didReceiveRequest envelope: BotJSON)
    /// After every event while attaching or connected, this runtime's or not.
    func conversationDidReceiveEvent()
    /// The connection is about to drop: state that needs it still connected goes now.
    func conversationWillDisconnect()
    /// Disconnected with `failure`. `retrying` when the engine reconnects on its own.
    func conversationDidDisconnect(_ failure: BotFailure, retrying: Bool)
}

extension HermesConversationOwner {
    func conversationWillAttach(_ attempt: Int) async throws {}
    func conversationDidIdentify(root: String) {}
    func conversationWillReplay(newRuntime: Bool) {}
    func conversationDidConnect(runtime: String, attempt: Int) async throws {}
    func conversationDidFailToAttach(_ error: Error) {}
    func conversation(didHold frame: BotJSON) {}
    func conversation(didReceiveRequest envelope: BotJSON) {}
    func conversationDidReceiveEvent() {}
    func conversationWillDisconnect() {}
}

/// Keeps one screen attached to one Hermes session on the connection's shared socket.
///
/// An attach reads, in order: the session's identity (`session.list` for a Bot Chat;
/// `session.create` once for a new session), an identity `session.resume` with
/// `omit_messages`, `session.events.since` from the last `seq`, then one full
/// `session.resume`. Frames that land meanwhile are held (#901) and handed over once the
/// owner has the snapshot. A drop reconnects on a backoff while the screen is active.
/// Recovery only reads; a prompt, answer, stop or setting goes out through `write`, once,
/// from a deliberate action, and is never resent.
///
/// Two ids per session: the stored key names it and goes in the drafts and caches; the
/// runtime id keys session-scoped calls and `seq`, changes after a reap, and is never kept.
@MainActor @Observable final class HermesConversation {
    enum ConnectionState { case disconnected, recovering, connected }

    /// The host's replay ring per session: 512 events.
    static let heldFrameLimit = 512
    /// How long `session.resume` refusals (4007, 4009) are retried before the advice shows.
    private static let resumeRefusalWindow = Duration.seconds(60)

    let server: URL
    let connection: BotConnection
    private(set) var target: ConversationTarget
    /// The screen's handle on the shared socket. Only this engine sets its callbacks.
    let wire: any BotTransport
    @ObservationIgnored weak var owner: (any HermesConversationOwner)?

    private(set) var connectionState = ConnectionState.disconnected
    /// Bumped by every reset, so work begun under an older attach knows it is stale.
    private(set) var generation = 0
    /// The Bot Chat's canonical root, or the session's key.
    private(set) var root: String?
    /// The root a Bot Chat deep link named. Seeded into `root`, so the changed-root
    /// rejection refuses the bot's replacement chat under the link's identity (#554).
    private let linkedRoot: String?
    /// Set when that seeded root is not the bot's canonical chat any more.
    private(set) var linkedRootIsStale = false
    /// The stored key `session.resume` attaches: the Bot Chat's compression tip, or the
    /// key the host resolved for a session.
    private(set) var storedKey: String?
    private(set) var runtime: String?
    private(set) var sequence = 0
    private(set) var epoch: String?
    /// True when frames were lost since the last attach began; the owner rebuilds.
    private(set) var replayWasReset = false
    /// True from `activate()` until `suspend()`: the screen wants this session connected,
    /// whether it is, is reconnecting, or failed and shows why.
    private(set) var isActive = false
    private(set) var isReconnecting = false
    private var shouldRetryConnection = false
    /// This runtime's frames that arrived while attaching, applied once the replay and the
    /// snapshot are in, so a live frame never moves `sequence` past events the replay is
    /// about to apply. At most `heldFrameLimit`; frames past it are only counted in
    /// `framesPastHold`, and any of those makes the release a gap.
    @ObservationIgnored private var heldFrames: [BotJSON] = []
    @ObservationIgnored private var framesPastHold = 0
    /// When `session.resume` first refused this run of reconnects with 4007 or 4009; nil
    /// once a reconnect succeeds, fails another way, or the screen leaves.
    @ObservationIgnored private var resumeRefusedSince: ContinuousClock.Instant?
    /// Automatic reconnect attempts since the last connect, for the log.
    @ObservationIgnored private var reconnectRetries = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    private let reconnectDelay: (Duration) async throws -> Void
    private let now: () -> ContinuousClock.Instant

    /// `linkedRoot` is a Bot Chat deep link's root; nil for every other open.
    init(server: URL, connection: BotConnection, target: ConversationTarget, linkedRoot: String? = nil,
         wire: any BotTransport,
         reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.server = server; self.connection = connection; self.target = target
        self.linkedRoot = linkedRoot; self.root = linkedRoot
        self.wire = wire
        self.reconnectDelay = reconnectDelay; self.now = now
        wire.onEvent = { [weak self] event in self?.receive(event) }
        wire.onDisconnect = { [weak self] error in self?.disconnect(error) }
    }

    /// Wants the session connected until `suspend()`, and attaches now.
    func activate() async {
        isActive = true
        await attach()
    }

    /// Leaves: stops reconnecting and drops the connection. The host session stays.
    func suspend() {
        isActive = false; shouldRetryConnection = false; isReconnecting = false
        reconnectTask?.cancel(); reconnectTask = nil
        resumeRefusedSince = nil; reconnectRetries = 0
        reset()
    }

    /// Throws `.stale` once a newer attach began or the task was cancelled.
    func check(_ attempt: Int) throws {
        guard generation == attempt, !Task.isCancelled else { throw BotFailure.stale }
    }

    /// Sends one call under the attach `attempt` began. `validateDispatch` runs at the
    /// socket write, so a call that went stale while queued is never sent.
    func request(_ call: HermesCall, attempt: Int, validateDispatch: (() throws -> Void)? = nil) async throws -> BotJSON {
        try check(attempt)
        let reply = try await wire.call(call, validateDispatch: validateDispatch)
        try check(attempt)
        return reply
    }

    /// Sends one deliberate write (a prompt, stop, answer or setting) bound to the attach
    /// and runtime the user acted on. At the socket write it is refused with `.stale` once
    /// a newer attach began or the runtime changed; `stillCurrent` adds the owner's checks.
    /// Nothing resends it: after a lost reply the next snapshot says what happened.
    func write(_ call: HermesCall, attempt: Int, runtime: String,
               stillCurrent: (() throws -> Void)? = nil) async throws -> BotJSON {
        try await request(call, attempt: attempt) { [weak self] in
            guard let self else { throw BotFailure.stale }
            try self.check(attempt)
            guard self.runtime == runtime else { throw BotFailure.stale }
            try stillCurrent?()
        }
    }

    /// Reads the session's live state; `full` asks for the transcript as well. The host
    /// answers 4007 while it swaps in a replacement runtime and 4009 while a client-gone
    /// interrupt settles, and both clear on their own, so they come back as
    /// `ResumeRefusal` for the reconnect window. Matched by code alone: a real "session
    /// not found" also says 4007, and only the host's wording, which can change, differs.
    func resume(full: Bool, attempt: Int) async throws -> BotJSON {
        do {
            return try await request(.sessionResume(profile: target.profile, sessionID: storedKey ?? "", omitMessages: !full),
                                     attempt: attempt)
        } catch BotFailure.rejected(let code) where [4007, 4009].contains(code) {
            throw ResumeRefusal(code: code)
        }
    }

    /// Whether a `session.resume` reply is this attach's: its runtime and stored key. A
    /// session that has not started answers in the reduced shape, with `stored_session_id`
    /// in place of `session_key`; a Bot Chat's reply must carry `session_key`.
    func isCurrent(_ reply: BotJSON) -> Bool {
        reply["session_id"].text == runtime && attachedKey(reply) == storedKey
    }

    /// Ends the connection after `error` and reconnects on the backoff while active and
    /// the failure can clear on its own.
    func disconnect(_ error: Error) {
        owner?.conversationWillDisconnect()
        wire.close()
        heldFrames = []; framesPastHold = 0
        connectionState = .disconnected
        let refusal = error as? ResumeRefusal
        let failure = refusal.map { BotFailure.rejected($0.code) } ?? error as? BotFailure ?? .transport
        if let refusal {
            // Retried on the backoff until a minute after the first refusal in a row.
            let since = resumeRefusedSince ?? now()
            resumeRefusedSince = since
            shouldRetryConnection = since.duration(to: now()) < Self.resumeRefusalWindow
            let code = refusal.code, retrying = shouldRetryConnection, name = logName
            HermesConnectionLog.logger.notice("\(name, privacy: .public): session.resume refused with \(code, privacy: .public); \(retrying ? "within" : "past", privacy: .public) the retry window")
        } else {
            resumeRefusedSince = nil
            switch failure {
            case .transport: shouldRetryConnection = true
            case .rejected(let code): shouldRetryConnection = [408, 429].contains(code) || (500...599).contains(code)
            default: shouldRetryConnection = false
            }
        }
        owner?.conversationDidDisconnect(failure, retrying: shouldRetryConnection)
        scheduleReconnect()
    }

    /// A `session.resume` the host refused for now (see `resume(full:attempt:)`).
    private struct ResumeRefusal: Error { let code: Int }

    /// The log's name for this kind of conversation: never an id or a Profile name.
    private var logName: String {
        if case .canonicalChat = target { return "Bot Chat" }
        return "Hermes session"
    }

    private func reset() {
        generation += 1
        wire.close()
        heldFrames = []; framesPastHold = 0
        connectionState = .disconnected
        owner?.conversationDidReset()
    }

    private func attach() async {
        reset()
        let attempt = generation
        connectionState = .recovering
        do {
            try await owner?.conversationWillAttach(attempt)
            try check(attempt)
            try await wire.connect()
            try check(attempt)
            try await identify(attempt)
            // Identity only: the full read below is the one that carries the transcript.
            let first = try await resume(full: false, attempt: attempt)
            guard let foundKey = attachedKey(first), let foundRuntime = first["session_id"].text,
                  !foundRuntime.isEmpty, let foundEpoch = wire.replayEpoch else { throw BotFailure.wrongIdentity }
            replayWasReset = epoch != foundEpoch || runtime != foundRuntime
            let newRuntime = runtime != foundRuntime
            if replayWasReset { sequence = 0 }
            runtime = foundRuntime; epoch = foundEpoch; storedKey = foundKey
            owner?.conversationWillReplay(newRuntime: newRuntime)
            let replay = try await request(.sessionEventsSince(sessionID: foundRuntime, lastSeen: sequence), attempt: attempt)
            let missed = try reconcile(replay)
            owner?.conversationDidReplay(replay, frames: missed)
            let snapshot = try await resume(full: true, attempt: attempt)
            try await owner?.conversationDidReadSnapshot(snapshot, runtime: foundRuntime, attempt: attempt)
            try check(attempt)
            guard connectionState == .recovering else { throw BotFailure.transport }
            connectionState = .connected
            let frames = releaseHeldFrames()
            let retries = reconnectRetries, name = logName
            HermesConnectionLog.logger.notice("\(name, privacy: .public) reattached after \(retries, privacy: .public) retries: frames held \(frames.held, privacy: .public), applied \(frames.applied, privacy: .public), dropped \(frames.dropped, privacy: .public)")
            reconnectRetries = 0; resumeRefusedSince = nil
            shouldRetryConnection = false
            try await owner?.conversationDidConnect(runtime: foundRuntime, attempt: attempt)
        } catch {
            guard attempt == generation, !Task.isCancelled else { return }
            owner?.conversationDidFailToAttach(error)
            disconnect(error)
        }
    }

    /// Settles which stored key to resume. A Bot Chat is looked up by its title on every
    /// attach, and a changed root is refused before resume, which can auto-continue. A
    /// session resumes its own key; the host follows it to a compression tip. A new
    /// session is created here once, then is a session.
    private func identify(_ attempt: Int) async throws {
        switch target {
        case .canonicalChat(let profile):
            let lookup = try await request(.sessionList(profile: profile), attempt: attempt)
            guard let rows = lookup["sessions"].list else { throw BotFailure.unsupported }
            guard rows.count == 1 else { throw BotFailure.missingChat }
            guard let foundRoot = rows[0]["id"].text, !foundRoot.isEmpty,
                  let foundTip = rows[0]["resolved_id"].text, !foundTip.isEmpty else { throw BotFailure.unsupported }
            if let root, root != foundRoot {
                // The rejected root is the one a deep link named: report it so the
                // inbox can say so, rather than sitting on an error the user cannot act on.
                if root == linkedRoot { linkedRootIsStale = true }
                throw BotFailure.wrongIdentity
            }
            root = foundRoot; storedKey = foundTip
            owner?.conversationDidIdentify(root: foundRoot)
        case .session(_, let key):
            root = key; storedKey = key
            owner?.conversationDidIdentify(root: key)
        case .new(let profile):
            // A lost reply may leave a session on the host that this phone never learns
            // of. The host keeps no row for it until its first prompt and reaps it.
            let created = try await request(.sessionNew(profile: profile), attempt: attempt)
            guard let key = created["stored_session_id"].text, !key.isEmpty,
                  created["session_id"].text?.isEmpty == false else { throw BotFailure.unsupported }
            target = .session(profile: profile, key: key)
            root = key; storedKey = key
            owner?.conversationDidIdentify(root: key)
        }
    }

    /// The stored key a `session.resume` reply attached. A Bot Chat's must be the tip its
    /// lookup found. A session takes the key the host resolved: `session_key`, or
    /// `stored_session_id` in the reduced reply of a session that has not started.
    private func attachedKey(_ reply: BotJSON) -> String? {
        if case .canonicalChat = target {
            return reply["session_key"].text == storedKey ? storedKey : nil
        }
        guard let key = reply["session_key"].text ?? reply["stored_session_id"].text, !key.isEmpty else { return nil }
        return key
    }

    /// Checks a `session.events.since` reply and moves the cursor to its `latest_seq`.
    /// Returns the events after the old cursor, in order. A new epoch, a truncated ring, a
    /// hole, or a cursor ahead of the host's sets `replayWasReset`.
    private func reconcile(_ reply: BotJSON) throws -> [BotJSON] {
        guard let latest = reply["latest_seq"].integer, latest >= 0,
              let receivedEpoch = reply["epoch"].text, !receivedEpoch.isEmpty,
              let truncated = reply["truncated"].flag, let events = reply["events"].list else { throw BotFailure.unsupported }
        if epoch != receivedEpoch || truncated || latest < sequence { replayWasReset = true }
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
        return missed
    }

    /// Routes one event from the shared socket, which carries other screens' sessions
    /// too: only this runtime's frames and host requests reach the owner.
    private func receive(_ event: BotJSON) {
        guard connectionState != .disconnected, runtime != nil else { return }
        defer { owner?.conversationDidReceiveEvent() }
        if let session = Self.requestSession(event) {
            guard session == runtime else { return }
            owner?.conversation(didReceiveRequest: event)
            return
        }
        guard event["session_id"].text == runtime else { return }
        guard connectionState == .connected else {
            if heldFrames.count < Self.heldFrameLimit { heldFrames.append(event) } else { framesPastHold += 1 }
            owner?.conversation(didHold: event)
            return
        }
        admit(event)
    }

    /// The session a host request envelope names: a string `id`, a `method` and
    /// `params.session_id`. Nil for a sequenced event.
    private static func requestSession(_ event: BotJSON) -> String? {
        guard let id = event["id"].text, !id.isEmpty, let method = event["method"].text, !method.isEmpty,
              let session = event["params"]["session_id"].text, !session.isEmpty else { return nil }
        return session
    }

    /// Hands one of this runtime's frames to the owner in `seq` order, saying when frames
    /// before it were lost. A repeat of the last frame is dropped.
    private func admit(_ event: BotJSON) {
        guard let next = event["seq"].integer, next > 0 else {
            replayWasReset = true
            owner?.conversationDidLoseFrames()
            return
        }
        guard next != sequence else { return }
        let gap = next != sequence + 1
        if gap { replayWasReset = true }
        sequence = next
        owner?.conversation(didReceive: event, afterGap: gap)
    }

    /// Applies the frames held while attaching, now that the replay and the snapshot are
    /// in: one the replay already covered (or for a runtime this attach left) is dropped,
    /// and each later one takes the live path. Frames past the hold limit are lost, so the
    /// owner rebuilds from a full snapshot, as after a truncated replay.
    private func releaseHeldFrames() -> (held: Int, applied: Int, dropped: Int) {
        let frames = heldFrames, lost = framesPastHold
        heldFrames = []; framesPastHold = 0
        guard lost == 0 else {
            replayWasReset = true
            owner?.conversationDidLoseFrames()
            return (frames.count + lost, 0, frames.count + lost)
        }
        var applied = 0
        for event in frames where event["session_id"].text == runtime {
            if let seq = event["seq"].integer, seq > 0, seq <= sequence { continue }
            admit(event)
            applied += 1
        }
        return (frames.count, applied, frames.count - applied)
    }

    /// Reattaches while the screen is active, after 1, 2, 4, 8, 16 and then at most 30
    /// seconds. Reattaching only reads: nothing the user sent is sent again.
    private func scheduleReconnect() {
        guard isActive, shouldRetryConnection, reconnectTask == nil else { return }
        isReconnecting = true
        let delay = reconnectDelay
        reconnectTask = Task { [weak self] in
            var seconds = 1
            while !Task.isCancelled {
                do { try await delay(.seconds(seconds)) } catch { return }
                guard let self, self.isActive, self.shouldRetryConnection, !Task.isCancelled else { return }
                self.reconnectRetries += 1
                await self.attach()
                guard !Task.isCancelled else { return }
                if !self.shouldRetryConnection || self.connectionState == .connected {
                    self.isReconnecting = false; self.reconnectTask = nil
                    return
                }
                seconds = min(seconds * 2, 30)
            }
        }
    }
}
