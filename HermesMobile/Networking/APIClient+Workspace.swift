import Foundation

protocol WorkspaceFileClient: Sendable {
    var scope: String { get }
    var opensTopLevelFolders: Bool { get }
    func directoryList(path: String) async throws -> DirectoryListResponse
    func file(path: String) async throws -> FileResponse
    func rawFileData(path: String) async throws -> Data
    func rawFilePreviewData(path: String) async throws -> Data
    func imagePreviewData(path: String) async throws -> Data
    func mediaData(path: String) async throws -> Data
    func mediaExportData(path: String) async throws -> Data
}

struct WorkspaceFolderReadFailure: LocalizedError, Equatable {
    let code: String

    var isMissing: Bool { code == "ENOENT" || code == "ENOTDIR" }

    var errorDescription: String? {
        if isMissing { return String(localized: "This folder is no longer on the server.") }
        if code == "EACCES" { return String(localized: "The server refused the request. Check the server permissions and try again.") }
        return String(localized: "The server rejected the request: \(code)")
    }
}

struct WebUIWorkspaceFileClient: WorkspaceFileClient {
    let apiClient: APIClient
    let sessionID: String
    let scope: String
    let opensTopLevelFolders = true

    init?(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        guard let sessionID = session.sessionId else { return nil }
        self.init(sessionID: sessionID, workspace: session.workspace, server: server, apiClient: apiClient)
    }

    init(sessionID: String, workspace: String?, server: URL, apiClient: APIClient? = nil) {
        self.apiClient = apiClient ?? APIClient(baseURL: server)
        self.sessionID = sessionID
        scope = "\(server.absoluteString)|\(workspace ?? "")"
    }

    func directoryList(path: String) async throws -> DirectoryListResponse {
        try await apiClient.directoryList(sessionID: sessionID, path: path)
    }

    func file(path: String) async throws -> FileResponse {
        try await apiClient.file(sessionID: sessionID, path: path)
    }

    func rawFileData(path: String) async throws -> Data {
        try await apiClient.rawFileData(sessionID: sessionID, path: path)
    }

    func rawFilePreviewData(path: String) async throws -> Data {
        try await apiClient.rawFilePreviewData(sessionID: sessionID, path: path)
    }

    func imagePreviewData(path: String) async throws -> Data {
        try await apiClient.rawFileData(sessionID: sessionID, path: path)
    }

    func mediaData(path: String) async throws -> Data {
        try await apiClient.mediaData(sessionID: sessionID, path: path)
    }

    func mediaExportData(path: String) async throws -> Data {
        try await apiClient.mediaData(sessionID: sessionID, path: path)
    }
}

extension APIClient {
    func workspaces() async throws -> WorkspacesResponse {
        try await send(endpoint: .workspaces, method: "GET")
    }

    func workspaceSuggestions(prefix: String) async throws -> WorkspaceSuggestionsResponse {
        try await send(endpoint: .workspaceSuggestions(prefix: prefix), method: "GET")
    }

    func addWorkspace(path: String, name: String? = nil, create: Bool? = nil) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceAdd,
            method: "POST",
            body: AddWorkspaceRequest(path: path, name: name, create: create)
        )
    }

    func removeWorkspace(path: String) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceRemove,
            method: "POST",
            body: RemoveWorkspaceRequest(path: path)
        )
    }

    func renameWorkspace(path: String, name: String) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceRename,
            method: "POST",
            body: RenameWorkspaceRequest(path: path, name: name)
        )
    }

    func reorderWorkspaces(paths: [String]) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceReorder,
            method: "POST",
            body: ReorderWorkspacesRequest(paths: paths)
        )
    }

    func directoryList(sessionID: String, path: String? = nil) async throws -> DirectoryListResponse {
        try await send(
            endpoint: .directoryList(sessionID: sessionID, path: path),
            method: "GET"
        )
    }

    func file(sessionID: String, path: String) async throws -> FileResponse {
        try await send(endpoint: .file(sessionID: sessionID, path: path), method: "GET")
    }

    func rawFileData(sessionID: String, path: String) async throws -> Data {
        try await sendData(endpoint: .rawFile(sessionID: sessionID, path: path), method: "GET")
    }

    func rawFilePreviewData(sessionID: String, path: String) async throws -> Data {
        try await sendBoundedData(
            endpoint: .rawFile(sessionID: sessionID, path: path),
            limit: BotArtifactBuffer.maximumBytes
        )
    }

    func mediaData(sessionID: String, path: String) async throws -> Data {
        try await sendData(endpoint: .media(sessionID: sessionID, path: path), method: "GET")
    }

    func remoteTranscriptMediaData(from url: URL) async throws -> Data {
        if Self.isSameOrigin(url, as: baseURL) {
            return try await downloadData(from: url, using: session, mapsUnauthorized: true)
        }

        return try await downloadData(from: url, using: publicMediaSession, mapsUnauthorized: false)
    }
}

