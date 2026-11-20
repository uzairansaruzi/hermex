import Foundation
import OSLog

@MainActor final class HermesGateway {
    struct Options {
        var rpcDeadline: Duration = .seconds(30)
        var heartbeatInterval: Duration = .seconds(15)
        var probeDeadline: Duration = .seconds(8)
        var socketFactory: ((URLRequest) -> any BotSocket)?
    }

    let http: HermesConnection
    private let profile: String?
    private(set) var replayEpoch: String?
    private(set) var speaksCanonicalProtocol = false
    private var subscriptions = HermesCanonicalSubscriptions()
    private let options: Options
    private var socket: (any BotSocket)?
    private var opening: Task<Void, Error>?
    private var handshakeAttempt: Int?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var probing: (generation: Int, deadline: Task<Void, Never>)?
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var isRetired = false
    private var consumers: [Consumer] = []
    private var nextID = 0
    private var detachCount = 0
    private var pending: [Int: Pending] = [:]

    private struct Consumer {
        let id: Int
        weak var client: BotClient?
        var attached: Bool
    }

    private struct Pending {
        let continuation: CheckedContinuation<BotJSON, Error>
        let consumer: Int?
        let method: String
        let deadline: Task<Void, Never>
        let rejection: HermesCall.Rejection
    }

    init(http: HermesConnection, options: Options = Options(), profile: String? = nil) {
        self.http = http
        self.options = options
        self.profile = profile
    }


    func isAttached(_ consumer: Int) -> Bool {
        consumers.contains { $0.id == consumer && $0.attached }
    }

    private func maySend(_ consumer: Int?) -> Bool {
        guard let consumer else { return true }
        return isAttached(consumer)
    }

    func join(_ client: BotClient) async throws {
        guard !isRetired else { throw BotFailure.stale }
        let isOpen = socket != nil && opening == nil
        consumers.removeAll { $0.id == client.consumerID || $0.client == nil }
        consumers.append(Consumer(id: client.consumerID, client: client, attached: isOpen))
        if isOpen { return }
        try await (opening ?? open()).value
        guard isAttached(client.consumerID) else { throw BotFailure.transport }
    }

    func leave(_ client: BotClient) {
        consumers.removeAll { $0.id == client.consumerID }
        for (id, entry) in pending where entry.consumer == client.consumerID {
            pending[id] = nil
            entry.deadline.cancel()
            entry.continuation.resume(throwing: BotFailure.transport)
        }
        let detaches = subscriptions.release(client.consumerID)
        guard !consumers.contains(where: { $0.client != nil }) else {
            detach(detaches)
            return
        }
        if socket != nil || opening != nil {
            let label = socketLabel(generation)
            HermesConnectionLog.logger.notice("\(label, privacy: .public) closed, last screen left")
        }
        end(nil)
    }

    func closeForBackground() {
        guard socket != nil || opening != nil else { return }
        let label = socketLabel(generation)
        HermesConnectionLog.logger.notice("\(label, privacy: .public) closed, app in background")
        end(nil)
    }

    func dropSocket() {
        guard socket != nil || opening != nil else { return }
        let label = socketLabel(generation)
        HermesConnectionLog.logger.notice("\(label, privacy: .public) closed, dashboard restarted")
        end(BotFailure.transport)
    }

    func probe() async {
        if probing == nil {
            guard let socket, opening == nil, !isRetired else { return }
            let owner = generation, deadline = options.probeDeadline
            let watchdog = Task { [weak self] in
                do { try await Task.sleep(for: deadline) } catch { return }
                self?.settleProbe(alive: false, generation: owner)
            }
            probing = (owner, watchdog)
            Task { [weak self] in
                do { try await socket.send(.string(#"{"jsonrpc":"2.0","id":"probe","method":"gateway.ping","params":{}}"#)) }
                catch { self?.fail(error, generation: owner) }
            }
        }
        await withCheckedContinuation { probeWaiters.append($0) }
    }

    private func settleProbe(alive: Bool, generation owner: Int) {
        guard let probe = probing, probe.generation == owner else { return }
        probing = nil
        probe.deadline.cancel()
        let waiters = probeWaiters
        probeWaiters = []
        if !alive {
            let label = socketLabel(owner), seconds = options.probeDeadline.components.seconds
            HermesConnectionLog.logger.error("\(label, privacy: .public): no frame \(seconds, privacy: .public) s after the network changed; closing")
            end(BotFailure.transport)
        }
        for waiter in waiters { waiter.resume() }
    }

    func retire() {
        isRetired = true
        end(BotFailure.stale)
    }

    func send(_ call: HermesCall, for consumer: Int?, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        var params = try call.params(hostVersion: http.serverVersion)
        guard let socket, !Task.isCancelled, maySend(consumer) else { throw BotFailure.stale }
        if speaksCanonicalProtocol { params = call.canonicalParams(params) }
        nextID += 1
        let id = nextID, owner = generation
        if speaksCanonicalProtocol, let consumer, let attachment = call.attachment {
            subscriptions.willAttach(id, profile: attachment.profile, requested: attachment.requested, consumer: consumer)
        }
        let frame = BotJSON.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string(call.method), "params": .object(params)
        ])
        let text: String
        if case .fileAttach = call {
            text = try await Task.detached { String(decoding: try JSONEncoder().encode(frame), as: UTF8.self) }.value
            guard owner == generation, !Task.isCancelled, maySend(consumer) else { throw BotFailure.stale }
        } else { text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self) }
        let timesOutLocally = call.timesOutLocally, cancellationSafe = call.isCancellationSafe
        let rejection = call.rejection, rpcDeadline = call.deadline(options.rpcDeadline), method = call.method
        let reply: BotJSON = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: rpcDeadline) } catch { return }
                    guard let self, self.generation == owner, self.pending[id] != nil else { return }
                    let label = self.socketLabel(owner), seconds = rpcDeadline.components.seconds
                    HermesConnectionLog.logger.error("\(label, privacy: .public): \(method, privacy: .public) got no reply in \(seconds, privacy: .public) s")
                    if timesOutLocally { self.settle(id, throwing: BotFailure.transport) }
                    else { self.expire(id) }
                }
                pending[id] = Pending(continuation: continuation, consumer: consumer, method: method, deadline: deadline, rejection: rejection)
                Task { [weak self] in
                    guard let self, self.generation == owner, self.pending[id] != nil else { return }
                    do {
                        try validateDispatch?()
                    } catch {
                        self.settle(id, throwing: error)
                        return
                    }
                    do { try await socket.send(.string(text)) }
                    catch { self.fail(error, generation: owner) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id, generation: owner, safely: cancellationSafe) }
        }
        switch call {
        case .sessionResume, .sessionBranch:
            if let runtime = reply["session_id"].text, !runtime.isEmpty { http.noteAttached(runtime) }
        case .sessionClose(let runtime): http.noteClosed(runtime)
        default: break
        }
        return reply
    }

    func respond(toRequest id: String, result: BotJSON, for consumer: Int,
                 validateDispatch: (() throws -> Void)?) async throws {
        guard let socket, !Task.isCancelled, maySend(consumer) else { throw BotFailure.stale }
        try validateDispatch?()
        let frame = BotJSON.object(["jsonrpc": .string("2.0"), "id": .string(id), "result": result])
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        let owner = generation
        do { try await socket.send(.string(text)) } catch {
            fail(error, generation: owner)
            throw BotFailure.transport
        }
    }

    func release(_ consumer: Int, from session: HermesCanonicalSubscriptions.Session) {
        detach(subscriptions.release(consumer, from: session).map { [$0] } ?? [])
    }

    private func detach(_ calls: [HermesCall]) {
        guard let socket, opening == nil else { return }
        let owner = generation
        for call in calls {
            guard let params = try? call.canonicalParams(call.params(hostVersion: http.serverVersion)) else { continue }
            detachCount += 1
            let frame = BotJSON.object([
                "jsonrpc": .string("2.0"), "id": .string("detach-\(detachCount)"),
                "method": .string(call.method), "params": .object(params)
            ])
            guard let data = try? JSONEncoder().encode(frame) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            Task { [weak self] in
                do { try await socket.send(.string(text)) } catch { self?.fail(error, generation: owner) }
            }
        }
    }

    private func cancel(_ id: Int, generation owner: Int, safely: Bool) {
        guard owner == generation, let entry = pending[id] else { return }
        if safely { settle(id, throwing: CancellationError()); return }
        guard let consumer = entry.consumer else { return }
        consumers.first { $0.id == consumer }?.client?.close()
    }

    private func expire(_ id: Int) {
        guard let entry = pending[id] else { return }
        guard let consumer = entry.consumer else {
            end(BotFailure.transport)
            return
        }
        guard let client = consumers.first(where: { $0.id == consumer })?.client else {
            settle(id, throwing: BotFailure.transport)
            return
        }
        leave(client)
        client.socketEnded(BotFailure.transport)
    }

    private func settle(_ id: Int, throwing error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.deadline.cancel()
        entry.continuation.resume(throwing: error)
    }

    private func open() -> Task<Void, Error> {
        let owner = generation
        let attempt = Task {
            do {
                let upgrade = try await http.gatewayUpgrade(profile: profile)
                if owner == generation { handshakeAttempt = http.attemptCount }
                try await handshake(upgrade, generation: owner)
                opening = nil
                for index in consumers.indices { consumers[index].attached = true }
                if let record = handshakeAttempt { http.noteLiveHandshake(nil, attempt: record) }
                handshakeAttempt = nil
            } catch {
                if owner == generation {
                    let label = socketLabel(owner), reason = HermesConnectionLog.reason(error)
                    HermesConnectionLog.logger.error("\(label, privacy: .public) failed to open: \(reason, privacy: .public)")
                    if let record = handshakeAttempt { http.noteLiveHandshake(error, attempt: record) }
                    end(nil)
                }
                if let profile, case BotFailure.upgradeRefused(403) = error, await http.opensSharedSocket() {
                    let serving = try? await HermesProfileServing.read(on: http)
                    throw BotFailure.profileNotServed(profile, serving?.reason)
                }
                throw error
            }
        }
        opening = attempt
        return attempt
    }

    private func handshake(_ upgrade: URLRequest, generation owner: Int) async throws {
        func check() throws {
            guard owner == generation else { throw BotFailure.stale }
        }
        try check()
        let label = socketLabel(owner)
        let socket: any BotSocket
        if let socketFactory = options.socketFactory { socket = socketFactory(upgrade) }
        else {
            let task = http.session.webSocketTask(with: upgrade)
            task.maximumMessageSize = 16 * 1024 * 1024
            task.resume()
            socket = NativeBotSocket(task: task, label: label)
        }
        self.socket = socket
        let ready = try await Self.receive(socket, label: label)
        try check()
        guard ready["method"].text == "event", ready["params"]["type"].text == "gateway.ready",
              let epoch = ready["params"]["payload"]["replay_epoch"].text, !epoch.isEmpty
        else { throw BotFailure.unsupported }
        let canonical = ready["params"]["payload"]["session_authority"].flag == true
        replayEpoch = epoch
        speaksCanonicalProtocol = canonical
        startReader(socket, generation: owner)
        do { _ = try await send(.clientCapabilities, for: nil, validateDispatch: nil) }
        catch BotFailure.rejected {}
        try check()
        startHeartbeat(socket, generation: owner)
        HermesConnectionLog.logger.notice("\(label, privacy: .public) open")
    }

    private func startReader(_ socket: any BotSocket, generation owner: Int) {
        let label = socketLabel(owner)
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await Self.receive(socket, label: label)
                    guard let self, self.generation == owner else { return }
                    self.settleProbe(alive: true, generation: owner)
                    self.consume(frame, generation: owner)
                }
            } catch {
                self?.fail(error, generation: owner)
            }
        }
    }

    private func startHeartbeat(_ socket: any BotSocket, generation owner: Int) {
        let interval = options.heartbeatInterval
        heartbeat = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.generation == owner else { return }
                beat += 1
                let frame = #"{"jsonrpc":"2.0","id":"heartbeat-\#(beat)","method":"gateway.ping","params":{}}"#
                do { try await socket.send(.string(frame)) }
                catch {
                    self.fail(error, generation: owner)
                    return
                }
            }
        }
    }

    private static func receive(_ socket: any BotSocket, label: String) async throws -> BotJSON {
        try await withThrowingTaskGroup(of: BotJSON.self) { group in
            group.addTask {
                let frame = try await socket.receive()
                let data: Data
                switch frame {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw BotFailure.unsupported
                }
                return try JSONDecoder().decode(BotJSON.self, from: data)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                HermesConnectionLog.logger.error("\(label, privacy: .public): no frame for 45 s; closing")
                socket.cancel()
                throw BotFailure.transport
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw BotFailure.transport }
            return result
        }
    }

    private func consume(_ frame: BotJSON, generation owner: Int) {
        if frame["method"].text == "event" { deliver(frame["params"], generation: owner); return }
        if frame["id"].text != nil, frame["method"].text != nil { deliver(frame, generation: owner); return }
        guard let id = frame["id"].integer else { return }
        if speaksCanonicalProtocol, let detach = subscriptions.didAnswer(id, with: frame["result"]) { self.detach([detach]) }
        guard let entry = pending.removeValue(forKey: id) else {
            let label = socketLabel(owner)
            HermesConnectionLog.logger.notice("\(label, privacy: .public): reply for call \(id, privacy: .public) matched no open call")
            return
        }
        entry.deadline.cancel()
        if let code = frame["error"]["code"].integer {
            if code == -32601, entry.consumer != nil { http.noteUnavailable(entry.method) }
            let data = frame["error"]["data"]
            if speaksCanonicalProtocol, entry.rejection != .room,
               let reason = ["stale_generation": HermesFenceRefusal.Reason.generation,
                             "revision_conflict": .revision][data["reason"].text ?? ""] {
                entry.continuation.resume(throwing: HermesFenceRefusal(reason: reason, revision: data["revision"].integer,
                                                                       generation: data["execution_generation"].integer))
                return
            }
            switch entry.rejection {
            case .room:
                entry.continuation.resume(throwing: BotRoomFailure(code: code, reason: frame["error"]["data"]["reason"].text))
            case .setting:
                entry.continuation.resume(throwing: BotSettingFailure.rejected(
                    code, frame["error"]["message"].text ?? BotFailure.rejected(code).localizedDescription))
            case .screen:
                entry.continuation.resume(throwing: ScreenCallFailure(
                    code: code, refusal: frame["error"]["data"]["code"].text, message: frame["error"]["message"].text))
            case .plain:
                entry.continuation.resume(throwing: BotFailure.rejected(code))
            }
        }
        else if frame["result"] != .null { entry.continuation.resume(returning: frame["result"]) }
        else { entry.continuation.resume(throwing: BotFailure.unsupported) }
    }

    private func deliver(_ event: BotJSON, generation owner: Int) {
        for consumer in consumers where consumer.attached {
            guard generation == owner else { return }
            guard isAttached(consumer.id), let client = consumer.client else { continue }
            client.onEvent?(event)
        }
    }

    private func fail(_ error: Error, generation owner: Int) {
        guard owner == generation else { return }
        end(error)
    }

    private func end(_ error: Error?) {
        let label = socketLabel(generation), wasLive = socket != nil || opening != nil
        if let record = handshakeAttempt, let error, (error as? BotFailure) != .stale {
            http.noteLiveHandshake(error, attempt: record)
        }
        handshakeAttempt = nil
        settleProbe(alive: true, generation: generation)
        generation += 1
        opening = nil
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(); socket = nil
        let interrupted = pending.values
        pending.removeAll()
        let lost = consumers.filter(\.attached).compactMap(\.client)
        consumers.removeAll()
        subscriptions.removeAll()
        for entry in interrupted {
            entry.deadline.cancel()
            entry.continuation.resume(throwing: BotFailure.transport)
        }
        guard let error else { return }
        if wasLive, (error as? BotFailure) == .stale {
            HermesConnectionLog.logger.notice("\(label, privacy: .public) closed, connection retired")
        } else if wasLive {
            let reason = HermesConnectionLog.reason(error), calls = interrupted.count, screens = lost.count
            HermesConnectionLog.logger.error("\(label, privacy: .public) dropped: \(reason, privacy: .public); calls failed: \(calls, privacy: .public), screens told: \(screens, privacy: .public)")
        }
        for client in lost { client.socketEnded(error) }
    }

    private func socketLabel(_ number: Int) -> String { "c\(http.serial) socket s\(number)" }
}

private extension HermesCall {
    enum Rejection { case plain, room, setting, screen }

    var isCancellationSafe: Bool {
        switch self {
        case .fileAttach, .completePath, .completeFolder, .completeWorkspacePath, .completeSlash, .subagentList, .subagentTail,
             .subagentRoster,
             .sessionActiveList, .approvalPending, .sessionMostRecent, .profilesList, .profileModelOptions, .projectsTree,
             .commitMessage, .approvalSummary, .displayStatus, .displayObserve, .pluginsList, .rollbackList,
             .rollbackDiff: return true
        default: return false
        }
    }

    var timesOutLocally: Bool {
        switch self {
        case .subagentList, .subagentTail, .subagentRoster, .sessionActiveList, .approvalPending, .sessionMostRecent,
             .completeSlash, .slashExec,
             .profileModelOptions, .projectsTree, .completeFolder, .completeWorkspacePath, .commitMessage,
             .approvalSummary, .displayStatus, .displayObserve, .displayLeaseAcquire, .displayLeaseRelease,
             .displayStart, .displayStop, .pluginsList, .pluginsToggle, .pluginsInstall, .pluginsRemove, .pluginsUpdate,
             .pluginsSettings, .rollbackList, .rollbackDiff: return true
        case .completePath(_, _, _, let timesOutLocally): return timesOutLocally
        default: return false
        }
    }

    func deadline(_ standard: Duration) -> Duration {
        switch self {
        case .slashExec, .pluginsList: return standard * 2
        case .pluginsToggle: return standard * 6
        case .pluginsInstall, .pluginsUpdate: return standard * 10
        case .approvalSummary: return min(standard, .seconds(20))
        case .commitMessage, .displayStart: return .seconds(120)
        case .sessionCompress: return .seconds(660)
        case .sessionMutate(let mutation) where mutation.operation.name == "compress": return .seconds(660)
        default: return standard
        }
    }

    var rejection: Rejection {
        if method.hasPrefix("groups.") { return .room }
        if method.hasPrefix("display.") { return .screen }
        switch self {
        case .configSet, .sessionCwdSet, .sessionControl, .modelOptions, .configuredModelOptions, .profileModelOptions,
             .sessionControlRead: return .setting
        case .commandDispatch(let name, _, _) where name == "goal": return .setting
        case .slashExec, .sessionRename, .promptRewind, .sessionUndo, .sessionCompress, .sessionWorkspaceMove, .sessionMutate,
             .projectsCreate, .projectsUpdate, .projectsDelete, .sessionBranch, .pluginsToggle, .pluginsInstall,
             .pluginsRemove, .pluginsUpdate, .pluginsSettings, .connectedAppsConnect, .connectedAppsRemove,
             .rollbackList, .rollbackDiff, .rollbackRestore: return .setting
        default: return .plain
        }
    }
}

protocol BotSocket: Sendable {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel()
}

struct NativeBotSocket: BotSocket {
    let task: URLSessionWebSocketTask
    let label: String
    private let isClosedHere = OSAllocatedUnfairLock(initialState: false)

    init(task: URLSessionWebSocketTask, label: String) {
        self.task = task
        self.label = label
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        do { return try await task.receive() } catch {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, let refusal = BotFailure(upgradeStatus: status) {
                throw refusal
            }
            let code = task.closeCode
            if code != .invalid, !isClosedHere.withLock({ $0 }) {
                HermesConnectionLog.logger.error("\(label, privacy: .public) closed by the other end with code \(code.rawValue, privacy: .public)")
            }
            throw error
        }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func cancel() {
        isClosedHere.withLock { $0 = true }
        task.cancel(with: .normalClosure, reason: nil)
    }
}

extension BotFailure {
    init?(upgradeStatus status: Int) {
        switch status {
        case 101: return nil
        case 408, 429, 500...599: self = .rejected(status)
        default: self = .upgradeRefused(status)
        }
    }
}
