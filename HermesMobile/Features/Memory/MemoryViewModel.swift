import Foundation
import Observation

@MainActor
@Observable
final class MemoryViewModel {
    private(set) var memoryText: String?
    private(set) var userText: String?
    private(set) var soulText: String?
    private(set) var projectContextText: String?
    private(set) var projectContextName: String?
    private(set) var projectContextPath: String?
    private(set) var projectContextWorkspace: String?
    private(set) var isProjectContextShadowed = false
    private(set) var isExternalNotesEnabled = false
    private(set) var memoryMtime: Date?
    private(set) var userMtime: Date?
    private(set) var soulMtime: Date?
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
        projectContextText = response.projectContext
        projectContextName = response.projectContextName
        projectContextPath = response.projectContextPath
        projectContextWorkspace = response.projectContextWorkspace
        isProjectContextShadowed = response.projectContextShadowed == true
        isExternalNotesEnabled = response.externalNotesEnabled == true
        memoryMtime = response.memoryMtime.map { Date(timeIntervalSince1970: $0) }
        userMtime = response.userMtime.map { Date(timeIntervalSince1970: $0) }
        soulMtime = response.soulMtime.map { Date(timeIntervalSince1970: $0) }
        hasLoaded = true
    }
}
