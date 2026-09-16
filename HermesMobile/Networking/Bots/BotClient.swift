import Foundation

/// One cookie jar and socket per connection owner. The receive loop multiplexes
/// RPC replies and events, so a quiet tool never blocks a Stop request.
@MainActor final class BotClient: BotTransport {
    private let connection: BotConnection
    private let session: URLSession
    private var socket: (any BotSocket)?
    private let socketFactory: ((URL, [String]) -> any BotSocket)?
    private var reader: Task<Void, Never>?
    private var generation = 0
    private var imageUploads: [UUID: Task<String, Error>] = [:]
    private var artifactTasks: [UUID: Task<Data, Error>] = [:]
    private var nextID = 0
    private var settingCalls = Set<Int>()
    private var pending: [Int: CheckedContinuation<BotJSON, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private(set) var replayEpoch: String?
    /// `version` from `/api/status`, captured before the auth gate; nil when omitted.
    private(set) var serverVersion: String?
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral,
         socketFactory: ((URL, [String]) -> any BotSocket)? = nil) {
        self.socketFactory = socketFactory
        self.connection = connection
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    private func http(_ endpoint: BotEndpoint, body: BotJSON? = nil) async throws -> BotJSON {
        var request = URLRequest(url: endpoint.url(base: connection.address))
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BotFailure.transport }
        guard response.statusCode == 200 else { throw BotFailure.rejected(response.statusCode) }
        return try JSONDecoder().decode(BotJSON.self, from: data)
    }

    func connect() async throws {
        close()
        let owner = generation
        func check() throws {
            guard owner == generation, !Task.isCancelled else { throw BotFailure.stale }
        }
        do {
            let status = try await http(.status)
            try check()
            serverVersion = status["version"].text
            guard status["auth_required"].flag == true,
                  status["auth_providers"].list?.contains(.string("basic")) == true else { throw BotFailure.unsupported }
            _ = try await http(.login, body: .object([
                "provider": .string("basic"), "username": .string(connection.username),
                "password": .string(connection.password)
            ]))
            try check()
            let identity = try await http(.identity)
            try check()
            guard identity["provider"].text == "basic" else { throw BotFailure.wrongIdentity }
            let ticket = try await http(.ticket, body: .object([:]))
            try check()
            guard let token = ticket["ticket"].text, !token.isEmpty,
                  var parts = URLComponents(url: BotEndpoint.socket.url(base: connection.address), resolvingAgainstBaseURL: false)
            else { throw BotFailure.unsupported }
            parts.scheme = connection.address.scheme == "https" ? "wss" : "ws"
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            let protocols = ["hermes-gateway-v1", "hermes-gateway-ticket." + token]
            let socket: any BotSocket
            if let socketFactory { socket = socketFactory(url, protocols) }
            else {
                let task = session.webSocketTask(with: url, protocols: protocols)
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
        } catch {
            if owner == generation { close() }
            throw error
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

    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)? = nil) async throws -> BotJSON {
        guard ["profiles.list", "profiles.get_asset", "profiles.describe", "profiles.configure", "profiles.set_asset",
               "session.list", "session.resume", "session.events.since",
               "file.attach", "prompt.submit", "session.steer", "session.redirect", "session.interrupt", "approval.respond", "clarify.respond",
               "sudo.respond", "secret.respond", "mcp.setup.respond",
               "model.options", "config.set", "session.cwd.set", "session.control.read", "session.control"].contains(method)
        else { throw BotFailure.unsupported }
        try Self.validateProfileEditorCall(method, params)
        guard let socket, !Task.isCancelled else { throw BotFailure.stale }
        nextID += 1
        let id = nextID
        if ["config.set", "session.cwd.set", "session.control", "model.options", "session.control.read"].contains(method) {
            settingCalls.insert(id)
        }
        defer { settingCalls.remove(id) }
        // The host still has a missing-runtime fallback for effort/fast. The
        // maintainer accepts that limitation; never send global or display writes.
        if method == "config.set" {
            guard params["scope"]?.text == "session", params["session_id"]?.text?.isEmpty == false,
                  let value = params["value"]?.text else { throw BotFailure.unsupported }
            switch params["key"]?.text {
            case "model": guard value.hasSuffix(" --session") else { throw BotFailure.unsupported }
            case "reasoning": guard BotModelCatalog.effortLevels.contains(value) else { throw BotFailure.unsupported }
            case "fast": guard ["fast", "normal"].contains(value) else { throw BotFailure.unsupported }
            default: throw BotFailure.unsupported
            }
        }
        let owner = generation
        let frame = BotJSON.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string(method), "params": .object(params)
        ])
        let text: String
        if method == "file.attach" {
            text = try await Task.detached { String(decoding: try JSONEncoder().encode(frame), as: UTF8.self) }.value
            guard owner == generation, !Task.isCancelled else { throw BotFailure.stale }
        } else { text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.generation == owner else { return }
                    self.close()
                    self.onDisconnect?(BotFailure.transport)
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
                if method == "file.attach" {
                    // This RPC only stores bytes. A late reply must not enter a
                    // prompt, but cancelling it need not drop the conversation.
                    self.deadlines.removeValue(forKey: id)?.cancel()
                    self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
                } else { self.close() }
            }
        }
    }

    /// Profile writes stay a typed exception to the small RPC allowlist. This
    /// prevents the editor from becoming a generic gateway command surface.
    private static func validateProfileEditorCall(_ method: String, _ params: [String: BotJSON]) throws {
        guard ["profiles.describe", "profiles.configure", "profiles.set_asset"].contains(method) else { return }
        guard params["name"]?.text?.isEmpty == false else { throw BotFailure.unsupported }

        if method == "profiles.describe" {
            guard Set(params.keys) == ["name"] else { throw BotFailure.unsupported }
            return
        }

        if method == "profiles.set_asset" {
            guard Set(params.keys).isSubset(of: ["name", "asset", "data", "clear"]),
                  params["asset"]?.text == "avatar" else { throw BotFailure.unsupported }
            let clear = params["clear"]?.flag == true
            let data = params["data"]?.text
            // Base64 for the server's 2 MB decoded cap, with small data-URL headroom.
            guard clear != (data != nil), data?.isEmpty != true,
                  data == nil || data!.utf8.count <= 3_000_000 else {
                throw BotFailure.unsupported
            }
            return
        }

        let allowed = Set(["name", "description", "soul", "model", "provider", "confirm_expensive_model",
                           "disabled_skills", "enabled_toolsets", "enabled_mcp_servers",
                           "ui_meta", "ui_meta_expected_revisions"])
        guard Set(params.keys).isSubset(of: allowed), params.count > 1 else { throw BotFailure.unsupported }
        if params["description"] != nil, params["description"]?.text == nil { throw BotFailure.unsupported }
        if params["soul"] != nil, params["soul"]?.text == nil { throw BotFailure.unsupported }
        let model = params["model"]?.text
        let provider = params["provider"]?.text
        guard (model == nil) == (provider == nil), model?.isEmpty != true, provider?.isEmpty != true else { throw BotFailure.unsupported }
        if params["confirm_expensive_model"] != nil {
            guard model != nil, params["confirm_expensive_model"]?.flag != nil else { throw BotFailure.unsupported }
        }
        for key in ["disabled_skills", "enabled_toolsets", "enabled_mcp_servers"] where params[key] != nil {
            guard let list = params[key]?.list, list.allSatisfy({ $0.text?.isEmpty == false }) else { throw BotFailure.unsupported }
        }
        if params["ui_meta"] != nil {
            guard let metadata = params["ui_meta"]?.fields, Set(metadata.keys) == ["hermes-bots"],
                  metadata["hermes-bots"]?.fields != nil,
                  let expected = params["ui_meta_expected_revisions"]?.fields,
                  Set(expected.keys) == ["hermes-bots"],
                  let revision = expected["hermes-bots"]?.integer, revision >= 0 else {
                throw BotFailure.unsupported
            }
        } else if params["ui_meta_expected_revisions"] != nil {
            throw BotFailure.unsupported
        }
    }

    private func consume(_ frame: BotJSON) {
        if frame["method"].text == "event" { onEvent?(frame["params"]); return }
        guard let id = frame["id"].integer, let continuation = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        if let code = frame["error"]["code"].integer {
            if settingCalls.contains(id) {
                continuation.resume(throwing: BotSettingFailure.rejected(code, frame["error"]["message"].text ?? BotFailure.rejected(code).localizedDescription))
            } else { continuation.resume(throwing: BotFailure.rejected(code)) }
        }
        else if frame["result"] != .null { continuation.resume(returning: frame["result"]) }
        else { continuation.resume(throwing: BotFailure.unsupported) }
    }

    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        guard context.connectionID == connection.id, socket != nil else { throw BotFailure.stale }
        let owner = generation
        let url = try BotEndpoint.artifactURL(base: connection.address, path: path, context: context)
        let id = UUID()
        let task = Task { try await BotEndpoint.downloadArtifact(session: session, url: url) }
        artifactTasks[id] = task
        defer { artifactTasks[id] = nil }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            guard owner == generation, !Task.isCancelled else { throw BotFailure.stale }
            return data
        } onCancel: { task.cancel() }
    }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        guard context.connectionID == connection.id, socket != nil else { throw BotFailure.stale }
        let owner = generation
        let id = UUID()
        let task = Task { try await BotAttachmentUpload.image(session: session, base: connection.address,
                                                            data: data, filename: filename, profile: context.profile) }
        imageUploads[id] = task
        defer { imageUploads[id] = nil }
        return try await withTaskCancellationHandler {
            let path = try await task.value
            guard owner == generation, !Task.isCancelled else { throw BotFailure.stale }
            return path
        } onCancel: { task.cancel() }
    }

    func close() {
        generation += 1
        for task in imageUploads.values { task.cancel() }
        imageUploads.removeAll()
        for task in artifactTasks.values { task.cancel() }
        artifactTasks.removeAll()
        reader?.cancel(); reader = nil
        socket?.cancel(); socket = nil
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let interrupted = pending.values
        pending.removeAll()
        for continuation in interrupted { continuation.resume(throwing: BotFailure.transport) }
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
