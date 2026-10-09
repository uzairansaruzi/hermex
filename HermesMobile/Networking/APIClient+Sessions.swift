import Foundation

extension APIClient {
    /// Parameterless overload kept so `InsightsDataClient` (and any other
    /// protocol witness) still sees the exact `sessions()` signature — a method
    /// with defaulted parameters cannot satisfy that requirement.
    func sessions() async throws -> SessionsResponse {
        try await sessions(includeArchived: false, archivedLimit: nil, allProfiles: false)
    }

    /// Fetches the session list. `includeArchived` opts in to archived rows
    /// (merged with the visible ones; each row carries an `archived` flag) and
    /// `archivedLimit` optionally caps how many archived rows the server appends
    /// (issue #17). `allProfiles` sends `all_profiles=1`. Defaults keep today's
    /// request untouched.
    func sessions(
        includeArchived: Bool = false,
        archivedLimit: Int? = nil,
        allProfiles: Bool = false
    ) async throws -> SessionsResponse {
        try await send(
            endpoint: .sessions(
                includeArchived: includeArchived,
                archivedLimit: archivedLimit,
                allProfiles: allProfiles
            ),
            method: "GET"
        )
    }

    /// The sidebar list. Upstream scopes `GET /api/sessions` to the active
    /// profile unless `all_profiles=1`, and may report how many rows that hid in
    /// `other_profile_count`. When the scoped page has nothing the phone can
    /// show, ask once for every profile — unless the server explicitly counted
    /// zero hidden rows. A missing count is not that signal: the field is
    /// optional, and treating it as zero left Default on "No sessions yet"
    /// while other profiles held the conversations.
    ///
    /// Hermes desktop stores those conversations in the agent database, and
    /// webui omits them until `show_cli_sessions` is on (it defaults off). An
    /// empty page with that gate closed is why the phone and the watch both
    /// said "No sessions yet" while Hermes itself had the chats. When
    /// `revealAgentSessions` is set — the phone's own "show CLI sessions"
    /// preference, which defaults on — open the gate, refetch, and close it
    /// again only if the refetch is still empty. The phone list and the watch
    /// both call this, so the two surfaces stay on the same fetch.
    func sidebarSessions(
        includeArchived: Bool = false,
        archivedLimit: Int? = nil,
        revealAgentSessions: Bool = true
    ) async throws -> SessionsResponse {
        let scoped = try await sessions(includeArchived: includeArchived, archivedLimit: archivedLimit)
        if scoped.containsSidebarRows(includeArchived: includeArchived) {
            return scoped
        }

        let widened: SessionsResponse
        let allProfiles: Bool
        if scoped.otherProfileCount == 0 {
            widened = scoped
            allProfiles = false
        } else {
            allProfiles = true
            let everyProfile = try await sessions(
                includeArchived: includeArchived,
                archivedLimit: archivedLimit,
                allProfiles: true
            )
            if everyProfile.containsSidebarRows(includeArchived: includeArchived) {
                return everyProfile
            }
            widened = everyProfile
        }

        guard revealAgentSessions else { return widened }
        return try await revealingAgentSessions(
            fallback: widened,
            includeArchived: includeArchived,
            archivedLimit: archivedLimit,
            allProfiles: allProfiles
        )
    }

    /// Opens `show_cli_sessions` when the sidebar is empty because webui is
    /// hiding the agent database. A settings failure leaves the empty page as
    /// it was. A refetch that is still empty puts the gate back, so a server
    /// with no agent history does not keep the flag flipped on.
    private func revealingAgentSessions(
        fallback: SessionsResponse,
        includeArchived: Bool,
        archivedLimit: Int?,
        allProfiles: Bool
    ) async throws -> SessionsResponse {
        let settings: SettingsResponse
        do {
            settings = try await self.settings()
        } catch {
            return fallback
        }
        guard settings.showCliSessions == false else { return fallback }

        do {
            _ = try await updateSettings(showCliSessions: true)
        } catch {
            return fallback
        }

        let refreshed: SessionsResponse
        do {
            refreshed = try await sessions(
                includeArchived: includeArchived,
                archivedLimit: archivedLimit,
                allProfiles: allProfiles
            )
        } catch {
            // The gate was opened above. A failed refetch must put it back,
            // or one sidebar miss leaves show_cli_sessions on for every client.
            _ = try? await updateSettings(showCliSessions: false)
            return fallback
        }
        if refreshed.containsSidebarRows(includeArchived: includeArchived) {
            return refreshed
        }

        _ = try? await updateSettings(showCliSessions: false)
        return refreshed
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

    /// Imports a CLI or messaging session into the WebUI-owned session store.
    /// The returned session is authoritative for whether continuation is safe.
    func importExternalSession(id: String) async throws -> SessionResponse {
        try await send(
            endpoint: .importCLISession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    /// Creates a session. A nil `projectID` leaves `project_id` out of the body, so
    /// the session starts unassigned; the server stores a given id without checking it.
    func createSession(
        workspace: String?,
        model: String?,
        modelProvider: String?,
        profile: String?,
        projectID: String? = nil
    ) async throws -> SessionResponse {
        try await send(
            endpoint: .newSession,
            method: "POST",
            body: NewSessionRequest(
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile,
                projectId: projectID
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

    /// Copies a session. Answers with the whole duplicated session, so no
    /// follow-up fetch is needed. Rejects subagent sessions with a 400 — they
    /// are view-only upstream.
    func duplicateSession(id: String) async throws -> SessionResponse {
        try await send(
            endpoint: .duplicateSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
        )
    }

    func compressSession(id: String, focusTopic: String? = nil) async throws -> SessionCompressResponse {
        try await send(
            endpoint: .compressSession,
            method: "POST",
            body: CompressSessionRequest(sessionId: id, focusTopic: focusTopic)
        )
    }

    /// Truncates the session to empty on the server and resets its title to
    /// Untitled. Destructive and irreversible — only call it behind a
    /// confirmation. Answers the same compact session shape as rename (#389).
    func clearSession(id: String) async throws -> SessionMutationResponse {
        try await send(
            endpoint: .clearSession,
            method: "POST",
            body: SessionIDRequest(sessionId: id)
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
    let projectId: String?
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

private extension SessionsResponse {
    func containsSidebarRows(includeArchived: Bool) -> Bool {
        (sessions ?? []).contains { $0.belongsOnSidebar(includeArchived: includeArchived) }
    }
}
