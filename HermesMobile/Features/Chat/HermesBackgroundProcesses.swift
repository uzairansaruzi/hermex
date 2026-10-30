import Foundation
import Observation

/// One background command a Hermes session's agent started, projected from the
/// gateway's `process.list`. The initializer is intentionally tolerant: the contract
/// requires only `session_id` (which **is** the process id), and hosts may add fields
/// (a future one already carries `pid`, `owner_task_id`, `started_at`,
/// `session_scoped`) or omit presentation details. A row without usable identity is
/// omitted rather than guessed at.
struct HermesBackgroundProcess: Identifiable, Equatable, Sendable {
    struct Identity: Equatable, Hashable, Sendable {
        let processID: String
    }

    let processID: String
    let command: String?
    let cwd: String?
    /// The host's status word, verbatim. Recognized exit states are presentation only;
    /// anything unrecognized stays displayable.
    let status: String?
    /// The host's own uptime string, when it reports one.
    let uptime: String?
    /// The host's uptime in seconds, when it reports a number instead.
    let uptimeSeconds: Double?
    let pid: Int?
    let exitCode: Int?
    let completionReason: String?
    let terminationSource: String?
    /// The last output the host keeps for the process, ANSI-free and client-bounded.
    let tail: String?
    /// Earlier output was cut, by the host or by the client bound.
    let tailTruncated: Bool

    var id: Identity { Identity(processID: processID) }

    init?(_ value: BotJSON) {
        guard let processID = value["session_id"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !processID.isEmpty else { return nil }
        self.processID = processID
        command = value["command"].text.flatMap { $0.isEmpty ? nil : $0 }
        cwd = value["cwd"].text.flatMap { $0.isEmpty ? nil : $0 }
        status = value["status"].text.flatMap { $0.isEmpty ? nil : $0 }
        uptime = value["uptime"].text.flatMap { $0.isEmpty ? nil : $0 }
        uptimeSeconds = value["uptime"].number
        pid = value["pid"].integer
        exitCode = value["exit_code"].integer
        completionReason = value["completion_reason"].text.flatMap { $0.isEmpty ? nil : $0 }
        terminationSource = value["termination_source"].text.flatMap { $0.isEmpty ? nil : $0 }

        // The host keeps the last 4,000 characters; the client re-bounds in case a
        // future host widens it. Without a tail, the short preview stands in.
        let rawTail = value["output_tail"].text ?? value["output_preview"].text
        if let rawTail, !rawTail.isEmpty {
            let bounded = Self.boundedTail(rawTail.strippingANSIEscapes())
            tail = bounded.text
            tailTruncated = bounded.wasTruncated
        } else {
            tail = nil
            tailTruncated = false
        }
    }

    /// A status the host reports as finished, in its known spellings. The list keeps
    /// running and recently finished rows, so a finished row stays inspectable.
    var isFinished: Bool {
        guard let status else { return false }
        return Self.finishedStatuses.contains(status.lowercased())
    }

    /// Only a process the host reports as running — or reports no status for — may be
    /// stopped; an unrecognized status stays displayable but never stoppable.
    var isStoppable: Bool { status == nil || !isFinished && status.lowercased() == "running" }

    static let finishedStatuses: Set<String> = [
        "exited", "finished", "completed", "done", "failed", "killed", "cancelled", "canceled", "dead"
    ]

    static func boundedTail(_ text: String) -> (text: String, wasTruncated: Bool) {
        let bytes = Data(text.utf8)
        guard bytes.count > HermesBackgroundProcesses.maximumTailBytes else { return (text, false) }
        return (String(decoding: bytes.suffix(HermesBackgroundProcesses.maximumTailBytes), as: UTF8.self), true)
    }
}

/// The host's answer to a confirmed `process.kill` that reached it. Only `killed` and
/// `already_exited` are successes; everything else keeps the row and shows a failure.
struct HermesBackgroundProcessResult: Equatable, Sendable {
    let process: HermesBackgroundProcess.Identity
    let isKilled: Bool
    let output: String?
    let exitCode: Int?
}

/// Owns one Hermes chat's background-process inspection (#1420), beside its delegated
/// workers on the same socket and attach generation. It refreshes only on connect, at a
/// turn's end, when the sheet opens, or on an explicit pull — never on a timer. A stop
/// is confirmed and re-validated at dispatch; a lost or failed reply is never retried.
@MainActor @Observable final class HermesBackgroundProcesses {
    enum Availability: Equatable { case unknown, supported, unsupported }

    struct Context: Equatable, Sendable {
        let connectionID: UUID
        let runtime: String
        /// The attach's `HermesConversation.generation`.
        let generation: Int
    }

    struct StopAction: Identifiable, Equatable, Sendable {
        let id = UUID()
        let context: Context
        let process: HermesBackgroundProcess.Identity
    }

    static let maximumProcesses = 64
    static let maximumTailBytes = 16 * 1024

    private(set) var availability = Availability.unknown
    private(set) var processes: [HermesBackgroundProcess] = []
    private(set) var omittedProcessCount = 0
    /// Every process the host reports as running. Stored apart from `rows`-style detail
    /// so the toolbar redraws only when the count itself changes.
    private(set) var runningCount = 0
    private(set) var isRefreshing = false
    private(set) var stoppingProcess: HermesBackgroundProcess.Identity?
    /// The last kill the host confirmed for a row, kept until the row goes or a refresh
    /// reports the process gone.
    private(set) var result: HermesBackgroundProcessResult?
    private(set) var errorMessage: String?

    @ObservationIgnored private let wire: any BotTransport
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var listRequestID = UUID()
    @ObservationIgnored private var stopRequestID = UUID()

    init(wire: any BotTransport) {
        self.wire = wire
    }

    func connect(_ next: Context) async {
        disconnect()
        context = next
        await refresh()
    }

    func disconnect() {
        context = nil
        listRequestID = UUID()
        stopRequestID = UUID()
        availability = .unknown
        processes = []
        omittedProcessCount = 0
        runningCount = 0
        isRefreshing = false
        stoppingProcess = nil
        result = nil
        errorMessage = nil
    }

    func refresh() async {
        guard let owner = context else { return }
        // A host that already answered -32601 for this method stays hidden without
        // another request: the connection's missing-method cache is the feature gate.
        guard !wire.unavailableMethods.contains(HermesCall.processList(sessionID: owner.runtime).method) else {
            availability = .unsupported
            return
        }
        let requestID = UUID()
        listRequestID = requestID
        isRefreshing = true
        do {
            let reply = try await wire.call(.processList(sessionID: owner.runtime)) { [weak self] in
                guard let self, self.owns(owner) else { throw BotFailure.stale }
            }
            guard owns(owner), listRequestID == requestID else { return }
            guard let rows = reply["processes"].list else { throw BotFailure.unsupported }
            install(rows.compactMap(HermesBackgroundProcess.init))
            availability = .supported
            errorMessage = nil
            isRefreshing = false
        } catch {
            guard owns(owner), listRequestID == requestID, !Task.isCancelled else { return }
            isRefreshing = false
            if Self.isUnsupported(error) {
                availability = .unsupported
                processes = []
                omittedProcessCount = 0
                countRunning()
                result = nil
                errorMessage = nil
            } else if error as? BotFailure != .stale {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func prepareStop(_ process: HermesBackgroundProcess) -> StopAction? {
        guard let context, process.isStoppable, stoppingProcess == nil,
              current(process.id) != nil else { return nil }
        return StopAction(context: context, process: process.id)
    }

    /// Re-lists immediately before the destructive call, so a process that exited during
    /// confirmation is never killed, and re-validates ownership at the socket write. The
    /// gateway then resolves the authorized live record at dispatch time. `not_found`
    /// and RPC 4044 refresh instead of failing; `error` and an unknown status keep the
    /// row and report the failure. A reply that never arrives is never retried.
    func stop(_ action: StopAction) async {
        guard owns(action.context), current(action.process) != nil, stoppingProcess == nil else { return }
        let requestID = UUID()
        stopRequestID = requestID
        stoppingProcess = action.process
        errorMessage = nil
        do {
            let reply = try await wire.call(.processList(sessionID: action.context.runtime)) { [weak self] in
                guard let self, self.owns(action.context) else { throw BotFailure.stale }
            }
            guard owns(action.context), let rows = reply["processes"].list else { throw BotFailure.unsupported }
            install(rows.compactMap(HermesBackgroundProcess.init))
            guard let fresh = current(action.process), fresh.isStoppable else {
                stoppingProcess = nil
                errorMessage = String(localized: "This process is no longer running.")
                return
            }
            let killReply = try await wire.call(.processKill(sessionID: action.context.runtime,
                                                             processID: action.process.processID)) { [weak self] in
                guard let self, self.owns(action.context), self.stopRequestID == requestID,
                      self.stoppingProcess == action.process,
                      self.current(action.process)?.isStoppable == true else { throw BotFailure.stale }
            }
            guard owns(action.context), stopRequestID == requestID, stoppingProcess == action.process else { return }
            let status = killReply["status"].text ?? ""
            switch status {
            case "killed", "already_exited":
                let output = (killReply["output"].text ?? killReply["error"].text)
                    .map { HermesBackgroundProcess.boundedTail($0.strippingANSIEscapes()).text }
                    .flatMap { $0.isEmpty ? nil : $0 }
                result = HermesBackgroundProcessResult(process: action.process, isKilled: status == "killed",
                                                       output: output, exitCode: killReply["exit_code"].integer)
                stoppingProcess = nil
            case "not_found":
                stoppingProcess = nil
                await refresh()
                guard owns(action.context) else { return }
                errorMessage = String(localized: "This process is no longer running.")
            default:
                stoppingProcess = nil
                errorMessage = String(localized: "The host could not stop this process.")
            }
        } catch BotFailure.rejected(4044) {
            guard owns(action.context), stopRequestID == requestID else { return }
            stoppingProcess = nil
            await refresh()
            guard owns(action.context) else { return }
            errorMessage = String(localized: "This process is no longer running.")
        } catch {
            guard owns(action.context), stopRequestID == requestID, stoppingProcess == action.process,
                  !Task.isCancelled else { return }
            stoppingProcess = nil
            if error as? BotFailure != .stale { errorMessage = Self.message(for: error) }
        }
    }

    private func install(_ received: [HermesBackgroundProcess]) {
        let bounded = Array(received.prefix(Self.maximumProcesses))
        processes = bounded
        omittedProcessCount = max(0, received.count - bounded.count)
        countRunning()
        if let result, current(result.process) == nil { self.result = nil }
        if let stoppingProcess, current(stoppingProcess) == nil { self.stoppingProcess = nil }
    }

    private func countRunning() {
        let count = processes.filter { !$0.isFinished }.count + omittedProcessCount
        if count != runningCount { runningCount = count }
    }

    private func current(_ identity: HermesBackgroundProcess.Identity) -> HermesBackgroundProcess? {
        processes.first { $0.id == identity }
    }

    private func owns(_ owner: Context) -> Bool {
        context == owner && !Task.isCancelled
    }

    private static func isUnsupported(_ error: Error) -> Bool {
        error as? BotFailure == .unsupported || error as? BotFailure == .rejected(-32601)
    }

    private static func message(for error: Error) -> String {
        if error as? BotFailure == .rejected(4001) {
            return String(localized: "This Hermes connection no longer owns these processes. Reconnect to inspect them.")
        }
        if isUnsupported(error) {
            return String(localized: "This Hermes host does not support background process inspection.")
        }
        if error as? BotFailure == .transport {
            return String(localized: "The result is unknown. Reconnect and refresh before acting again.")
        }
        return (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Background processes could not be refreshed.")
    }
}
