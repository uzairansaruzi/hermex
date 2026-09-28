import Foundation

/// One socket per connection owner, on the sign-in and cookie jar its
/// `HermesConnection` shares with the server's other Bot consumers. The receive loop
/// multiplexes RPC replies and events, so a quiet tool never blocks a Stop request.
@MainActor final class BotClient: BotTransport {
    private let http: HermesConnection
    private let rpcDeadline: Duration
    private let heartbeatInterval: Duration
    private var socket: (any BotSocket)?
    private let socketFactory: ((URLRequest) -> any BotSocket)?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var generation = 0
    private var imageUploads: [UUID: Task<String, Error>] = [:]
    private var artifactTasks: [UUID: Task<Data, Error>] = [:]
    private var nextID = 0
    private var settingCalls = Set<Int>()
    private var roomCalls = Set<Int>()
    private var pending: [Int: CheckedContinuation<BotJSON, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private(set) var replayEpoch: String?
    /// `version` from the connection's last `/api/status` read, before the auth gate; nil when omitted.
    var serverVersion: String? { http.serverVersion }
    /// `install_id` from the same read; nil when omitted.
    var serverInstallID: String? { http.serverInstallID }
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    /// A client on the sign-in `server`'s saved connection shares with its other consumers.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    /// A client with its own cookie jar and sign-in, for credentials that are not saved
    /// yet (connection setup, dev auto-login) and for tests.
    convenience init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral,
                     rpcDeadline: Duration = .seconds(30), heartbeatInterval: Duration = .seconds(15),
                     socketFactory: ((URLRequest) -> any BotSocket)? = nil) {
        self.init(http: HermesConnection(connection: connection, configuration: configuration),
                  rpcDeadline: rpcDeadline, heartbeatInterval: heartbeatInterval, socketFactory: socketFactory)
    }

    /// `heartbeatInterval` is the `gateway.ping` cadence; tests shorten it. `socketFactory`
    /// gets the finished gateway upgrade; nil opens a native socket on the connection's session.
    init(http: HermesConnection, rpcDeadline: Duration = .seconds(30), heartbeatInterval: Duration = .seconds(15),
         socketFactory: ((URLRequest) -> any BotSocket)? = nil) {
        self.http = http
        self.rpcDeadline = rpcDeadline
        self.heartbeatInterval = heartbeatInterval
        self.socketFactory = socketFactory
    }

    /// Signs in unless the connection already is, mints a fresh ticket, opens the
    /// socket and completes the handshake: `gateway.ready`, then `client.capabilities`
    /// as the first outbound frame, then the keepalive. Callers send nothing until
    /// this returns, so no RPC can precede the handshake.
    func connect() async throws {
        close()
        let owner = generation
        func check() throws {
            guard owner == generation, !Task.isCancelled else { throw BotFailure.stale }
        }
        do {
            let upgrade = try await http.gatewayUpgrade()
            try check()
            let socket: any BotSocket
            if let socketFactory { socket = socketFactory(upgrade) }
            else {
                let task = http.session.webSocketTask(with: upgrade)
                task.maximumMessageSize = 16 * 1024 * 1024
                task.resume()
                socket = NativeBotSocket(task: task)
            }
            self.socket = socket
            let ready = try await Self.receive(socket)
            try check()
            guard ready["method"].text == "event", ready["params"]["type"].text == "gateway.ready",
                  let epoch = ready["params"]["payload"]["replay_epoch"].text, !epoch.isEmpty
            else { throw BotFailure.unsupported }
            replayEpoch = epoch
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let frame = try await Self.receive(socket)
                        guard let self, self.generation == owner else { return }
                        self.consume(frame)
                    }
                } catch {
                    guard let self, self.generation == owner else { return }
                    self.close()
                    self.onDisconnect?(error)
                }
            }
            // Without this the host treats the socket as a build that predates
            // server→client requests: approvals are withdrawn unsent, clarify is
            // answered empty, and sudo/secret are skipped. A host older than the
            // capability answers -32601 and connects as before; the shared web
            // client ignores any rejection here too, so only a lost socket fails.
            do { _ = try await call(.clientCapabilities) }
            catch BotFailure.rejected {}
            try check()
            startHeartbeat(socket, owner: owner)
        } catch {
            if owner == generation { close() }
            throw error
        }
    }

    /// Sends `gateway.ping` on a fixed cadence, because the host sends no JSON
    /// heartbeat of its own and an idle socket would otherwise hit the 45 s
    /// silence deadline in `receive`. The pong is just more inbound traffic: its
    /// string id matches no pending call, so `consume` drops it. A failed send is
    /// a lost socket.
    private func startHeartbeat(_ socket: any BotSocket, owner: Int) {
        let interval = heartbeatInterval
        heartbeat = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.generation == owner else { return }
                beat += 1
                let frame = #"{"jsonrpc":"2.0","id":"heartbeat-\#(beat)","method":"gateway.ping","params":{}}"#
                do { try await socket.send(.string(frame)) }
                catch {
                    guard self.generation == owner else { return }
                    self.close()
                    self.onDisconnect?(error)
                    return
                }
            }
        }
    }

    private static func receive(_ socket: any BotSocket) async throws -> BotJSON {
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
                socket.cancel()
                throw BotFailure.transport
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw BotFailure.transport }
            return result
        }
    }

    /// Admits and sends one typed request. `HermesCall.params()` refuses a value the
    /// host must never receive; `validateDispatch` runs at the actual socket write.
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)? = nil) async throws -> BotJSON {
        let params = try call.params()
        guard let socket, !Task.isCancelled else { throw BotFailure.stale }
        nextID += 1
        let id = nextID
        if call.rejectsAsRoomFailure { roomCalls.insert(id) }
        defer { roomCalls.remove(id) }
        if call.rejectsAsSettingFailure { settingCalls.insert(id) }
        defer { settingCalls.remove(id) }
        let owner = generation
        let frame = BotJSON.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string(call.method), "params": .object(params)
        ])
        let timesOutLocally = call.timesOutLocally, cancellationSafe = call.isCancellationSafe
        let text: String
        if case .fileAttach = call {
            text = try await Task.detached { String(decoding: try JSONEncoder().encode(frame), as: UTF8.self) }.value
            guard owner == generation, !Task.isCancelled else { throw BotFailure.stale }
        } else { text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                let rpcDeadline = self.rpcDeadline
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: rpcDeadline) } catch { return }
                    guard let self, self.generation == owner else { return }
                    if timesOutLocally {
                        self.deadlines.removeValue(forKey: id)
                        self.pending.removeValue(forKey: id)?.resume(throwing: BotFailure.transport)
                    } else {
                        self.close()
                        self.onDisconnect?(BotFailure.transport)
                    }
                }
                Task { [weak self] in
                    guard let self, self.generation == owner, self.pending[id] != nil else { return }
                    do {
                        // Validate at the actual socket dispatch, after any executor delay.
                        try validateDispatch?()
                    } catch {
                        self.deadlines.removeValue(forKey: id)?.cancel()
                        self.pending.removeValue(forKey: id)?.resume(throwing: error)
                        return
                    }
                    do { try await socket.send(.string(text)) }
                    catch {
                        guard self.generation == owner else { return }
                        self.close()
                        self.onDisconnect?(error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == owner else { return }
                if cancellationSafe {
                    self.deadlines.removeValue(forKey: id)?.cancel()
                    self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
                } else { self.close() }
            }
        }
    }

    private func consume(_ frame: BotJSON) {
        if frame["method"].text == "event" { onEvent?(frame["params"]); return }
        // Server requests have string ids and no replay sequence. Forward the
        // original envelope so consumers cannot mistake them for sequenced events.
        if frame["id"].text != nil, frame["method"].text != nil {
            onEvent?(frame); return
        }
        guard let id = frame["id"].integer, let continuation = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        if let code = frame["error"]["code"].integer {
            if roomCalls.contains(id) {
                continuation.resume(throwing: BotRoomFailure(code: code, reason: frame["error"]["data"]["reason"].text))
            } else if settingCalls.contains(id) {
                continuation.resume(throwing: BotSettingFailure.rejected(code, frame["error"]["message"].text ?? BotFailure.rejected(code).localizedDescription))
            } else { continuation.resume(throwing: BotFailure.rejected(code)) }
        }
        else if frame["result"] != .null { continuation.resume(returning: frame["result"]) }
        else { continuation.resume(throwing: BotFailure.unsupported) }
    }

    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        guard context.connectionID == http.connection.id, socket != nil else { throw BotFailure.stale }
        let owner = generation
        let request = try HermesREST.downloadArtifact(path: path, profile: context.profile, sessionID: context.sessionID)
            .request(base: http.connection.address)
        let id = UUID()
        let http = self.http
        let task = Task {
            try await http.authorized(request, validateDispatch: { try self.checkOwner(owner) }) { request, session in
                try await BotArtifactDownload.data(session: session, request: request)
            }
        }
        artifactTasks[id] = task
        defer { artifactTasks[id] = nil }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try checkOwner(owner)
            return data
        } onCancel: { task.cancel() }
    }

    func deleteProfile(_ name: String) async throws {
        guard socket != nil, BotProfileName.isValid(name) else { throw BotFailure.stale }
        let owner = generation
        let data = try await http.data(.deleteProfile(name: name), validateDispatch: { try self.checkOwner(owner) })
        try checkOwner(owner)
        guard (try? JSONDecoder().decode(BotJSON.self, from: data))?["ok"].flag == true else { throw BotFailure.unsupported }
    }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        guard context.connectionID == http.connection.id, socket != nil else { throw BotFailure.stale }
        let owner = generation
        let id = UUID()
        let http = self.http
        let task = Task {
            try await BotAttachmentUpload.image(data: data, filename: filename, profile: context.profile, via: http,
                                                validateDispatch: { try self.checkOwner(owner) })
        }
        imageUploads[id] = task
        defer { imageUploads[id] = nil }
        return try await withTaskCancellationHandler {
            let path = try await task.value
            try checkOwner(owner)
            return path
        } onCancel: { task.cancel() }
    }

    /// Throws `.stale` once `close()` or a reconnect has ended the `owner` generation. The
    /// HTTP calls check it on their result and, through `validateDispatch`, before each
    /// send: `close()` can land while they wait on the shared sign-in.
    private func checkOwner(_ owner: Int) throws {
        guard owner == generation, !Task.isCancelled else { throw BotFailure.stale }
    }

    func close() {
        generation += 1
        for task in imageUploads.values { task.cancel() }
        imageUploads.removeAll()
        for task in artifactTasks.values { task.cancel() }
        artifactTasks.removeAll()
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(); socket = nil
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let interrupted = pending.values
        pending.removeAll()
        for continuation in interrupted { continuation.resume(throwing: BotFailure.transport) }
    }
}

/// How the socket treats each request once it is on the wire.
private extension HermesCall {
    /// Reads and uploads that never control agent execution. Cancelling one
    /// discards its late reply; cancelling any other call closes the socket,
    /// because its outcome is unknown.
    var isCancellationSafe: Bool {
        switch self {
        case .fileAttach, .completePath, .subagentList, .subagentTail, .sessionActiveList: return true
        default: return false
        }
    }

    /// Optional reads whose timeout fails only that request. Any other call that
    /// times out is a lost socket.
    var timesOutLocally: Bool {
        switch self {
        case .subagentList, .subagentTail, .sessionActiveList: return true
        default: return false
        }
    }

    /// Room rejections carry the host's reason as `BotRoomFailure`.
    var rejectsAsRoomFailure: Bool { method.hasPrefix("groups.") }

    /// Setting rejections carry the host's message as `BotSettingFailure`.
    var rejectsAsSettingFailure: Bool {
        switch self {
        case .configSet, .sessionCwdSet, .sessionControl, .modelOptions, .configuredModelOptions, .sessionControlRead: return true
        default: return false
        }
    }
}

/// The socket boundary permits scripted frames without a backend or Profile storage.
protocol BotSocket: Sendable {
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel()
}

private struct NativeBotSocket: BotSocket {
    let task: URLSessionWebSocketTask
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}
