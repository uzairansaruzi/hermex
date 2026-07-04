import Foundation
import Observation

/// Drives the workspace-registry management sheet (issue #22): add, remove,
/// rename, and reorder entries via the undocumented `/api/workspaces/*`
/// mutation routes. Every mutation prefers the `workspaces` echo the server
/// returns; when it is missing (tolerant decoding — these routes carry no
/// stability promise) the list is refetched from `GET /api/workspaces`.
@MainActor
@Observable
final class WorkspaceRegistryViewModel {
    private(set) var workspaces: [WorkspaceRoot] = []
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    /// Set when a management route returns 404 — a future server release may
    /// drop these undocumented routes; the UI then explains instead of crashing.
    private(set) var managementUnavailable = false

    /// True once any mutation succeeded, so the presenting picker knows to
    /// refresh its own copy of the registry on dismiss.
    private(set) var didMutateRegistry = false

    /// Removal is confirmation-gated (write-safety rule): a swipe-to-delete only
    /// stages the entry here; the API call happens in `confirmPendingRemoval()`.
    private(set) var pendingRemoval: WorkspaceRoot?

    private let client: APIClient

    init(server: URL) {
        client = APIClient(baseURL: server)
    }

    init(client: APIClient) {
        self.client = client
    }

    var rows: [WorkspaceRoot] {
        workspaces.filter { $0.path?.isEmpty == false }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        do {
            let response = try await client.workspaces()
            workspaces = response.workspaces ?? []
        } catch {
            record(error)
        }
    }

    func loadSuggestions(prefix: String) async -> [String] {
        (try? await client.workspaceSuggestions(prefix: prefix))?.suggestions ?? []
    }

    @discardableResult
    func addWorkspace(path: String, name: String?, create: Bool) async -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        return await performMutation {
            try await self.client.addWorkspace(
                path: trimmedPath,
                name: trimmedName?.isEmpty == false ? trimmedName : nil,
                create: create ? true : nil
            )
        }
    }

    @discardableResult
    func renameWorkspace(path: String, to name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !trimmedName.isEmpty else { return false }

        return await performMutation {
            try await self.client.renameWorkspace(path: path, name: trimmedName)
        }
    }

    // MARK: Removal (confirmation-gated)

    func requestRemoval(of workspace: WorkspaceRoot) {
        pendingRemoval = workspace
    }

    func cancelPendingRemoval() {
        pendingRemoval = nil
    }

    @discardableResult
    func confirmPendingRemoval() async -> Bool {
        guard let path = pendingRemoval?.path, !path.isEmpty else {
            pendingRemoval = nil
            return false
        }
        pendingRemoval = nil

        return await performMutation {
            try await self.client.removeWorkspace(path: path)
        }
    }

    // MARK: Reorder

    /// Applies the move locally (trivial optimistic step so the row lands where
    /// the user dropped it), then asks the server to persist the full order.
    /// On failure the list is refetched so local order never drifts from the server.
    @discardableResult
    func moveWorkspaces(fromOffsets source: IndexSet, toOffset destination: Int) async -> Bool {
        var reordered = workspaces
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != workspaces else { return true }
        workspaces = reordered

        let paths = reordered.compactMap { workspace -> String? in
            guard let path = workspace.path, !path.isEmpty else { return nil }
            return path
        }
        guard !paths.isEmpty else { return false }

        let succeeded = await performMutation {
            try await self.client.reorderWorkspaces(paths: paths)
        }
        if !succeeded {
            // Refetch so local order never drifts from the server, but keep the
            // reorder failure visible (load() clears error state on entry).
            let failureMessage = errorMessage
            let failure = lastError
            await load()
            if errorMessage == nil {
                errorMessage = failureMessage
                lastError = failure
            }
        }
        return succeeded
    }

    // MARK: - Helpers

    private func performMutation(_ operation: @escaping () async throws -> WorkspaceMutationResponse) async -> Bool {
        isMutating = true
        errorMessage = nil
        lastError = nil
        defer { isMutating = false }

        do {
            let response = try await operation()
            didMutateRegistry = true
            if let updated = response.workspaces {
                workspaces = updated
            } else {
                await load()
            }
            return true
        } catch {
            record(error)
            return false
        }
    }

    private func record(_ error: Error) {
        lastError = error
        errorMessage = error.localizedDescription
        if case APIError.http(let statusCode, _) = error, statusCode == 404 {
            managementUnavailable = true
        }
    }
}
