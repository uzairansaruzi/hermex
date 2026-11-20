import Foundation

typealias FileWorkspaceSearch = @MainActor (String) async throws -> [ComposerFilePathSearch.Match]

enum WorkspaceSearchState: Equatable {
    case searching
    case found([ComposerFilePathSearch.Match])
    case unavailable
}

@MainActor
@Observable
final class FileBrowserViewModel {
    @ObservationIgnored private var files: (any WorkspaceFileClient)?
    private let defaults: UserDefaults
    @ObservationIgnored private var expansionStore: FileTreeExpansionStore?

    private(set) var tree = FileTree()
    private(set) var expandedPaths: Set<String> = []
    private(set) var loadingPaths: [String: Int] = [:]
    private(set) var failedPaths: [String: String] = [:]
    private(set) var selectedPath: String?
    private(set) var isLoadingRoot = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    private var hasLoadedInitialRoot = false
    private var hasRestoredExpansion = false
    private var loadGenerations: [String: Int] = [:]
    private var prefetches: [String: Task<FileResponse, Error>] = [:]

    private var workspaceSearch: (scope: String, query: String, state: WorkspaceSearchState)?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private let searchDebounce: @MainActor () async throws -> Void

    init(files: (any WorkspaceFileClient)?, defaults: UserDefaults = .standard,
         searchDebounce: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.files = files
        self.defaults = defaults
        self.searchDebounce = searchDebounce
        expansionStore = files.map { FileTreeExpansionStore(scope: $0.scope, defaults: defaults) }
    }

    func visibleNodes(matching searchQuery: String) -> [VisibleFileTreeNode] {
        tree.visibleNodes(expanded: expandedPaths, searchQuery: searchQuery)
    }

    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func isLoading(_ path: String) -> Bool {
        loadingPaths[path] != nil
    }

    func loadFailure(for path: String) -> String? {
        failedPaths[path]
    }

    func childCount(of path: String) -> Int? {
        tree.children(of: path)?.count
    }

    func takeLastError() -> Error? {
        defer { lastError = nil }
        return lastError
    }

    func loadInitialRootIfNeeded() async {
        guard !hasLoadedInitialRoot else { return }
        hasLoadedInitialRoot = true
        await loadRoot(reloadingOpenDirectories: false)
    }

    func refresh() async {
        await loadRoot(reloadingOpenDirectories: true)
    }

    func retryRoot() async {
        await loadRoot(reloadingOpenDirectories: false)
    }

    func switchWorkspace(to files: (any WorkspaceFileClient)?) async {
        guard files?.scope != self.files?.scope else { return }
        self.files = files
        expansionStore = files.map { FileTreeExpansionStore(scope: $0.scope, defaults: defaults) }
        cancelPrefetches()
        for path in loadGenerations.keys { _ = bumpGeneration(for: path) }
        tree = FileTree()
        expandedPaths = []
        loadingPaths = [:]
        failedPaths = [:]
        selectedPath = nil
        errorMessage = nil
        lastError = nil
        isLoadingRoot = false
        hasRestoredExpansion = false
        hasLoadedInitialRoot = true
        await loadRoot(reloadingOpenDirectories: false)
    }

    func toggleDirectory(_ path: String) async {
        if expandedPaths.contains(path), failedPaths[path] == nil {
            setExpanded(expandedPaths.subtracting([path]))
            return
        }

        setExpanded(expandedPaths.union([path]))
        if !tree.isLoaded(path) || failedPaths[path] != nil {
            await loadDirectory(path)
        }
    }

    func select(path: String) async {
        selectedPath = path
        let ancestors = FileTree.ancestorPaths(of: path)
        if !ancestors.allSatisfy(expandedPaths.contains) {
            setExpanded(expandedPaths.union(ancestors))
        }
        for ancestor in ancestors where !tree.isLoaded(ancestor) {
            await loadDirectory(ancestor)
        }
    }

    private func loadRoot(reloadingOpenDirectories: Bool) async {
        guard let files else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        let generation = bumpGeneration(for: FileTree.rootPath)
        isLoadingRoot = true
        errorMessage = nil
        lastError = nil

        do {
            let response = try await files.directoryList(path: FileTree.rootPath)
            guard generation == loadGenerations[FileTree.rootPath] else { return }
            commitListing(response.entries ?? [], of: FileTree.rootPath)
            if !hasRestoredExpansion {
                hasRestoredExpansion = true
                expandedPaths = expansionStore?.load()
                    ?? (files.opensTopLevelFolders ? FileTree.defaultExpandedPaths(in: tree.rootNodes) : [])
            }
            isLoadingRoot = false
            await loadOpenDescendants(of: FileTree.rootPath, reloadingLoaded: reloadingOpenDirectories)
        } catch {
            guard generation == loadGenerations[FileTree.rootPath] else { return }
            if let failure = error as? WorkspaceFolderReadFailure {
                if failure.isMissing { dropTree() }
                errorMessage = failure.localizedDescription
            } else if !Self.isCancellationError(error) {
                lastError = error
                errorMessage = error.localizedDescription
            } else if !tree.isRootLoaded {
                hasLoadedInitialRoot = false
            }
            isLoadingRoot = false
        }
    }

    private func loadOpenDescendants(of directory: String, reloadingLoaded: Bool) async {
        guard let nodes = tree.children(of: directory) else { return }
        let open = nodes.filter { $0.isDirectory && expandedPaths.contains($0.path) }
        guard !open.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for node in open {
                group.addTask { @MainActor in
                    if reloadingLoaded || !self.tree.isLoaded(node.path) {
                        await self.loadDirectory(node.path)
                    }
                    await self.loadOpenDescendants(of: node.path, reloadingLoaded: reloadingLoaded)
                }
            }
        }
    }

    private func loadDirectory(_ path: String) async {
        guard let files else { return }

        let generation = bumpGeneration(for: path)
        loadingPaths[path] = generation
        failedPaths[path] = nil
        lastError = nil
        defer {
            if loadingPaths[path] == generation {
                loadingPaths[path] = nil
            }
        }

        do {
            let response = try await files.directoryList(path: path)
            guard generation == loadGenerations[path] else { return }
            if tree.node(at: path)?.isDirectory == true {
                commitListing(response.entries ?? [], of: path)
            }
        } catch {
            guard generation == loadGenerations[path] else { return }
            if error is WorkspaceFolderReadFailure {
                failedPaths[path] = error.localizedDescription
            } else if !Self.isCancellationError(error) {
                lastError = error
                failedPaths[path] = error.localizedDescription
            }
        }
    }

    private func commitListing(_ entries: [WorkspaceEntry], of directory: String) {
        let previousFolders = Set((tree.children(of: directory) ?? []).filter(\.isDirectory).map(\.path))
        let previousKeys = Set(tree.children.keys)
        tree.setChildren(entries, of: directory)
        let currentFolders = Set((tree.children(of: directory) ?? []).filter(\.isDirectory).map(\.path))
        let stale = previousFolders.subtracting(currentFolders).union(previousKeys.subtracting(tree.children.keys))
        for path in stale {
            _ = bumpGeneration(for: path)
        }
    }

    private func dropTree() {
        for path in loadGenerations.keys where path != FileTree.rootPath { _ = bumpGeneration(for: path) }
        cancelPrefetches()
        tree = FileTree()
        loadingPaths = [:]
        failedPaths = [:]
    }

    private func bumpGeneration(for path: String) -> Int {
        let next = (loadGenerations[path] ?? 0) + 1
        loadGenerations[path] = next
        return next
    }

    private func setExpanded(_ paths: Set<String>) {
        expandedPaths = paths
        expansionStore?.save(paths)
    }

    func searchWorkspace(_ query: String, in scope: String?, using search: FileWorkspaceSearch?) async {
        searchGeneration &+= 1
        let generation = searchGeneration
        workspaceSearch = nil
        let query = query.trimmingCharacters(in: .whitespaces)
        guard let scope, let search, BotFilePathSearch.searchesEveryFolder(query) else { return }

        let state: WorkspaceSearchState
        do {
            try await searchDebounce()
            state = .found(try await search(query).filter { !$0.isDirectory })
        } catch {
            state = .unavailable
        }
        guard generation == searchGeneration, !Task.isCancelled else { return }
        workspaceSearch = (scope, query, state)
    }

    func workspaceSearchState(for query: String, in scope: String?, hiding shown: [VisibleFileTreeNode]) -> WorkspaceSearchState? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard scope != nil, BotFilePathSearch.searchesEveryFolder(query) else { return nil }
        guard let workspaceSearch, workspaceSearch.scope == scope, workspaceSearch.query == query else { return .searching }
        guard case .found(let matches) = workspaceSearch.state else { return workspaceSearch.state }
        let shownPaths = Set(shown.map(\.node.path))
        return .found(matches.filter { !shownPaths.contains($0.path) })
    }

    func openWorkspaceHit(_ match: ComposerFilePathSearch.Match) -> FileTreeNode? {
        cancelPrefetches()
        return FileTreeNode(entry: WorkspaceEntry(name: match.name, path: match.path, type: "file", isDirectory: false),
                            parentPath: match.parentPath.isEmpty ? FileTree.rootPath : match.parentPath)
    }

    func prefetchFile(at path: String) {
        guard prefetches[path] == nil,
              let files,
              FilePreviewViewModel.loadsTextPreview(forPath: path) else { return }

        cancelPrefetches()
        prefetches[path] = Task {
            try await files.file(path: path)
        }
    }

    func takePrefetch(for path: String) -> Task<FileResponse, Error>? {
        let task = prefetches.removeValue(forKey: path)
        cancelPrefetches()
        return task
    }

    func prefetchedFile(at path: String) -> Task<FileResponse, Error>? {
        prefetches[path]
    }

    func cancelPrefetches() {
        prefetches.values.forEach { $0.cancel() }
        prefetches.removeAll()
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }
}

struct FileTreeExpansionStore {
    private let defaults: UserDefaults
    private let key: String

    init(scope: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "fileTree.expanded|\(scope)"
    }

    func load() -> Set<String>? {
        guard let paths = defaults.stringArray(forKey: key) else { return nil }
        return Set(paths)
    }

    func save(_ paths: Set<String>) {
        defaults.set(Array(paths).sorted(), forKey: key)
    }
}
