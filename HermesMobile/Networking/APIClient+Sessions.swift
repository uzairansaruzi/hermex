import Foundation

extension APIClient {
    /// Parameterless overload kept so `InsightsDataClient` (and any other
    /// protocol witness) still sees the exact `sessions()` signature — a method
    /// with defaulted parameters cannot satisfy that requirement.
    func sessions() async throws -> SessionsResponse {
        try await sessions(includeArchived: false, archivedLimit: nil)
    }

    /// Fetches the session list. `includeArchived` opts in to archived rows
    /// (merged with the visible ones; each row carries an `archived` flag) and
    /// `archivedLimit` optionally caps how many archived rows the server appends
    /// (issue #17). Defaults keep today's request untouched.
    func sessions(includeArchived: Bool = false, archivedLimit: Int? = nil) async throws -> SessionsResponse {
        try await send(
            endpoint: .sessions(includeArchived: includeArchived, archivedLimit: archivedLimit),
            method: "GET"
        )
    }

    func searchSessions(query: String, content: Bool = true, depth: Int = 5) async throws -> SessionSearchResponse {
        try await send(
            endpoint: .sessionsSearch(query: query, content: content, depth: depth),
            method: "GET"
        )
    }

    func session(
        id: String,
        includeMessages: Bool = true,
        messageLimit: Int? = 50,
        messageBefore: Int? = nil,
        expandRenderable: Bool = false
    ) async throws -> SessionResponse {
        try await send(
            endpoint: .session(
                id: id,
                includeMessages: includeMessages,
                messageLimit: messageLimit,
                messageBefore: messageBefore,
                expandRenderable: expandRenderable
            ),
            method: "GET"
        )
    }

    func sessionStatus(id: String) async throws -> SessionStatusResponse {
        try await send(endpoint: .sessionStatus(id: id), method: "GET")
    }

    func createSession(workspace: String?, model: String?, modelProvider: String?, profile: String?) async throws -> SessionResponse {
        try await send(
            endpoint: .newSession,
            method: "POST",
            body: NewSessionRequest(
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile
            )
        )
    }

    func renameSession(id: String, title: String) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .renameSession,
            method: "POST",
            body: RenameSessionRequest(sessionId: id, title: title)
        )
    }

    func deleteSession(id: String) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .deleteSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func pinSession(id: String, pinned: Bool) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .pinSession,
            method: "POST",
            body: PinSessionRequest(sessionId: id, pinned: pinned)
        )
    }

    func archiveSession(id: String, archived: Bool) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .archiveSession,
            method: "POST",
            body: ArchiveSessionRequest(sessionId: id, archived: archived)
        )
    }

    func branchSession(id: String, keepCount: Int? = nil, title: String? = nil) async throws -> SessionBranchResponse {
        try await send(
            endpoint: .branchSession,
            method: "POST",
            body: BranchSessionRequest(sessionId: id, keepCount: keepCount, title: title)
        )
    }

    func compressSession(id: String, focusTopic: String? = nil) async throws -> SessionCompressResponse {
        try await send(
            endpoint: .compressSession,
            method: "POST",
            body: CompressSessionRequest(sessionId: id, focusTopic: focusTopic)
        )
    }

    func undoSession(id: String) async throws -> SessionUndoResponse {
        try await send(
            endpoint: .undoSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func retrySession(id: String) async throws -> SessionRetryResponse {
        try await send(
            endpoint: .retrySession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func truncateSession(id: String, keepCount: Int) async throws -> SessionResponse {
        try await send(
            endpoint: .truncateSession,
            method: "POST",
            body: TruncateSessionRequest(sessionId: id, keepCount: keepCount)
        )
    }

    func updateSession(
        id: String,
        workspace: String?,
        model: String?,
        modelProvider: String?
    ) async throws -> SessionResponse {
        try await send(
            endpoint: .updateSession,
            method: "POST",
            body: UpdateSessionRequest(
                sessionId: id,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider
            )
        )
    }

    func moveSession(id: String, projectID: String?) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .moveSession,
            method: "POST",
            body: MoveSessionRequest(sessionId: id, projectId: projectID)
        )
    }

    func sessionYolo(sessionID: String) async throws -> SessionYoloResponse {
        try await send(endpoint: .sessionYolo(sessionID: sessionID), method: "GET")
    }

    func setSessionYolo(sessionID: String, enabled: Bool) async throws -> SessionYoloResponse {
        try await send(
            endpoint: .sessionYolo(sessionID: nil),
            method: "POST",
            body: SessionYoloRequest(sessionId: sessionID, enabled: enabled)
        )
    }
}

private struct NewSessionRequest: Encodable {
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
}

private struct RenameSessionRequest: Encodable {
    let sessionId: String
    let title: String
}

private struct SessionIDRequest: Encodable {
    let sessionId: String
}

private struct PinSessionRequest: Encodable {
    let sessionId: String
    let pinned: Bool
}

private struct ArchiveSessionRequest: Encodable {
    let sessionId: String
    let archived: Bool
}

private struct BranchSessionRequest: Encodable {
    let sessionId: String
    let keepCount: Int?
    let title: String?
}

private struct CompressSessionRequest: Encodable {
    let sessionId: String
    let focusTopic: String?
}

private struct TruncateSessionRequest: Encodable {
    let sessionId: String
    let keepCount: Int
}

private struct UpdateSessionRequest: Encodable {
    let sessionId: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
}

private struct MoveSessionRequest: Encodable {
    let sessionId: String
    let projectId: String?
}

private struct SessionYoloRequest: Encodable {
    let sessionId: String
    let enabled: Bool
}

