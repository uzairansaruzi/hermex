import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSkillEndpointTests: APIClientTestCase {
    func testToggleSkillPostsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/toggle")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["name"] as? String, "swift-refactor")
            XCTAssertEqual(body["enabled"] as? Bool, false)

            return apiTestJSONResponse("""
            {"ok": true, "name": "swift-refactor", "enabled": false}
            """, for: request)
        }

        let response = try await client.toggleSkill(name: "swift-refactor", enabled: false)
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.name, "swift-refactor")
        XCTAssertEqual(response.enabled, false)
    }

    func testSkillContentBuildsExpectedQueryAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/content")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["name"], "swift-refactor")
            XCTAssertNil(query["file"])
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {"name": "swift-refactor", "content": "# Swift Refactor\\n\\nRefactors Swift code.", "linked_files": {"README.md": "Read me", "config.json": "Config"}}
            """, for: request)
        }

        let response = try await client.skillContent(name: "swift-refactor")
        XCTAssertEqual(response.name, "swift-refactor")
        XCTAssertEqual(response.content, "# Swift Refactor\n\nRefactors Swift code.")
        XCTAssertEqual(response.linkedFiles, ["README.md", "config.json"])
    }

    func testSkillContentDecodesGroupedLinkedFiles() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/skills/content")

            return apiTestJSONResponse("""
            {
              "name": "google-workspace",
              "content": "# Google Workspace",
              "linked_files": {
                "references": ["references/auth.md"],
                "scripts": ["scripts/setup.py", "scripts/google_api.py"],
                "assets": []
              }
            }
            """, for: request)
        }

        let response = try await client.skillContent(name: "google-workspace")

        XCTAssertEqual(response.linkedFiles, [
            "references/auth.md",
            "scripts/google_api.py",
            "scripts/setup.py"
        ])
    }
}
