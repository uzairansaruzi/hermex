import XCTest
@testable import HermesMobile

final class SkillsViewModelTests: APIClientTestCase {
    @MainActor
    func testGroupedSkillsNormalizesBlankCategoriesAndSortsRows() {
        let groups = SkillsViewModel.groupedSkills(for: [
            SkillSummary(name: "zed", category: " coding ", description: nil, path: nil),
            SkillSummary(name: "Alpha", category: "coding", description: nil, path: nil),
            SkillSummary(name: "loose", category: "   ", description: nil, path: nil),
            SkillSummary(name: nil, category: nil, description: nil, path: nil)
        ])

        XCTAssertEqual(groups.map(\.category), ["coding", "Uncategorized"])
        XCTAssertEqual(groups.first?.skills.map(\.name), ["Alpha", "zed"])
        XCTAssertEqual(groups.last?.skills.map { $0.name ?? "Unnamed Skill" }, ["loose", "Unnamed Skill"])
    }

    @MainActor
    func testToggleSkillOptimisticallyUpdatesThenReloadsServerState() async throws {
        var paths: [String] = []
        var skillsLoadCount = 0
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/skills":
                skillsLoadCount += 1
                let disabled = skillsLoadCount > 1
                return apiTestJSONResponse("""
                {"skills": [{"name": "swift-refactor", "category": "coding", "disabled": \(disabled)}]}
                """, for: request)
            case "/api/skills/toggle":
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["name"] as? String, "swift-refactor")
                XCTAssertEqual(body["enabled"] as? Bool, false)
                return apiTestJSONResponse("""
                {"ok": true, "name": "swift-refactor", "enabled": false}
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = SkillsViewModel(client: client)

        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)

        XCTAssertEqual(paths, ["/api/skills", "/api/skills/toggle", "/api/skills"])
        XCTAssertEqual(model.skills.first?.disabled, true)
        XCTAssertNil(model.lastError)
    }

    /// A Hermes host's `{detail}` refusal (#1069): the row turns back, and the screen has the
    /// host's reason to show.
    @MainActor
    func testARefusedToggleRollsBackAndKeepsTheHostsReason() async throws {
        let client = ScriptedSkillsClient([SkillSummary(name: "arxiv", category: "research", description: nil, path: nil,
                                                        disabled: false)])
        client.toggleError = HermesCronRefusal(detail: "Profile 'research' does not exist.")
        let model = SkillsViewModel(client: client)

        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)

        XCTAssertEqual(client.toggles.map(\.name), ["arxiv"])
        XCTAssertEqual(client.toggles.map(\.enabled), [false])
        XCTAssertEqual(model.skills.first?.disabled, false)
        XCTAssertEqual(model.toggleErrorMessage, "The server rejected the request: Profile 'research' does not exist.")

        model.clearToggleError()
        XCTAssertNil(model.toggleErrorMessage)
    }

    /// A Hermes host sends no tags, so search reads names, descriptions and categories alone.
    @MainActor
    func testSearchWithoutTagsMatchesNamesAndDescriptions() async {
        let model = SkillsViewModel(client: ScriptedSkillsClient([
            SkillSummary(name: "apple-notes", category: "apple", description: "Manage Apple Notes.", path: nil, disabled: false),
            SkillSummary(name: "arxiv", category: "research", description: "Search papers.", path: nil, disabled: true)
        ]))

        await model.load()

        XCTAssertEqual(model.filteredGroupedSkills(searchText: "papers").flatMap(\.skills).map(\.name), ["arxiv"])
        XCTAssertEqual(model.filteredGroupedSkills(searchText: "NOTES").flatMap(\.skills).map(\.name), ["apple-notes"])
    }
}

/// A Skills server on scripted data: it lists `skills` and records each toggle, failing it
/// with `toggleError` when set.
@MainActor private final class ScriptedSkillsClient: SkillsDataClient {
    nonisolated var skillsFeatures: SkillsFeatures { .hermes }
    var toggleError: Error?
    private(set) var toggles: [(name: String, enabled: Bool)] = []
    private let list: [SkillSummary]

    init(_ skills: [SkillSummary]) { list = skills }

    func skills() async throws -> SkillsResponse { SkillsResponse(skills: list) }
    func skillContent(name _: String, file _: String?) async throws -> SkillDetailResponse { throw BotFailure.unsupported }

    func toggleSkill(name: String, enabled: Bool) async throws -> ToggleSkillResponse {
        toggles.append((name, enabled))
        if let toggleError { throw toggleError }
        return ToggleSkillResponse(ok: true, name: name, enabled: enabled)
    }
}
