import Foundation

/// The reads one chat's Files browser, file previews and transcript media go through
/// (#1112): webui's session routes (`WebUIWorkspaceFileClient`) or a Hermes host's file
/// routes (`HermesWorkspaceFileClient`). File paths are workspace-relative and `/`-joined,
/// `FileTree.rootPath` for the root, as the file tree keys them; only a conformance turns one
/// into a server path. A MEDIA reference's `path` is the reply's own, not workspace-scoped.
protocol WorkspaceFileClient: Sendable {
    /// The workspace this client reads, for keying the tree's caches: one value per server and
    /// workspace on webui, and per server, Profile, session and folder on Hermes.
    var scope: String { get }
    func directoryList(path: String) async throws -> DirectoryListResponse
    /// A text file's content for its preview.
    func file(path: String) async throws -> FileResponse
    /// A file's whole bytes, for Save to Files and Share.
    func rawFileData(path: String) async throws -> Data
    /// `rawFileData` for Quick Look: at most 25 MB.
    func rawFilePreviewData(path: String) async throws -> Data
    /// An image's bytes for its preview, which its export then reuses: the whole file on webui,
    /// at most 25 MB on a Hermes host.
    func imagePreviewData(path: String) async throws -> Data
    /// A MEDIA reference's bytes, by the local path the reply names: the whole file on webui, at
    /// most 25 MB on a Hermes host.
    func mediaData(path: String) async throws -> Data
    /// A MEDIA reference's whole bytes, for Save and Share once `mediaData` stopped at its cap.
    func mediaExportData(path: String) async throws -> Data
}

/// A folder the server answered for without its entries (#1112): a Hermes host lists a folder it
/// can't read as 200 `{entries: [], error}`, with `ENOENT` or `ENOTDIR` once it is gone, `EACCES`
/// without permission, or the `strerror` of any other failure, none of which names a path.
struct WorkspaceFolderReadFailure: LocalizedError, Equatable {
    let code: String

    var isMissing: Bool { code == "ENOENT" || code == "ENOTDIR" }

    var errorDescription: String? {
        if isMissing { return String(localized: "This folder is no longer on the server.") }
        if code == "EACCES" { return String(localized: "The server refused the request. Check the server permissions and try again.") }
        return String(localized: "The server rejected the request: \(code)")
    }
}

/// A webui session's workspace through its session-scoped routes (`/api/list`, `/api/file`,
/// `/api/file/raw`, `/api/media`), which resolve every path against the session's workspace.
struct WebUIWorkspaceFileClient: WorkspaceFileClient {
    let apiClient: APIClient
    let sessionID: String
    let scope: String

    /// Nil without a session ID, which every route needs.
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

    /// `rawFileData` for Quick Look: stops at 25 MB, and refuses a larger
    /// `Content-Length` before reading the body.
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

