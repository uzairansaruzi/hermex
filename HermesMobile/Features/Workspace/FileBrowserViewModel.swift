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

    init(session: SessionSummary, server: URL) {
        self.session = session
        apiClient = APIClient(baseURL: server)
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
    func load(path: String) async {
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil

        do {
            let response = try await apiClient.directoryList(sessionID: sessionID, path: path)
            currentPath = response.path ?? path
            entries = response.entries ?? []
        } catch {
            if !error.isCancellation {
                lastError = error
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }
}

struct FileBreadcrumb: Identifiable, Equatable {
    var id: String { path }

    let title: String
    let path: String
}
