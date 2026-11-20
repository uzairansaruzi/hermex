import Foundation
import Observation

@MainActor @Observable final class HermesChatRequests {
    private let engine: HermesConversation
    @ObservationIgnored var onFailure: (String) -> Void = { _ in }
    @ObservationIgnored var onNeedsReattach: () -> Void = {}
    @ObservationIgnored var onOpenChange: () -> Void = {}

    private(set) var open: [BotServerRequest] = [] {
        didSet {
            if let id = errorRequestID, !open.contains(where: { $0.pending?.requestID == id }) {
                errorMessage = nil; errorRequestID = nil
            }
            onOpenChange()
        }
    }
    private var errorRequestID: String?
    private(set) var connection: BotConnectionOperation? { didSet { onOpenChange() } }
    private(set) var hasUnreadableConnection = false { didSet { onOpenChange() } }
    @ObservationIgnored private var unreadableConnectionID: String?
    @ObservationIgnored private var settledConnectionID: String?
    private(set) var connectionResolution: BotRequestResolution?
    private(set) var answeringRequestID: String?
    private(set) var errorMessage: String?
    private(set) var withdrawal: BotRequestWithdrawal?
    private(set) var approvalBypass = false
    private(set) var approvalMode: String?
    private var hostApprovesAll: Bool { approvalMode == HermesApprovalMode.off.rawValue }
    private var bypassOutlivedTurnOff = false
    @ObservationIgnored private var bypassReports = 0
    private(set) var isChangingApprovalBypass = false
    @ObservationIgnored var isStoppingHere = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var replayRevision = 0
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var envelopeShownWhenLeft: BotRequestWithdrawal.Envelope?
    @ObservationIgnored private var themeRequestsTaken: Set<String> = []

    init(engine: HermesConversation) {
        self.engine = engine
    }

    var onScreen: BotPendingRequest? {
        let shown = open.compactMap(\.pending).filter(Self.isShownHere)
        return shown.first { if case .question = $0 { return true }; return false }
            ?? shown.first { if case .approval = $0 { return true }; return false }
            ?? shown.first
            ?? connection.map(BotPendingRequest.connection)
    }

    var isWaiting: Bool { !open.isEmpty || connection != nil || hasUnreadableConnection }

    var stopWithdrawsAnswers: Bool {
        connection != nil || hasUnreadableConnection
            || open.contains { if case .desktopTask? = $0.pending { return false }; return true }
    }

    var mayTurnOffApprovalBypass: Bool { approvalBypass && !hostApprovesAll && !bypassOutlivedTurnOff }

    var approvalCount: Int {
        open.filter { if case .approval? = $0.pending { return true }; return false }.count
    }

    var mayAnswer: Bool {
        guard engine.connectionState == .connected, answeringRequestID == nil, !isChangingApprovalBypass,
              let request = onScreen, Self.isAnsweredHere(request) else { return false }
        return resolution(for: request)?.blocksFurtherAnswers != true
    }

    var onScreenResolution: BotRequestResolution? { onScreen.flatMap(resolution(for:)) }

    static func isShownHere(_ request: BotPendingRequest) -> Bool {
        if case .desktopTask = request { return true }
        return isAnsweredHere(request)
    }

    static func isAnsweredHere(_ request: BotPendingRequest) -> Bool {
        switch request {
        case .approval, .question, .credential, .connection: return true
        case .desktopTask: return false
        }
    }

    func prepareAnswer() -> HermesAnswerAction? {
        guard mayAnswer, let runtime = engine.runtime, let id = onScreen?.requestID else { return nil }
        let prompt = open.first { $0.pending?.requestID == id }?.promptGeneration
        return HermesAnswerAction(generation: engine.generation, runtime: runtime, requestID: id, promptGeneration: prompt)
    }

    private var summaryScope: ApprovalSummaries.Scope? {
        guard let root = engine.root else { return nil }
        return .init(server: engine.server, connectionID: engine.connection.id,
                     conversation: .session(profile: engine.target.profile, key: root))
    }

    func summaryPresentation(for approval: BotApprovalRequest, workingDirectory: String?) -> ApprovalSummaryPresentation? {
        guard engine.connectionState == .connected, answeringRequestID != approval.requestID,
              let runtime = engine.runtime, let scope = summaryScope,
              open.contains(where: { $0.pending == .approval(approval) }),
              let input = ApprovalSummaries.input(description: approval.consequence, command: approval.command,
                                                  cwd: approval.workingDirectory ?? workingDirectory) else { return nil }
        let key = ApprovalSummaries.Key(scope: scope, request: .approval(approval.requestID))
        let attempt = engine.generation
        return ApprovalSummaryPresentation(key: key) { [weak self] in
            guard let self else { throw BotFailure.stale }
            let call = HermesCall.approvalSummary(input: input, language: ApprovalSummaries.language(),
                                                  sessionID: runtime, profile: self.engine.target.profile)
            let reply = try await self.engine.request(call, attempt: attempt) {
                guard self.open.contains(where: { $0.pending == .approval(approval) }),
                      self.answeringRequestID != approval.requestID else { throw BotFailure.stale }
            }
            guard let text = reply["text"].text else { throw BotFailure.unsupported }
            return text
        }
    }

    private func retireSummary(_ requestID: String) {
        guard let scope = summaryScope else { return }
        ApprovalSummaries.shared.remove(.init(scope: scope, request: .approval(requestID)))
    }

    private func retainPendingSummaries() {
        guard let scope = summaryScope else { return }
        let pending = open.compactMap { row -> ApprovalSummaries.Key? in
            guard case .approval(let approval)? = row.pending else { return nil }
            return .init(scope: scope, request: .approval(approval.requestID))
        }
        ApprovalSummaries.shared.retain(Set(pending), in: scope)
    }

    @discardableResult
    func respond(_ action: HermesAnswerAction, choice: BotApprovalRequest.Choice) async -> Bool {
        guard case .approval(let approval)? = onScreen, approval.requestID == action.requestID,
              approval.choices.contains(choice), action == prepareAnswer() else { return false }
        return await deliver(.approval(choice), action) == .answered
    }

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

    @discardableResult
    func answerCredential(_ action: HermesAnswerAction, value: String) async -> Bool {
        guard case .credential(let credential)? = onScreen, credential.requestID == action.requestID,
              action == prepareAnswer() else { return false }
        return await deliver(.value(value), action) == .answered
    }

    @discardableResult
    func skipApprovals(_ action: HermesAnswerAction) async -> Bool {
        guard case .approval(let approval)? = onScreen, approval.requestID == action.requestID,
              action == prepareAnswer() else { return false }
        guard await setApprovalBypass(true, for: action) else { return false }
        guard approval.choices.contains(.once) else { return false }
        let released = await deliver(.approval(.once), action)
        return released == .answered || released == .alreadyResolved
    }

    func toggleApprovalBypass() async -> Bool? {
        let enabled = !approvalBypass
        guard enabled || mayTurnOffApprovalBypass, await setApprovalBypass(enabled, for: nil) else { return nil }
        return approvalBypass
    }

    func setApprovalBypass(_ enabled: Bool) async {
        guard enabled != approvalBypass, enabled || mayTurnOffApprovalBypass else { return }
        await setApprovalBypass(enabled, for: nil)
    }

    @discardableResult
    func setApprovalMode(_ mode: HermesApprovalMode) async -> Bool {
        guard engine.connectionState == .connected, let runtime = engine.runtime, !isChangingApprovalBypass,
              answeringRequestID == nil else { return false }
        let attempt = engine.generation
        let reportsBefore = bypassReports
        isChangingApprovalBypass = true
        errorMessage = nil
        var dispatched = false
        do {
            let reply = try await engine.write(.configSet(sessionID: runtime, profile: engine.target.profile, setting: .approvalMode(mode)),
                                               attempt: attempt, runtime: runtime) { dispatched = true }
            guard attempt == engine.generation, !Task.isCancelled else { return false }
            isChangingApprovalBypass = false
            guard reply["key"].text == "approvals.mode", reply["value"].text == mode.rawValue else {
                throw BotSettingFailure.unknownOutcome
            }
            approvalMode = mode.rawValue
            if bypassReports == reportsBefore, mode == .off { approvalBypass = true }
            return true
        } catch {
            guard attempt == engine.generation, !Task.isCancelled else { return false }
            isChangingApprovalBypass = false
            failChange(error, dispatched: dispatched)
            return false
        }
    }

    @discardableResult
    func respondToConnection(_ action: HermesAnswerAction, _ answer: BotConnectionOperation.Answer) async -> Bool {
        guard case .connection(let operation)? = onScreen, operation.opID == action.requestID,
              answer.isOffered(by: operation), action == prepareAnswer() else { return false }
        answeringRequestID = action.requestID
        errorMessage = nil
        do {
            let reply = try await engine.write(.connectionRespond(sessionID: action.runtime, opID: action.requestID, answer: answer),
                                               attempt: action.generation, runtime: action.runtime) { [weak self] in
                guard let self, case .connection(let current)? = self.onScreen, current.opID == action.requestID,
                      answer.isOffered(by: current) else { throw BotFailure.stale }
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

    func continueConnection(runtime: String, attempt: Int) async throws {
        guard let opID = connection?.opID else { return }
        guard answeringRequestID == nil else { throw BotFailure.stale }
        answeringRequestID = opID
        defer { if answeringRequestID == opID { answeringRequestID = nil } }
        do {
            let reply = try await engine.write(.connectionRespond(sessionID: runtime, opID: opID, answer: .continueWithout),
                                               attempt: attempt, runtime: runtime) { [weak self] in
                guard let self, self.connection?.opID == opID else { throw BotFailure.stale }
            }
            if reply["settled"].flag == true { closeConnection(opID) }
        } catch BotFailure.rejected {
        } catch {
            if error as? BotFailure != .stale {
                connectionResolution = BotRequestResolution(requestID: opID, outcome: .uncertain)
                engine.disconnect(error)
            }
            throw error
        }
    }

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
            if outcome == .uncertain {
                guard open.contains(where: { $0.pending?.requestID == action.requestID }) else { return outcome }
                fail(BotRequestResolution(requestID: action.requestID, outcome: .uncertain).message(.hermes), about: action.requestID)
                return outcome
            }
            open.removeAll { $0.pending?.requestID == action.requestID }
            retireSummary(action.requestID)
            return outcome
        } catch {
            guard action.generation == engine.generation, !Task.isCancelled else { return nil }
            answeringRequestID = nil
            if error as? BotFailure == .stale { return nil }
            if case BotFailure.rejected(let code) = error {
                fail([401, 403, -32601].contains(code)
                    ? BotFailure.rejected(code).localizedDescription
                    : String(localized: "The server did not accept that response. The request is still waiting."),
                     about: action.requestID)
                return nil
            }
            engine.disconnect(error)
            return nil
        }
    }

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
            failChange(error, dispatched: dispatched)
            return false
        }
    }

    private func failChange(_ error: Error, dispatched: Bool) {
        if error as? BotFailure == .stale { return }
        if case BotSettingFailure.rejected = error { fail(error.localizedDescription) }
        else if !dispatched { fail(error.localizedDescription) }
        else { fail(BotSettingFailure.unknownOutcome.localizedDescription) }
    }

    private func fail(_ message: String, about requestID: String? = nil) {
        errorMessage = message
        errorRequestID = requestID
        onFailure(message)
    }

    func receive(_ envelope: BotJSON) {
        guard let request = BotServerRequest(envelope), request.sessionID == engine.runtime,
              !answersTheme(envelope) else { return }
        revision += 1
        if let index = open.firstIndex(where: { $0.id == request.id }) {
            if case .approval(let old)? = open[index].pending, old.requestID != request.pending?.requestID {
                retireSummary(old.requestID)
            }
            open[index] = request
        } else { open.append(request) }
        withdrawal = nil
    }

    func cancel(_ payload: BotJSON) {
        guard let id = payload["id"].text, !id.isEmpty, let method = payload["method"].text, !method.isEmpty else { return }
        revision += 1
        let envelope = BotRequestWithdrawal.Envelope(id: id, method: method)
        let shown = envelope == envelopeOnScreen
        for row in open where row.id == id && row.method == method {
            if case .approval(let approval)? = row.pending { retireSummary(approval.requestID) }
        }
        open.removeAll { $0.id == id && $0.method == method }
        if shown { withdrawal = onScreen == nil ? note(envelope, reason: payload["reason"].text) : nil }
    }

    func receiveConnection(_ payload: BotJSON, opens: Bool) {
        guard let frame = BotConnectionOperation(payload) else {
            if opens { holdUnreadableConnection(payload) } else if payload["settled"].flag == true { hasUnreadableConnection = false }
            return
        }
        applyConnection(frame, opens: opens)
    }

    func holdRequestFrame() { revision += 1 }

    func withdrawAll() {
        revision += 1
        open = []
        retainPendingSummaries()
        if let opID = connection?.opID { closeConnection(opID) }
        hasUnreadableConnection = false
    }

    func applyBypass(_ info: BotJSON) {
        if let yolo = info["yolo"].flag {
            bypassReports += 1
            if yolo != approvalBypass { approvalBypass = yolo }
            if !yolo, bypassOutlivedTurnOff { bypassOutlivedTurnOff = false }
        }
        if let mode = info["approval_mode"].text, mode != approvalMode { approvalMode = mode }
    }

    func promptAccepted() { withdrawal = nil }

    func willLeave() {
        if let scope = summaryScope { ApprovalSummaries.shared.leave(scope) }
        guard engine.connectionState == .connected else { return }
        envelopeShownWhenLeft = envelopeOnScreen
    }

    func disconnect() {
        connection = nil; hasUnreadableConnection = false
    }

    func reset() {
        if let scope = summaryScope { ApprovalSummaries.shared.leave(scope) }
        open = []; answeringRequestID = nil; isChangingApprovalBypass = false
        errorMessage = nil; withdrawal = nil
        connection = nil; hasUnreadableConnection = false
    }

    func willReplay() { replayRevision = revision }

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

    func willReadSnapshot() { snapshotRevision = revision }

    func didReadSnapshot(_ snapshot: BotJSON) {
        if snapshotRevision == revision { restore(snapshot["open_requests"]) }
        restoreConnection(snapshot["pending_connection"])
        applyBypass(snapshot["info"])
        if withdrawal != nil, onScreen != nil { withdrawal = nil }
    }

    private var envelopeOnScreen: BotRequestWithdrawal.Envelope? {
        guard let shown = onScreen?.requestID else { return nil }
        return open.first { $0.pending?.requestID == shown }.map { BotRequestWithdrawal.Envelope(id: $0.id, method: $0.method) }
    }

    private func note(_ envelope: BotRequestWithdrawal.Envelope, reason: String?) -> BotRequestWithdrawal? {
        guard let note = BotRequestWithdrawal(method: envelope.method, reason: reason) else { return nil }
        return note.reason == .stopped && isStoppingHere ? nil : note
    }

    private func restoreConnection(_ pending: BotJSON) {
        guard let frame = BotConnectionOperation(pending) else {
            connection = nil
            if pending != .null { holdUnreadableConnection(pending) } else { hasUnreadableConnection = false }
            return
        }
        hasUnreadableConnection = false
        applyConnection(frame, opens: true)
    }

    private func holdUnreadableConnection(_ payload: BotJSON) {
        connection = nil
        unreadableConnectionID = payload["op_id"].text
        hasUnreadableConnection = true
    }

    private func applyConnection(_ frame: BotConnectionOperation, opens: Bool) {
        guard frame.opID != settledConnectionID else { return }
        let next: BotConnectionOperation
        if let held = connection, held.opID == frame.opID { next = held.applying(frame) }
        else if opens || frame.isSettled { next = frame }
        else { return }
        if opens { hasUnreadableConnection = false }
        if next.isSettled {
            if hasUnreadableConnection, unreadableConnectionID == next.opID { hasUnreadableConnection = false }
            return closeConnection(next.opID)
        }
        if connectionResolution?.requestID != next.opID { connectionResolution = nil }
        if next.opID != connection?.opID { withdrawal = nil }
        if next != connection { connection = next }
    }

    private func closeConnection(_ opID: String) {
        settledConnectionID = opID
        if connectionResolution?.requestID == opID { connectionResolution = nil }
        if connection?.opID == opID { connection = nil }
    }

    private func resolution(for request: BotPendingRequest) -> BotRequestResolution? {
        guard case .connection(let operation) = request, connectionResolution?.requestID == operation.opID else { return nil }
        return connectionResolution
    }

    private func restore(_ rows: BotJSON) {
        var seen = Set<String>()
        open = (rows.list ?? []).filter { !answersTheme($0) }.compactMap(BotServerRequest.init)
            .filter { $0.sessionID == engine.runtime && seen.insert($0.id).inserted }
        retainPendingSummaries()
    }

    private func answersTheme(_ envelope: BotJSON) -> Bool {
        guard let method = envelope["method"].text, HermesThemeRequest.methods.contains(method) else { return false }
        let params = envelope["params"]
        guard let id = envelope["id"].text, !id.isEmpty, let runtime = engine.runtime,
              params["session_id"].text == runtime else { return true }
        guard themeRequestsTaken.insert(id).inserted else { return true }
        let answer: HermesRequestAnswer
        if method == "theme.apply" {
            let change = HermesThemeRequest.apply(params)
            change.store(in: .standard)
            AppAppearanceSettings.applyStoredToConnectedScenes()
            answer = .value(change.answer)
        } else {
            answer = .said(HermesThemeRequest.said(params))
        }
        let action = HermesAnswerAction(generation: engine.generation, runtime: runtime, requestID: id)
        Task { [weak self, engine] in
            do {
                _ = try await engine.answer(answer, action) {}
            } catch BotFailure.stale {
                self?.themeRequestsTaken.remove(id)
            } catch {}
        }
        return true
    }
}

@MainActor @Observable final class HermesHostNotices {
    struct Notice: Equatable, Identifiable {
        enum Level: Equatable { case info, warning, error, success }
        let id: String
        let text: String
        let linkedText: AttributedString
        let level: Level
        let detail: String?
        fileprivate let serial: Int
    }

    typealias Timer = @MainActor (_ delay: Duration, _ expire: @escaping @MainActor () -> Void) -> Task<Void, Never>

    private(set) var notices: [Notice] = []
    var shown: Notice? { notices.last }
    var waitingCount: Int { max(notices.count - 1, 0) }

    @ObservationIgnored private let timer: Timer
    @ObservationIgnored private var expiries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissed: [String: String] = [:]
    @ObservationIgnored private var serial = 0

    init(timer: Timer? = nil) {
        self.timer = timer ?? Self.sleeping
    }

    deinit {
        expiries.values.forEach { $0.cancel() }
    }

    static let sleeping: Timer = { delay, expire in
        Task { @MainActor in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            expire()
        }
    }

    @discardableResult
    func receive(_ frame: BotJSON, live: Bool) -> Bool {
        switch frame["type"].text {
        case "notification.show": show(frame["payload"], live: live)
        case "notification.clear": clear(frame["payload"])
        default: return false
        }
        return true
    }

    private func show(_ payload: BotJSON, live: Bool) {
        guard let text = payload["text"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let expires = payload["kind"].text == "ttl"
        guard live || !expires else { return }
        let id = Self.nonEmpty(payload["key"]) ?? Self.nonEmpty(payload["id"]) ?? UUID().uuidString
        guard dismissed[id] != text else { return }
        dismissed[id] = nil
        expiries.removeValue(forKey: id)?.cancel()
        serial += 1
        let notice = Notice(id: id, text: text, linkedText: Self.linked(text), level: Self.level(payload["level"].text),
                            detail: Self.nonEmpty(payload["detail"]), serial: serial)
        if let index = notices.firstIndex(where: { $0.id == id }) {
            notices[index] = notice
        } else {
            notices.append(notice)
        }
        if expires, let milliseconds = payload["ttl_ms"].integer, milliseconds > 0 {
            let serial = notice.serial
            expiries[id] = timer(.milliseconds(milliseconds)) { [weak self] in self?.expire(id, serial: serial) }
        }
    }

    private func clear(_ payload: BotJSON) {
        guard let key = Self.nonEmpty(payload["key"]) else { return }
        dismissed[key] = nil
        remove(key)
    }

    func dismiss(_ notice: Notice) {
        dismissed[notice.id] = notice.text
        remove(notice.id)
    }

    func removeAll() {
        expiries.values.forEach { $0.cancel() }
        expiries = [:]; dismissed = [:]
        if !notices.isEmpty { notices = [] }
    }

    private func expire(_ id: String, serial: Int) {
        guard notices.first(where: { $0.id == id })?.serial == serial else { return }
        remove(id)
    }

    private func remove(_ id: String) {
        expiries.removeValue(forKey: id)?.cancel()
        if let index = notices.firstIndex(where: { $0.id == id }) { notices.remove(at: index) }
    }

    private static func nonEmpty(_ value: BotJSON) -> String? {
        guard let text = value.text, !text.isEmpty else { return nil }
        return text
    }

    private static func level(_ value: String?) -> Notice.Level {
        switch value {
        case "warn": .warning
        case "error": .error
        case "success": .success
        default: .info
        }
    }

    private static func linked(_ text: String) -> AttributedString {
        var linked = AttributedString(text)
        let range = NSRange(text.startIndex..., in: text)
        linkDetector?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let found = Range(match.range, in: text), let span = Range(found, in: linked) else { return }
            linked[span].link = url
        }
        return linked
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}
