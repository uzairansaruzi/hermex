import Foundation
import Observation
import OSLog

enum ConversationTarget: Hashable, Sendable {
    case canonicalChat(profile: String)
    case session(profile: String, key: String)
    case new(profile: String, cwd: String? = nil, model: HermesCall.Model? = nil)

    var profile: String {
        switch self {
        case .canonicalChat(let profile), .session(let profile, _), .new(let profile, _, _): return profile
        }
    }

    func draftKey(server: URL, connectionID: UUID, lineageRoot: String? = nil) -> ChatDraftKey {
        switch self {
        case .canonicalChat(let profile): return .bot(server: server, connectionID: connectionID, profile: profile)
        case .session(let profile, let key):
            return .hermesSession(server: server, connectionID: connectionID, profile: profile, key: lineageRoot ?? key)
        case .new(let profile, let cwd, _):
            return .hermesSession(server: server, connectionID: connectionID, profile: profile, key: nil, cwd: cwd)
        }
    }
}

struct HermesAnswerAction: Equatable {
    let generation: Int
    let runtime: String
    let requestID: String
    var promptGeneration: Int? = nil
}

enum HermesRequestAnswer: Equatable {
    case approval(BotApprovalRequest.Choice)
    case questions([BotQuestionAnswer])
    case value(String)
    case said(String)
}

@MainActor protocol HermesConversationOwner: AnyObject {
    func conversationDidReset()
    func conversationDidFollowReplacedChat()
    func conversationDidIdentify(root: String)
    func conversationWillReplay(newRuntime: Bool, newEpoch: Bool)
    func conversationDidReplay(_ reply: BotJSON, frames: [BotJSON])
    func conversationDidReadSnapshot(_ snapshot: BotJSON, runtime: String, attempt: Int) async throws
    func conversationDidConnect(runtime: String, attempt: Int) async throws
    func conversationDidFailToAttach(_ error: Error)
    func conversation(didReceive frame: BotJSON, afterGap: Bool)
    func conversationDidLoseFrames()
    func conversation(didHold frame: BotJSON)
    func conversation(didReceiveRequest envelope: BotJSON)
    func conversationWillDisconnect()
    func conversationDidDisconnect(_ failure: BotFailure, retrying: Bool)
}

extension HermesConversationOwner {
    func conversationDidFollowReplacedChat() {}
    func conversationDidIdentify(root: String) {}
    func conversationWillReplay(newRuntime: Bool, newEpoch: Bool) {}
    func conversationDidConnect(runtime: String, attempt: Int) async throws {}
    func conversationDidFailToAttach(_ error: Error) {}
    func conversation(didHold frame: BotJSON) {}
    func conversation(didReceiveRequest envelope: BotJSON) {}
    func conversationWillDisconnect() {}
}

@MainActor @Observable final class HermesConversation {
    enum ConnectionState { case disconnected, recovering, connected }

    static let heldFrameLimit = 512
    private static let resumeRefusalWindow = Duration.seconds(60)

    let server: URL
    let connection: BotConnection
    private(set) var target: ConversationTarget
    let wire: any BotTransport
    @ObservationIgnored weak var owner: (any HermesConversationOwner)?

    private(set) var connectionState = ConnectionState.disconnected
    private(set) var generation = 0
    private(set) var root: String?
    private(set) var storedKey: String?
    private(set) var runtime: String?
    private(set) var sequence = 0
    private(set) var epoch: String?
    private(set) var executionGeneration: Int?
    private(set) var revision: Int?
    @ObservationIgnored private var unansweredMutation: HermesCall.SessionMutation?

    var unansweredOperation: HermesCall.SessionMutation.Operation? { unansweredMutation?.operation }
    private(set) var replayWasReset = false
    private(set) var isActive = false
    private(set) var isReconnecting = false
    private(set) var shouldRetryConnection = false
    @ObservationIgnored private var heldFrames: [BotJSON] = []
    @ObservationIgnored private var framesPastHold = 0
    @ObservationIgnored private var resumeRefusedSince: ContinuousClock.Instant?
    @ObservationIgnored private var reconnectRetries = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    private let reconnectDelay: (Duration) async throws -> Void
    private let now: () -> ContinuousClock.Instant

    init(server: URL, connection: BotConnection, target: ConversationTarget, linkedRoot: String? = nil,
         wire: any BotTransport,
         reconnectDelay: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.server = server; self.connection = connection; self.target = target
        self.root = linkedRoot
        self.wire = wire
        self.reconnectDelay = reconnectDelay; self.now = now
        wire.onEvent = { [weak self] event in self?.receive(event) }
        wire.onDisconnect = { [weak self] error in self?.disconnect(error) }
    }

    func activate() async {
        isActive = true
        await attach()
    }

    func suspend() {
        isActive = false; shouldRetryConnection = false; isReconnecting = false
        reconnectTask?.cancel(); reconnectTask = nil
        resumeRefusedSince = nil; reconnectRetries = 0
        reset()
    }

    func adoptStoredKey(_ key: String?) {
        guard let key, !key.isEmpty, key != storedKey, connectionState == .connected else { return }
        storedKey = key
    }

    var fence: HermesCall.Fence { .init(profile: target.profile, generation: executionGeneration) }

    func adoptGeneration(_ generation: Int?) {
        guard let generation, generation > executionGeneration ?? -1 else { return }
        executionGeneration = generation
    }

    func adoptFences(revision: Int?, generation: Int?) {
        if let revision, revision > self.revision ?? -1 { self.revision = revision }
        adoptGeneration(generation)
    }

    func mutate(_ operation: HermesCall.SessionMutation.Operation, attempt: Int, runtime: String,
                stillCurrent: (() throws -> Void)? = nil) async throws -> BotJSON {
        let mutation: HermesCall.SessionMutation
        if let unanswered = unansweredMutation, unanswered.sessionID == runtime, unanswered.operation == operation {
            mutation = unanswered
        } else {
            guard let revision else { throw BotFailure.stale }
            mutation = .init(profile: target.profile, sessionID: runtime, requestID: UUID().uuidString, revision: revision,
                             generation: executionGeneration, operation: operation)
        }
        unansweredMutation = mutation
        do {
            let reply = try await write(.sessionMutate(mutation), attempt: attempt, runtime: runtime, stillCurrent: stillCurrent)
            unansweredMutation = nil
            adoptFences(revision: reply["revision"].integer, generation: reply["execution_generation"].integer)
            return reply
        } catch let refusal as HermesFenceRefusal {
            unansweredMutation = nil
            adoptFences(revision: refusal.revision, generation: refusal.generation)
            throw refusal
        } catch let error as BotSettingFailure {
            unansweredMutation = nil
            throw error
        }
    }

    func check(_ attempt: Int) throws {
        guard generation == attempt, !Task.isCancelled else { throw BotFailure.stale }
    }

    func request(_ call: HermesCall, attempt: Int, validateDispatch: (() throws -> Void)? = nil) async throws -> BotJSON {
        try check(attempt)
        let reply = try await wire.call(call, validateDispatch: validateDispatch)
        try check(attempt)
        return reply
    }

    func write(_ call: HermesCall, attempt: Int, runtime: String,
               stillCurrent: (() throws -> Void)? = nil) async throws -> BotJSON {
        try await request(call, attempt: attempt) { [weak self] in
            guard let self else { throw BotFailure.stale }
            try self.check(attempt)
            guard self.runtime == runtime else { throw BotFailure.stale }
            try stillCurrent?()
        }
    }

    func resume(attempt: Int) async throws -> BotJSON {
        do {
            return try await request(.sessionResume(profile: target.profile, sessionID: storedKey ?? "", omitMessages: true),
                                     attempt: attempt)
        } catch BotFailure.rejected(let code) where [4007, 4009].contains(code) {
            throw ResumeRefusal(code: code)
        }
    }

    func isCurrent(_ reply: BotJSON) -> Bool {
        reply["session_id"].text == runtime && attachedKey(reply) == storedKey
    }

    func disconnect(_ error: Error) {
        owner?.conversationWillDisconnect()
        wire.close()
        heldFrames = []; framesPastHold = 0
        connectionState = .disconnected
        let refusal = error as? ResumeRefusal
        let failure = refusal.map { BotFailure.rejected($0.code) } ?? error as? BotFailure ?? .transport
        if let refusal {
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

    private struct ResumeRefusal: Error { let code: Int }

    func answer(_ answer: HermesRequestAnswer, _ action: HermesAnswerAction,
                stillCurrent: @escaping () throws -> Void) async throws -> BotRequestResolution.Outcome? {
        func send(_ call: HermesCall) async throws -> BotJSON {
            try await write(call, attempt: action.generation, runtime: action.runtime, stillCurrent: stillCurrent)
        }
        func proxy(_ result: HermesCall.RequestAnswer) async throws -> BotJSON {
            if wire.speaksCanonicalProtocol {
                try await wire.respond(toRequest: action.requestID, result: result.json) { [weak self] in
                    guard let self else { throw BotFailure.stale }
                    try self.check(action.generation)
                    guard self.runtime == action.runtime else { throw BotFailure.stale }
                    try stillCurrent()
                }
                return .object(["status": .string("ok")])
            }
            let reply = try await send(.requestAnswer(id: action.requestID, result: result))
            guard ["ok", "expired"].contains(reply["status"].text ?? "") else { throw BotFailure.unsupported }
            return reply
        }
        func promptOutcome(_ reply: BotJSON) throws -> BotRequestResolution.Outcome {
            switch reply["status"].text {
            case "resolved": return .answered
            case "already_resolved": return .alreadyResolved
            default: throw BotFailure.unsupported
            }
        }
        let promptFence = action.promptGeneration.map { HermesCall.Fence(profile: target.profile, generation: $0) }
        switch answer {
        case .approval(let choice) where promptFence != nil:
            return try promptOutcome(try await send(.approvalRespond(sessionID: action.runtime, requestID: action.requestID,
                                                                     choice: choice, fence: promptFence)))
        case .questions(let answers) where promptFence != nil:
            guard let promptFence, answers.count == 1, answers[0].questionID == nil else { throw BotFailure.unsupported }
            return try promptOutcome(try await send(.clarifyRespond(sessionID: action.runtime, promptID: action.requestID,
                                                                    answer: answers[0].text, fence: promptFence)))
        case .approval(let choice):
            let reply = try await send(.approvalRespond(sessionID: action.runtime, requestID: action.requestID, choice: choice))
            guard let resolved = reply["resolved"].integer, resolved >= 0 else { return .uncertain }
            return resolved > 0 ? .answered : .alreadyResolved
        case .value(let value):
            return try await proxy(.value(value))["status"].text == "expired" ? .alreadyResolved : .answered
        case .said(let said):
            return try await proxy(.said(said))["status"].text == "expired" ? .alreadyResolved : .answered
        case .questions(let answers):
            for answer in answers {
                let reply: BotJSON
                if let id = answer.questionID {
                    reply = try await send(.clarifyLock(requestID: action.requestID, questionID: id, answer: answer.text))
                } else {
                    reply = try await proxy(.answer(answer.text))
                }
                if reply["status"].text == "expired" { return .alreadyResolved }
                if answer.questionID != nil {
                    guard reply["status"].text == "ok", let remaining = reply["remaining"].list else {
                        throw BotFailure.unsupported
                    }
                    if remaining.isEmpty { return .answered }
                    if answer == answers.last { return nil }
                }
            }
            return .answered
        }
    }

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
            async let noted: Void = wire.keepPlatformNote(profile: target.profile)
            try await wire.connect()
            try check(attempt)
            await noted
            try await identify(attempt)
            let first = try await resume(attempt: attempt)
            let canonicalEpoch = first["replay_epoch"].text.flatMap { $0.isEmpty ? nil : $0 }
            guard let foundKey = attachedKey(first), let foundRuntime = first["session_id"].text, !foundRuntime.isEmpty,
                  let foundEpoch = wire.speaksCanonicalProtocol ? canonicalEpoch : wire.replayEpoch
            else { throw BotFailure.wrongIdentity }
            let newEpoch = epoch != foundEpoch
            replayWasReset = newEpoch || runtime != foundRuntime
            let newRuntime = runtime != foundRuntime
            if replayWasReset { sequence = 0 }
            if newRuntime { executionGeneration = nil; revision = nil }
            runtime = foundRuntime; epoch = foundEpoch; storedKey = foundKey
            adoptFences(revision: first["revision"].integer, generation: first["execution_generation"].integer)
            owner?.conversationWillReplay(newRuntime: newRuntime, newEpoch: newEpoch)
            let replay = try await request(.sessionEventsSince(profile: target.profile, sessionID: foundRuntime,
                                                               lastSeen: sequence, replayEpoch: foundEpoch), attempt: attempt)
            let missed = try reconcile(replay)
            owner?.conversationDidReplay(replay, frames: missed)
            let snapshot = try await resume(attempt: attempt)
            adoptFences(revision: snapshot["revision"].integer, generation: snapshot["execution_generation"].integer)
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

    private func identify(_ attempt: Int) async throws {
        switch target {
        case .canonicalChat(let profile):
            let lookup = try await request(.sessionList(profile: profile), attempt: attempt)
            guard let rows = lookup["sessions"].list else { throw BotFailure.unsupported }
            guard rows.count == 1 else { throw BotFailure.missingChat }
            guard let foundRoot = rows[0]["id"].text, !foundRoot.isEmpty,
                  let foundTip = rows[0]["resolved_id"].text, !foundTip.isEmpty else { throw BotFailure.unsupported }
            if let root, root != foundRoot { owner?.conversationDidFollowReplacedChat() }
            root = foundRoot; storedKey = foundTip
            owner?.conversationDidIdentify(root: foundRoot)
        case .session(_, let key):
            root = key; storedKey = key
            owner?.conversationDidIdentify(root: key)
        case .new(let profile, let cwd, let model):
            let created = try await request(.sessionNew(profile: profile, cwd: cwd, model: model), attempt: attempt)
            guard let key = created["stored_session_id"].text, !key.isEmpty,
                  created["session_id"].text?.isEmpty == false else { throw BotFailure.unsupported }
            target = .session(profile: profile, key: key)
            root = key; storedKey = key
            owner?.conversationDidIdentify(root: key)
        }
    }

    private func attachedKey(_ reply: BotJSON) -> String? {
        let canonical = wire.speaksCanonicalProtocol
        if case .canonicalChat = target {
            let key = canonical ? reply["stored_session_id"].text : reply["session_key"].text
            return key == storedKey ? storedKey : nil
        }
        let resolved = canonical ? reply["stored_session_id"].text : reply["session_key"].text ?? reply["stored_session_id"].text
        guard let key = resolved, !key.isEmpty else { return nil }
        return key
    }

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
            adoptFrameFences(event)
            missed.append(event)
        }
        if cursor < latest { replayWasReset = true }
        epoch = receivedEpoch; sequence = latest
        return missed
    }

    private func receive(_ event: BotJSON) {
        guard connectionState != .disconnected, runtime != nil else { return }
        if event["type"].text == "session.reclaimed" { return reclaim(event["payload"]) }
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

    private func reclaim(_ payload: BotJSON) {
        let ownRuntime = payload["session_id"].text == runtime
        let ownKey = storedKey.map { payload["stored_session_id"].text == $0 } ?? false
        guard ownRuntime || ownKey else { return }
        let reason = payload["reason"].text ?? "unknown", name = logName
        HermesConnectionLog.logger.notice("\(name, privacy: .public): the host reclaimed the runtime (\(reason, privacy: .public)); reattaching")
        owner?.conversationDidLoseFrames()
    }

    private static func requestSession(_ event: BotJSON) -> String? {
        guard let id = event["id"].text, !id.isEmpty, let method = event["method"].text, !method.isEmpty,
              let session = event["params"]["session_id"].text, !session.isEmpty else { return nil }
        return session
    }

    private func adoptFrameFences(_ event: BotJSON) {
        let reportsRevision = ["session.info", "session.updated"].contains(event["type"].text ?? "")
        adoptFences(revision: reportsRevision ? event["payload"]["revision"].integer : nil,
                    generation: event["execution_generation"].integer)
        if event["type"].text == "session.updated" { adoptGeneration(event["payload"]["execution_generation"].integer) }
    }

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
        adoptFrameFences(event)
        owner?.conversation(didReceive: event, afterGap: gap)
    }

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
