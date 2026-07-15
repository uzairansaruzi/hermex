import Foundation

protocol KanbanDataClient: Sendable {
    func kanbanConfiguration() async throws -> KanbanConfiguration
    func kanbanBoards() async throws -> KanbanBoardsResponse
    func kanbanBoard(_ request: KanbanBoardRequest) async throws -> KanbanBoardSnapshot
    func kanbanStats(board: String) async throws -> KanbanStats
    func kanbanAssignees(board: String) async throws -> KanbanAssigneeHistory
    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope
}

extension APIClient: KanbanDataClient {
    func kanbanConfiguration() async throws -> KanbanConfiguration {
        try await kanbanJSON(endpoint: .kanbanConfig)
    }

    func kanbanBoards() async throws -> KanbanBoardsResponse {
        try await kanbanJSON(endpoint: .kanbanBoards)
    }

    func kanbanBoard(_ request: KanbanBoardRequest) async throws -> KanbanBoardSnapshot {
        try await kanbanJSON(endpoint: .kanbanBoard(request))
    }

    func kanbanStats(board: String) async throws -> KanbanStats {
        try await kanbanJSON(endpoint: .kanbanStats(board: board))
    }

    func kanbanAssignees(board: String) async throws -> KanbanAssigneeHistory {
        try await kanbanJSON(endpoint: .kanbanAssignees(board: board))
    }

    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope {
        try await kanbanJSON(endpoint: .kanbanEvents(request))
    }

    nonisolated func kanbanEventsStreamURL(_ request: KanbanEventsStreamRequest) -> URL {
        Endpoint.kanbanEventsStream(request).url(relativeTo: baseURL)
    }

    private func kanbanJSON<Response: Decodable>(endpoint: Endpoint) async throws -> Response {
        let (data, response) = try await sendDataReturningResponse(
            endpoint: endpoint,
            method: "GET",
            encodedBody: nil
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            throw KanbanResponseError.nonJSONContentType
        }
        return try decode(Response.self, from: data)
    }
}
