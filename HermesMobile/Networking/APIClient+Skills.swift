import Foundation

/// What the Skills screens read and toggle through (#1069): a webui server's `APIClient`, or
/// a Hermes host's `HermesSkillsClient`, which is bound to one Profile.
protocol SkillsDataClient: Sendable {
    var skillsFeatures: SkillsFeatures { get }
    /// Every skill, disabled ones included.
    func skills() async throws -> SkillsResponse
    /// A skill's SKILL.md, or one of its linked files when `file` names one.
    func skillContent(name: String, file: String?) async throws -> SkillDetailResponse
    func toggleSkill(name: String, enabled: Bool) async throws -> ToggleSkillResponse
}

/// The parts of Skills one server backs. Both list a skill's linked files and open each: webui
/// through its skill route, a Hermes host through its file routes (#1070).
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
