import Foundation
import Observation

/// A Hermes session's host requests in the main chat (#1011): approvals, questions, sudo and
/// secret prompts, Desktop's own tasks and `manage_connections` operations (#1141).
/// `HermesChatTurnCoordinator` owns it and feeds it the session's request frames; envelopes
/// parse with the Bot models (`BotServerRequest`, `BotConnectionOperation`), and answers go
/// out through the engine's guarded writes, once each, from a tap. Nothing is retried (#508):
/// a lost reply reconnects, and the attach's `open_requests` and `pending_connection` say
/// whether the request is still open.
///
/// The list is the host's: live envelopes, `request.cancel` withdrawals, and the
/// `open_requests` an attach's replay and snapshot carry, which replace it. An approval, a
/// question, a sudo or secret prompt and a Desktop task get a card; a Desktop task's is only
/// shown, never answered, since a reply from here would take the request from Desktop, which
/// answers it. Vault prompts (#943) and unknown methods get no card and are never answered.
/// Any open request still means the session waits for someone. Credential and setup values
/// pass straight to the dispatch and are never kept.
///
/// A connection operation is an event plus an RPC, not a server request: `connection.request`
/// opens it, each newer `connection.update` replaces it, its settled frame closes it, and the
/// snapshot's `pending_connection` restores it. Account operations' global updates never
/// reach a session, so they never touch its card.
@MainActor @Observable final class HermesChatRequests {
    private let engine: HermesConversation
    /// Reports a refused answer or setting, for the chat's error line.
    @ObservationIgnored var onFailure: (String) -> Void = { _ in }
    /// Asks the owner to reattach, whose `open_requests` settles a batch the host still
    /// holds questions of.
    @ObservationIgnored var onNeedsReattach: () -> Void = {}
    /// Runs after every change to `open`; the owner's Live Activity shows the wait (#1014).
    @ObservationIgnored var onOpenChange: () -> Void = {}

    /// This runtime's open requests, oldest first, one per envelope id.
    private(set) var open: [BotServerRequest] = [] { didSet { onOpenChange() } }
    /// The open `manage_connections` operation, live or restored from `pending_connection`.
    /// Cleared by its settled frame, a snapshot without it, a stop, a disconnect or a new attach.
    private(set) var connection: BotConnectionOperation? { didSet { onOpenChange() } }
    /// The host holds an operation this build cannot read (no id, deadline or readable row):
    /// the session waits with no card, until a settled frame or a snapshot says otherwise.
    private(set) var hasUnreadableConnection = false { didSet { onOpenChange() } }
    /// The last operation seen settling, so a late frame or snapshot never brings its card back.
    @ObservationIgnored private var settledConnectionID: String?
    /// The verdict on the connection card: inert once the host no longer holds its operation
    /// (4004), a warning after a lost reply. Scoped to its `op_id`, so it outlives the
    /// reconnect that restores the card and never reaches another operation's.
    private(set) var connectionResolution: BotRequestResolution?
    /// The request whose answer is in flight; its card stays inert.
    private(set) var answeringRequestID: String?
    /// Why the last answer or bypass change was refused. Cleared by the next one.
    private(set) var errorMessage: String?
    /// The note left where a card stood when the host withdrew it (#948): never for an
    /// answer given elsewhere or this phone's own stop. Cleared by a new request, an accepted
    /// prompt or leaving; never cached.
    private(set) var withdrawal: BotRequestWithdrawal?
    /// The session's approval bypass, as `session.info` reports `yolo`: on while this
    /// session's flag is set or the host approves everything itself (`approvals.mode: off`,
    /// or a `--yolo` launch).
    private(set) var approvalBypass = false
    /// `session.info`'s `approval_mode` is `off`: the host approves everything, whatever this
    /// session sets.
    private var hostApprovesAll = false
    /// Turning this session's flag off left `session.info`'s `yolo` on, so the bypass is the
    /// host's own (a `--yolo` launch, which `session.info` does not name). Cleared once the
    /// bypass goes off.
    private var bypassOutlivedTurnOff = false
    /// Bumped by every `session.info` that reports `yolo`, so a bypass write knows whether
    /// the host reported the result itself.
    @ObservationIgnored private var bypassReports = 0
    /// A `config.set yolo` in flight.
    private(set) var isChangingApprovalBypass = false
    /// This phone's Stop or Stop & send is in flight: the host withdrawing the cards then is
    /// the user's own doing, so it leaves no note.
    @ObservationIgnored var isStoppingHere = false
    /// Bumped by every request envelope and `request.cancel`, so an `open_requests` read
    /// before one never replaces it.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var replayRevision = 0
    @ObservationIgnored private var snapshotRevision = 0
    /// The envelope on screen when the chat last left a live connection, so a cancel in the
    /// replay on return still leaves its note. The next replay consumes it.
    @ObservationIgnored private var envelopeShownWhenLeft: BotRequestWithdrawal.Envelope?

    init(engine: HermesConversation) {
        self.engine = engine
    }

    /// The request a card shows: a question first, then an approval, then a sudo or secret
    /// prompt or a Desktop task, then a connection operation, as in Bot Chat.
    var onScreen: BotPendingRequest? {
        let shown = open.compactMap(\.pending).filter(Self.isShownHere)
        return shown.first { if case .question = $0 { return true }; return false }
            ?? shown.first { if case .approval = $0 { return true }; return false }
            ?? shown.first
            ?? connection.map(BotPendingRequest.connection)
    }

    /// The session waits on someone while any request is open, a card or not.
    var isWaiting: Bool { !open.isEmpty || connection != nil || hasUnreadableConnection }

    /// A stop would withdraw something only this chat's user could still give: any open
    /// request but Desktop's own tasks, which the host carries on without.
    var stopWithdrawsAnswers: Bool {
        connection != nil || hasUnreadableConnection
            || open.contains { if case .desktopTask? = $0.pending { return false }; return true }
    }

    /// The pill may turn the bypass off: only this session's own flag can be.
    var mayTurnOffApprovalBypass: Bool { approvalBypass && !hostApprovesAll && !bypassOutlivedTurnOff }

    /// The open approvals, for the overlay's count.
    var approvalCount: Int {
        open.filter { if case .approval? = $0.pending { return true }; return false }.count
    }

    /// True while the card on screen may be answered.
    var mayAnswer: Bool {
        guard engine.connectionState == .connected, answeringRequestID == nil, !isChangingApprovalBypass,
              let request = onScreen, Self.isAnsweredHere(request) else { return false }
        return resolution(for: request)?.blocksFurtherAnswers != true
    }

    /// The verdict the card on screen shows, if it has one.
    var onScreenResolution: BotRequestResolution? { onScreen.flatMap(resolution(for:)) }

    /// Whether this chat shows a card for `request`. Vault prompts stay Bot Chat's (#943).
    static func isShownHere(_ request: BotPendingRequest) -> Bool {
        if case .desktopTask = request { return true }
        return isAnsweredHere(request)
    }

    /// Whether this chat answers `request`. Vault prompts stay Bot Chat's (#943); a Desktop
    /// task is shown, never answered.
    static func isAnsweredHere(_ request: BotPendingRequest) -> Bool {
        switch request {
        case .approval, .question, .connection: return true
        case .credential(let credential): return credential.kind == .sudo || credential.kind == .secret
        case .desktopTask: return false
        }
    }

    /// Captures what an answer is checked against, or nil when the card on screen cannot be
    /// answered now.
    func prepareAnswer() -> HermesAnswerAction? {
        guard mayAnswer, let runtime = engine.runtime, let id = onScreen?.requestID else { return nil }
        return HermesAnswerAction(generation: engine.generation, runtime: runtime, requestID: id)
    }

    // MARK: Answers

    /// Answers the approval on screen with one of the choices the host offered. True once the
    /// host took it.
    @discardableResult
    func respond(_ action: HermesAnswerAction, choice: BotApprovalRequest.Choice) async -> Bool {
        guard case .approval(let approval)? = onScreen, approval.requestID == action.requestID,
              approval.choices.contains(choice), action == prepareAnswer() else { return false }
        return await deliver(.approval(choice), action) == .answered
    }

    /// Answers the question on screen: every outstanding batch question in one tap, each
    /// locked by its `qid`, or the single question's one unkeyed answer.
    @discardableResult
    func answerQuestion(_ action: HermesAnswerAction, _ answers: [BotQuestionAnswer]) async -> Bool {
        guard case .question(let question)? = onScreen, question.requestID == action.requestID,
              action == prepareAnswer() else { return false }
        if question.isBatch {
            let outstanding = question.questions.filter { !$0.isAnswered }.compactMap(\.wireID)
            guard answers.count == outstanding.count, Set(answers.compactMap(\.questionID)) == Set(outstanding) else { return false }
        } else {
            guard answers.count == 1, answers[0].questionID == nil else { return false }
        }
        return await deliver(.questions(answers), action) == .answered
    }

    /// Skips the question on screen with empty answers: an empty lock per outstanding batch
    /// question, never a bare answer, which the host reads as cancelling the whole batch; a
    /// single question's one empty `request.answer`.
    @discardableResult
    func skipQuestion(_ action: HermesAnswerAction) async -> Bool {
        guard case .question(let question)? = onScreen, question.requestID == action.requestID,
              action == prepareAnswer() else { return false }
        let answers = question.isBatch
            ? question.questions.filter { !$0.isAnswered }.compactMap { $0.wireID.map { BotQuestionAnswer(questionID: $0, text: "") } }
            : [BotQuestionAnswer(questionID: nil, text: "")]
        guard !answers.isEmpty else { return false }
        return await deliver(.questions(answers), action) == .answered
    }

    /// Sends the value typed for a sudo or secret prompt; empty is the host's skip. The value
    /// goes straight to the dispatch and is never stored.
    @discardableResult
    func answerCredential(_ action: HermesAnswerAction, value: String) async -> Bool {
        guard case .credential(let credential)? = onScreen, credential.requestID == action.requestID,
              action == prepareAnswer() else { return false }
        return await deliver(.value(value), action) == .answered
    }

    /// "Skip all this session": turns the session's approval bypass on, then releases the
    /// approval on screen with `once`. Two writes from one tap, each sent once. True once the
    /// bypass is on and the card has left; a refused release leaves the card answerable with
    /// its reason, and the bypass on for the approvals after it.
    @discardableResult
    func skipApprovals(_ action: HermesAnswerAction) async -> Bool {
        guard case .approval(let approval)? = onScreen, approval.requestID == action.requestID,
              action == prepareAnswer() else { return false }
        guard await setApprovalBypass(true, for: action) else { return false }
        // The host lists `once` first in every choice set it computes; without it the card
        // waits for one of its own choices.
        guard approval.choices.contains(.once) else { return false }
        return await deliver(.approval(.once), action) != nil
    }

    /// Turns the session's approval bypass off from its pill, so approvals ask again.
    func turnOffApprovalBypass() async {
        guard mayTurnOffApprovalBypass else { return }
        await setApprovalBypass(false, for: nil)
    }

    /// `/yolo` (#1036): turns the session's approval bypass on, or off when only this
    /// session's flag holds it. The bypass after the change, or nil when it did not change;
    /// a refusal's reason went to `onFailure`.
    func toggleApprovalBypass() async -> Bool? {
        let enabled = !approvalBypass
        guard enabled || mayTurnOffApprovalBypass, await setApprovalBypass(enabled, for: nil) else { return nil }
        return approvalBypass
    }

    /// Answers one row of the connection card, or Continue without: one `connection.respond`,
    /// checked at the write against the card on screen and never retried. The card stays
    /// until the host says the operation settled; its updates move the rows meanwhile. True
    /// once the host took it. 4004 says it no longer holds the operation: the card goes inert
    /// and the chat reattaches to read it. A lost reply warns on the card and reconnects.
    @discardableResult
    func respondToConnection(_ action: HermesAnswerAction, _ answer: BotConnectionOperation.Answer) async -> Bool {
        guard case .connection(let operation)? = onScreen, operation.opID == action.requestID,
              answer.isOffered(by: operation), action == prepareAnswer() else { return false }
        answeringRequestID = action.requestID
        errorMessage = nil
        do {
            let reply = try await engine.write(.connectionRespond(sessionID: action.runtime, opID: action.requestID, answer: answer),
                                               attempt: action.generation, runtime: action.runtime) { [weak self] in
                guard let self, self.onScreen?.requestID == action.requestID else { throw BotFailure.stale }
            }
            guard action.generation == engine.generation, !Task.isCancelled else { return false }
            guard reply["status"].text == "ok", let settled = reply["settled"].flag else { throw BotFailure.unsupported }
            answeringRequestID = nil
            if settled { closeConnection(action.requestID) }
            return true
        } catch {
            guard action.generation == engine.generation, !Task.isCancelled else { return false }
            answeringRequestID = nil
            if error as? BotFailure == .stale { return false }
            if case BotFailure.rejected(let code) = error {
                // The host replied over a live socket, so nothing it refused took effect.
                if code == 4004 {
                    connectionResolution = BotRequestResolution(requestID: action.requestID, outcome: .alreadyResolved)
                    onNeedsReattach()
                } else {
                    fail([401, 403, -32601].contains(code)
                        ? BotFailure.rejected(code).localizedDescription
                        : String(localized: "The server did not accept that response. The request is still waiting."))
                }
                return false
            }
            connectionResolution = BotRequestResolution(requestID: action.requestID, outcome: .uncertain)
            engine.disconnect(error)
            return false
        }
    }

    /// Releases the open operation before a Steer or Queue message, as Desktop does, so the
    /// message does not wait behind the blocked tool until its deadline: one
    /// `settled_by: "continue"`, never retried. A refusal (most often: it had already
    /// settled) lets the message go; a lost reply throws, and the message is held.
    func continueConnection(runtime: String, attempt: Int) async throws {
        guard let opID = connection?.opID else { return }
        do {
            let reply = try await engine.write(.connectionRespond(sessionID: runtime, opID: opID, answer: .continueWithout),
                                               attempt: attempt, runtime: runtime)
            if reply["settled"].flag == true { closeConnection(opID) }
        } catch BotFailure.rejected {
        } catch {
            if error as? BotFailure != .stale { engine.disconnect(error) }
            throw error
        }
    }

    /// Sends one answer and applies the host's verdict. An accepted or already resolved
    /// request leaves at once; a batch the host still holds questions of asks for a reattach.
    /// A refusal over the live socket leaves the card answerable with the reason. A lost
    /// reply reconnects, and the attach's `open_requests` shows whether it is still open.
    @discardableResult
    private func deliver(_ answer: HermesRequestAnswer, _ action: HermesAnswerAction) async -> BotRequestResolution.Outcome? {
        answeringRequestID = action.requestID
        errorMessage = nil
        do {
            let outcome = try await engine.answer(answer, action) { [weak self] in
                guard let self, self.onScreen?.requestID == action.requestID else { throw BotFailure.stale }
            }
            guard action.generation == engine.generation, !Task.isCancelled else { return nil }
            answeringRequestID = nil
            guard let outcome else {
                onNeedsReattach()
                return nil
            }
            revision += 1
            open.removeAll { $0.pending?.requestID == action.requestID }
            return outcome
        } catch {
            guard action.generation == engine.generation, !Task.isCancelled else { return nil }
            answeringRequestID = nil
            // A stale action is refused before the write, so nothing is in doubt.
            if error as? BotFailure == .stale { return nil }
            if case BotFailure.rejected(let code) = error {
                // The host replied over a live socket, so the answer did not take effect.
                fail([401, 403, -32601].contains(code)
                    ? BotFailure.rejected(code).localizedDescription
                    : String(localized: "The server did not accept that response. The request is still waiting."))
                return nil
            }
            engine.disconnect(error)
            return nil
        }
    }

    /// Sends `config.set yolo` for this session, once; true when the host confirmed `enabled`.
    /// `action` is the approval Skip all answers, which must still be on screen at the write.
    /// The reply confirms only the session's flag. The `session.info` the host sends ahead of
    /// it says whether approvals are bypassed; only a session with no agent sends none, and
    /// then the flag is the bypass.
    @discardableResult
    private func setApprovalBypass(_ enabled: Bool, for action: HermesAnswerAction?) async -> Bool {
        guard engine.connectionState == .connected, let runtime = engine.runtime, !isChangingApprovalBypass,
              answeringRequestID == nil else { return false }
        let attempt = engine.generation
        let reportsBefore = bypassReports
        isChangingApprovalBypass = true
        errorMessage = nil
        var dispatched = false
        do {
            let reply = try await engine.write(.configSet(sessionID: runtime, profile: engine.target.profile, setting: .yolo(enabled)),
                                               attempt: attempt, runtime: runtime) { [weak self] in
                if let action { guard let self, self.onScreen?.requestID == action.requestID else { throw BotFailure.stale } }
                dispatched = true
            }
            guard attempt == engine.generation, !Task.isCancelled else { return false }
            isChangingApprovalBypass = false
            guard reply["key"].text == "yolo", let value = reply["value"].text, ["0", "1"].contains(value) else {
                throw BotSettingFailure.unknownOutcome
            }
            guard (value == "1") == enabled else { throw BotSettingFailure.unknownOutcome }
            if bypassReports == reportsBefore {
                approvalBypass = enabled
            } else if !enabled, approvalBypass {
                bypassOutlivedTurnOff = true
            }
            return true
        } catch {
            guard attempt == engine.generation, !Task.isCancelled else { return false }
            isChangingApprovalBypass = false
            if error as? BotFailure == .stale { return false }
            if case BotSettingFailure.rejected = error { fail(error.localizedDescription) }
            else if !dispatched { fail(error.localizedDescription) }
            else { fail(BotSettingFailure.unknownOutcome.localizedDescription) }
            return false
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        onFailure(message)
    }

    // MARK: Frames

    /// A live request envelope for this runtime: added, or replacing the one with its id. It
    /// takes a withdrawn card's slot.
    func receive(_ envelope: BotJSON) {
        guard let request = BotServerRequest(envelope), request.sessionID == engine.runtime else { return }
        revision += 1
        if let index = open.firstIndex(where: { $0.id == request.id }) { open[index] = request } else { open.append(request) }
        withdrawal = nil
    }

    /// `request.cancel` withdraws only the matching envelope. Only the card on screen leaves a
    /// note, and only in an empty slot: a request behind it was never read.
    func cancel(_ payload: BotJSON) {
        guard let id = payload["id"].text, !id.isEmpty, let method = payload["method"].text, !method.isEmpty else { return }
        revision += 1
        let envelope = BotRequestWithdrawal.Envelope(id: id, method: method)
        let shown = envelope == envelopeOnScreen
        open.removeAll { $0.id == id && $0.method == method }
        if shown { withdrawal = onScreen == nil ? note(envelope, reason: payload["reason"].text) : nil }
    }

    /// `connection.request` (`opens`) or `connection.update` for this session. A request
    /// opens its operation in place of any held; an update replaces the held one only when its
    /// `seq` is newer; the settled frame closes it. Neither revives the last settled operation.
    func receiveConnection(_ payload: BotJSON, opens: Bool) {
        guard let frame = BotConnectionOperation(payload) else {
            if opens { hasUnreadableConnection = true } else if payload["settled"].flag == true { hasUnreadableConnection = false }
            return
        }
        applyConnection(frame, opens: opens)
    }

    /// A `request.cancel` the engine held while attaching: newer than any `open_requests` in
    /// flight.
    func holdRequestFrame() { revision += 1 }

    /// The host withdrew every request: a stop, from any client, which also settles an open
    /// connection operation. Stop & send is not one: a redirect while a tool waits on a
    /// request only steers.
    func withdrawAll() {
        revision += 1
        open = []
        if let opID = connection?.opID { closeConnection(opID) }
        hasUnreadableConnection = false
    }

    /// `session.info`'s `yolo` and `approval_mode`, live or in a snapshot.
    func applyBypass(_ info: BotJSON) {
        if let yolo = info["yolo"].flag {
            bypassReports += 1
            if yolo != approvalBypass { approvalBypass = yolo }
            if !yolo, bypassOutlivedTurnOff { bypassOutlivedTurnOff = false }
        }
        if let mode = info["approval_mode"].text, (mode == "off") != hostApprovesAll { hostApprovesAll = mode == "off" }
    }

    /// The host accepted a prompt: the withdrawn card's note has served its turn.
    func promptAccepted() { withdrawal = nil }

    // MARK: Attach

    /// Leaving a live connection: remember the card on screen for the replay on return.
    /// Leaving again before that replay keeps the one already held.
    func willLeave() {
        guard engine.connectionState == .connected else { return }
        envelopeShownWhenLeft = envelopeOnScreen
    }

    /// The socket dropped: the connection operation goes with it until the next attach's
    /// `pending_connection` restores it. Its verdict and the last settled `op_id` stay, for
    /// the card that attach restores.
    func disconnect() {
        connection = nil; hasUnreadableConnection = false
    }

    /// A new attach or leaving dropped the connection, and the requests with it. The
    /// connection card's verdict stays for the card the next attach restores.
    func reset() {
        open = []; answeringRequestID = nil; isChangingApprovalBypass = false
        errorMessage = nil; withdrawal = nil
        connection = nil; hasUnreadableConnection = false
    }

    /// The attach is about to read `session.events.since`.
    func willReplay() { replayRevision = revision }

    /// The replay's `open_requests` replaces the list unless a request frame came since it was
    /// asked for. A card the chat showed when it left leaves its note when the replay lost
    /// nothing and its last `request.cancel` is that card's: request frames have no `seq`, so
    /// a later cancel is the only trace of a card that took the slot after it.
    func didReplay(_ reply: BotJSON, frames: [BotJSON]) {
        if replayRevision == revision { restore(reply["open_requests"]) }
        if let left = envelopeShownWhenLeft {
            envelopeShownWhenLeft = nil
            let cancel = frames.last { $0["type"].text == "request.cancel" }?["payload"]
            if !engine.replayWasReset, let cancel, onScreen == nil,
               BotRequestWithdrawal.Envelope(id: cancel["id"].text ?? "", method: cancel["method"].text ?? "") == left {
                withdrawal = note(left, reason: cancel["reason"].text)
            }
        }
    }

    /// The attach is about to read the full snapshot.
    func willReadSnapshot() { snapshotRevision = revision }

    /// The snapshot's `open_requests`, `pending_connection` and `info.yolo`. The operation is
    /// always restored: connection frames that land during the read are held and go out after
    /// it in `seq` order, so they move or settle the restored operation instead of being lost.
    func didReadSnapshot(_ snapshot: BotJSON) {
        if snapshotRevision == revision { restore(snapshot["open_requests"]) }
        restoreConnection(snapshot["pending_connection"])
        applyBypass(snapshot["info"])
        if withdrawal != nil, onScreen != nil { withdrawal = nil }
    }

    // MARK: Helpers

    /// The card on screen by its envelope: the identity `request.cancel` names.
    private var envelopeOnScreen: BotRequestWithdrawal.Envelope? {
        guard let shown = onScreen?.requestID else { return nil }
        return open.first { $0.pending?.requestID == shown }.map { BotRequestWithdrawal.Envelope(id: $0.id, method: $0.method) }
    }

    /// The note for the host withdrawing `envelope`, or nil when it stays silent.
    private func note(_ envelope: BotRequestWithdrawal.Envelope, reason: String?) -> BotRequestWithdrawal? {
        guard let note = BotRequestWithdrawal(method: envelope.method, reason: reason) else { return nil }
        return note.reason == .stopped && isStoppingHere ? nil : note
    }

    /// Resume omits `pending_connection` when no operation is open, so a missing field clears
    /// the card, and one this build cannot read waits without one.
    private func restoreConnection(_ pending: BotJSON) {
        guard let frame = BotConnectionOperation(pending) else {
            connection = nil
            hasUnreadableConnection = pending != .null
            return
        }
        hasUnreadableConnection = false
        applyConnection(frame, opens: true)
    }

    private func applyConnection(_ frame: BotConnectionOperation, opens: Bool) {
        guard frame.opID != settledConnectionID else { return }
        let next: BotConnectionOperation
        if let held = connection, held.opID == frame.opID { next = held.applying(frame) }
        else if opens { next = frame }
        else { return }
        if opens { hasUnreadableConnection = false }
        if connectionResolution?.requestID != next.opID { connectionResolution = nil }
        if next.isSettled { return closeConnection(next.opID) }
        // A new operation takes a withdrawn card's slot.
        if next.opID != connection?.opID { withdrawal = nil }
        if next != connection { connection = next }
    }

    private func closeConnection(_ opID: String) {
        settledConnectionID = opID
        if connectionResolution?.requestID == opID { connectionResolution = nil }
        if connection?.opID == opID { connection = nil }
    }

    /// The verdict `request`'s card shows: only a connection operation carries one here.
    private func resolution(for request: BotPendingRequest) -> BotRequestResolution? {
        guard case .connection(let operation) = request, connectionResolution?.requestID == operation.opID else { return nil }
        return connectionResolution
    }

    /// Resume omits an empty `open_requests`; replay always carries it. One entry per id.
    private func restore(_ rows: BotJSON) {
        var seen = Set<String>()
        open = (rows.list ?? []).compactMap(BotServerRequest.init)
            .filter { $0.sessionID == engine.runtime && seen.insert($0.id).inserted }
    }
}
