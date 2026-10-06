import Foundation
import OSLog

/// The one gateway WebSocket a `HermesConnection` shares among its Bot screens. The inbox,
/// each open chat, a room, the creator and the editor hold their own `BotClient` on it.
/// The socket opens when the first of them connects and closes when the last one leaves,
/// so it lives exactly while some Bot screen is connected. An `.inactive` scene (Control
/// Center, a notification banner) keeps it; `.background` closes it once, silently
/// (`closeForBackground()`). The chat, inbox, rooms and editor reconnect on `.active`;
/// the creators reconnect on their next Create.
///
/// Every socket mints a fresh ticket and runs one handshake before anything else:
/// `gateway.ready` (recording `replay_epoch`), then `client.capabilities` as the first
/// outbound frame, then the keepalive. Screens that connect while it opens wait for that
/// one attempt, so several screens reconnecting after the same drop make one replacement.
///
/// The receive loop multiplexes, so a quiet tool never blocks a Stop request. A reply
/// settles only the call that sent it. Every event and string-id server request goes to
/// every attached screen, which admits only its own (a chat its runtime, the inbox
/// `sessions.changed`); the gateway never answers a server request itself.
///
/// A screen's `close()` ends only its own calls, and their late replies reach no one. A
/// screen's required call past its deadline ends only that screen, which hears it as a
/// lost connection. A lost socket (a read or send failure, 45 s of silence) ends every
/// attached screen's part, and each hears it once; anything later from that socket is
/// dropped by its generation. `retire()` does the same with `.stale` when the
/// connection's server or configuration is replaced, and refuses reconnects.
@MainActor final class HermesGateway {
    /// Tests shorten the deadlines and script the socket; production takes the defaults.
    struct Options {
        var rpcDeadline: Duration = .seconds(30)
        /// The `gateway.ping` cadence.
        var heartbeatInterval: Duration = .seconds(15)
        /// Gets the finished gateway upgrade; nil opens a native socket on the connection's session.
        var socketFactory: ((URLRequest) -> any BotSocket)?
    }

    let http: HermesConnection
    /// `replay_epoch` from the last socket's `gateway.ready`.
    private(set) var replayEpoch: String?
    private let options: Options
    private var socket: (any BotSocket)?
    /// The open attempt every connecting screen waits on; nil once the socket is open.
    private var opening: Task<Void, Error>?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    /// Numbers sockets. A frame, failure or deadline from an older one is ignored.
    private var generation = 0
    private var isRetired = false
    private var consumers: [Consumer] = []
    private var consumerCount = 0
    private var nextID = 0
    private var pending: [Int: Pending] = [:]

    private struct Consumer {
        let id: Int
        weak var client: BotClient?
        /// False while it waits for the socket to open.
        var attached: Bool
    }

    private struct Pending {
        let continuation: CheckedContinuation<BotJSON, Error>
        /// The screen that sent it; nil for the handshake's own call.
        let consumer: Int?
        /// `HermesCall.method`, for the log and the connection's missing methods.
        let method: String
        let deadline: Task<Void, Never>
        let rejection: HermesCall.Rejection
    }

    init(http: HermesConnection, options: Options = Options()) {
        self.http = http
        self.options = options
    }

    /// A new identity for one screen's `BotClient`.
    func makeConsumerID() -> Int {
        consumerCount += 1
        return consumerCount
    }

    func isAttached(_ consumer: Int) -> Bool {
        consumers.contains { $0.id == consumer && $0.attached }
    }

    /// Whether `consumer` may send: attached, or nil for the handshake's own call.
    private func maySend(_ consumer: Int?) -> Bool {
        guard let consumer else { return true }
        return isAttached(consumer)
    }

    /// Attaches `client` to the open socket, or waits for the socket to open, starting that
    /// when nobody has. Throws what opening threw, `.transport` for a client whose socket
    /// dropped before it could attach, and `.stale` once retired.
    func join(_ client: BotClient) async throws {
        guard !isRetired else { throw BotFailure.stale }
        let isOpen = socket != nil && opening == nil
        consumers.removeAll { $0.id == client.consumerID || $0.client == nil }
        consumers.append(Consumer(id: client.consumerID, client: client, attached: isOpen))
        if isOpen { return }
        try await (opening ?? open()).value
        guard isAttached(client.consumerID) else { throw BotFailure.transport }
    }

    /// Ends `client`'s part: its calls in flight fail with `.transport` and their late
    /// replies reach no one. The last screen to leave closes the socket, silently.
    func leave(_ client: BotClient) {
        consumers.removeAll { $0.id == client.consumerID }
        for (id, entry) in pending where entry.consumer == client.consumerID {
            pending[id] = nil
            entry.deadline.cancel()
            entry.continuation.resume(throwing: BotFailure.transport)
        }
        guard !consumers.contains(where: { $0.client != nil }) else { return }
        if socket != nil || opening != nil {
            let label = socketLabel(generation)
            HermesConnectionLog.logger.notice("\(label, privacy: .public) closed, last screen left")
        }
        end(nil)
    }

    /// Closes the socket because the app went to the background, so the host sees a clean
    /// close rather than a half-open socket the tunnel notices only at its idle cutoff.
    /// Silent: no attached screen hears it, because each suspends on `.background` itself.
    /// The chat, inbox, rooms and editor reconnect on `.active` onto a fresh socket, ticket
    /// and handshake; the creators reconnect on their next Create.
    func closeForBackground() {
        guard socket != nil || opening != nil else { return }
        let label = socketLabel(generation)
        HermesConnectionLog.logger.notice("\(label, privacy: .public) closed, app in background")
        end(nil)
    }

    /// Ends the socket for good because the connection was replaced. Attached screens hear
    /// `.stale` once, and every later `join` throws it.
    func retire() {
        isRetired = true
        end(BotFailure.stale)
    }

    /// Admits and sends one typed request for `consumer` (nil: the handshake's own), then
    /// waits for its reply. `HermesCall.params()` refuses a value the host must never
    /// receive and shapes it for the release the last sign-in read; `validateDispatch`
    /// runs at the actual socket write.
    func send(_ call: HermesCall, for consumer: Int?, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let params = try call.params(hostVersion: http.serverVersion)
        guard let socket, !Task.isCancelled, maySend(consumer) else { throw BotFailure.stale }
        nextID += 1
        let id = nextID, owner = generation
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
        return try await withTaskCancellationHandler {
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
                        // Validate at the actual socket dispatch, after any executor delay.
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
    }

    /// A cancelled read discards its late reply. Any other cancelled call may have reached
    /// the agent, so its screen ends as `close()` ends it; the socket stays for the others.
    private func cancel(_ id: Int, generation owner: Int, safely: Bool) {
        guard owner == generation, let entry = pending[id] else { return }
        if safely { settle(id, throwing: CancellationError()); return }
        guard let consumer = entry.consumer else { return }
        consumers.first { $0.id == consumer }?.client?.close()
    }

    /// A required call past its deadline. A screen's ends only that screen, which hears
    /// `.transport` once, as it did when it had its own socket; the heartbeat and the 45 s
    /// silence deadline decide whether the socket itself is gone. The handshake's own call
    /// means the socket never became usable.
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
                try await handshake(generation: owner)
                opening = nil
                for index in consumers.indices { consumers[index].attached = true }
            } catch {
                // An attempt a leave, fault or retirement already ended has nothing left to end.
                if owner == generation {
                    let label = socketLabel(owner), reason = HermesConnectionLog.reason(error)
                    HermesConnectionLog.logger.error("\(label, privacy: .public) failed to open: \(reason, privacy: .public)")
                    end(nil)
                }
                throw error
            }
        }
        opening = attempt
        return attempt
    }

    /// Signs in unless the connection already is, mints a fresh ticket, opens the socket
    /// and completes the handshake. No screen sends anything until it returns.
    private func handshake(generation owner: Int) async throws {
        func check() throws {
            guard owner == generation else { throw BotFailure.stale }
        }
        let upgrade = try await http.gatewayUpgrade()
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
        replayEpoch = epoch
        startReader(socket, generation: owner)
        // Without this the host treats the socket as a build that predates
        // server→client requests: approvals are withdrawn unsent, clarify is
        // answered empty, and sudo/secret are skipped. A host older than the
        // capability answers -32601 and connects as before; the shared web
        // client ignores any rejection here too, so only a lost socket fails.
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
                    self.consume(frame, generation: owner)
                }
            } catch {
                self?.fail(error, generation: owner)
            }
        }
    }

    /// Sends `gateway.ping` on a fixed cadence, because the host sends no JSON
    /// heartbeat of its own and an idle socket would otherwise hit the 45 s
    /// silence deadline in `receive`. The pong is just more inbound traffic: its
    /// string id matches no pending call, so `consume` drops it. A failed send is
    /// a lost socket.
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

    /// Reads one frame, or closes `socket` after 45 s of silence. `label` names the socket in the log.
    private static func receive(_ socket: any BotSocket, label: String) async throws -> BotJSON {
        // Heartbeats keep a healthy quiet socket alive. Silence eventually becomes
        // disconnected/unknown instead of leaving a permanent Working label.
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
        // Server requests have string ids and no replay sequence. Forward the
        // original envelope so screens cannot mistake them for sequenced events.
        if frame["id"].text != nil, frame["method"].text != nil { deliver(frame, generation: owner); return }
        // The keepalive's pongs have string ids and are dropped here, unlogged.
        guard let id = frame["id"].integer else { return }
        guard let entry = pending.removeValue(forKey: id) else {
            // Usually a late reply to a screen that has left.
            let label = socketLabel(owner)
            HermesConnectionLog.logger.notice("\(label, privacy: .public): reply for call \(id, privacy: .public) matched no open call")
            return
        }
        entry.deadline.cancel()
        if let code = frame["error"]["code"].integer {
            // The host lacks this method, so every screen on the connection leaves it off.
            // The handshake's own `client.capabilities` is exempt: an older host connects as before.
            if code == -32601, entry.consumer != nil { http.noteUnavailable(entry.method) }
            switch entry.rejection {
            case .room:
                entry.continuation.resume(throwing: BotRoomFailure(code: code, reason: frame["error"]["data"]["reason"].text))
            case .setting:
                entry.continuation.resume(throwing: BotSettingFailure.rejected(
                    code, frame["error"]["message"].text ?? BotFailure.rejected(code).localizedDescription))
            case .plain:
                entry.continuation.resume(throwing: BotFailure.rejected(code))
            }
        }
        else if frame["result"] != .null { entry.continuation.resume(returning: frame["result"]) }
        else { entry.continuation.resume(throwing: BotFailure.unsupported) }
    }

    private func deliver(_ event: BotJSON, generation owner: Int) {
        for consumer in consumers where consumer.attached {
            // A callback may close a screen or end the socket; check before each one.
            guard generation == owner else { return }
            guard isAttached(consumer.id), let client = consumer.client else { continue }
            client.onEvent?(event)
        }
    }

    private func fail(_ error: Error, generation owner: Int) {
        guard owner == generation else { return }
        end(error)
    }

    /// Closes the socket, fails every call on it with `.transport` and drops every screen.
    /// The attached ones hear `error` once, and the log records it; nil ends it silently
    /// (the last screen left, the app went to the background, or opening failed and its
    /// waiters get the error from `join`), and the caller logs why.
    private func end(_ error: Error?) {
        let label = socketLabel(generation), wasLive = socket != nil || opening != nil
        generation += 1
        opening = nil
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(); socket = nil
        let interrupted = pending.values
        pending.removeAll()
        let lost = consumers.filter(\.attached).compactMap(\.client)
        consumers.removeAll()
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

    /// Names socket `number` of this connection in the log, such as `c1 socket s0`.
    private func socketLabel(_ number: Int) -> String { "c\(http.serial) socket s\(number)" }
}

/// How the socket treats each request once it is on the wire.
private extension HermesCall {
    enum Rejection { case plain, room, setting }

    /// Reads and uploads that never control agent execution. Cancelling one
    /// discards its late reply; cancelling any other call ends its screen's part,
    /// because its outcome is unknown.
    var isCancellationSafe: Bool {
        switch self {
        case .fileAttach, .completePath, .completeSlash, .subagentList, .subagentTail, .sessionActiveList: return true
        default: return false
        }
    }

    /// Optional reads, and slash commands, whose timeout fails only that request: a slow
    /// command must never end its chat's connection. Any other call that times out ends its
    /// screen's connection; the socket stays for the others.
    var timesOutLocally: Bool {
        switch self {
        case .subagentList, .subagentTail, .sessionActiveList, .completeSlash, .slashExec: return true
        default: return false
        }
    }

    /// How long a reply may take. A slash command may run in the host's slash worker, which
    /// allows it 45 s, so `slash.exec` waits twice the usual deadline.
    func deadline(_ standard: Duration) -> Duration {
        if case .slashExec = self { return standard * 2 }
        return standard
    }

    /// Room rejections carry the host's reason as `BotRoomFailure`; setting rejections
    /// carry its message as `BotSettingFailure`. So do a refused `/goal`, whose 4004 message
    /// says what was wrong with it (#1013), and a refused slash command (#1036).
    var rejection: Rejection {
        if method.hasPrefix("groups.") { return .room }
        switch self {
        case .configSet, .sessionCwdSet, .sessionControl, .modelOptions, .configuredModelOptions, .sessionControlRead: return .setting
        case .commandDispatch(let name, _, _) where name == "goal": return .setting
        case .slashExec: return .setting
        default: return .plain
        }
    }
}

/// The socket boundary permits scripted frames without a backend or Profile storage.
protocol BotSocket: Sendable {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel()
}

/// The production socket. Tests open one against a loopback listener to check how
/// URLSession reports the handshake.
struct NativeBotSocket: BotSocket {
    let task: URLSessionWebSocketTask
    /// Names this socket in the log.
    let label: String
    /// Set by `cancel()`, so our own close, which URLSession also reports as code 1000, is not logged.
    private let isClosedHere = OSAllocatedUnfairLock(initialState: false)

    init(task: URLSessionWebSocketTask, label: String) {
        self.task = task
        self.label = label
    }

    /// A refused upgrade fails the first read with a bare `URLError`; the handshake's HTTP
    /// status, when there is one, says what refused it, and the gateway logs that failure.
    /// A socket the other end closed logs its close code, never its reason: a proxy can put
    /// any bytes there.
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
    /// The failure a gateway upgrade answered with `status` stands for, or nil for 101, an
    /// accepted upgrade whose later errors are the socket's own. 408, 429 and 5xx keep
    /// `.rejected` and its quiet retry and proxy copy; any other status is `.upgradeRefused`,
    /// which does not heal on its own.
    init?(upgradeStatus status: Int) {
        switch status {
        case 101: return nil
        case 408, 429, 500...599: self = .rejected(status)
        default: self = .upgradeRefused(status)
        }
    }
}
