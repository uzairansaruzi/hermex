import Foundation

struct SessionDuplicateResult {
    let session: SessionSummary?
    let errorMessage: String?
}

enum SessionMoveError: LocalizedError {
    case sessionIsStreaming

    var errorDescription: String? {
        String(localized: "This session is still responding. Wait for it to finish, then move it.")
    }
}

struct SessionMutator {
    let client: APIClient

    func setPinned(_ pinned: Bool, sessionID: String) async throws {
        _ = try await client.pinSession(id: sessionID, pinned: pinned)
    }

    func archive(sessionID: String) async throws {
        _ = try await client.archiveSession(id: sessionID, archived: true)
    }

    func delete(sessionID: String) async throws {
        _ = try await client.deleteSession(id: sessionID)
    }

    func rename(sessionID: String, title: String) async throws -> SessionMutationResponse {
        try await client.renameSession(id: sessionID, title: title)
    }

    func move(sessionID: String, to projectID: String?) async throws {
        do {
            _ = try await client.moveSession(id: sessionID, projectID: projectID)
        } catch APIError.http(let statusCode, _) where statusCode == 503 {
            throw SessionMoveError.sessionIsStreaming
        }
    }

    func duplicate(sessionID: String, title: String) async throws -> SessionDuplicateResult {
        let response = try await client.branchSession(id: sessionID, title: title)

        guard let duplicatedSessionID = response.sessionId else {
            return SessionDuplicateResult(
                session: nil,
                errorMessage: response.error ?? String(localized: "The server did not return the duplicated session ID.")
            )
        }

        let duplicatedResponse = try await client.session(
            id: duplicatedSessionID,
            includeMessages: false,
            messageLimit: nil
        )

        guard let duplicatedSessionDetail = duplicatedResponse.session else {
            return SessionDuplicateResult(
                session: nil,
                errorMessage: String(localized: "The server did not return the duplicated session.")
            )
        }

        return SessionDuplicateResult(
            session: SessionSummary(from: duplicatedSessionDetail),
            errorMessage: nil
        )
    }
}
