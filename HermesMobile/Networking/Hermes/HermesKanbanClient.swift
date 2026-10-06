import Foundation

/// Kanban on a Hermes host (#1043): the host's Kanban plugin under `/api/plugins/kanban`, read
/// over the sign-in, cookie jar and headers (#898) the server's Bot screens share. It reads
/// configuration, Boards, a Board, stats, assignee history, Card detail and the worker log,
/// and adapts each reply to the Kanban models webui fills:
/// - host paths and process data (`workspace_path`, `stored_path`, a log's `path`, `db_path`,
///   `default_workdir`, `worker_pid`, `claim_lock`) are dropped before decoding, so no view or
///   log can show them;
/// - every reply reads `read_only: true`, which keeps every write disabled until #1044, and
///   the writes keep `KanbanDataClient`'s throwing defaults;
/// - the Assigned Profile filter runs here, because the host's `/board` takes none.
///
/// A 404 on `/config` is a host without the Kanban plugin. Live updates come over the Board's
/// Kanban socket (`KanbanWebSocketEventClient`, #1045). The host has no REST events route, so
/// `kanbanEvents` throws; the feature state's polling fallback reloads the Board instead, and
/// a `since` request reads as unchanged while the Board's `latest_event_id` still equals it.
struct HermesKanbanClient: KanbanDataClient {
    let http: HermesConnection

    var backend: KanbanBackend { .hermes }

    @MainActor func makeEventStream(server: URL) -> any KanbanEventStreamingClient {
        KanbanWebSocketEventClient(http: http)
    }

    func kanbanConfiguration() async throws -> KanbanConfiguration {
        do {
            return try await read(.kanbanConfig)
        } catch BotFailure.rejected(404) {
            throw KanbanCapabilityError.kanbanUnavailable
        }
    }

    func kanbanBoards() async throws -> KanbanBoardsResponse {
        try await read(.kanbanBoards)
    }

    func kanbanBoard(_ request: KanbanBoardRequest) async throws -> KanbanBoardSnapshot {
        let snapshot: KanbanBoardSnapshot = try await read(.kanbanBoard(
            board: request.board,
            tenant: request.tenant,
            includeArchived: request.includeArchived
        ))
        // The host's `/board` takes no `since`, so the reply's `latest_event_id` answers it the
        // way webui's `changed` does: a poll or a foreground check keeps an unchanged Board.
        let changed = request.since.map { $0 != snapshot.latestEventID } ?? snapshot.changed
        let assignee = request.assignee.flatMap { $0.isEmpty ? nil : $0 }
        guard assignee != nil || changed != snapshot.changed else { return snapshot }
        return KanbanBoardSnapshot(
            columns: assignee.map { assignee in
                snapshot.columns?.map { column in
                    KanbanColumn(name: column.name, cards: column.cards?.filter { $0.assignee == assignee })
                }
            } ?? snapshot.columns,
            tenants: snapshot.tenants,
            assignees: snapshot.assignees,
            filters: snapshot.filters,
            changed: changed,
            latestEventID: snapshot.latestEventID,
            readOnly: snapshot.readOnly
        )
    }

    func kanbanStats(board: String) async throws -> KanbanStats {
        try await read(.kanbanStats(board: board))
    }

    func kanbanAssignees(board: String) async throws -> KanbanAssigneeHistory {
        try await read(.kanbanAssignees(board: board))
    }

    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope {
        throw BotFailure.unsupported
    }

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        try await read(.kanbanTask(id: request.cardID, board: request.board))
    }

    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog {
        try await read(.kanbanTaskLog(
            id: request.cardID,
            board: request.board,
            tailBytes: min(max(1, request.tailBytes), 2_000_000)
        ))
    }

    private func read<Response: Decodable>(_ rest: HermesREST) async throws -> Response {
        let data = try Self.adapted(try await http.data(rest))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }

    /// Keys whose values are host paths or process data, dropped at every depth.
    static let hostOnlyKeys: Set<String> = [
        "workspace_path", "stored_path", "path", "db_path", "default_workdir", "worker_pid", "claim_lock"
    ]

    /// A reply without `hostOnlyKeys`, marked `read_only`. `JSONSerialization` keeps the
    /// host's integers integers on the way back out. A body that is not a JSON object is an
    /// incompatible reply.
    static func adapted(_ data: Data) throws -> Data {
        guard var reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw KanbanResponseError.nonJSONContentType
        }
        reply = reply.filter { !hostOnlyKeys.contains($0.key) }.mapValues(withoutHostOnlyKeys)
        reply["read_only"] = true
        return try JSONSerialization.data(withJSONObject: reply)
    }

    private static func withoutHostOnlyKeys(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { !hostOnlyKeys.contains($0.key) }.mapValues(withoutHostOnlyKeys)
        case let array as [Any]:
            return array.map(withoutHostOnlyKeys)
        default:
            return value
        }
    }
}

/// A socket `KanbanWebSocketEventClient` reads: the gateway's socket boundary and a WebSocket
/// ping. Production wraps `URLSessionWebSocketTask` (`NativeBotSocket`); tests script one.
protocol KanbanSocket: BotSocket {
    /// Sends one ping frame and returns when its pong arrives. A refused upgrade throws what
    /// `receive()` throws for it.
    func ping() async throws
}

extension NativeBotSocket: KanbanSocket {
    func ping() async throws {
        let task = task
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, let refusal = BotFailure(upgradeStatus: status) {
                throw refusal
            }
            throw error
        }
    }
}

/// Live Kanban events from a Hermes host (#1045): one WebSocket per open Board,
/// `/api/plugins/kanban/events?board=&since=&ticket=` on the Board's `HermesConnection`. Every
/// connect mints a fresh single-use ticket there, never the gateway's, so the upgrade carries
/// the connection's headers to its own origin only. It offers no subprotocol.
///
/// The host sends `{events, cursor}` only when events land: no hello and no heartbeat, and a
/// dashboard bound to loopback (how a tunneled one runs) sends no protocol pings either, so a
/// tunnel such as Cloudflare would close a quiet socket at about 100 s. This client pings every
/// 25 s, and a ping that has seen neither its pong nor a frame by the next one ends the socket.
/// The first pong or frame proves the upgrade and reports `.opened`. A 403 on the upgrade, the
/// host's answer to a used or expired ticket, opens once more on a fresh ticket before the
/// failure is reported. `stop()` closes the socket cleanly, and nothing from it is reported after.
@MainActor final class KanbanWebSocketEventClient: KanbanEventStreamingClient {
    /// Tests script the socket and the clock; production takes the defaults.
    struct Options {
        /// The ping cadence, and how long a ping may go without its pong or a frame.
        var keepalive: Duration = .seconds(25)
        var sleep: @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// Gets the finished upgrade; nil opens a native socket on the connection's session.
        var socketFactory: ((URLRequest) -> any KanbanSocket)?
    }

    private let http: HermesConnection
    private let options: Options
    private var onFrame: (@MainActor (KanbanStreamFrame) -> Void)?
    private var onFailure: (@MainActor () -> Void)?
    /// The Board and cursor of the current `start`, for the one fresh-ticket retry.
    private var target: (board: String, since: Int)?
    private var mayRetryRefusal = false
    /// Numbers sockets. Anything from an older one, or from before `stop()`, is dropped.
    private var generation = 0
    private var socket: (any KanbanSocket)?
    private var opener: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var isOpen = false
    /// A ping went out and neither its pong nor a frame has arrived since.
    private var awaitingPong = false

    init(http: HermesConnection, options: Options = Options()) {
        self.http = http
        self.options = options
    }

    func start(
        board: String,
        since: Int,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        stop()
        self.onFrame = onFrame
        self.onFailure = onFailure
        target = (board, since)
        mayRetryRefusal = true
        connect()
    }

    func stop() {
        close()
        onFrame = nil
        onFailure = nil
        target = nil
    }

    /// Mints a ticket and opens a socket on it.
    private func connect() {
        guard let target else { return }
        let owner = generation, http = http
        opener = Task { [weak self] in
            do {
                let upgrade = try await http.kanbanEventsUpgrade(board: target.board, since: target.since)
                self?.open(upgrade, generation: owner)
            } catch {
                self?.fail(error, generation: owner)
            }
        }
    }

    private func open(_ upgrade: URLRequest, generation owner: Int) {
        guard owner == generation else { return }
        let socket: any KanbanSocket
        if let socketFactory = options.socketFactory { socket = socketFactory(upgrade) } else {
            let task = http.session.webSocketTask(with: upgrade)
            task.maximumMessageSize = 16 * 1024 * 1024
            task.resume()
            socket = NativeBotSocket(task: task, label: label(owner))
        }
        self.socket = socket
        reader = Task { [weak self] in
            do {
                while true {
                    let message = try await socket.receive()
                    guard let self, self.generation == owner else { return }
                    self.consume(message)
                }
            } catch {
                self?.fail(error, generation: owner)
            }
        }
        let sleep = options.sleep, interval = options.keepalive
        keepalive = Task { [weak self] in
            while true {
                do { try await sleep(interval) } catch { return }
                guard let self, self.generation == owner else { return }
                guard !self.awaitingPong else {
                    let name = self.label(owner), seconds = interval.components.seconds
                    HermesConnectionLog.logger.error("\(name, privacy: .public): no pong or frame in \(seconds, privacy: .public) s; closing")
                    self.fail(BotFailure.transport, generation: owner)
                    return
                }
                self.ping(socket, generation: owner)
            }
        }
        ping(socket, generation: owner)
    }

    private func ping(_ socket: any KanbanSocket, generation owner: Int) {
        awaitingPong = true
        // Not kept: closing the socket fails a ping still waiting for its pong.
        Task { [weak self] in
            do { try await socket.ping() } catch {
                self?.fail(error, generation: owner)
                return
            }
            guard let self, self.generation == owner else { return }
            self.markAlive()
        }
    }

    private func consume(_ message: URLSessionWebSocketTask.Message) {
        markAlive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        onFrame?(KanbanStreamFrameDecoder.decodeSocketFrame(data))
    }

    /// A pong or a frame: the socket is alive, and the first one reports it open.
    private func markAlive() {
        awaitingPong = false
        guard !isOpen else { return }
        isOpen = true
        mayRetryRefusal = false
        HermesConnectionLog.logger.notice("\(self.label(self.generation), privacy: .public) open")
        onFrame?(.opened)
    }

    private func fail(_ error: Error, generation owner: Int) {
        guard owner == generation else { return }
        let retry = mayRetryRefusal && error as? BotFailure == .upgradeRefused(403)
        let name = label(owner), wasOpen = isOpen, reason = HermesConnectionLog.reason(error)
        close()
        if retry {
            mayRetryRefusal = false
            connect()
            return
        }
        if wasOpen {
            HermesConnectionLog.logger.error("\(name, privacy: .public) dropped: \(reason, privacy: .public)")
        } else {
            HermesConnectionLog.logger.error("\(name, privacy: .public) failed to open: \(reason, privacy: .public)")
        }
        let onFailure = self.onFailure
        stop()
        guard let onFailure else { return }
        // Reported from a task of its own: the one failing here may be the reader or the
        // keepalive, which `close()` has just cancelled. A later start or stop drops it.
        let reported = generation
        Task { [weak self] in
            guard self?.generation == reported else { return }
            onFailure()
        }
    }

    /// Closes the socket and ends its tasks; the callbacks stay for a retry.
    private func close() {
        generation += 1
        opener?.cancel(); opener = nil
        reader?.cancel(); reader = nil
        keepalive?.cancel(); keepalive = nil
        socket?.cancel(); socket = nil
        isOpen = false
        awaitingPong = false
    }

    /// Names socket `number` in the log, such as `c1 kanban socket s0`, never the Board or host.
    private func label(_ number: Int) -> String { "c\(http.serial) kanban socket s\(number)" }
}
