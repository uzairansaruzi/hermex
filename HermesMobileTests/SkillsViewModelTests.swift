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

    @MainActor
    func testToggleSkillRevertsOnFailure() async throws {
        var shouldFailToggle = false
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse("""
                {"skills": [{"name": "swift-refactor", "category": "coding", "disabled": false}]}
                """, for: request)
            case "/api/skills/toggle":
                shouldFailToggle = true
                throw URLError(.notConnectedToInternet)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = SkillsViewModel(client: client)

        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)

        XCTAssertTrue(shouldFailToggle)
        XCTAssertEqual(model.skills.first?.disabled, false)
        XCTAssertNotNil(model.lastError)
    }
}
