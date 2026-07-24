import Foundation

@Observable
final class FileBrowserViewModel {
    private let session: SessionSummary
    private let apiClient: APIClient

    private(set) var entries: [WorkspaceEntry] = []
    private(set) var currentPath = "."
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private var hasLoadedInitialPath = false
    private var lastRequestedPath = "."
    private var loadRevision = 0

    var isAtRoot: Bool {
        currentPath == "."
    }

    var displayPath: String {
        isAtRoot ? String(localized: "Root") : currentPath
    }

    var parentPath: String? {
        guard !isAtRoot else { return nil }

        let parts = currentPath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "." }

        return parts.dropLast().joined(separator: "/")
    }

    var breadcrumbs: [FileBreadcrumb] {
        guard currentPath != "." else {
            return [FileBreadcrumb(title: String(localized: "Root"), path: ".")]
        }

        let parts = currentPath.split(separator: "/").map(String.init)
        var breadcrumbs = [FileBreadcrumb(title: String(localized: "Root"), path: ".")]

        for index in parts.indices {
            let title = parts[index]
            let path = parts[...index].joined(separator: "/")
            breadcrumbs.append(FileBreadcrumb(title: title, path: path))
        }

        return breadcrumbs
    }

    init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.session = session
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    @MainActor
    func loadInitialRootIfNeeded() async {
        guard !hasLoadedInitialPath else { return }
        hasLoadedInitialPath = true
        await loadRoot()
    }

    @MainActor
    func loadRoot() async {
        await load(path: ".")
    }

    @MainActor
    func reloadCurrentPath() async {
        await load(path: currentPath)
    }

    @MainActor
    func retryLastLoad() async {
        await load(path: lastRequestedPath)
    }

    @MainActor
    func load(path: String) async {
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        lastRequestedPath = path
        loadRevision += 1
        let revision = loadRevision
        isLoading = true
        errorMessage = nil
        lastError = nil

        do {
            let response = try await apiClient.directoryList(sessionID: sessionID, path: path)
            guard revision == loadRevision else { return }
            currentPath = response.path ?? path
            entries = response.entries ?? []
        } catch {
            guard revision == loadRevision else { return }
            if !Self.isCancellationError(error) {
                lastError = error
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
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

struct FileBreadcrumb: Identifiable, Equatable {
    var id: String { path }

    let title: String
    let path: String
}
