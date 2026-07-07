import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientWorkspaceFileTests: APIClientTestCase {
    func testProjectsBuildsExpectedPathAndDecodesProjectList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects")
            XCTAssertNil(request.httpBody)

            return apiTestJSONResponse("""
            {
              "projects": [
                {
                  "project_id": "proj123",
                  "name": "Client Work",
                  "color": "#336699",
                  "created_at": 1770000000
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.projects()
        let project = try XCTUnwrap(response.projects?.first)

        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Work")
        XCTAssertEqual(project.color, "#336699")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testProjectsToleratesLossyProjectFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects")

            return apiTestJSONResponse("""
            {
              "projects": [
                {
                  "project_id": 123,
                  "name": true,
                  "color": 456,
                  "created_at": "1770000000"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.projects()
        let project = try XCTUnwrap(response.projects?.first)

        XCTAssertEqual(project.projectId, "123")
        XCTAssertEqual(project.name, "true")
        XCTAssertEqual(project.color, "456")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testCreateProjectBuildsExpectedBodyAndDecodesCreatedProject() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/create")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["name"] as? String, "Client Work")
            XCTAssertEqual(json?["color"] as? String, "#7cb9ff")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "project": {
                "project_id": "proj123",
                "name": "Client Work",
                "color": "#7cb9ff",
                "profile": "default",
                "created_at": 1770000000
              }
            }
            """, for: request)
        }

        let response = try await client.createProject(name: "Client Work", color: "#7cb9ff")
        let project = try XCTUnwrap(response.project)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Work")
        XCTAssertEqual(project.color, "#7cb9ff")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testRenameProjectBuildsExpectedBodyAndDecodesRenamedProject() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/rename")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertEqual(json?["name"] as? String, "Client Archive")
            XCTAssertEqual(json?["color"] as? String, "#f5c542")
            XCTAssertNil(json?["projectId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "project": {
                "project_id": "proj123",
                "name": "Client Archive",
                "color": "#f5c542",
                "created_at": "1770000000",
                "unexpected": "ignored"
              }
            }
            """, for: request)
        }

        let response = try await client.renameProject(id: "proj123", name: "Client Archive", color: "#f5c542")
        let project = try XCTUnwrap(response.project)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(project.projectId, "proj123")
        XCTAssertEqual(project.name, "Client Archive")
        XCTAssertEqual(project.color, "#f5c542")
        XCTAssertEqual(project.createdAt, 1_770_000_000)
    }

    func testRenameProjectOmitsColorWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/rename")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertEqual(json?["name"] as? String, "Client Archive")
            XCTAssertNil(json?["color"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "project": {
                "project_id": "proj123",
                "name": "Client Archive"
              }
            }
            """, for: request)
        }

        let response = try await client.renameProject(id: "proj123", name: "Client Archive", color: nil)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.project?.projectId, "proj123")
        XCTAssertNil(response.project?.color)
    }

    func testDeleteProjectBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/projects/delete")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertNil(json?["projectId"])

            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        let response = try await client.deleteProject(id: "proj123")

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.project)
    }

    func testWorkspacesDecodesWorkspaceObjects() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces")

            return apiTestJSONResponse("""
            {
              "workspaces": [
                {"path": "/Users/test/project", "name": "Project"}
              ],
              "last": "/Users/test/project"
            }
            """, for: request)
        }

        let response = try await client.workspaces()

        XCTAssertEqual(response.last, "/Users/test/project")
        XCTAssertEqual(response.workspaces?.first?.path, "/Users/test/project")
        XCTAssertEqual(response.workspaces?.first?.name, "Project")
    }

    func testWorkspacesToleratesLegacyStringEntries() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces")

            return apiTestJSONResponse("""
            {
              "workspaces": ["/Users/test/project"],
              "last": null
            }
            """, for: request)
        }

        let response = try await client.workspaces()

        XCTAssertEqual(response.workspaces?.first?.path, "/Users/test/project")
        XCTAssertNil(response.workspaces?.first?.name)
    }

    func testWorkspaceSuggestionsBuildsExpectedQueryAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/suggest")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["prefix"], "/Users/test/pro")

            return apiTestJSONResponse("""
            {
              "suggestions": [
                "/Users/test/project",
                "/Users/test/prototypes"
              ],
              "prefix": "/Users/test/pro"
            }
            """, for: request)
        }

        let response = try await client.workspaceSuggestions(prefix: "/Users/test/pro")

        XCTAssertEqual(response.prefix, "/Users/test/pro")
        XCTAssertEqual(response.suggestions, ["/Users/test/project", "/Users/test/prototypes"])
    }

    func testAddWorkspaceBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/add")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/newproject")
            XCTAssertEqual(json["name"] as? String, "New Project")
            XCTAssertEqual(json["create"] as? Bool, true)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "workspaces": [
                {"path": "/Users/test/project", "name": "Project"},
                {"path": "/Users/test/newproject", "name": "New Project"}
              ]
            }
            """, for: request)
        }

        let response = try await client.addWorkspace(path: "/Users/test/newproject", name: "New Project", create: true)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.count, 2)
        XCTAssertEqual(response.workspaces?.last?.path, "/Users/test/newproject")
        XCTAssertEqual(response.workspaces?.last?.name, "New Project")
    }

    func testAddWorkspaceOmitsOptionalFieldsWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/add")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/newproject")
            XCTAssertNil(json["name"])
            XCTAssertNil(json["create"])

            return apiTestJSONResponse("""
            {"ok": true, "workspaces": [{"path": "/Users/test/newproject", "name": "newproject"}]}
            """, for: request)
        }

        let response = try await client.addWorkspace(path: "/Users/test/newproject")

        XCTAssertEqual(response.ok, true)
    }

    func testAddWorkspaceSurfacesServerErrorString() async throws {
        let client = makeClient { request in
            let (_, data) = apiTestJSONResponse("""
            {"error": "Workspace already in list"}
            """, for: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        do {
            _ = try await client.addWorkspace(path: "/Users/test/project")
            XCTFail("Expected APIError.http")
        } catch let error as APIError {
            XCTAssertEqual(error.serverMessage, "Workspace already in list")
            XCTAssertTrue(error.localizedDescription.contains("Workspace already in list"))
        }
    }

    func testRemoveWorkspaceBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/remove")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/oldproject")

            return apiTestJSONResponse("""
            {"ok": true, "workspaces": [{"path": "/Users/test/project", "name": "Project"}]}
            """, for: request)
        }

        let response = try await client.removeWorkspace(path: "/Users/test/oldproject")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.map(\.path), ["/Users/test/project"])
    }

    func testRenameWorkspaceBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/rename")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["path"] as? String, "/Users/test/project")
            XCTAssertEqual(json["name"] as? String, "Renamed")

            return apiTestJSONResponse("""
            {"ok": true, "workspaces": [{"path": "/Users/test/project", "name": "Renamed"}]}
            """, for: request)
        }

        let response = try await client.renameWorkspace(path: "/Users/test/project", name: "Renamed")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.first?.name, "Renamed")
    }

    func testReorderWorkspacesBuildsExpectedBodyAndDecodesUpdatedList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces/reorder")
            XCTAssertEqual(request.httpMethod, "POST")

            let json = try apiTestJSONBody(from: request)
            XCTAssertEqual(json["paths"] as? [String], ["/Users/test/b", "/Users/test/a"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "workspaces": [
                {"path": "/Users/test/b", "name": "B"},
                {"path": "/Users/test/a", "name": "A"}
              ]
            }
            """, for: request)
        }

        let response = try await client.reorderWorkspaces(paths: ["/Users/test/b", "/Users/test/a"])

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.workspaces?.compactMap(\.path), ["/Users/test/b", "/Users/test/a"])
    }

    func testWorkspaceMutationToleratesMissingWorkspacesEcho() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {"ok": true, "unexpected_new_field": {"nested": 1}}
            """, for: request)
        }

        let response = try await client.removeWorkspace(path: "/Users/test/project")

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.workspaces)
    }

    func testDirectoryListDecodesUpstreamEntries() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/list")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], ".")

            return apiTestJSONResponse("""
            {
              "entries": [
                {"name": "Sources", "path": "Sources", "type": "dir", "size": null},
                {"name": "LinkedDocs", "path": "LinkedDocs", "type": "symlink", "is_dir": true},
                {"name": "README.md", "path": "README.md", "type": "file", "size": 1200}
              ],
              "path": "."
            }
            """, for: request)
        }

        let response = try await client.directoryList(sessionID: "abc123", path: ".")

        XCTAssertEqual(response.path, ".")
        XCTAssertEqual(response.entries?.count, 3)
        XCTAssertEqual(response.entries?[0].name, "Sources")
        XCTAssertEqual(response.entries?[0].type, "dir")
        XCTAssertEqual(response.entries?[1].type, "symlink")
        XCTAssertEqual(response.entries?[1].isDirectory, true)
        XCTAssertEqual(response.entries?[2].size, 1200)
    }

    func testDirectoryListBuildsNestedPathQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/list")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], "Sources/App")

            return apiTestJSONResponse("""
            {
              "entries": [],
              "path": "Sources/App"
            }
            """, for: request)
        }

        let response = try await client.directoryList(sessionID: "abc123", path: "Sources/App")

        XCTAssertEqual(response.path, "Sources/App")
    }

    func testFileReadBuildsExpectedQueryAndDecodesTextResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], "Sources/App/FilePreviewView.swift")

            return apiTestJSONResponse("""
            {
              "path": "Sources/App/FilePreviewView.swift",
              "content": "import SwiftUI\\n",
              "size": 15,
              "lines": 2,
              "unexpected": "ignored"
            }
            """, for: request)
        }

        let response = try await client.file(sessionID: "abc123", path: "Sources/App/FilePreviewView.swift")

        XCTAssertEqual(response.path, "Sources/App/FilePreviewView.swift")
        XCTAssertEqual(response.content, "import SwiftUI\n")
        XCTAssertEqual(response.size, 15)
        XCTAssertEqual(response.lines, 2)
    }

    func testFileReadToleratesMissingOptionalMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file")

            return apiTestJSONResponse("""
            {
              "content": "hello"
            }
            """, for: request)
        }

        let response = try await client.file(sessionID: "abc123", path: "README.md")

        XCTAssertEqual(response.content, "hello")
        XCTAssertNil(response.path)
        XCTAssertNil(response.size)
        XCTAssertNil(response.lines)
    }

    func testRawFileBuildsExpectedQueryAndReturnsBytes() async throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file/raw")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["path"], "Screenshots/result.png")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
            return (try XCTUnwrap(response), expectedData)
        }

        let response = try await client.rawFileData(sessionID: "abc123", path: "Screenshots/result.png")

        XCTAssertEqual(response, expectedData)
    }

    func testMediaDataBuildsExpectedQueryAndReturnsBytes() async throws {
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let mediaPath = "/Users/hermes/.hermes/browser_screenshots/result image.png"
        let sessionID = "abc123"
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], sessionID)
            XCTAssertEqual(query["path"], mediaPath)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
            return (try XCTUnwrap(response), expectedData)
        }

        let response = try await client.mediaData(sessionID: sessionID, path: mediaPath)

        XCTAssertEqual(response, expectedData)
    }

    @MainActor
    func testFilePreviewExportPayloadUsesLoadedTextContent() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file")

            return apiTestJSONResponse("""
            {
              "path": "Sources/Notes.txt",
              "content": "hello\\n",
              "size": 6,
              "lines": 1
            }
            """, for: request)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Sources/Notes.txt",
            apiClient: client
        )

        await viewModel.load()
        let payload = try await viewModel.exportPayload()

        XCTAssertEqual(payload.data, Data("hello\n".utf8))
        XCTAssertEqual(payload.filename, "Notes.txt")
        XCTAssertTrue(payload.contentType.conforms(to: .text))
        XCTAssertFalse(payload.isImage)
    }

    @MainActor
    func testFilePreviewExportPayloadFetchesRawDataForUnsupportedPreview() async throws {
        let rawData = Data([0x50, 0x4B, 0x03, 0x04])
        var requestedPaths: [String] = []
        let client = makeClient { request in
            requestedPaths.append(request.url?.path ?? "nil")
            XCTAssertEqual(request.url?.path, "/api/file/raw")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "session-abc")
            XCTAssertEqual(query["path"], "Build/archive.zip")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/zip"]
            )
            return (try XCTUnwrap(response), rawData)
        }
        let viewModel = try FilePreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            path: "Build/archive.zip",
            apiClient: client
        )

        await viewModel.load()
        let payload = try await viewModel.exportPayload()

        if case .unavailable = viewModel.preview {
            XCTAssertTrue(true)
        } else {
            XCTFail("Zip files should keep the unsupported-preview state.")
        }
        XCTAssertEqual(payload.data, rawData)
        XCTAssertEqual(payload.filename, "archive.zip")
        XCTAssertEqual(payload.contentType, UTType.zip)
        XCTAssertFalse(payload.isImage)
        XCTAssertEqual(requestedPaths, ["/api/file/raw"])
    }
}
