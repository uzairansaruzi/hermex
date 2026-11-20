import Foundation

@MainActor
@Observable
final class ComposerFilePathSearch {
    struct Match: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let name: String
        let parentPath: String
        let isDirectory: Bool

        init(path: String, name: String, parentPath: String, isDirectory: Bool) {
            self.path = path
            self.name = name
            self.parentPath = parentPath
            self.isDirectory = isDirectory
        }

        init(node: FileTreeNode) {
            self.init(
                path: node.path,
                name: node.name,
                parentPath: Self.parentPath(of: node.path),
                isDirectory: node.isDirectory
            )
        }

        static func parentPath(of path: String) -> String {
            let parent = FileTree.parentPath(of: path)
            return parent == FileTree.rootPath ? "" : parent
        }
    }

    private(set) var matches: [Match] = []
    private(set) var isLoading = false
    private(set) var scopeRevision = 0

    private var listings: [String: [FileTreeNode]] = [:]
    private var loadedSessionID: String?
    private var generation = 0
    private var cacheGeneration = 0

    private static let matchLimit = 20

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

    func search(_ query: String, load: (String) async throws -> [Match]) async {
        generation &+= 1
        let generation = self.generation
        isLoading = true
        matches = []

        do {
            let rows = try await load(query)
            guard generation == self.generation else { return }
            isLoading = false
            matches = rows
        } catch {
            guard generation == self.generation else { return }
            isLoading = false
            matches = []
        }
    }

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

    func reset(reloadingOpenQuery: Bool = false) {
        generation &+= 1
        cacheGeneration &+= 1
        if reloadingOpenQuery { scopeRevision &+= 1 }
        listings.removeAll()
        loadedSessionID = nil
        matches = []
        isLoading = false
    }

    private func dropCacheIfSessionChanged(_ sessionID: String) {
        guard sessionID != loadedSessionID else { return }
        cacheGeneration &+= 1
        listings.removeAll()
        loadedSessionID = sessionID
    }

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

    private static func nodes(from entries: [WorkspaceEntry], in directory: String) -> [FileTreeNode] {
        entries
            .filter { $0.targetOutsideWorkspace != true }
            .compactMap { FileTreeNode(entry: $0, parentPath: directory) }
            .filter { !climbsOutOfWorkspace($0.path) && !$0.path.contains(where: \.isWhitespace) }
    }

    private static func climbsOutOfWorkspace(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

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
