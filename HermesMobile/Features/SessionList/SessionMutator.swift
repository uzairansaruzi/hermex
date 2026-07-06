import Foundation

struct SessionDuplicateResult {
    let session: SessionSummary?
    let errorMessage: String?
}

/// The server refuses `/api/session/move` with a 503 while the session is
/// streaming (it holds the per-session agent lock). Surface that as a specific,
/// actionable message instead of the generic "server unavailable" copy (issue #25).
struct SessionMoveWhileStreamingError: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "This session is still responding, so it can't be moved yet. Try again when it finishes.")
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
        } catch let error as APIError {
            // Only a 503 carrying the server's JSON error payload is the documented
            // "session is busy (streaming)" refusal; a proxy/tunnel 503 has no JSON
            // body and keeps the generic connectivity message.
            guard case .http(let statusCode, _) = error,
                  statusCode == 503,
                  error.serverMessage != nil
            else { throw error }

            throw SessionMoveWhileStreamingError()
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
