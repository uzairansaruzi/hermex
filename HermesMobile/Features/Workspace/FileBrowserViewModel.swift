import Foundation

/// A host's file-name search over a whole workspace (#1389), for a query the loaded tree can't
/// answer: a Hermes chat's `complete.path`. Files without one filters only what it has listed.
typealias FileWorkspaceSearch = @MainActor (String) async throws -> [ComposerFilePathSearch.Match]

/// What Files' Workspace section shows for one query (#1389).
enum WorkspaceSearchState: Equatable {
    /// The query's answer has not landed: static "Searching…" text.
    case searching
    /// Files the loaded tree does not already show, possibly none.
    case found([ComposerFilePathSearch.Match])
    /// The search failed: inline "Try Again", and the tree still filters.
    case unavailable
}

/// Owns the workspace file tree for one chat: lists directories through its
/// `WorkspaceFileClient` as the user opens them, remembers which folders are open per
/// workspace (`WorkspaceFileClient.scope`), and warms file previews on press-down so the next
/// screen has its content ready. A nil client is a chat without a session to read from.
@MainActor
@Observable
final class FileBrowserViewModel {
    @ObservationIgnored private var files: (any WorkspaceFileClient)?
    private let defaults: UserDefaults
    @ObservationIgnored private var expansionStore: FileTreeExpansionStore?

    private(set) var tree = FileTree()
    private(set) var expandedPaths: Set<String> = []
    /// Directory path → generation of the listing that owns its spinner.
    private(set) var loadingPaths: [String: Int] = [:]
    /// Directory path → message for listings that failed; tapping the row retries.
    private(set) var failedPaths: [String: String] = [:]
    private(set) var selectedPath: String?
    private(set) var isLoadingRoot = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    private var hasLoadedInitialRoot = false
    private var hasRestoredExpansion = false
    /// Per-directory generation counters so a stale listing never overwrites a newer one.
    private var loadGenerations: [String: Int] = [:]
    /// At most one prefetch is in flight: a newer press-down replaces the previous one, and
    /// opening a file takes its task out so the next visit fetches fresh content.
    private var prefetches: [String: Task<FileResponse, Error>] = [:]

    /// The latest settled workspace search, stamped with the workspace and query it answered.
    private var workspaceSearch: (scope: String, query: String, state: WorkspaceSearchState)?
    /// Bumped per search so a reply that lands after a newer query never publishes.
    @ObservationIgnored private var searchGeneration = 0
    /// Waits out typing before a search asks the host; tests pass one that returns at once.
    @ObservationIgnored private let searchDebounce: @MainActor () async throws -> Void

    init(files: (any WorkspaceFileClient)?, defaults: UserDefaults = .standard,
         searchDebounce: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.files = files
        self.defaults = defaults
        self.searchDebounce = searchDebounce
        expansionStore = files.map { FileTreeExpansionStore(scope: $0.scope, defaults: defaults) }
    }

    // MARK: - Reading

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

    /// Nil until the directory has been listed.
    func childCount(of path: String) -> Int? {
        tree.children(of: path)?.count
    }

    /// Hands the most recent failure to the caller once, so a recovered folder or a plain
    /// collapse never re-reports an error that already surfaced.
    func takeLastError() -> Error? {
        defer { lastError = nil }
        return lastError
    }

    // MARK: - Loading

    func loadInitialRootIfNeeded() async {
        guard !hasLoadedInitialRoot else { return }
        hasLoadedInitialRoot = true
        await loadRoot(reloadingOpenDirectories: false)
    }

    /// Pull-to-refresh: re-lists the root and every open directory, keeping expansion.
    func refresh() async {
        await loadRoot(reloadingOpenDirectories: true)
    }

    func retryRoot() async {
        await loadRoot(reloadingOpenDirectories: false)
    }

    /// Moves the tree to another workspace, as when a Hermes chat's folder changes (#1112):
    /// drops every listing, the expansion, the selection and the prefetches, makes every
    /// listing in flight stale, then lists the new root with that workspace's own expansion.
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

    /// Opens or closes a directory. Opening lists it on first use; tapping a failed listing retries.
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

    /// Marks a file as the current one and opens every folder above it, listing any that
    /// have not been fetched yet, so the row is on screen when the tree is shown again.
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
                // The server's answer about the folder, not a failed request: no error is
                // reported, and a folder that is gone shows its missing state, not old rows.
                if failure.isMissing { dropTree() }
                errorMessage = failure.localizedDescription
            } else if !Self.isCancellationError(error) {
                lastError = error
                errorMessage = error.localizedDescription
            }
            isLoadingRoot = false
        }
    }

    /// Lists every expanded directory under `directory` whose parents are also open, in
    /// parallel, then recurses into them. Unloaded directories are fetched; loaded ones only
    /// when `reloadingLoaded` is set.
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
        // Clear the spinner on every exit, but only if a newer listing has not taken it over.
        defer {
            if loadingPaths[path] == generation {
                loadingPaths[path] = nil
            }
        }

        do {
            let response = try await files.directoryList(path: path)
            guard generation == loadGenerations[path] else { return }
            // A root refresh that finished meanwhile may have dropped this directory; an
            // orphaned listing would be shown as current if the folder ever came back.
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

    /// Stores a listing and invalidates in-flight requests for every folder the listing
    /// dropped (and any cached listing beneath it), so a folder that is removed and recreated
    /// cannot resurface a response that was requested before it disappeared.
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

    /// Forgets every listing and the prefetches, and makes every listing in flight stale,
    /// including a folder's first, which has no cached children yet.
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

    // MARK: - Workspace search (#1389)

    /// Asks `search` for the files matching `query` across the workspace `scope` names, once the
    /// typing settles. Files runs it per query and workspace and cancels it for the next, so only
    /// the latest search ever publishes. A short or path-shaped query, or no search at all,
    /// clears the answer: the loaded tree alone filters it, as before.
    func searchWorkspace(_ query: String, in scope: String?, using search: FileWorkspaceSearch?) async {
        searchGeneration &+= 1
        let generation = searchGeneration
        workspaceSearch = nil
        let query = query.trimmingCharacters(in: .whitespaces)
        guard let scope, let search, BotFilePathSearch.searchesEveryFolder(query) else { return }

        let state: WorkspaceSearchState
        do {
            try await searchDebounce()
            // Folders aren't shown: opening one would list every folder above it.
            state = .found(try await search(query).filter { !$0.isDirectory })
        } catch {
            state = .unavailable
        }
        guard generation == searchGeneration, !Task.isCancelled else { return }
        workspaceSearch = (scope, query, state)
    }

    /// The Workspace section for `query` in `scope`: nil when it doesn't search, `.searching`
    /// until this query's own answer lands, then the files it found minus those `shown`, the
    /// loaded tree's matches, already lists. An answer for another workspace never shows.
    func workspaceSearchState(for query: String, in scope: String?, hiding shown: [VisibleFileTreeNode]) -> WorkspaceSearchState? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard scope != nil, BotFilePathSearch.searchesEveryFolder(query) else { return nil }
        guard let workspaceSearch, workspaceSearch.scope == scope, workspaceSearch.query == query else { return .searching }
        guard case .found(let matches) = workspaceSearch.state else { return workspaceSearch.state }
        let shownPaths = Set(shown.map(\.node.path))
        return .found(matches.filter { !shownPaths.contains($0.path) })
    }

    /// Opens a Workspace hit as a file node without selecting it: selecting lists and expands
    /// every folder above it, and a Hermes folder lists only when it is tapped (#1233). Every
    /// prefetch stops, since none was for this file.
    func openWorkspaceHit(_ match: ComposerFilePathSearch.Match) -> FileTreeNode? {
        cancelPrefetches()
        return FileTreeNode(entry: WorkspaceEntry(name: match.name, path: match.path, type: "file", isDirectory: false),
                            parentPath: match.parentPath.isEmpty ? FileTree.rootPath : match.parentPath)
    }

    // MARK: - Prefetch

    /// Starts fetching a text file's content while the finger is still down on its row.
    func prefetchFile(at path: String) {
        guard prefetches[path] == nil,
              let files,
              FilePreviewViewModel.loadsTextPreview(forPath: path) else { return }

        cancelPrefetches()
        prefetches[path] = Task {
            try await files.file(path: path)
        }
    }

    /// Called when a file opens: hands over that file's prefetch, if any, and cancels every
    /// other one. The task leaves the table so reopening the file fetches it again.
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

/// Remembers which folders are open, keyed by the client's `scope` so one server's or one
/// chat's layout never shows up under another: server and workspace on webui; server, Profile,
/// session and folder on Hermes. A missing record means "use the default expansion".
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
