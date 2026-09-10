import Foundation
import Observation

@MainActor @Observable final class BotConversation {
    enum ConnectionState { case disconnected, recovering, connected }
    enum TurnState { case unknown, idle, submitting, running, needsAttention, stopping, uncertain, interrupted }
    struct StopAction: Equatable { let generation: Int; let revision: Int; let runtime: String }

    let profile: BotProfile
    let connection: BotConnection
    let server: URL
    private(set) var connectionState = ConnectionState.disconnected
    private(set) var turn = TurnState.unknown
    private(set) var messages: [ChatMessage] = []
    private(set) var liveMessages: [ChatMessage] = []
    private(set) var errorMessage: String?
    private(set) var draft = ""
    private(set) var uncertainSend = false
    private(set) var uncertainStop = false
    private(set) var root: String?
    private(set) var runtime: String?
    private(set) var sequence = 0
    private(set) var epoch: String?
    private(set) var replayWasReset = false
    private var tip: String?
    private var generation = 0
    private var turnRevision = 0
    private var turnStartedAt: Double?
    private var snapshotDirty = false
    private var fullSnapshotNeeded = false
    private var refreshTask: Task<Void, Never>?
    private var stopAcknowledged = false
    private var localOperation = false
    private var hydrated = false
    private let wire: any BotTransport
    private let drafts: ChatDraftStore

    init(server: URL, connection: BotConnection, profile: BotProfile,
         wire: (any BotTransport)? = nil, drafts: ChatDraftStore? = nil) {
        self.server = server; self.connection = connection; self.profile = profile
        self.wire = wire ?? BotClient(connection: connection)
        self.drafts = drafts ?? .shared
        self.wire.onEvent = { [weak self] event in self?.observe(event) }
        self.wire.onDisconnect = { [weak self] error in self?.disconnected(error) }
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

    func editDraft(_ text: String) {
        guard hydrated, !uncertainSend, !localOperation else { return }
        draft = text
        drafts.setDraft(text, for: draftKey)
    }

    func recover() async {
        suspend()
        let owner = generation
        connectionState = .recovering
        errorMessage = nil
        do {
            if !hydrated {
                let saved = await drafts.draft(for: draftKey)
                try check(owner)
                draft = saved?.text ?? ""
                uncertainSend = saved?.botSubmissionUncertain ?? false
                hydrated = true
            }
            try await wire.connect()
            try check(owner)
            let lookup = try await request("session.list", ["profile": .string(profile.id), "title": .string("Bot Chat"), "include_hidden": .bool(true)], owner: owner)
            guard let rows = lookup["sessions"].list else { throw BotFailure.unsupported }
            guard rows.count == 1 else { throw BotFailure.missingChat }
            guard let foundRoot = rows[0]["id"].text, !foundRoot.isEmpty,
                  let foundTip = rows[0]["resolved_id"].text, !foundTip.isEmpty else { throw BotFailure.unsupported }
            // Resume can auto-continue. Reject a changed root before making that call.
            if let root, root != foundRoot { throw BotFailure.wrongIdentity }
            root = foundRoot; tip = foundTip
            let first = try await request("session.resume", resumeParams(), owner: owner)
            guard first["session_key"].text == foundTip, let foundRuntime = first["session_id"].text,
                  !foundRuntime.isEmpty, let foundEpoch = wire.replayEpoch else { throw BotFailure.wrongIdentity }
            replayWasReset = epoch != foundEpoch || runtime != foundRuntime
            if replayWasReset { sequence = 0 }
            runtime = foundRuntime; epoch = foundEpoch
            let replay = try await request("session.events.since", ["session_id": .string(foundRuntime), "last_seen": .number(Double(sequence))], owner: owner)
            try reconcileReplay(replay)
            let current = try await request("session.resume", resumeParams(), owner: owner)
            try applySnapshot(current, full: true)
            try check(owner)
            connectionState = .connected
            scheduleRefresh()
        } catch {
            guard owner == generation, !Task.isCancelled else { return }
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

    private func reconcileReplay(_ reply: BotJSON) throws {
        guard let latest = reply["latest_seq"].integer, latest >= 0,
              let receivedEpoch = reply["epoch"].text, !receivedEpoch.isEmpty,
              let truncated = reply["truncated"].flag, let events = reply["events"].list else { throw BotFailure.unsupported }
        if epoch != receivedEpoch || truncated || latest < sequence { replayWasReset = true }
        var cursor = sequence
        for event in events {
            guard event["session_id"].text == runtime else { throw BotFailure.wrongIdentity }
            guard let next = event["seq"].integer, next > 0, next <= latest else { throw BotFailure.unsupported }
            if next <= cursor { continue }
            if next != cursor + 1 { replayWasReset = true }
            cursor = next
        }
        if cursor < latest { replayWasReset = true }
        epoch = receivedEpoch; sequence = latest
        // Replay is only a continuity check. A full snapshot replaces text below.
    }

    private func applySnapshot(_ snapshot: BotJSON, full: Bool) throws {
        guard snapshot["session_id"].text == runtime, snapshot["session_key"].text == tip,
              let running = snapshot["running"].flag, snapshot["hydrating"].flag != true else { throw BotFailure.unsupported }
        if let value = snapshot["info"]["profile_name"].text, value != profile.id { throw BotFailure.wrongIdentity }
        if full {
            guard let history = snapshot["messages"].list, snapshot["messages_omitted"].flag != true else { throw BotFailure.unsupported }
            messages = history.enumerated().compactMap { index, row in
                guard let role = row["role"].text, ["user", "assistant"].contains(role), let text = row["text"].text else { return nil }
                return ChatMessage(role: role, content: text, timestamp: nil, messageId: "\(root ?? "")/\(index)")
            }
        }
        let inflight = snapshot["inflight"]
        let startedAt = inflight["started_at"].number ?? snapshot["turn_started_at"].number
        if startedAt != turnStartedAt { turnRevision += 1; turnStartedAt = startedAt }
        liveMessages = []
        if let text = inflight["user"].text, !text.isEmpty {
            liveMessages.append(ChatMessage(role: "user", content: text, timestamp: nil, messageId: "live-user"))
        }
        if let text = inflight["assistant"].text, !text.isEmpty {
            liveMessages.append(ChatMessage(role: "assistant", content: text, timestamp: nil, messageId: "live-assistant"))
        }
        if !running { uncertainStop = false; stopAcknowledged = false }
        let attention = snapshot["pending_approval"] != .null || snapshot["pending_clarify"] != .null
        let continuation = snapshot["auto_continue"] != .null && snapshot["auto_continue"].flag != false
        let queued = snapshot["queued"] != .null
        if attention { turn = .needsAttention }
        else if uncertainStop && stopAcknowledged { turn = .stopping }
        else if uncertainSend || uncertainStop { turn = .uncertain }
        else if localOperation { /* A snapshot cannot acknowledge a local command. */ }
        else if running || continuation || queued { turn = .running }
        else if inflight["error"] != .null || snapshot["status"].text == "interrupted" { turn = .interrupted }
        else { turn = .idle }
    }

    func send() async {
        guard maySend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let runtime else { return }
        let owner = generation
        let text = draft
        let revision = turnRevision
        localOperation = true; turn = .submitting; uncertainSend = true
        drafts.setBotSubmissionUncertain(true, for: draftKey)
        do {
            // No network dispatch until the durable ambiguity marker is on disk.
            try await drafts.flush()
            try check(owner)
        } catch {
            guard owner == generation else { return }
            localOperation = false; uncertainSend = false
            drafts.setBotSubmissionUncertain(false, for: draftKey)
            turn = .idle; errorMessage = String(localized: "Could not save the draft. Your message was not sent.")
            return
        }
        do {
            _ = try await request("prompt.submit", ["session_id": .string(runtime), "text": .string(text)], owner: owner) { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner)
                guard self.turnRevision == revision else { throw BotFailure.stale }
            }
            drafts.setDraft("", for: draftKey)
            drafts.setBotSubmissionUncertain(false, for: draftKey)
            try await drafts.flush()
            try check(owner)
            draft = ""; uncertainSend = false; localOperation = false; turn = .running
            fullSnapshotNeeded = true; snapshotDirty = true; scheduleRefresh()
        } catch {
            guard owner == generation, !Task.isCancelled else { return }
            localOperation = false
            if error as? BotFailure == .stale {
                uncertainSend = false
                drafts.setBotSubmissionUncertain(false, for: draftKey)
                try? await drafts.flush()
            }
            if case BotFailure.rejected(let code) = error {
                // Only explicit admission/auth/parameter failures establish nonacceptance.
                if [401, 403, 4090, -32601, -32602].contains(code) {
                    uncertainSend = false
                    drafts.setBotSubmissionUncertain(false, for: draftKey)
                    try? await drafts.flush()
                }
            }
            disconnected(error)
        }
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

    /// Explicitly discard a held ambiguous prompt after the user checks Desktop.
    /// The old text is never restored to the sendable composer.
    func discardUncertainSubmission() async {
        guard uncertainSend, connectionState == .connected, !localOperation else { return }
        let owner = generation
        drafts.setDraft("", for: draftKey)
        drafts.setBotSubmissionUncertain(false, for: draftKey)
        do {
            try await drafts.flush()
            try check(owner)
            draft = ""; uncertainSend = false
            await recover()
        } catch {
            if owner == generation {
                drafts.setBotSubmissionUncertain(true, for: draftKey)
                errorMessage = String(localized: "Could not save the draft. The held message is still unresolved.")
            }
        }
    }

    private func observe(_ event: BotJSON) {
        guard connectionState != .disconnected, event["session_id"].text == runtime, runtime != nil else { return }
        guard let next = event["seq"].integer, next > 0 else {
            replayWasReset = true; snapshotDirty = true; fullSnapshotNeeded = true
            turnRevision += 1
            if !localOperation { turn = .unknown }
            scheduleRefresh(); return
        }
        guard next != sequence else { return }
        let discontinuity = next != sequence + 1
        if discontinuity {
            replayWasReset = true; fullSnapshotNeeded = true; turnRevision += 1
            if !localOperation { turn = .unknown }
        }
        sequence = next
        let type = event["type"].text ?? ""
        if ["message.start", "message.complete", "session.info", "error", "approval.request", "clarify.request"].contains(type) {
            turnRevision += 1
            fullSnapshotNeeded = true
            // Current state is pending reconciliation; don't dispatch new work.
            if !localOperation { turn = .unknown }
        }
        if type == "message.delta", !discontinuity, !localOperation, !uncertainSend, !uncertainStop { turn = .running }
        snapshotDirty = true
        scheduleRefresh()
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
                    let reply = try await self.request("session.resume", self.resumeParams(full: full), owner: owner)
                    try self.applySnapshot(reply, full: full)
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
        wire.close()
        refreshTask?.cancel(); refreshTask = nil
        connectionState = .disconnected
        turn = uncertainSend || uncertainStop ? .uncertain : .unknown
        turnRevision += 1
        errorMessage = (error as? BotFailure ?? .transport).localizedDescription
    }

    func suspend() {
        generation += 1; turnRevision += 1
        refreshTask?.cancel(); refreshTask = nil
        wire.close()
        localOperation = false
        connectionState = .disconnected; turn = .unknown
        Task { try? await drafts.flush() }
    }
}
