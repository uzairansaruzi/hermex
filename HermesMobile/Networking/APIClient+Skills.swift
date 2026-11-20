import Foundation

protocol SkillsDataClient: Sendable {
    var skillsFeatures: SkillsFeatures { get }
    func skills() async throws -> SkillsResponse
    func skillContent(name: String, file: String?) async throws -> SkillDetailResponse
    func toggleSkill(name: String, enabled: Bool) async throws -> ToggleSkillResponse
}

struct SkillsFeatures: Equatable, Sendable {
    let hasLinkedFiles: Bool

    static let webui = SkillsFeatures(hasLinkedFiles: true)
    static let hermes = SkillsFeatures(hasLinkedFiles: true)
}

extension APIClient: SkillsDataClient {
    nonisolated var skillsFeatures: SkillsFeatures { .webui }

    func skills() async throws -> SkillsResponse {
        try await send(endpoint: .skills, method: "GET")
    }

    func skillContent(name: String, file: String? = nil) async throws -> SkillDetailResponse {
        try await send(endpoint: .skillContent(name: name, file: file), method: "GET")
    }

    func toggleSkill(name: String, enabled: Bool) async throws -> ToggleSkillResponse {
        try await send(
            endpoint: .toggleSkill,
            method: "POST",
            body: ToggleSkillRequest(name: name, enabled: enabled)
        )
    }
}
