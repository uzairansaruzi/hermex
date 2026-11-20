import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceRegistryViewModel {
    private(set) var workspaces: [WorkspaceRoot] = []
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    private(set) var managementUnavailable = false

    private(set) var didMutateRegistry = false

    private(set) var pendingRemoval: WorkspaceRoot?

    private let client: APIClient

    private var mutationGeneration = 0

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

    func requestRemoval(of workspace: WorkspaceRoot) {
        pendingRemoval = workspace
    }

    func cancelPendingRemoval() {
        pendingRemoval = nil
    }

    @discardableResult
    func confirmRemoval(of workspace: WorkspaceRoot) async -> Bool {
        pendingRemoval = nil
        guard let path = workspace.path, !path.isEmpty else { return false }

        return await performMutation {
            try await self.client.removeWorkspace(path: path)
        }.succeeded
    }

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

    private struct MutationOutcome {
        let succeeded: Bool
        let superseded: Bool
    }

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
