import Foundation
import Observation

struct HermesBtw: Equatable {
    enum State: Equatable {
        case waiting
        case answered(String)
        case unavailable
    }

    let id = UUID()
    let question: String
    fileprivate(set) var taskID: String?
    fileprivate(set) var state = State.waiting
}

struct HermesBackgroundTask: Equatable, Identifiable {
    enum State: Equatable {
        case running
        case finished(String)
        case unavailable
    }

    let id: String
    let prompt: String
    fileprivate(set) var state: State
}

enum HermesGoalReply: Equatable {
    case exec(output: String)
    case send(notice: String?, message: String, display: String?)
}

enum HermesSideTaskFailure: Error, Equatable {
    case notSent
    case refused
    case unconfirmed
}

@MainActor @Observable final class HermesChatSideTasks {
    private let engine: HermesConversation
    @ObservationIgnored var onBackgroundChange: (HermesBackgroundTask) -> Void = { _ in }
    @ObservationIgnored var onGoalChange: (SubmittedGoal?) -> Void = { _ in }
    @ObservationIgnored var onNeedsReattach: () -> Void = {}

    private(set) var btw: HermesBtw?
    private(set) var backgroundTasks: [HermesBackgroundTask] = []
    private(set) var goal: SubmittedGoal?
    private(set) var automations: [BotSessionControl] = []
    private(set) var pendingAutomation: BotSessionControl?
    private(set) var isChangingAutomation = false
    private var controlAttempt: Int?

    @ObservationIgnored private var unclaimed: [String: BotJSON] = [:]
    @ObservationIgnored private var startsInFlight = 0
    @ObservationIgnored private var controlRevision = 0
    @ObservationIgnored private var needsResultRead = false
    @ObservationIgnored private var pendingAttempt = 0

    init(engine: HermesConversation) {
        self.engine = engine
    }

    var isAsking: Bool { btw?.state == .waiting }

    static func isGoalControl(_ argument: String) -> Bool {
        let normalized = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let verbs: Set = ["", "status", "show", "pause", "resume", "clear", "stop", "done", "unwait"]
        let first = normalized.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return verbs.contains(normalized) || ["wait", "gate"].contains(first)
    }

    func dispatchGoal(_ argument: String) async throws -> HermesGoalReply {
        let reply = try await write { .commandDispatch(name: "goal", argument: argument, sessionID: $0) }
        switch reply["type"].text {
        case "exec":
            return .exec(output: reply["output"].text ?? "")
        case "send":
            guard let message = reply["message"].text,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BotFailure.unsupported }
            return .send(notice: Self.nonEmpty(reply["notice"].text), message: message, display: Self.nonEmpty(reply["display"].text))
        default:
            throw BotFailure.unsupported
        }
    }

    var controlsAutomations: Bool { !engine.wire.unavailableMethods.contains("session.control") }

    var canChangeAutomations: Bool { controlAttempt == engine.generation }

    func ask(_ control: BotSessionControl) {
        guard control.action != nil, canChangeAutomations, automations.contains(control), !isChangingAutomation else { return }
        pendingAutomation = control
        pendingAttempt = engine.generation
    }

    func cancelAutomation() { pendingAutomation = nil }

    func confirmAutomation(_ control: BotSessionControl) async throws {
        pendingAutomation = nil
        guard pendingAttempt == engine.generation, canChangeAutomations, automations.contains(control),
              let action = control.action, !isChangingAutomation else { throw BotFailure.stale }
        isChangingAutomation = true
        defer { isChangingAutomation = false }
        let revision = controlRevision, attempt = engine.generation
        let profile = engine.target.profile
        let reply: BotJSON
        do {
            reply = try await write({ .sessionControl(sessionID: $0, profile: profile, action: action) }) { [weak self] in
                guard self?.automations.contains(control) == true else { throw BotFailure.stale }
            }
        } catch is HermesChatTurnCoordinator.NotSent where !automations.contains(control) {
            throw BotFailure.stale
        }
        guard reply["control"].fields != nil else { throw BotSettingFailure.unknownOutcome }
        guard controlRevision == revision else { return }
        controlRevision += 1
        applyControl(reply["control"], attempt: attempt)
    }

    func ask(_ question: String) async throws {
        let asked = HermesBtw(question: question)
        btw = asked
        let started: (reply: BotJSON, early: BotJSON?)
        do {
            started = try await start { .promptBtw(sessionID: $0, text: question) }
        } catch HermesSideTaskFailure.unconfirmed {
            update(asked.id) { $0.state = .unavailable }
            return
        } catch {
            if btw?.id == asked.id { btw = nil }
            throw error
        }
        guard let taskID = Self.nonEmpty(started.reply["task_id"].text) else {
            update(asked.id) { $0.state = .unavailable }
            return
        }
        update(asked.id) { $0.taskID = taskID }
        if let early = started.early { receive(early) }
    }

    func closeBtw() { btw = nil }

    func forgetChat() {
        btw = nil; backgroundTasks = []
        unclaimed = [:]; needsResultRead = false
    }

    func startBackground(_ prompt: String) async throws {
        let (reply, early) = try await start { .promptBackground(sessionID: $0, text: prompt) }
        guard let taskID = Self.nonEmpty(reply["task_id"].text) else { throw HermesSideTaskFailure.unconfirmed }
        let task = HermesBackgroundTask(id: taskID, prompt: prompt, state: .running)
        backgroundTasks.append(task)
        onBackgroundChange(task)
        if let early { receive(early) }
    }

    @discardableResult
    func receive(_ frame: BotJSON) -> Bool {
        let payload = frame["payload"]
        switch frame["type"].text {
        case "btw.complete":
            guard let taskID = Self.nonEmpty(payload["task_id"].text) else { return true }
            let text = payload["text"].text ?? ""
            if let btw, btw.taskID == taskID {
                update(btw.id) { $0.state = .answered(text) }
            } else if startsInFlight > 0 {
                unclaimed[taskID] = frame
            }
            return true
        case "background.complete":
            guard let taskID = Self.nonEmpty(payload["task_id"].text) else { return true }
            if backgroundTasks.contains(where: { $0.id == taskID }) {
                settle(taskID, .finished(payload["text"].text ?? ""))
            } else if startsInFlight > 0 {
                unclaimed[taskID] = frame
            }
            return true
        case "session.control.update":
            controlRevision += 1
            applyControl(payload["control"], attempt: engine.generation)
            return true
        default:
            return false
        }
    }

    func didReplay(_ frames: [BotJSON], lostFrames: Bool) {
        guard lostFrames else { return }
        frames.forEach { receive($0) }
        if let btw, btw.state == .waiting { update(btw.id) { $0.state = .unavailable } }
        needsResultRead = true
    }

    func didConnect(runtime: String, attempt: Int) {
        if pendingAttempt != attempt { pendingAutomation = nil }
        readControl(runtime: runtime, attempt: attempt)
        if needsResultRead {
            needsResultRead = false
            readResults()
        }
    }

    private func readControl(runtime: String, attempt: Int) {
        guard !engine.wire.unavailableMethods.contains("session.control.read") else { return }
        let revision = controlRevision
        Task { [weak self, engine] in
            guard let reply = try? await engine.request(.sessionControlRead(sessionID: runtime, profile: engine.target.profile),
                                                         attempt: attempt),
                  let self, self.controlRevision == revision else { return }
            self.applyControl(reply["control"], attempt: attempt)
        }
    }

    private func readResults() {
        let pending = backgroundTasks.filter { if case .finished = $0.state { return false }; return true }
        guard !pending.isEmpty else { return }
        let profile = engine.target.profile, wire = engine.wire
        Task { [weak self] in
            for task in pending {
                let state: HermesBackgroundTask.State
                do {
                    let messages = try await wire.sessionMessages(task.id, profile: profile)
                    state = messages.flatMap(Self.result).map(HermesBackgroundTask.State.finished) ?? .unavailable
                } catch BotFailure.stale {
                    self?.needsResultRead = true
                    return
                } catch {
                    state = .unavailable
                }
                self?.settle(task.id, state)
            }
        }
    }

    static func result(_ messages: [BotJSON]) -> String? {
        messages.last { message in
            message["role"].text == "assistant" && (message["tool_calls"].list ?? []).isEmpty
                && nonEmpty(text(message["content"])) != nil
        }.flatMap { text($0["content"]) }
    }

    private func start(_ call: (String) -> HermesCall) async throws -> (reply: BotJSON, early: BotJSON?) {
        startsInFlight += 1
        defer {
            startsInFlight -= 1
            if startsInFlight == 0 { unclaimed = [:] }
        }
        do {
            let reply = try await write(call)
            return (reply, Self.nonEmpty(reply["task_id"].text).flatMap { unclaimed.removeValue(forKey: $0) })
        } catch is HermesChatTurnCoordinator.NotSent {
            throw HermesSideTaskFailure.notSent
        } catch BotFailure.rejected(_) {
            throw HermesSideTaskFailure.refused
        } catch {
            throw HermesSideTaskFailure.unconfirmed
        }
    }

    private func write(_ call: (String) -> HermesCall, stillCurrent: (() throws -> Void)? = nil) async throws -> BotJSON {
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw HermesChatTurnCoordinator.NotSent(underlying: BotFailure.transport)
        }
        var dispatched = false
        do {
            return try await engine.write(call(runtime), attempt: engine.generation, runtime: runtime) {
                try stillCurrent?()
                dispatched = true
            }
        } catch {
            if Self.isReaped(error) { onNeedsReattach() }
            throw dispatched ? error : HermesChatTurnCoordinator.NotSent(underlying: error)
        }
    }

    static func isReaped(_ error: Error) -> Bool {
        switch error {
        case BotFailure.rejected(4001), BotSettingFailure.rejected(4001, _): return true
        default: return false
        }
    }

    private func update(_ id: UUID, _ change: (inout HermesBtw) -> Void) {
        guard var btw, btw.id == id else { return }
        change(&btw)
        self.btw = btw
    }

    private func settle(_ taskID: String, _ state: HermesBackgroundTask.State) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == taskID }),
              backgroundTasks[index].state != state else { return }
        if case .finished = backgroundTasks[index].state { return }
        backgroundTasks[index].state = state
        onBackgroundChange(backgroundTasks[index])
    }

    private func applyControl(_ control: BotJSON, attempt: Int) {
        guard control.fields != nil else { return }
        if controlAttempt != attempt { controlAttempt = attempt }
        let automations = BotSessionControl.read(control).filter { $0.kind != .goal }
        if automations != self.automations { self.automations = automations }
        let goal = Self.goal(control["goal"])
        guard goal != self.goal else { return }
        self.goal = goal
        onGoalChange(goal)
    }

    private static func goal(_ goal: BotJSON) -> SubmittedGoal? {
        guard goal.fields != nil, let title = goal["title"].text else { return nil }
        return SubmittedGoal(goal: title, status: goal["status"].text, turnsUsed: goal["turns_used"].integer,
                             maxTurns: goal["max_turns"].integer, lastVerdict: goal["last_verdict"].text,
                             lastReason: goal["last_reason"].text, pausedReason: goal["paused_reason"].text)
    }

    private static func text(_ content: BotJSON) -> String? {
        if let text = content.text { return text }
        return content.list.map { parts in parts.compactMap { $0["text"].text }.joined() }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
