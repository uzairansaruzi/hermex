import Foundation

/// One Bot screen's use of its connection's shared gateway socket (`HermesGateway`). The
/// inbox, each chat, a room, the creator and the editor hold their own; a chat's controls
/// and delegated work share the chat's. `connect()` attaches to the socket, opening it when
/// no other screen has; `close()` ends only this screen's calls, uploads and downloads,
/// never the socket another screen is using.
@MainActor final class BotClient: BotTransport {
    private let gateway: HermesGateway
    let consumerID: Int
    private var http: HermesConnection { gateway.http }
    /// Bumped by `close()`, `connect()` and a lost socket, so this screen's late HTTP
    /// results are dropped.
    private var attempt = 0
    private var imageUploads: [UUID: Task<String, Error>] = [:]
    private var artifactTasks: [UUID: Task<Data, Error>] = [:]
    var replayEpoch: String? { gateway.replayEpoch }
    /// `version` from the connection's last `/api/status` read, before the auth gate; nil when omitted.
    var serverVersion: String? { http.serverVersion }
    /// `install_id` from the same read; nil when omitted.
    var serverInstallID: String? { http.serverInstallID }
    var unavailableMethods: Set<String> { http.unavailableMethods }
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?

    /// A screen's client on the sign-in and socket `server`'s saved connection shares with
    /// its other Bot screens.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    /// A client with its own cookie jar, sign-in and socket, for credentials that are not
    /// saved yet (connection setup, dev auto-login) and for tests. `heartbeatInterval` is the
    /// `gateway.ping` cadence; `socketFactory` gets the finished gateway upgrade, and nil
    /// opens a native socket.
    convenience init(connection: BotConnection, configuration: URLSessionConfiguration = .ephemeral,
                     rpcDeadline: Duration = .seconds(30), heartbeatInterval: Duration = .seconds(15),
                     socketFactory: ((URLRequest) -> any BotSocket)? = nil) {
        self.init(http: HermesConnection(connection: connection, configuration: configuration, gateway: .init(
            rpcDeadline: rpcDeadline, heartbeatInterval: heartbeatInterval, socketFactory: socketFactory)))
    }

    /// A client on `http`'s shared gateway.
    init(http: HermesConnection) {
        gateway = http.gateway
        consumerID = gateway.makeConsumerID()
    }

    /// Attaches to the gateway socket once its handshake is done, so no RPC can precede it.
    /// A socket another screen has open is joined as it is; otherwise this signs in unless
    /// the connection already is and opens one, or waits for the one already opening.
    func connect() async throws {
        close()
        let attempt = self.attempt
        do { try await gateway.join(self) }
        catch { throw attempt == self.attempt ? error : BotFailure.stale }
        guard attempt == self.attempt else { throw BotFailure.stale }
        guard !Task.isCancelled else { close(); throw BotFailure.stale }
    }

    /// Admits and sends one typed request. `HermesCall.params()` refuses a value the
    /// host must never receive; `validateDispatch` runs at the actual socket write.
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)? = nil) async throws -> BotJSON {
        try await gateway.send(call, for: consumerID, validateDispatch: validateDispatch)
    }

    func artifactData(path: String, context: BotArtifactContext) async throws -> Data {
        guard context.connectionID == http.connection.id, gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let request = try HermesREST.downloadArtifact(path: path, profile: context.profile, sessionID: context.sessionID)
            .request(base: http.connection.address)
        let id = UUID()
        let http = self.http
        let task = Task {
            try await http.authorized(request, validateDispatch: { try self.checkOwner(attempt) }) { request, session in
                try await BotArtifactDownload.data(session: session, request: request)
            }
        }
        artifactTasks[id] = task
        defer { artifactTasks[id] = nil }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try checkOwner(attempt)
            return data
        } onCancel: { task.cancel() }
    }

    func deleteProfile(_ name: String) async throws {
        guard gateway.isAttached(consumerID), BotProfileName.isValid(name) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.deleteProfile(name: name), validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        guard (try? JSONDecoder().decode(BotJSON.self, from: data))?["ok"].flag == true else { throw BotFailure.unsupported }
    }

    func currentProfile() async throws -> String {
        guard gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let data = try await http.data(.profilesActive, validateDispatch: { try self.checkOwner(attempt) })
        try checkOwner(attempt)
        // Usually `default`, which `BotProfileName` reserves for creation, so only emptiness is refused.
        guard let profile = (try? JSONDecoder().decode(BotJSON.self, from: data))?["current"].text,
              !profile.isEmpty else { throw BotFailure.unsupported }
        return profile
    }

    func uploadImage(data: Data, filename: String, context: BotArtifactContext) async throws -> String {
        guard context.connectionID == http.connection.id, gateway.isAttached(consumerID) else { throw BotFailure.stale }
        let attempt = self.attempt
        let id = UUID()
        let http = self.http
        let task = Task {
            try await BotAttachmentUpload.image(data: data, filename: filename, profile: context.profile, via: http,
                                                validateDispatch: { try self.checkOwner(attempt) })
        }
        imageUploads[id] = task
        defer { imageUploads[id] = nil }
        return try await withTaskCancellationHandler {
            let path = try await task.value
            try checkOwner(attempt)
            return path
        } onCancel: { task.cancel() }
    }

    /// Throws `.stale` once `close()`, a reconnect or a lost socket has ended `attempt`.
    /// The HTTP calls check it on their result and, through `validateDispatch`, before
    /// each send: `close()` can land while they wait on the shared sign-in.
    private func checkOwner(_ attempt: Int) throws {
        guard attempt == self.attempt, !Task.isCancelled else { throw BotFailure.stale }
    }

    /// Ends this screen's part: its calls fail with `.transport`, its uploads and downloads
    /// stop, and nothing more reaches `onEvent`. Not a disconnect: `onDisconnect` stays quiet.
    func close() {
        endLocalWork()
        gateway.leave(self)
    }

    /// The gateway's report that this client's connection is gone: its socket was lost or
    /// retired with its connection, or one of its required calls went unanswered past its
    /// deadline. The gateway has already failed its calls.
    func socketEnded(_ error: Error) {
        endLocalWork()
        onDisconnect?(error)
    }

    private func endLocalWork() {
        attempt += 1
        for task in imageUploads.values { task.cancel() }
        imageUploads.removeAll()
        for task in artifactTasks.values { task.cancel() }
        artifactTasks.removeAll()
    }
}
