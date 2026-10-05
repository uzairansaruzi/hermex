import Foundation
import Observation

/// The `/btw` side question a Hermes session's panel shows (#1013). It is answered from a
/// snapshot of the conversation with tools off, beside the running turn, and never enters
/// the transcript.
struct HermesBtw: Equatable {
    enum State: Equatable {
        /// Asked; waiting for its `btw.complete`.
        case waiting
        /// The host's answer. Empty when it produced none.
        case answered(String)
        /// A reconnect lost the answer, or the host never confirmed the question.
        case unavailable
    }

    /// This ask, so a reply never lands on a later one.
    let id = UUID()
    let question: String
    /// The host's `btw_…` id, once the ask is confirmed.
    fileprivate(set) var taskID: String?
    fileprivate(set) var state = State.waiting
}

/// A `/background` task: a side agent in its own `bg_<id>` session under the Profile, shown
/// as a transcript card until its result replaces it (#1013).
struct HermesBackgroundTask: Equatable, Identifiable {
    enum State: Equatable {
        case running
        /// `background.complete`'s text, or the side session's last reply. A failure is the
        /// host's `error: …` text.
        case finished(String)
        /// Neither the replay nor the side session had a result. A later completion or read
        /// can still fill it.
        case unavailable
    }

    /// The host's `bg_…` task id, which is also the side session's id.
    let id: String
    let prompt: String
    fileprivate(set) var state: State
}

/// What the host made of a `/goal` command (`command.dispatch`).
enum HermesGoalReply: Equatable {
    /// Done on the host; `output` says what changed.
    case exec(output: String)
    /// The goal wants a turn: `message` goes out as a prompt, once. `display` is what the
    /// transcript shows for it, when the host names one.
    case send(notice: String?, message: String, display: String?)
}

/// Why a side question or background task did not start.
enum HermesSideTaskFailure: Error, Equatable {
    /// It never reached the host.
    case notSent
    /// The host refused it.
    case refused
    /// It went out, but the host's answer was lost: it may run with no way to follow it.
    case unconfirmed
}

/// A Hermes session's side work in the main chat (#1013): its goal, one `/btw` question at a
/// time, and its `/background` tasks. `HermesChatTurnCoordinator` owns it and hands it the
/// session's `btw.complete`, `background.complete` and `session.control.update` frames;
/// completions match by `task_id`, and unknown ids are ignored. Each ask, start and goal
/// command is one `write`, never resent.
///
/// Completions ride the session's replay. When an attach lost frames (a truncated ring, a new
/// epoch or runtime, a live gap), a question still waiting reads as unavailable and each task
/// without a result is read once from its side session: its last reply, or unavailable.
@MainActor @Observable final class HermesChatSideTasks {
    private let engine: HermesConversation
    /// A task's card changed: added, finished, or unavailable.
    @ObservationIgnored var onBackgroundChange: (HermesBackgroundTask) -> Void = { _ in }
    /// The goal `session.control` reports changed.
    @ObservationIgnored var onGoalChange: (SubmittedGoal?) -> Void = { _ in }
    /// The host reaped the runtime (4001): reattach to the stored key.
    @ObservationIgnored var onNeedsReattach: () -> Void = {}

    /// The question the panel shows; nil once closed.
    private(set) var btw: HermesBtw?
    /// This chat's background tasks, oldest first.
    private(set) var backgroundTasks: [HermesBackgroundTask] = []
    /// The goal from the last control snapshot; nil without one.
    private(set) var goal: SubmittedGoal?

    /// Completions whose task id this chat has not learned yet: the host can finish a task
    /// before its reply to the ask is read. Kept only while an ask or start is in flight.
    @ObservationIgnored private var unclaimed: [String: BotJSON] = [:]
    @ObservationIgnored private var startsInFlight = 0
    /// Bumped by every control frame, so a read sent before one never replaces it.
    @ObservationIgnored private var controlRevision = 0
    /// The last attach lost frames: tasks without a result are read once connected.
    @ObservationIgnored private var needsResultRead = false

    init(engine: HermesConversation) {
        self.engine = engine
    }

    /// A question is out and unanswered; only one at a time.
    var isAsking: Bool { btw?.state == .waiting }

    // MARK: Goal

    /// Whether a `/goal` argument controls the session's goal (status, pause, resume, done,
    /// clear and the rest) rather than setting a new one, as the host's `is_goal_control`
    /// reads it. A goal's own turns keep the session busy, so these run mid-turn.
    static func isGoalControl(_ argument: String) -> Bool {
        let normalized = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let verbs: Set = ["", "status", "show", "pause", "resume", "clear", "stop", "done", "unwait"]
        let first = normalized.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return verbs.contains(normalized) || ["wait", "gate"].contains(first)
    }

    /// Runs one `/goal` command (`command.dispatch goal`): a verb or a new goal's text.
    /// Throws `NotSent` when it never went out; a refusal carries the host's message.
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

    // MARK: btw

    /// Asks `question` and opens the panel on it. Throws, with the panel closed, when the
    /// question never reached the host or the host refused it. A lost answer leaves the
    /// panel saying the answer is unavailable.
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

    /// Closes the panel. The host still answers; the answer is ignored.
    func closeBtw() { btw = nil }

    // MARK: Background

    /// Starts a background task and adds its running card. Throws when it never went out,
    /// was refused, or its task id was lost.
    func startBackground(_ prompt: String) async throws {
        let (reply, early) = try await start { .promptBackground(sessionID: $0, text: prompt) }
        guard let taskID = Self.nonEmpty(reply["task_id"].text) else { throw HermesSideTaskFailure.unconfirmed }
        let task = HermesBackgroundTask(id: taskID, prompt: prompt, state: .running)
        backgroundTasks.append(task)
        onBackgroundChange(task)
        if let early { receive(early) }
    }

    // MARK: Frames

    /// Applies one of the session's side frames; false for any other frame.
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
            applyControl(payload["control"])
            return true
        default:
            return false
        }
    }

    /// An attach's replay. With frames lost, its completions still apply, and the rest is
    /// settled: a waiting question is unavailable, and tasks are read once connected.
    /// Without, the owner applies the frames in order.
    func didReplay(_ frames: [BotJSON], lostFrames: Bool) {
        guard lostFrames else { return }
        frames.forEach { receive($0) }
        if let btw, btw.state == .waiting { update(btw.id) { $0.state = .unavailable } }
        needsResultRead = true
    }

    /// Connected: reads the goal, and the results the last replay lost.
    func didConnect(runtime: String, attempt: Int) {
        readControl(runtime: runtime, attempt: attempt)
        if needsResultRead {
            needsResultRead = false
            readResults()
        }
    }

    // MARK: Reads

    /// `session.control.read`, unless a control frame arrives first.
    private func readControl(runtime: String, attempt: Int) {
        guard !engine.wire.unavailableMethods.contains("session.control.read") else { return }
        let revision = controlRevision
        Task { [weak self, engine] in
            guard let reply = try? await engine.request(.sessionControlRead(sessionID: runtime, profile: engine.target.profile),
                                                         attempt: attempt),
                  let self, self.controlRevision == revision else { return }
            self.applyControl(reply["control"])
        }
    }

    /// Reads each task still without a result from its side session. A chat that left
    /// meanwhile reads again on its next attach.
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

    /// A side session's result: its last reply that is not a tool call.
    static func result(_ messages: [BotJSON]) -> String? {
        messages.last { message in
            message["role"].text == "assistant" && (message["tool_calls"].list ?? []).isEmpty
                && nonEmpty(text(message["content"])) != nil
        }.flatMap { text($0["content"]) }
    }

    // MARK: Helpers

    /// Sends one side call on the attached runtime and returns its reply, with the task's
    /// completion when it came first. Failures map to `HermesSideTaskFailure`.
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

    /// One write bound to the attached runtime. Throws `NotSent` when it never went out. A
    /// 4001 means the host reaped the runtime, whether it arrives plain or, from `/goal`, as
    /// a setting refusal; the chat reattaches either way.
    private func write(_ call: (String) -> HermesCall) async throws -> BotJSON {
        guard engine.connectionState == .connected, let runtime = engine.runtime else {
            throw HermesChatTurnCoordinator.NotSent(underlying: BotFailure.transport)
        }
        var dispatched = false
        do {
            return try await engine.write(call(runtime), attempt: engine.generation, runtime: runtime) { dispatched = true }
        } catch {
            if Self.isReaped(error) { onNeedsReattach() }
            throw dispatched ? error : HermesChatTurnCoordinator.NotSent(underlying: error)
        }
    }

    /// The host no longer has the runtime (4001).
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

    /// A task's new state. A result is final: a later read never replaces it.
    private func settle(_ taskID: String, _ state: HermesBackgroundTask.State) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == taskID }),
              backgroundTasks[index].state != state else { return }
        if case .finished = backgroundTasks[index].state { return }
        backgroundTasks[index].state = state
        onBackgroundChange(backgroundTasks[index])
    }

    private func applyControl(_ control: BotJSON) {
        guard control.fields != nil else { return }
        let goal = Self.goal(control["goal"])
        guard goal != self.goal else { return }
        self.goal = goal
        onGoalChange(goal)
    }

    /// A control snapshot's goal as the goal menu reads it; nil once cleared.
    private static func goal(_ goal: BotJSON) -> SubmittedGoal? {
        guard goal.fields != nil, let title = goal["title"].text else { return nil }
        return SubmittedGoal(goal: title, status: goal["status"].text, turnsUsed: goal["turns_used"].integer,
                             maxTurns: goal["max_turns"].integer, lastVerdict: goal["last_verdict"].text,
                             lastReason: goal["last_reason"].text, pausedReason: goal["paused_reason"].text)
    }

    /// A row's text: a string, or its text parts joined.
    private static func text(_ content: BotJSON) -> String? {
        if let text = content.text { return text }
        return content.list.map { parts in parts.compactMap { $0["text"].text }.joined() }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
