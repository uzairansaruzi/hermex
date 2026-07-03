import Foundation
import Observation

@MainActor
@Observable
final class SkillsViewModel {
    private(set) var skills: [SkillSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private(set) var togglingSkillNames: Set<String> = []

    private let client: APIClient

    init(server: URL) {
        client = APIClient(baseURL: server)
    }

    init(client: APIClient) {
        self.client = client
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
            let tags = skill.tags?.contains { $0.localizedCaseInsensitiveContains(query) } ?? false
            return name || description || category || tags
        }

        guard !filtered.isEmpty else { return [] }

        return Self.groupedSkills(for: filtered)
    }

    func setSkill(_ skill: SkillSummary, enabled: Bool) async {
        guard let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }

        let previousSkills = skills
        lastError = nil
        errorMessage = nil
        togglingSkillNames.insert(name)
        updateSkill(named: name, disabled: !enabled)
        defer { togglingSkillNames.remove(name) }

        do {
            _ = try await client.toggleSkill(name: name, enabled: enabled)
            await load()
        } catch {
            skills = previousSkills
            lastError = error
            errorMessage = error.localizedDescription
        }
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

    private func updateSkill(named name: String, disabled: Bool) {
        skills = skills.map { skill in
            guard skill.name == name else { return skill }
            return SkillSummary(
                name: skill.name,
                category: skill.category,
                description: skill.description,
                path: skill.path,
                disabled: disabled,
                tags: skill.tags,
                relatedSkills: skill.relatedSkills
            )
        }
    }
}
