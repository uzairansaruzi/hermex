import Foundation
import Observation

@MainActor
@Observable
final class MemoryViewModel {
    private(set) var memoryText: String?
    private(set) var userText: String?
    private(set) var soulText: String?
    private(set) var memoryMtime: Date?
    private(set) var userMtime: Date?
    private(set) var soulMtime: Date?
    private(set) var projectContextText: String?
    private(set) var projectContextName: String?
    private(set) var projectContextWorkspace: String?
    private(set) var projectContextMtime: Date?
    private(set) var isProjectContextShadowed = false
    private(set) var isExternalNotesEnabled: Bool?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?

    private let client: APIClient

    init(server: URL, client: APIClient? = nil) {
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        do {
            let response = try await client.memory()
            apply(response)
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// The read-only project-context section only appears when the server sent a
    /// non-empty document. Servers without the field (or with an empty/blank one,
    /// which is what upstream returns when no readable context file exists) render
    /// the screen exactly as before.
    var showsProjectContext: Bool {
        guard let text = projectContextText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Non-localized "name — workspace" detail line for the project-context section.
    var projectContextDetail: String? {
        let parts = [projectContextName, projectContextWorkspace]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    func content(for section: MemorySection) -> String {
        switch section {
        case .memory:
            return memoryText ?? ""
        case .user:
            return userText ?? ""
        case .soul:
            return soulText ?? ""
        }
    }

    func modifiedAt(for section: MemorySection) -> Date? {
        switch section {
        case .memory:
            return memoryMtime
        case .user:
            return userMtime
        case .soul:
            return soulMtime
        }
    }

    func save(section: MemorySection, content: String) async -> Bool {
        isSaving = true
        actionErrorMessage = nil
        lastError = nil
        defer { isSaving = false }

        do {
            let writeResponse = try await client.writeMemory(section: section, content: content)
            guard writeResponse.ok != false else {
                actionErrorMessage = writeResponse.error ?? String(localized: "Could not save memory.")
                return false
            }

            let refreshed = try await client.memory()
            apply(refreshed)
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func apply(_ response: MemoryResponse) {
        memoryText = response.memory
        userText = response.user
        soulText = response.soul
        memoryMtime = response.memoryMtime.map { Date(timeIntervalSince1970: $0) }
        userMtime = response.userMtime.map { Date(timeIntervalSince1970: $0) }
        soulMtime = response.soulMtime.map { Date(timeIntervalSince1970: $0) }
        projectContextText = response.projectContext
        projectContextName = response.projectContextName
        projectContextWorkspace = response.projectContextWorkspace
        projectContextMtime = response.projectContextMtime.map { Date(timeIntervalSince1970: $0) }
        isProjectContextShadowed = response.projectContextShadowed ?? false
        isExternalNotesEnabled = response.externalNotesEnabled
        hasLoaded = true
    }
}
