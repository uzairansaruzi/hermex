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

    /// Monotonic token for mutation requests: because `@MainActor` methods are
    /// reentrant across network awaits, a slow older mutation response (add,
    /// rename, remove, or reorder) could land after a newer one and overwrite
    /// the newer result with a stale registry echo. Every mutation bumps this;
    /// only the most recent one may apply its echo, refetch, or record errors.
    private var mutationGeneration = 0

    /// Count of in-flight mutations, so `isMutating` stays true until the last
    /// overlapping mutation settles instead of flipping off when the first does.
    private var inFlightMutations = 0

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
        }.succeeded
    }

    @discardableResult
    func renameWorkspace(path: String, to name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !trimmedName.isEmpty else { return false }

        return await performMutation {
            try await self.client.renameWorkspace(path: path, name: trimmedName)
        }.succeeded
    }

    // MARK: Removal (confirmation-gated)

    func requestRemoval(of workspace: WorkspaceRoot) {
        pendingRemoval = workspace
    }

    func cancelPendingRemoval() {
        pendingRemoval = nil
    }

    /// Performs the removal for a workspace the user already confirmed in the
    /// dialog. Takes the workspace explicitly (rather than reading
    /// `pendingRemoval`) because SwiftUI clears the presentation binding —
    /// and with it the staged state — before the confirm action's task runs.
    @discardableResult
    func confirmRemoval(of workspace: WorkspaceRoot) async -> Bool {
        pendingRemoval = nil
        guard let path = workspace.path, !path.isEmpty else { return false }

        return await performMutation {
            try await self.client.removeWorkspace(path: path)
        }.succeeded
    }

    // MARK: Reorder

    /// Applies the move locally (trivial optimistic step so the row lands where
    /// the user dropped it), then asks the server to persist the full order.
    /// On failure the list is refetched so local order never drifts from the server.
    ///
    /// Offsets are relative to `rows` (what the list renders), not `workspaces`:
    /// tolerant decoding can leave pathless entries that the UI filters out, so
    /// the move is applied to the visible rows and any hidden entries are kept
    /// at the end — mirroring the server, which appends omitted entries.
    @discardableResult
    func moveWorkspaces(fromOffsets source: IndexSet, toOffset destination: Int) async -> Bool {
        let originalRows = rows
        var reorderedRows = originalRows
        reorderedRows.move(fromOffsets: source, toOffset: destination)
        guard reorderedRows != originalRows else { return true }

        let hiddenEntries = workspaces.filter { !($0.path?.isEmpty == false) }
        workspaces = reorderedRows + hiddenEntries

        let paths = reorderedRows.compactMap { workspace -> String? in
            guard let path = workspace.path, !path.isEmpty else { return nil }
            return path
        }
        guard !paths.isEmpty else { return false }

        let outcome = await performMutation {
            try await self.client.reorderWorkspaces(paths: paths)
        }
        if !outcome.succeeded, !outcome.superseded {
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
        return outcome.succeeded
    }

    // MARK: - Helpers

    /// Outcome of one mutation call. `superseded` means a newer mutation
    /// started while this one was awaiting its response, so this one applied
    /// nothing locally (its echo would be stale) — the caller must not
    /// refetch or surface errors for a superseded mutation either.
    private struct MutationOutcome {
        let succeeded: Bool
        let superseded: Bool
    }

    /// Runs one mutation call and applies its outcome. Staleness is checked
    /// after the await: a mutation superseded by a newer one (any kind — the
    /// UI leaves swipe rename/delete reachable while another mutation is in
    /// flight) must not apply its echo, refetch, or overwrite error state.
    private func performMutation(
        _ operation: @escaping () async throws -> WorkspaceMutationResponse
    ) async -> MutationOutcome {
        mutationGeneration += 1
        let generation = mutationGeneration
        inFlightMutations += 1
        isMutating = true
        errorMessage = nil
        lastError = nil
        defer {
            inFlightMutations -= 1
            isMutating = inFlightMutations > 0
        }

        do {
            let response = try await operation()
            let superseded = generation != mutationGeneration
            // These undocumented routes signal failure via non-2xx today, but
            // the body explicitly carries `ok`/`error` — honor a 2xx that
            // reports `ok: false` as a failure instead of a success.
            if response.ok == false {
                if !superseded {
                    record(WorkspaceMutationRejection(serverMessage: response.error))
                }
                return MutationOutcome(succeeded: false, superseded: superseded)
            }
            didMutateRegistry = true
            guard !superseded else {
                return MutationOutcome(succeeded: true, superseded: true)
            }
            if let updated = response.workspaces {
                workspaces = updated
            } else {
                await load()
            }
            return MutationOutcome(succeeded: true, superseded: false)
        } catch {
            let superseded = generation != mutationGeneration
            if !superseded {
                record(error)
            }
            return MutationOutcome(succeeded: false, superseded: superseded)
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
