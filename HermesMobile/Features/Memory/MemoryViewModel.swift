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
    private(set) var hiddenSections: Set<MemorySection> = []
    private(set) var characterLimits: [MemorySection: Int] = [:]
    private(set) var readOnlySections: Set<MemorySection> = []
    private(set) var conflictedSection: MemorySection?
    private(set) var isReloading = false

    let features: MemoryFeatures
    private let client: any MemoryDataClient

    init(server: URL, client: (any MemoryDataClient)? = nil) {
        let client: any MemoryDataClient = client ?? APIClient(baseURL: server)
        self.client = client
        features = client.memoryFeatures
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
        conflictedSection = nil
    }

    var visibleSections: [MemorySection] {
        MemorySection.allCases.filter { !hiddenSections.contains($0) }
    }

    func characterLimit(for section: MemorySection) -> Int? {
        characterLimits[section]
    }

    func isReadOnly(_ section: MemorySection) -> Bool {
        readOnlySections.contains(section)
    }

    var showsProjectContext: Bool {
        guard let text = projectContextText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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

    func save(section: MemorySection, content: String, loaded: String? = nil) async -> Bool {
        guard !isReadOnly(section) else { return false }
        if let limit = characterLimit(for: section), MemoryCharacterCount(draft: content, limit: limit).isOver {
            actionErrorMessage = String(localized: "Over the host's limit. Shorten to save.")
            return false
        }
        isSaving = true
        actionErrorMessage = nil
        lastError = nil
        conflictedSection = nil
        defer { isSaving = false }

        do {
            let writeResponse = try await client.saveMemory(
                section: section, content: content, loaded: loaded ?? self.content(for: section)
            )
            guard writeResponse.ok != false else {
                actionErrorMessage = writeResponse.error ?? String(localized: "Could not save memory.")
                return false
            }

            let refreshed = try await client.memory()
            apply(refreshed)
            return true
        } catch is MemoryConflict {
            conflictedSection = section
            return false
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func reload(_ section: MemorySection) async -> String? {
        isReloading = true
        actionErrorMessage = nil
        lastError = nil
        defer { isReloading = false }

        do {
            apply(try await client.memory())
            conflictedSection = nil
            return content(for: section)
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return nil
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
        hiddenSections = response.hiddenSections
        characterLimits = response.characterLimits
        readOnlySections = response.readOnlySections
        hasLoaded = true
    }
}
