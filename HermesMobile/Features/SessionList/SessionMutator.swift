import Foundation

struct SessionDuplicateResult {
    let session: SessionSummary?
    let errorMessage: String?
}

struct SessionMoveWhileStreamingError: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "This session is still responding, so it can't be moved yet. Try again when it finishes.")
    }
}

struct SessionArchiveRefusal: LocalizedError, Equatable {
    let archived: Bool
    let serverMessage: String?

    var errorDescription: String? {
        if let serverMessage {
            return serverMessage
        }
        return archived
            ? String(localized: "The server could not archive this session.")
            : String(localized: "The server could not unarchive this session.")
    }
}

struct SessionMutator {
    let client: APIClient

    func setPinned(_ pinned: Bool, sessionID: String) async throws {
        _ = try await client.pinSession(id: sessionID, pinned: pinned)
    }

    func archive(sessionID: String) async throws {
        try await setArchived(true, sessionID: sessionID)
    }

    func unarchive(sessionID: String) async throws {
        try await setArchived(false, sessionID: sessionID)
    }

    private func setArchived(_ archived: Bool, sessionID: String) async throws {
        let response = try await client.archiveSession(id: sessionID, archived: archived)
        let serverMessage = response.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let serverMessage, !serverMessage.isEmpty {
            throw SessionArchiveRefusal(archived: archived, serverMessage: serverMessage)
        }
        if response.ok == false {
            throw SessionArchiveRefusal(archived: archived, serverMessage: nil)
        }
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
            guard case .http(let statusCode, _) = error,
                  statusCode == 503,
                  error.serverMessage != nil
            else { throw error }

            throw SessionMoveWhileStreamingError()
        }
    }

    func duplicate(sessionID: String) async throws -> SessionDuplicateResult {
        let response = try await client.duplicateSession(id: sessionID)

        guard let duplicatedSessionDetail = response.session else {
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
