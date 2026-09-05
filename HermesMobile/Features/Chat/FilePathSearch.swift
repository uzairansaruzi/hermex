import Foundation

/// The workspace files and folders the composer's `@` panel offers for one query.
///
/// The query is a path being typed, so exactly one folder has to be listed: the
/// one the query names. `src/Ch` lists `src` and ranks its entries against `Ch`;
/// `Ch` ranks the workspace root's own entries. Nothing recurses, so a large
/// workspace costs the same as a small one.
///
/// Listings are cached for the composer's lifetime, so walking back up a path
/// the user is retyping costs no requests at all. The cache is dropped when the
/// session changes, because a path is only meaningful inside the workspace it
/// came from.
@MainActor
@Observable
final class ComposerFilePathSearch {
    /// One row: the path that gets inserted, plus what the row draws.
    struct Match: Identifiable, Equatable {
        var id: String { path }
        /// Workspace-relative, exactly as the server spelled it.
        let path: String
        let name: String
        /// The folder the entry sits in, empty at the workspace root.
        let parentPath: String
        let isDirectory: Bool

        init(node: FileTreeNode) {
            path = node.path
            name = node.name
            let parent = FileTree.parentPath(of: node.path)
            parentPath = parent == FileTree.rootPath ? "" : parent
            isDirectory = node.isDirectory
        }
    }

    private(set) var matches: [Match] = []
    private(set) var isLoading = false

    /// Directory path → its entries. A composer is short-lived next to a
    /// workspace, and the worst a stale row can do is send the viewer after a
    /// file the server no longer has, which the viewer already reports.
    private var listings: [String: [FileTreeNode]] = [:]
    private var loadedSessionID: String?
    /// Bumped per query so a listing that lands after a newer query never
    /// overwrites the rows on screen.
    private var generation = 0
    /// Bumped whenever the cache stops meaning what it meant: another session,
    /// or a workspace switch. A listing still in flight belongs to the scope it
    /// was asked in, so it must neither be cached under the new one nor counted
    /// as an answer about it.
    private var cacheGeneration = 0

    /// Most rows one panel offers. Past this the panel is a scroll rather than
    /// a choice, and the ranking already put the best rows on top.
    private static let matchLimit = 20

    /// Lists the folder `query` names and ranks it against the query's last
    /// segment. A failed listing reads as "nothing matched": the panel is a
    /// shortcut, and an error box over the keyboard would be in the way of the
    /// user simply typing the path.
    func search(_ query: String, sessionID: String, apiClient: APIClient) async {
        dropCacheIfSessionChanged(sessionID)

        generation &+= 1
        let generation = self.generation
        let request = Request(query: query)

        if listings[request.directory] == nil {
            isLoading = true
            matches = []
        }

        do {
            let nodes = try await entries(
                in: request.directory,
                sessionID: sessionID,
                apiClient: apiClient
            )
            guard generation == self.generation else { return }
            isLoading = false
            matches = Self.ranked(nodes, against: request.segment)
        } catch {
            guard generation == self.generation else { return }
            isLoading = false
            matches = []
        }
    }

    /// The entries of one workspace folder, listed at most once.
    ///
    /// The panel and the view model's `@path` confirmation share this cache, so
    /// re-opening the panel over a directory a restored draft already had
    /// checked costs nothing. Never recurses, and a folder that climbs out of
    /// the workspace is answered empty without asking the server.
    ///
    /// Throws `CancellationError` when the session or workspace moved while the
    /// listing was in flight. That is deliberately the same shape as a failed
    /// request: the folder is *unanswered*, so its candidates stay open for the
    /// next pass rather than being settled against a root they never described.
    func entries(in directory: String, sessionID: String, apiClient: APIClient) async throws -> [FileTreeNode] {
        dropCacheIfSessionChanged(sessionID)

        guard !Self.climbsOutOfWorkspace(directory) else { return [] }
        if let cached = listings[directory] { return cached }

        let cacheGeneration = self.cacheGeneration
        let response = try await apiClient.directoryList(sessionID: sessionID, path: directory)
        guard cacheGeneration == self.cacheGeneration else { throw CancellationError() }

        let nodes = Self.nodes(from: response.entries ?? [], in: directory)
        listings[directory] = nodes
        return nodes
    }

    /// Forgets every listing.
    ///
    /// The session's workspace can be switched underneath a chat (`/workspace`,
    /// or the composer's workspace picker) without the session id changing, and
    /// a folder listed against the old root says nothing about the new one. The
    /// view model calls this the moment the workspace moves.
    func reset() {
        // A listing already in flight belongs to the old workspace; bumping both
        // generations is what stops it reaching the new one's rows and the new
        // one's cache.
        generation &+= 1
        cacheGeneration &+= 1
        listings.removeAll()
        loadedSessionID = nil
        matches = []
        isLoading = false
    }

    /// A path only means anything inside the session it came from.
    private func dropCacheIfSessionChanged(_ sessionID: String) {
        guard sessionID != loadedSessionID else { return }
        cacheGeneration &+= 1
        listings.removeAll()
        loadedSessionID = sessionID
    }

    /// The folder a query names and the segment it is filtering that folder by.
    private struct Request {
        let directory: String
        let segment: String

        init(query: String) {
            guard let slash = query.lastIndex(of: "/") else {
                directory = FileTree.rootPath
                segment = query
                return
            }
            let prefix = String(query[query.startIndex..<slash])
            directory = prefix.isEmpty ? FileTree.rootPath : prefix
            segment = String(query[query.index(after: slash)...])
        }
    }

    /// Drops anything a reference cannot name: an entry the server marked as a
    /// symlink pointing outside the workspace, any path with a `..` component,
    /// and any path containing whitespace.
    ///
    /// The whitespace rule is the reference syntax's, not the filesystem's. The
    /// only form verified against upstream is `@` plus the plain path followed
    /// by a space, which means the space inside `My File.swift` ends the
    /// reference: the path would insert and then never read back as one. Better
    /// not to offer it than to offer something that quietly does not work.
    private static func nodes(from entries: [WorkspaceEntry], in directory: String) -> [FileTreeNode] {
        entries
            .filter { $0.targetOutsideWorkspace != true }
            .compactMap { FileTreeNode(entry: $0, parentPath: directory) }
            .filter { !climbsOutOfWorkspace($0.path) && !$0.path.contains(where: \.isWhitespace) }
    }

    private static func climbsOutOfWorkspace(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// An empty segment is the whole folder in tree order. A typed segment is
    /// ranked by `FileTreeSearch`, which is the same scorer the workspace search
    /// field uses, so the same typing finds the same file in both places.
    private static func ranked(_ nodes: [FileTreeNode], against segment: String) -> [Match] {
        guard !segment.isEmpty else {
            return FileTree.sorted(nodes).prefix(matchLimit).map { Match(node: $0) }
        }

        let query = segment.lowercased()
        let scored = nodes.compactMap { node -> (node: FileTreeNode, score: Int)? in
            guard let score = FileTreeSearch.score(
                value: node.name.lowercased(),
                query: query,
                fuzzy: true
            ) else {
                return nil
            }
            return (node, score)
        }

        return scored
            .sorted { left, right in
                if left.score != right.score { return left.score < right.score }
                if left.node.isDirectory != right.node.isDirectory { return left.node.isDirectory }
                return left.node.name.localizedStandardCompare(right.node.name) == .orderedAscending
            }
            .prefix(matchLimit)
            .map { Match(node: $0.node) }
    }
}
