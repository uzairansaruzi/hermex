import Foundation

/// A Hermes chat's working folder (#1112): the folder `session.info` says its runtime works in,
/// and the terminal backend it runs commands on, for the session `storedKey` names under
/// `profile`. Files, transcript file links and MEDIA references read it; the composer's `@`
/// panel (#1113) and Git (#1114) read the same context.
struct HermesWorkspaceContext: Hashable, Sendable {
    let server: URL
    let profile: String
    let storedKey: String
    /// The host path of the folder. Never shown, logged or persisted.
    let cwd: String
    /// `local`, `docker`, `ssh`, …; nil while the host has not said.
    let terminalBackend: String?

    /// Only a `local` backend's folder is on the host the dashboard reads; any other backend's
    /// is in a container or on another machine, so its files are not browsable.
    var isLocal: Bool { terminalBackend == "local" }
}

/// A Hermes chat's workspace files (#1112), through the host's `/api/fs/*` routes on the sign-in
/// its Bot screens share. Those routes read any host path a signed-in client names, so the fence
/// here is the client's own rule, not a security boundary: a workspace-relative path becomes
/// `cwd + "/" + path` only when it is relative and climbs nowhere (`hostPath`), and a child's
/// path is its folder's plus its name, never the listing's `path`, which the host resolves
/// (`/private/var/…` for `/var/…`) and so can leave the folder the chat asked for. Downloads send
/// the relative path with the Profile and stored key, so the host anchors them to the session's
/// own folder. Rows, previews and errors carry only relative paths. Checked at the
/// `HERMES_AGENT_TESTED_SHA` pin (ca678285) in `hermes_cli/web_routers/files.py`.
@MainActor final class HermesWorkspaceFileClient: WorkspaceFileClient {
    let context: HermesWorkspaceContext
    nonisolated let scope: String
    private let http: HermesConnection

    init(context: HermesWorkspaceContext, http: HermesConnection) {
        self.context = context
        self.http = http
        scope = "\(context.server.absoluteString)|hermes|\(context.profile)|\(context.storedKey)|\(context.cwd)"
    }

    /// One folder, not recursive, folders first as the host sorts them. The host hides build,
    /// VCS and credential entries, and lists a symlinked folder as a file. A folder it can't read
    /// answers 200 `{entries: [], error}`, which throws `WorkspaceFolderReadFailure`.
    func directoryList(path: String) async throws -> DirectoryListResponse {
        let reply = try Self.json(try await send(.fsList(path: try Self.hostPath(path, in: context.cwd))))
        if let code = reply["error"].text, !code.isEmpty { throw WorkspaceFolderReadFailure(code: code) }
        guard let rows = reply["entries"].list else { throw APIError.decoding(underlying: BotFailure.unsupported) }
        let entries = rows.compactMap { row -> WorkspaceEntry? in
            guard let name = row["name"].text, Self.isName(name) else { return nil }
            let isDirectory = row["isDirectory"].flag == true
            return WorkspaceEntry(name: name, path: path == FileTree.rootPath ? name : path + "/" + name,
                                  type: isDirectory ? "dir" : "file", isDirectory: isDirectory)
        }
        return DirectoryListResponse(entries: entries, path: path, workspace: nil, error: nil)
    }

    /// The file's first 512 KiB as text, or none for a binary file. The host decodes it with
    /// replacement characters, so it is only ever a preview: export downloads the file. A
    /// truncated file has no line count. A symlinked folder, which the listing shows as a file,
    /// throws `BotArtifactFailure.folder` here and from every download.
    func file(path: String) async throws -> FileResponse {
        let name = path.split(separator: "/").last.map(String.init)
        let body: Data
        do {
            body = try await send(.fsReadText(path: try Self.hostPath(path, in: context.cwd)))
        } catch let refusal as HermesCronRefusal where refusal.detail == "Path points to a directory" {
            throw BotArtifactFailure.folder
        }
        let reply = try Self.json(body)
        let isBinary = reply["binary"].flag == true
        let isTruncated = reply["truncated"].flag == true
        let text = isBinary ? nil : reply["text"].text
        return FileResponse(
            content: text, path: path, name: name,
            language: reply["language"].text, size: reply["byteSize"].integer,
            lines: isTruncated ? nil : text.map { $0.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } },
            error: nil, isBinary: isBinary, isTruncated: isTruncated, isPreviewOnly: true
        )
    }

    /// The whole file, for Save to Files and Share: no size cap, as on webui, and an empty file
    /// is the file.
    func rawFileData(path: String) async throws -> Data {
        _ = try Self.hostPath(path, in: context.cwd)
        return try await download(path, limit: nil, allowsEmpty: true)
    }

    /// At most 25 MB (`BotArtifactBuffer`), for Quick Look.
    func rawFilePreviewData(path: String) async throws -> Data {
        _ = try Self.hostPath(path, in: context.cwd)
        return try await download(path)
    }

    /// An image preview keeps the 25 MB cap of every Hermes preview download.
    func imagePreviewData(path: String) async throws -> Data {
        try await rawFilePreviewData(path: path)
    }

    /// A MEDIA path is the reply's own, often outside the folder, so it is sent as written; the
    /// host resolves it against the session and decides what it serves. At most 25 MB, for the
    /// MEDIA viewer's preview.
    func mediaData(path: String) async throws -> Data {
        try await download(path)
    }

    /// `mediaData` for Save and Share: the whole file, as `rawFileData` reads one.
    func mediaExportData(path: String) async throws -> Data {
        try await download(path, limit: nil, allowsEmpty: true)
    }

    /// The host path of `path`, a workspace-relative path: the folder itself for
    /// `FileTree.rootPath`, else `cwd + "/" + path`. Refuses an absolute path, a `..` component
    /// and a path with nothing past the root, before any request.
    nonisolated static func hostPath(_ path: String, in cwd: String) throws -> String {
        let root = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if path == FileTree.rootPath { return root }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0"), !parts.contains(".."),
              parts.contains(where: { !$0.isEmpty && $0 != "." }) else { throw BotArtifactFailure.invalidReference }
        return (root == "/" ? "" : root) + "/" + path
    }

    private func download(_ path: String, limit: Int? = BotArtifactBuffer.maximumBytes,
                          allowsEmpty: Bool = false) async throws -> Data {
        let request = try HermesREST.downloadArtifact(path: path, profile: context.profile, sessionID: context.storedKey)
            .request(base: http.connection.address)
        return try await http.authorized(request) { request, session in
            try await BotArtifactDownload.data(session: session, request: request, limit: limit, allowsEmpty: allowsEmpty)
        }
    }

    /// One request's body, or the failure its status means (`HermesCronClient.accepted`). A reason
    /// that names a path, as an `OSError`'s can, reads as the generic failure instead, so no host
    /// path reaches the screen. A dropped request reads as the webui's network failure.
    private func send(_ rest: HermesREST) async throws -> Data {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest) } catch let error as URLError { throw APIError.network(underlying: error) }
        do { return try HermesCronClient.accepted(reply) } catch let refusal as HermesCronRefusal {
            throw refusal.detail.contains(where: { $0 == "/" || $0 == "\\" }) ? BotArtifactFailure.unavailable : refusal
        }
    }

    /// One file or folder name, so a path joined from names never leaves its folder.
    private static func isName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains { $0 == "/" || $0 == "\\" || $0 == "\0" }
    }

    private static func json(_ body: Data) throws -> BotJSON {
        do { return try JSONDecoder().decode(BotJSON.self, from: body) } catch { throw APIError.decoding(underlying: error) }
    }
}
