import Foundation

struct HermesWorkspaceContext: Hashable, Sendable {
    let server: URL
    let profile: String
    let storedKey: String
    let cwd: String
    let terminalBackend: String?

    var isLocal: Bool { terminalBackend == "local" }
}

@MainActor final class HermesWorkspaceFileClient: WorkspaceFileClient {
    let context: HermesWorkspaceContext
    nonisolated let scope: String
    nonisolated let opensTopLevelFolders = false
    private let http: HermesConnection
    private let previewLimit: Int

    init(context: HermesWorkspaceContext, http: HermesConnection, previewLimit: Int = BotArtifactBuffer.maximumBytes) {
        self.context = context
        self.http = http
        self.previewLimit = previewLimit
        scope = "\(context.server.absoluteString)|hermes|\(context.profile)|\(context.storedKey)|\(context.cwd)"
    }

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
            lines: isTruncated ? nil : text.map(Self.lineCount),
            error: nil, isBinary: isBinary, isTruncated: isTruncated, isPreviewOnly: true
        )
    }

    func rawFileData(path: String) async throws -> Data {
        try await download(try Self.hostPath(path, in: context.cwd), inSession: false, limit: nil, allowsEmpty: true)
    }

    func rawFilePreviewData(path: String) async throws -> Data {
        try await download(try Self.hostPath(path, in: context.cwd), inSession: false, limit: previewLimit)
    }

    func imagePreviewData(path: String) async throws -> Data {
        try await rawFilePreviewData(path: path)
    }

    func mediaData(path: String) async throws -> Data {
        try await download(path, inSession: true, limit: previewLimit)
    }

    func mediaExportData(path: String) async throws -> Data {
        try await download(path, inSession: true, limit: nil, allowsEmpty: true)
    }

    nonisolated static func hostPath(_ path: String, in cwd: String) throws -> String {
        let root = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if let last = (path == FileTree.rootPath ? root : path).unicodeScalars.last,
           last.properties.isWhitespace || (0x1C...0x1F).contains(last.value) {
            throw BotArtifactFailure.unavailable
        }
        if path == FileTree.rootPath { return root }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0"), !parts.contains(".."),
              parts.contains(where: { !$0.isEmpty && $0 != "." }) else { throw BotArtifactFailure.invalidReference }
        return (root == "/" ? "" : root) + "/" + path
    }

    private func download(_ path: String, inSession: Bool, limit: Int?, allowsEmpty: Bool = false) async throws -> Data {
        let request = try HermesREST.downloadArtifact(path: path, profile: context.profile,
                                                      sessionID: inSession ? context.storedKey : nil)
            .request(base: http.connection.address)
        return try await http.authorized(request) { request, session in
            try await BotArtifactDownload.data(session: session, request: request, limit: limit, allowsEmpty: allowsEmpty)
        }
    }

    private func send(_ rest: HermesREST) async throws -> Data {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest) } catch let error as URLError { throw APIError.network(underlying: error) }
        do { return try HermesCronClient.accepted(reply) } catch let refusal as HermesCronRefusal {
            throw refusal.detail.contains(where: { $0 == "/" || $0 == "\\" }) ? BotArtifactFailure.unavailable : refusal
        }
    }

    nonisolated static func lineCount(_ text: String) -> Int {
        let newlines = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return text.isEmpty || text.utf8.last == 0x0A ? newlines : newlines + 1
    }

    private static func isName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains { $0 == "/" || $0 == "\\" || $0 == "\0" }
    }

    private static func json(_ body: Data) throws -> BotJSON {
        do { return try JSONDecoder().decode(BotJSON.self, from: body) } catch { throw APIError.decoding(underlying: error) }
    }
}
