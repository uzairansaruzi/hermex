import Foundation

protocol KanbanDataClient: Sendable {
    func kanbanConfiguration() async throws -> KanbanConfiguration
    func kanbanBoards() async throws -> KanbanBoardsResponse
    func kanbanBoard(board: String) async throws -> KanbanBoardSnapshot
}

extension APIClient: KanbanDataClient {
    func kanbanConfiguration() async throws -> KanbanConfiguration {
        try await kanbanJSON(endpoint: .kanbanConfig)
    }

    func kanbanBoards() async throws -> KanbanBoardsResponse {
        try await kanbanJSON(endpoint: .kanbanBoards)
    }

    func kanbanBoard(board: String) async throws -> KanbanBoardSnapshot {
        try await kanbanJSON(endpoint: .kanbanBoard(board: board))
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
