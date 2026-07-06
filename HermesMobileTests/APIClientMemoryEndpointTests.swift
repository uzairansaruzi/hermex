import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientMemoryEndpointTests: APIClientTestCase {
    func testMemoryBuildsExpectedPathAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes\\n\\n- Prefer SwiftUI",
              "user": "# Profile\\n\\n- Name: Developer",
              "soul": "# Agent Soul\\n\\n- Be concise",
              "memory_path": "/Users/test/.hermes/memories/MEMORY.md",
              "user_path": "/Users/test/.hermes/memories/USER.md",
              "soul_path": "/Users/test/.hermes/SOUL.md",
              "memory_mtime": 1770000000,
              "user_mtime": 1770000100,
              "soul_mtime": "1770000200",
              "project_context": "# Project\\n\\n- Ship it",
              "project_context_name": "AGENTS.md",
              "project_context_path": "/Users/test/workspace/AGENTS.md",
              "project_context_workspace": "/Users/test/workspace",
              "project_context_mtime": 1770000300,
              "project_context_shadowed": [
                {
                  "name": "PROJECT.md",
                  "path": "/Users/test/PROJECT.md",
                  "shadowed_by": "AGENTS.md"
                }
              ],
              "external_notes_enabled": true
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.memory, "# Notes\n\n- Prefer SwiftUI")
        XCTAssertEqual(response.user, "# Profile\n\n- Name: Developer")
        XCTAssertEqual(response.soul, "# Agent Soul\n\n- Be concise")
        XCTAssertEqual(response.memoryPath, "/Users/test/.hermes/memories/MEMORY.md")
        XCTAssertEqual(response.userPath, "/Users/test/.hermes/memories/USER.md")
        XCTAssertEqual(response.soulPath, "/Users/test/.hermes/SOUL.md")
        XCTAssertEqual(response.memoryMtime, 1_770_000_000)
        XCTAssertEqual(response.userMtime, 1_770_000_100)
        XCTAssertEqual(response.soulMtime, 1_770_000_200)
        XCTAssertEqual(response.projectContext, "# Project\n\n- Ship it")
        XCTAssertEqual(response.projectContextName, "AGENTS.md")
        XCTAssertEqual(response.projectContextPath, "/Users/test/workspace/AGENTS.md")
        XCTAssertEqual(response.projectContextWorkspace, "/Users/test/workspace")
        XCTAssertEqual(response.projectContextMtime, 1_770_000_300)
        XCTAssertEqual(response.projectContextShadowed, true)
        XCTAssertEqual(response.externalNotesEnabled, true)
    }

    func testMemoryToleratesMissingFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "",
              "user": null
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.memory, "")
        XCTAssertNil(response.user)
        XCTAssertNil(response.soul)
        XCTAssertNil(response.memoryMtime)
        XCTAssertNil(response.userMtime)
        XCTAssertNil(response.soulMtime)
        XCTAssertNil(response.projectContext)
        XCTAssertNil(response.projectContextName)
        XCTAssertNil(response.projectContextPath)
        XCTAssertNil(response.projectContextWorkspace)
        XCTAssertNil(response.projectContextMtime)
        XCTAssertNil(response.projectContextShadowed)
        XCTAssertNil(response.externalNotesEnabled)
    }

    func testMemoryDecodesProjectContextShadowedBooleanShape() async throws {
        // The API docs describe project_context_shadowed as a boolean flag even though
        // upstream currently sends a list; both shapes must decode.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "project_context": "# Project",
              "project_context_shadowed": true
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.projectContext, "# Project")
        XCTAssertEqual(response.projectContextShadowed, true)
    }

    func testMemoryDecodesEmptyShadowedListAsNotShadowed() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "project_context": "# Project",
              "project_context_shadowed": []
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.projectContextShadowed, false)
    }

    func testMemoryToleratesNullAndUnexpectedShadowedShapes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "project_context": "# Project",
              "project_context_shadowed": null,
              "external_notes_enabled": "yes"
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertNil(response.projectContextShadowed)
        XCTAssertNil(response.externalNotesEnabled)
    }

    func testMemoryWriteBuildsExpectedPathBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory/write")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["section"] as? String, "user")
            XCTAssertEqual(body?["content"] as? String, "# Profile\n\n- Updated from iOS")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "section": "user",
              "path": "/Users/test/.hermes/memories/USER.md",
              "unexpected": "ignored"
            }
            """, for: request)
        }

        let response = try await client.writeMemory(section: .user, content: "# Profile\n\n- Updated from iOS")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.section, .user)
        XCTAssertEqual(response.path, "/Users/test/.hermes/memories/USER.md")
    }

    func testMemoryWriteToleratesMissingFieldsAndUnknownSection() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory/write")

            return apiTestJSONResponse("""
            {
              "section": "future"
            }
            """, for: request)
        }

        let response = try await client.writeMemory(section: .soul, content: "# Soul")

        XCTAssertNil(response.ok)
        XCTAssertNil(response.section)
        XCTAssertNil(response.path)
    }
}
