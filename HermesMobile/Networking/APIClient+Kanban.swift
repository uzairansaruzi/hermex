import Foundation

protocol KanbanDataClient: Sendable {
    func kanbanConfiguration() async throws -> KanbanConfiguration
    func kanbanBoards() async throws -> KanbanBoardsResponse
    func kanbanBoard(_ request: KanbanBoardRequest) async throws -> KanbanBoardSnapshot
    func kanbanStats(board: String) async throws -> KanbanStats
    func kanbanAssignees(board: String) async throws -> KanbanAssigneeHistory
    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope
    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope
    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog
    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse
    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope
    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope
    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async throws -> KanbanCardMutationEnvelope
    func blockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope
    func unblockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope
    func addKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope
    func removeKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope
}

extension KanbanDataClient {
    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        throw KanbanUnsupportedClientMethod.cardDetail
    }

    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog {
        throw KanbanUnsupportedClientMethod.workerLog
    }

    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse {
        throw KanbanUnsupportedClientMethod.addComment
    }

    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.createCard
    }

    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.editCard
    }

    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.cardStatus
    }

    func blockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.blockCard
    }

    func unblockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        throw KanbanUnsupportedClientMethod.unblockCard
    }

    func addKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        throw KanbanUnsupportedClientMethod.addDependency
    }

    func removeKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        throw KanbanUnsupportedClientMethod.removeDependency
    }
}

private enum KanbanUnsupportedClientMethod: Error {
    case cardDetail
    case workerLog
    case addComment
    case createCard
    case editCard
    case cardStatus
    case blockCard
    case unblockCard
    case addDependency
    case removeDependency
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

    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        try await kanbanJSON(endpoint: .kanbanCardDetail(request))
    }

    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog {
        try await kanbanJSON(endpoint: .kanbanWorkerLog(request))
    }

    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse {
        try await kanbanJSON(
            endpoint: .kanbanAddComment(request),
            method: "POST",
            body: KanbanCommentBody(body: request.body)
        )
    }

    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope {
        try await kanbanJSON(
            endpoint: .kanbanCreateCard(request),
            method: "POST",
            body: KanbanCreateCardBody(request: request)
        )
    }

    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope {
        try await kanbanJSON(
            endpoint: .kanbanEditCard(request),
            method: "PATCH",
            body: KanbanEditCardBody(request: request)
        )
    }

    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async throws -> KanbanCardMutationEnvelope {
        guard request.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "running" else {
            throw KanbanRequestError.runningStatusRequiresDispatcher
        }
        return try await kanbanJSON(
            endpoint: .kanbanCardStatus(request),
            method: "PATCH",
            body: KanbanStatusBody(status: request.status)
        )
    }

    func blockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        try await kanbanJSON(
            endpoint: .kanbanBlockCard(request),
            method: "POST",
            body: KanbanActionBody(reason: request.reason)
        )
    }

    func unblockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        try await kanbanJSON(
            endpoint: .kanbanUnblockCard(request),
            method: "POST",
            body: KanbanActionBody(reason: nil)
        )
    }

    func addKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        try await kanbanJSON(
            endpoint: .kanbanAddDependency(request),
            method: "POST",
            body: KanbanDependencyBody(request: request)
        )
    }

    func removeKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        try await kanbanJSON(
            endpoint: .kanbanRemoveDependency(request),
            method: "POST",
            body: KanbanDependencyBody(request: request)
        )
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

    private func kanbanJSON<Response: Decodable, Body: Encodable>(
        endpoint: Endpoint,
        method: String,
        body: Body
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encodedBody = try encoder.encode(body)
        let (data, response) = try await sendDataReturningResponse(
            endpoint: endpoint,
            method: method,
            encodedBody: encodedBody
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            throw KanbanResponseError.nonJSONContentType
        }
        return try decode(Response.self, from: data)
    }
}

private struct KanbanCommentBody: Encodable {
    let body: String
}

enum KanbanRequestError: Error, Equatable {
    case runningStatusRequiresDispatcher
}

private struct KanbanStatusBody: Encodable {
    let status: String
}

private struct KanbanActionBody: Encodable {
    let reason: String?

    enum CodingKeys: CodingKey { case reason }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

private struct KanbanDependencyBody: Encodable {
    let parentID: String
    let childID: String

    init(request: KanbanDependencyMutationRequest) {
        parentID = request.prerequisiteID
        childID = request.dependentID
    }
}

private struct KanbanCreateCardBody: Encodable {
    let title: String
    let body: String?
    let status: String
    let priority: Int?
    let assignee: String?
    let tenant: String?
    let workspaceKind: String
    let workspacePath: String?
    let skills: [String]?
    let maxRuntimeSeconds: Int?
    let parents: [String]?
    let idempotencyKey: String

    init(request: KanbanCreateCardRequest) {
        title = request.title
        body = request.body
        status = request.status
        priority = request.priority
        assignee = request.assignee
        tenant = request.tenant
        workspaceKind = request.workspaceKind
        workspacePath = request.workspacePath
        skills = request.skills
        maxRuntimeSeconds = request.maxRuntimeSeconds
        parents = request.prerequisiteID.map { [$0] }
        idempotencyKey = request.idempotencyKey
    }
}

private struct KanbanEditCardBody: Encodable {
    let request: KanbanEditCardRequest

    enum CodingKeys: String, CodingKey {
        case title, body, tenant, priority, assignee, status
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request.title, forKey: .title)
        try container.encode(request.body, forKey: .body)
        try container.encode(request.priority, forKey: .priority)
        if let tenant = request.tenant {
            try container.encode(tenant, forKey: .tenant)
        } else {
            try container.encodeNil(forKey: .tenant)
        }
        if let assignee = request.assignee {
            try container.encode(assignee, forKey: .assignee)
        } else {
            try container.encodeNil(forKey: .assignee)
        }
        try container.encodeIfPresent(request.status, forKey: .status)
    }
}
