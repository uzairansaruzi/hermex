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
/// A 404 on `/config` is a host without the Kanban plugin. The host has no event route, so
/// `kanbanEvents` throws and the feature state starts no live updates until #1045.
struct HermesKanbanClient: KanbanDataClient {
    let http: HermesConnection

    var backend: KanbanBackend { .hermes }

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
        guard let assignee = request.assignee, !assignee.isEmpty else { return snapshot }
        return KanbanBoardSnapshot(
            columns: snapshot.columns?.map { column in
                KanbanColumn(name: column.name, cards: column.cards?.filter { $0.assignee == assignee })
            },
            tenants: snapshot.tenants,
            assignees: snapshot.assignees,
            filters: snapshot.filters,
            changed: snapshot.changed,
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
