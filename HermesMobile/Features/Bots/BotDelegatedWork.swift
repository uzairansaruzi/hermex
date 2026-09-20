import Foundation
import Observation

/// One live worker projected by the direct-Hermes gateway. The initializer is
/// intentionally tolerant: a future host may add fields or omit presentation
/// details, while identity remains the minimum needed to show a row.
struct BotDelegatedWorker: Identifiable, Equatable, Sendable {
    struct Identity: Equatable, Hashable, Sendable {
        let subagentID: String
        let startedAt: Double?
        let delegationID: String?
    }

    let subagentID: String
    let parentID: String?
    let depth: Int
    let goal: String
    let delegationID: String?
    let model: String?
    let startedAt: Double?
    let status: String
    let toolCount: Int?
    let lastTool: String?

    var id: Identity { identity }
    var identity: Identity { Identity(subagentID: subagentID, startedAt: startedAt, delegationID: delegationID) }

    /// Treat ids as potentially reusable across snapshots even though current
    /// hosts generate a fresh id per spawn. Destructive control therefore also
    /// requires the generation-bearing timestamp.
    var canInterrupt: Bool { startedAt != nil }

    init?(_ value: BotJSON) {
        guard let subagentID = value["subagent_id"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subagentID.isEmpty else { return nil }
        self.subagentID = subagentID
        parentID = value["parent_id"].text.flatMap { $0.isEmpty ? nil : $0 }
        depth = max(0, value["depth"].integer ?? 0)
        let rawGoal = value["goal"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        goal = rawGoal.isEmpty ? String(localized: "Delegated worker") : rawGoal
        delegationID = value["delegation_id"].text.flatMap { $0.isEmpty ? nil : $0 }
        model = value["model"].text.flatMap { $0.isEmpty ? nil : $0 }
        startedAt = value["started_at"].number
        let rawStatus = value["status"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        status = rawStatus.isEmpty ? String(localized: "Working") : rawStatus
        toolCount = value["tool_count"].integer.flatMap { $0 >= 0 ? $0 : nil }
        lastTool = value["last_tool"].text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct BotDelegatedTail: Equatable, Sendable {
    let worker: BotDelegatedWorker.Identity
    let available: Bool
    let text: String
    let truncated: Bool
}

/// A durable async-delegation delivery projected from transcript display
/// metadata. The report itself stays opaque so future host formatting remains
/// readable without Hermex having to parse server-authored prose.
struct BotDelegationCompletion: Identifiable, Equatable, Sendable {
    static let displayKind = "async_delegation_complete"
    static let maximumDisplayCount = 999

    let id: String
    let report: String
    let delegationID: String?
    let taskCount: Int
    let completedCount: Int
    let failedCount: Int
    let durationSeconds: Double?

    init?(_ message: ChatMessage) {
        guard message.displayKind == Self.displayKind else { return nil }
        let metadata = message.displayMetadata ?? [:]
        id = message.id
        report = message.content ?? ""
        delegationID = Self.string(metadata["delegation_id"])

        let tasks = Self.boundedCount(metadata["task_count"], fallback: 1)
        let failed = min(tasks, Self.boundedCount(metadata["failed_count"], fallback: 0))
        taskCount = tasks
        failedCount = failed
        completedCount = min(max(0, tasks - failed), Self.boundedCount(
            metadata["completed_count"], fallback: max(0, tasks - failed)
        ))

        if let duration = Self.number(metadata["duration_seconds"]), duration.isFinite, duration >= 0 {
            durationSeconds = duration
        } else {
            durationSeconds = nil
        }
    }

    var hasFailures: Bool { failedCount > 0 }

    private static func boundedCount(_ value: JSONValue?, fallback: Int) -> Int {
        guard let number = number(value), number.isFinite,
              number.rounded(.towardZero) == number else { return fallback }
        guard number > 0 else { return 0 }
        guard number < Double(maximumDisplayCount) else { return maximumDisplayCount }
        return Int(number)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw) = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value else { return nil }
        return number
    }
}

/// Owns live delegated-work inspection for exactly one Bot conversation
/// transport generation. It refreshes only on connect, an explicit user action,
/// or coalesced subagent lifecycle events; worker tails are always opt-in reads.
@MainActor @Observable final class BotDelegatedWork {
    enum Availability: Equatable { case unknown, supported, unsupported }

    struct Context: Equatable, Sendable {
        let connectionID: UUID
        let runtime: String
        let generation: Int
    }

    struct InterruptAction: Identifiable, Equatable, Sendable {
        let id = UUID()
        let context: Context
        let worker: BotDelegatedWorker.Identity
    }

    static let maximumWorkers = 64
    static let maximumTailBytes = 16 * 1024

    private(set) var availability = Availability.unknown
    private(set) var workers: [BotDelegatedWorker] = []
    private(set) var omittedWorkerCount = 0
    private(set) var isRefreshing = false
    private(set) var loadingTail: BotDelegatedWorker.Identity?
    private(set) var tail: BotDelegatedTail?
    private(set) var interruptingWorker: BotDelegatedWorker.Identity?
    private(set) var interruptedWorker: BotDelegatedWorker.Identity?
    private(set) var errorMessage: String?

    @ObservationIgnored private let wire: any BotTransport
    /// Fired after the active worker count may have changed, for the Live Activity chips (#489).
    @ObservationIgnored var onWorkersChanged: (() -> Void)?
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var listRequestID = UUID()
    @ObservationIgnored private var tailRequestID = UUID()
    @ObservationIgnored private var eventRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var eventRefreshPending = false

    init(wire: any BotTransport) {
        self.wire = wire
    }

    var activeCount: Int { workers.count + omittedWorkerCount }
    var hasWorkers: Bool { !workers.isEmpty }

    func connect(_ next: Context) async {
        disconnect()
        context = next
        await refresh()
    }

    func disconnect() {
        context = nil
        listRequestID = UUID()
        tailRequestID = UUID()
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        eventRefreshPending = false
        availability = .unknown
        workers = []
        omittedWorkerCount = 0
        isRefreshing = false
        loadingTail = nil
        tail = nil
        interruptingWorker = nil
        interruptedWorker = nil
        errorMessage = nil
    }

    func refresh() async {
        guard let owner = context else { return }
        let requestID = UUID()
        listRequestID = requestID
        isRefreshing = true
        do {
            let next = try await fetchWorkers(owner)
            guard owns(owner), listRequestID == requestID else { return }
            install(next)
            availability = .supported
            errorMessage = nil
            isRefreshing = false
        } catch {
            guard owns(owner), listRequestID == requestID, !Task.isCancelled else { return }
            isRefreshing = false
            if Self.isUnsupported(error) {
                availability = .unsupported
                workers = []
                omittedWorkerCount = 0
                tail = nil
                errorMessage = nil
            } else if error as? BotFailure != .stale {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Coalesces the finite lifecycle/tool events that can change the roster.
    /// Token and reasoning deltas do not call this and never cause list polling.
    func noteSubagentEvent() {
        guard context != nil else { return }
        eventRefreshPending = true
        guard eventRefreshTask == nil else { return }
        eventRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            while self.eventRefreshPending, !Task.isCancelled {
                self.eventRefreshPending = false
                await self.refresh()
                if self.eventRefreshPending {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            self.eventRefreshTask = nil
        }
    }

    func loadTail(for worker: BotDelegatedWorker) async {
        guard let owner = context, current(worker.identity) != nil else { return }
        let requestID = UUID()
        tailRequestID = requestID
        loadingTail = worker.identity
        tail = nil
        errorMessage = nil
        do {
            let reply = try await wire.call("subagent.tail", [
                "session_id": .string(owner.runtime),
                "subagent_id": .string(worker.subagentID)
            ]) { [weak self] in
                guard let self, self.owns(owner), self.current(worker.identity) != nil else { throw BotFailure.stale }
            }
            guard owns(owner), tailRequestID == requestID, current(worker.identity) != nil else { return }
            guard reply["subagent_id"].text == worker.subagentID,
                  let available = reply["available"].flag,
                  let text = reply["text"].text,
                  let hostTruncated = reply["truncated"].flag else { throw BotFailure.unsupported }
            let bounded = Self.boundedTail(text)
            tail = BotDelegatedTail(worker: worker.identity, available: available,
                                    text: available ? bounded.text : "",
                                    truncated: available && (hostTruncated || bounded.wasTruncated))
            loadingTail = nil
        } catch {
            guard owns(owner), tailRequestID == requestID, !Task.isCancelled else { return }
            loadingTail = nil
            if error as? BotFailure != .stale { errorMessage = Self.message(for: error) }
        }
    }

    func hideTail() {
        tailRequestID = UUID()
        loadingTail = nil
        tail = nil
    }

    func prepareInterrupt(_ worker: BotDelegatedWorker) -> InterruptAction? {
        guard let context, worker.canInterrupt, interruptingWorker == nil,
              current(worker.identity) != nil else { return nil }
        return InterruptAction(context: context, worker: worker.identity)
    }

    /// Re-lists immediately before the destructive call. This rejects a worker
    /// that completed during confirmation and an id that has since been reused.
    /// The gateway then resolves the authorized live record at dispatch time.
    func interrupt(_ action: InterruptAction) async {
        guard owns(action.context), current(action.worker) != nil, interruptingWorker == nil else { return }
        interruptingWorker = action.worker
        interruptedWorker = nil
        errorMessage = nil
        do {
            let fresh = try await fetchWorkers(action.context)
            guard owns(action.context) else { throw BotFailure.stale }
            install(fresh)
            guard current(action.worker) != nil else {
                interruptingWorker = nil
                errorMessage = String(localized: "This worker is no longer active.")
                return
            }
            let reply = try await wire.call("subagent.interrupt", [
                "session_id": .string(action.context.runtime),
                "subagent_id": .string(action.worker.subagentID)
            ]) { [weak self] in
                guard let self, self.owns(action.context),
                      self.interruptingWorker == action.worker,
                      self.current(action.worker) != nil else { throw BotFailure.stale }
            }
            guard owns(action.context), interruptingWorker == action.worker else { return }
            guard reply["subagent_id"].text == action.worker.subagentID,
                  let found = reply["found"].flag else { throw BotFailure.unsupported }
            interruptingWorker = nil
            if found {
                interruptedWorker = action.worker
            } else {
                await refresh()
                guard owns(action.context) else { return }
                errorMessage = String(localized: "This worker is no longer active.")
            }
        } catch {
            guard owns(action.context), interruptingWorker == action.worker, !Task.isCancelled else { return }
            interruptingWorker = nil
            if error as? BotFailure != .stale { errorMessage = Self.message(for: error) }
        }
    }

    private func fetchWorkers(_ owner: Context) async throws -> [BotDelegatedWorker] {
        guard owns(owner) else { throw BotFailure.stale }
        let reply = try await wire.call("subagent.list", ["session_id": .string(owner.runtime)]) { [weak self] in
            guard let self, self.owns(owner) else { throw BotFailure.stale }
        }
        guard owns(owner), let rows = reply["subagents"].list else { throw BotFailure.unsupported }
        return rows.compactMap(BotDelegatedWorker.init)
    }

    private func install(_ received: [BotDelegatedWorker]) {
        let bounded = Array(received.prefix(Self.maximumWorkers))
        workers = Self.hierarchyOrder(bounded)
        omittedWorkerCount = max(0, received.count - bounded.count)
        onWorkersChanged?()
        if let tail, current(tail.worker) == nil { self.tail = nil }
        if let loadingTail, current(loadingTail) == nil { self.loadingTail = nil }
        if let interruptedWorker, current(interruptedWorker) == nil { self.interruptedWorker = nil }
    }

    private func current(_ identity: BotDelegatedWorker.Identity) -> BotDelegatedWorker? {
        workers.first { $0.identity == identity }
    }

    private func owns(_ owner: Context) -> Bool {
        context == owner && !Task.isCancelled
    }

    private static func hierarchyOrder(_ workers: [BotDelegatedWorker]) -> [BotDelegatedWorker] {
        let ids = Set(workers.map(\.subagentID))
        let roots = workers.filter { $0.parentID == nil || !ids.contains($0.parentID ?? "") }
        var result: [BotDelegatedWorker] = []
        var visited = Set<BotDelegatedWorker.Identity>()
        func append(_ worker: BotDelegatedWorker) {
            guard visited.insert(worker.identity).inserted else { return }
            result.append(worker)
            for child in workers where child.parentID == worker.subagentID { append(child) }
        }
        for root in roots { append(root) }
        for worker in workers { append(worker) }
        return result
    }

    private static func boundedTail(_ text: String) -> (text: String, wasTruncated: Bool) {
        let bytes = Data(text.utf8)
        guard bytes.count > maximumTailBytes else { return (text, false) }
        return (String(decoding: bytes.suffix(maximumTailBytes), as: UTF8.self), true)
    }

    private static func isUnsupported(_ error: Error) -> Bool {
        error as? BotFailure == .unsupported || error as? BotFailure == .rejected(-32601)
    }

    private static func message(for error: Error) -> String {
        if error as? BotFailure == .rejected(4001) {
            return String(localized: "This Hermes connection no longer owns these workers. Reconnect to inspect them.")
        }
        if isUnsupported(error) {
            return String(localized: "This Hermes host does not support delegated-work inspection.")
        }
        if error as? BotFailure == .transport {
            return String(localized: "The result is unknown. Reconnect and refresh before acting again.")
        }
        return (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Delegated work could not be refreshed.")
    }
}
