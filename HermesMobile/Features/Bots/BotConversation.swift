import Foundation
import Observation

@MainActor @Observable final class BotConversation {
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
    }

    private(set) var submittingPrompt: BotPromptMode?
    private(set) var promptReceipt: String?
    private(set) var unavailablePromptModes: Set<BotPromptMode> = []

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
    private(set) var settledActivity: [BotSettledActivity] = []
    private(set) var liveActivity = BotTurnActivity()
    private(set) var plan: BotPlan?
    /// `status.update` text while the bot works (compacting, compressing); nil once ready.
    private(set) var workStatus: String?
    /// The approval or question from the last snapshot's `pending_approval` /
    /// `pending_clarify`. Snapshot-owned, so an answer given in Desktop clears it
    /// on the next read without the phone polling for it.
    private(set) var blockingRequest: BotPendingRequest?
    /// A credential prompt or a Desktop-renderer task. Neither appears in a
    /// snapshot, so they live and die with the event stream.
    private(set) var streamRequest: BotStreamRequest?
    /// Set while an answer is in flight, to keep the card's controls inert.
    private(set) var answeringRequestID: String?
    /// The verdict on the request currently on screen, if it has one.
    private(set) var requestResolution: BotRequestResolution?
    private var tip: String?
    private var generation = 0
    private var turnRevision = 0
    private var turnStartedAt: Double?
    private var snapshotIsBusy: Bool?
    private var snapshotDirty = false
    private var fullSnapshotNeeded = false
    private var refreshTask: Task<Void, Never>?
    private var stopAcknowledged = false
    private var promptReceiptPersistsWhileIdle = false
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

    var mayGuide: Bool {
        hydrated && connectionState == .connected && [.running, .needsAttention].contains(turn)
            && !localOperation && !uncertainSend && !uncertainStop && answeringRequestID == nil
    }

    func maySubmit(_ mode: BotPromptMode) -> Bool {
        !unavailablePromptModes.contains(mode) && (mode == .send ? maySend : mayGuide)
    }

    func preparePrompt(_ mode: BotPromptMode) -> PromptAction? {
        guard maySubmit(mode), let runtime,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PromptAction(generation: generation, revision: turnRevision, runtime: runtime, mode: mode, text: draft)
    }

    var mayEditDraft: Bool { hydrated && !uncertainSend && !localOperation }

    /// The one request blocking this conversation. A clarify or approval wins over
    /// a stream request: it is the outer blocker, and the host resolves the inner
    /// one on its own deadline either way.
    var pendingRequest: BotPendingRequest? {
        blockingRequest ?? streamRequest?.pending
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
            if replayWasReset {
                sequence = 0
                promptReceipt = nil; promptReceiptPersistsWhileIdle = false
            }
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
            // Credential and Desktop-task prompts reach no snapshot, so while the
            // ring still holds them replay is the only way back to one after a
            // reconnect. Dropping them here left a blocked bot looking idle.
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
            liveActivity = BotTurnActivity(); workStatus = nil; streamRequest = nil
            return false
        case "todo.updated":
            if let next = BotPlan(payload), next.revision >= (plan?.revision ?? 0) { plan = next }
        case "status.update":
            let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            workStatus = payload["kind"].text == "ready" || text.isEmpty ? nil : text
        default:
            return liveActivity.apply(type: type, payload: payload)
        }
        return true
    }

    private func applySnapshot(_ snapshot: BotJSON, full: Bool) throws {
        guard snapshot["session_id"].text == runtime, snapshot["session_key"].text == tip,
              let running = snapshot["running"].flag, snapshot["hydrating"].flag != true else { throw BotFailure.unsupported }
        if let value = snapshot["info"]["profile_name"].text, value != profile.id { throw BotFailure.wrongIdentity }
        if full {
            guard let history = snapshot["messages"].list, snapshot["messages_omitted"].flag != true else { throw BotFailure.unsupported }
            let projected = BotTranscriptProjection.project(history: history, root: root ?? "")
            messages = projected.messages
            settledActivity = projected.activity
        }
        if let next = BotPlan(snapshot["todo_state"]), next.revision >= (plan?.revision ?? 0) { plan = next }
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
        if !running {
            uncertainStop = false; stopAcknowledged = false; workStatus = nil
            streamRequest = nil
            // Only a full snapshot carries the settled rows, so live rows wait for it
            // instead of vanishing on the inflight read that first reports idle.
            if full { liveActivity.clearTurnWork() }
        }
        applyPendingRequest(snapshot)
        // A request the phone cannot address still blocks the bot. Claiming the
        // turn is running would be the lie; attention without a card is the truth.
        let attention = pendingRequest != nil
            || snapshot["pending_approval"] != .null || snapshot["pending_clarify"] != .null
        let continuation = snapshot["auto_continue"] != .null && snapshot["auto_continue"].flag != false
        let queued = snapshot["queued"] != .null
        let busy = running || continuation || queued || attention
        // Receipts confirm admission; the snapshot owns whether that admitted work
        // is still active. Do not leave an old confirmation above an idle composer.
        if (!busy && !promptReceiptPersistsWhileIdle) || (busy && promptReceiptPersistsWhileIdle) {
            promptReceipt = nil; promptReceiptPersistsWhileIdle = false
        }
        if snapshotIsBusy != busy { turnRevision += 1; snapshotIsBusy = busy }
        if attention { turn = .needsAttention }
        else if uncertainStop && stopAcknowledged { turn = .stopping }
        else if uncertainSend || uncertainStop { turn = .uncertain }
        else if localOperation { /* A snapshot cannot acknowledge a local command. */ }
        else if running || continuation || queued { turn = .running }
        else if inflight["error"] != .null || snapshot["status"].text == "interrupted" { turn = .interrupted }
        else { turn = .idle }
    }

    /// Installs the snapshot's pending approval or question. A clarify outranks an
    /// approval because approvals resolve inside a tool batch while a clarify blocks
    /// the whole turn. A different request id drops the previous request's verdict
    /// so a new card is never born inert.
    private func applyPendingRequest(_ snapshot: BotJSON) {
        let question = BotQuestionRequest(snapshot["pending_clarify"]).map(BotPendingRequest.question)
        let approval = BotApprovalRequest(snapshot["pending_approval"]).map(BotPendingRequest.approval)
        let next = question ?? approval
        if next?.requestID != blockingRequest?.requestID {
            answeringRequestID = nil
            if requestResolution?.requestID != next?.requestID { requestResolution = nil }
        }
        blockingRequest = next
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
        localOperation = true; uncertainSend = true; submittingPrompt = action.mode
        promptReceipt = nil; promptReceiptPersistsWhileIdle = false; errorMessage = nil
        defer { if generation == owner { submittingPrompt = nil } }
        drafts.setBotSubmissionUncertain(true, for: draftKey)
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
        do {
            let reply = try await request(action.mode.method, action.mode.params(runtime: action.runtime, text: action.text), owner: owner) { [weak self] in
                guard let self else { throw BotFailure.stale }
                try self.check(owner)
                guard self.connectionState == .connected, self.runtime == action.runtime,
                      self.turnRevision == action.revision else { throw BotFailure.stale }
            }
            let outcome = action.mode.outcome(reply)
            if outcome == .rejected {
                try await releasePromptMarker(owner: owner)
                localOperation = false
                errorMessage = String(localized: "The bot did not accept this message. Your draft is still here.")
                refreshAfterPrompt()
                return
            }
            guard let receipt = outcome.receipt else { throw BotFailure.unsupported }
            drafts.setDraft("", for: draftKey)
            drafts.setBotSubmissionUncertain(false, for: draftKey)
            try await drafts.flush()
            try check(owner)
            draft = ""; uncertainSend = false; localOperation = false
            promptReceipt = receipt
            promptReceiptPersistsWhileIdle = outcome == .voiceStopped
            refreshAfterPrompt()
        } catch {
            guard owner == generation, !Task.isCancelled else { return }
            // Only failures known to precede admission release the draft. A 5000
            // may follow a side effect; an unrecognized success shape is ambiguous.
            let safe = error as? BotFailure == .stale || action.mode.definitelyRejected(error)
            if safe {
                do { try await releasePromptMarker(owner: owner) }
                catch { guard owner == generation else { return }; disconnected(error); localOperation = false; return }
            }
            guard owner == generation else { return }
            if !safe {
                // A failed durable clear must leave the original text held too.
                drafts.setDraft(action.text, for: draftKey)
                drafts.setBotSubmissionUncertain(true, for: draftKey)
                try? await drafts.flush()
                guard owner == generation, !Task.isCancelled else { return }
            }
            localOperation = false
            let needsRecovery: Bool
            if case BotFailure.rejected(let code) = error { needsRecovery = [401, 403, 4001, 4090].contains(code) }
            else { needsRecovery = false }
            if action.mode != .send, safe, !needsRecovery {
                if case BotFailure.rejected(let code) = error, [-32601, 4010].contains(code) {
                    // 4010 can be temporary during initialization; do not hide it
                    // permanently. A missing method stays unavailable this lifetime.
                    if code == -32601 { unavailablePromptModes.insert(action.mode) }
                    errorMessage = String(localized: "This action is unavailable for the bot's current work. Your draft is still here.")
                } else {
                    errorMessage = String(localized: "The work changed before this message could be sent. Choose an action again.")
                }
                refreshAfterPrompt()
            } else { disconnected(error) }
        }
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
        promptReceipt = nil; promptReceiptPersistsWhileIdle = false
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
        // The host locks every answer it is handed and reads an empty one as a
        // skip, so a partial batch would silently skip the questions the user
        // never touched. All of them, or none: `skipQuestion` is the none.
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
            let reply = try await self.request(request.kind.respondMethod, [
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
            let reply = try await self.request(task.kind.respondMethod, [
                "request_id": .string(action.requestID),
                "result": .string(BotDesktopTaskRequest.declinedResult)
            ], owner: action.generation, validateDispatch: self.answerGuard(action))
            return reply["status"].text == "expired" ? .alreadyResolved : .answered
        }
    }

    private func dispatchAnswers(_ answers: [BotQuestionAnswer], for action: AnswerAction) async {
        await deliver(action) {
            for answer in answers {
                var params: [String: BotJSON] = [
                    "request_id": .string(action.requestID), "answer": .string(answer.text)
                ]
                if let id = answer.questionID { params["question_id"] = .string(id) }
                let reply = try await self.request("clarify.respond", params, owner: action.generation,
                                                   validateDispatch: self.answerGuard(action))
                // A late answer to a prompt the host already dropped comes back as
                // `expired`; nothing was locked, so the rest have nothing to lock either.
                if reply["status"].text == "expired" { return .alreadyResolved }
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

    /// Runs one answer dispatch under the rules every request kind shares. The
    /// closure returns the host's verdict; a throw is a delivery problem, and only
    /// a lost socket leaves the outcome unknown.
    private func deliver(_ action: AnswerAction,
                         _ dispatch: () async throws -> BotRequestResolution.Outcome) async {
        localOperation = true
        answeringRequestID = action.requestID
        errorMessage = nil
        do {
            let outcome = try await dispatch()
            guard action.generation == generation, !Task.isCancelled else { return }
            localOperation = false; answeringRequestID = nil
            requestResolution = BotRequestResolution(requestID: action.requestID, outcome: outcome)
            // Snapshots clear an approval or question; a stream request has no
            // snapshot to clear it and the host emits `.expire` only on timeout,
            // so an answered one is retired here or the card would outlive it.
            if streamRequest?.pending.requestID == action.requestID { streamRequest = nil }
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
            liveActivity = BotTurnActivity(); streamRequest = nil
            if !localOperation { turn = .unknown }
            scheduleRefresh(); return
        }
        guard next != sequence else { return }
        let discontinuity = next != sequence + 1
        if discontinuity {
            replayWasReset = true; fullSnapshotNeeded = true; turnRevision += 1
            // Missed events may hold tool rows, a notice's clear or a stream
            // request's expiry; partial or stale state is worse than none.
            liveActivity = BotTurnActivity(); streamRequest = nil
            if !localOperation { turn = .unknown }
        }
        sequence = next
        let type = event["type"].text ?? ""
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

    /// Tracks the credential or Desktop-task request the event stream is
    /// announcing or tearing down. These never reach a resume snapshot, so the
    /// stream is the only record of them; returns true when the current one changed.
    private func applyStreamRequest(type: String, payload: BotJSON) -> Bool {
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
        // A stream request lives only in the stream, so a lost socket makes its
        // state unknowable. The card goes rather than lying about it.
        streamRequest = nil; answeringRequestID = nil
        connectionState = .disconnected
        turn = uncertainSend || uncertainStop ? .uncertain : .unknown
        turnRevision += 1
        errorMessage = (error as? BotFailure ?? .transport).localizedDescription
    }

    func suspend() {
        generation += 1; turnRevision += 1
        refreshTask?.cancel(); refreshTask = nil
        wire.close()
        localOperation = false; submittingPrompt = nil
        streamRequest = nil; answeringRequestID = nil
        connectionState = .disconnected; turn = .unknown
        Task { try? await drafts.flush() }
    }
}
