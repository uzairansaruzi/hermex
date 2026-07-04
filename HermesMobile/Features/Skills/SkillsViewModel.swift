import Foundation
import Observation

@MainActor
@Observable
final class SkillsViewModel {
    private(set) var skills: [SkillSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    private let client: APIClient

    init(server: URL) {
        client = APIClient(baseURL: server)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        do {
            let response = try await client.skills()
            skills = response.skills ?? []
        } catch {
            guard !error.isCancellation else { return }

            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    var groupedSkills: [(category: String, skills: [SkillSummary])] {
        Self.groupedSkills(for: skills)
    }

    func filteredGroupedSkills(searchText: String) -> [(category: String, skills: [SkillSummary])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groupedSkills }

        let filtered = skills.filter { skill in
            let name = skill.name?.localizedCaseInsensitiveContains(query) ?? false
            let description = skill.description?.localizedCaseInsensitiveContains(query) ?? false
            let category = skill.category?.localizedCaseInsensitiveContains(query) ?? false
            return name || description || category
        }

        guard !filtered.isEmpty else { return [] }

        return Self.groupedSkills(for: filtered)
    }

    static func groupedSkills(for skills: [SkillSummary]) -> [(category: String, skills: [SkillSummary])] {
        let grouped = Dictionary(grouping: skills, by: categoryName(for:))
        return grouped
            .sorted {
                $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .map { (category: $0.key, skills: sortedSkills($0.value)) }
    }

    private static func categoryName(for skill: SkillSummary) -> String {
        let category = skill.category?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let category, !category.isEmpty else {
            return String(localized: "Uncategorized")
        }
        return category
    }

    private static func sortedSkills(_ skills: [SkillSummary]) -> [SkillSummary] {
        skills.sorted { lhs, rhs in
            displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }
    }

    private static func displayName(for skill: SkillSummary) -> String {
        let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Unnamed Skill")
        }
        return name
    }
}
