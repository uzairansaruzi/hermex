import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class ContractReadinessTests: XCTestCase {
    func testEndpointContractMatrixMatchesPinnedUpstreamPaths() throws {
        let contracts: [EndpointContract] = [
            .init(name: "health", method: "GET", endpoint: .health, path: "/health"),
            .init(name: "auth status", method: "GET", endpoint: .authStatus, path: "/api/auth/status"),
            .init(name: "login", method: "POST", endpoint: .login, path: "/api/auth/login"),
            .init(name: "logout", method: "POST", endpoint: .logout, path: "/api/auth/logout"),
            .init(name: "sessions", method: "GET", endpoint: .sessions(), path: "/api/sessions"),
            .init(
                name: "sessions including archived",
                method: "GET",
                endpoint: .sessions(includeArchived: true, archivedLimit: 3),
                path: "/api/sessions",
                query: ["include_archived": "1", "archived_limit": "3"]
            ),
            .init(
                name: "sessions including archived without limit",
                method: "GET",
                endpoint: .sessions(includeArchived: true),
                path: "/api/sessions",
                query: ["include_archived": "1"]
            ),
            .init(
                name: "session search",
                method: "GET",
                endpoint: .sessionsSearch(query: "billing plan", content: true, depth: 5),
                path: "/api/sessions/search",
                query: ["q": "billing plan", "content": "1", "depth": "5"]
            ),
            .init(
                name: "session detail",
                method: "GET",
                endpoint: .session(id: "session-123", includeMessages: true, messageLimit: 50, messageBefore: 100),
                path: "/api/session",
                query: ["session_id": "session-123", "messages": "1", "msg_limit": "50", "msg_before": "100"]
            ),
            .init(
                name: "session detail cold load expand_renderable",
                method: "GET",
                endpoint: .session(id: "session-123", includeMessages: true, messageLimit: 50, messageBefore: nil, expandRenderable: true),
                path: "/api/session",
                query: ["session_id": "session-123", "messages": "1", "msg_limit": "50", "expand_renderable": "1"]
            ),
            .init(
                name: "session status",
                method: "GET",
                endpoint: .sessionStatus(id: "session-123"),
                path: "/api/session/status",
                query: ["session_id": "session-123"]
            ),
            .init(name: "new session", method: "POST", endpoint: .newSession, path: "/api/session/new"),
            .init(name: "rename session", method: "POST", endpoint: .renameSession, path: "/api/session/rename"),
            .init(name: "delete session", method: "POST", endpoint: .deleteSession, path: "/api/session/delete"),
            .init(name: "pin session", method: "POST", endpoint: .pinSession, path: "/api/session/pin"),
            .init(name: "archive session", method: "POST", endpoint: .archiveSession, path: "/api/session/archive"),
            .init(name: "branch session", method: "POST", endpoint: .branchSession, path: "/api/session/branch"),
            .init(name: "compress session", method: "POST", endpoint: .compressSession, path: "/api/session/compress"),
            .init(name: "undo session", method: "POST", endpoint: .undoSession, path: "/api/session/undo"),
            .init(name: "retry session", method: "POST", endpoint: .retrySession, path: "/api/session/retry"),
            .init(name: "truncate session", method: "POST", endpoint: .truncateSession, path: "/api/session/truncate"),
            .init(name: "update session", method: "POST", endpoint: .updateSession, path: "/api/session/update"),
            .init(name: "move session", method: "POST", endpoint: .moveSession, path: "/api/session/move"),
            .init(
                name: "session yolo",
                method: "GET",
                endpoint: .sessionYolo(sessionID: "session-123"),
                path: "/api/session/yolo",
                query: ["session_id": "session-123"]
            ),
            .init(name: "projects", method: "GET", endpoint: .projects, path: "/api/projects"),
            .init(name: "create project", method: "POST", endpoint: .createProject, path: "/api/projects/create"),
            .init(name: "rename project", method: "POST", endpoint: .renameProject, path: "/api/projects/rename"),
            .init(name: "delete project", method: "POST", endpoint: .deleteProject, path: "/api/projects/delete"),
            .init(name: "chat start", method: "POST", endpoint: .chatStart, path: "/api/chat/start"),
            .init(
                name: "chat stream",
                method: "GET",
                endpoint: .chatStream(streamID: "stream-123"),
                path: "/api/chat/stream",
                query: ["stream_id": "stream-123"]
            ),
            .init(
                name: "chat cancel",
                method: "GET",
                endpoint: .chatCancel(streamID: "stream-123"),
                path: "/api/chat/cancel",
                query: ["stream_id": "stream-123"]
            ),
            .init(
                name: "chat stream status",
                method: "GET",
                endpoint: .chatStreamStatus(streamID: "stream-123"),
                path: "/api/chat/stream/status",
                query: ["stream_id": "stream-123"]
            ),
            .init(name: "chat steer", method: "POST", endpoint: .chatSteer, path: "/api/chat/steer"),
            .init(name: "goal", method: "POST", endpoint: .submitGoal, path: "/api/goal"),
            .init(
                name: "approval pending",
                method: "GET",
                endpoint: .approvalPending(sessionID: "session-123"),
                path: "/api/approval/pending",
                query: ["session_id": "session-123"]
            ),
            .init(
                name: "approval stream",
                method: "GET",
                endpoint: .approvalStream(sessionID: "session-123"),
                path: "/api/approval/stream",
                query: ["session_id": "session-123"]
            ),
            .init(name: "approval respond", method: "POST", endpoint: .approvalRespond, path: "/api/approval/respond"),
            .init(
                name: "clarification pending",
                method: "GET",
                endpoint: .clarifyPending(sessionID: "session-123"),
                path: "/api/clarify/pending",
                query: ["session_id": "session-123"]
            ),
            .init(
                name: "clarification stream",
                method: "GET",
                endpoint: .clarifyStream(sessionID: "session-123"),
                path: "/api/clarify/stream",
                query: ["session_id": "session-123"]
            ),
            .init(name: "clarification respond", method: "POST", endpoint: .clarifyRespond, path: "/api/clarify/respond"),
            .init(name: "btw", method: "POST", endpoint: .btw, path: "/api/btw"),
            .init(name: "background", method: "POST", endpoint: .background, path: "/api/background"),
            .init(
                name: "background status",
                method: "GET",
                endpoint: .backgroundStatus(sessionID: "session-123"),
                path: "/api/background/status",
                query: ["session_id": "session-123"]
            ),
            .init(name: "workspaces", method: "GET", endpoint: .workspaces, path: "/api/workspaces"),
            .init(
                name: "workspace suggestions",
                method: "GET",
                endpoint: .workspaceSuggestions(prefix: "/Users/uzair"),
                path: "/api/workspaces/suggest",
                query: ["prefix": "/Users/uzair"]
            ),
            .init(name: "workspace add", method: "POST", endpoint: .workspaceAdd, path: "/api/workspaces/add"),
            .init(name: "workspace remove", method: "POST", endpoint: .workspaceRemove, path: "/api/workspaces/remove"),
            .init(name: "workspace rename", method: "POST", endpoint: .workspaceRename, path: "/api/workspaces/rename"),
            .init(name: "workspace reorder", method: "POST", endpoint: .workspaceReorder, path: "/api/workspaces/reorder"),
            .init(
                name: "directory list root",
                method: "GET",
                endpoint: .directoryList(sessionID: "session-123", path: nil),
                path: "/api/list",
                query: ["session_id": "session-123"]
            ),
            .init(
                name: "directory list nested",
                method: "GET",
                endpoint: .directoryList(sessionID: "session-123", path: "Sources/App.swift"),
                path: "/api/list",
                query: ["session_id": "session-123", "path": "Sources/App.swift"]
            ),
            .init(
                name: "file",
                method: "GET",
                endpoint: .file(sessionID: "session-123", path: "Sources/App.swift"),
                path: "/api/file",
                query: ["session_id": "session-123", "path": "Sources/App.swift"]
            ),
            .init(
                name: "raw file",
                method: "GET",
                endpoint: .rawFile(sessionID: "session-123", path: "Assets/icon.png"),
                path: "/api/file/raw",
                query: ["session_id": "session-123", "path": "Assets/icon.png"]
            ),
            .init(
                name: "media",
                method: "GET",
                endpoint: .media(path: "Assets/icon.png"),
                path: "/api/media",
                query: ["path": "Assets/icon.png"]
            ),
            .init(name: "models", method: "GET", endpoint: .models, path: "/api/models"),
            .init(name: "models live", method: "GET", endpoint: .modelsLive, path: "/api/models/live"),
            .init(name: "commands", method: "GET", endpoint: .commands, path: "/api/commands"),
            .init(name: "default model", method: "POST", endpoint: .defaultModel, path: "/api/default-model"),
            .init(name: "reasoning read", method: "GET", endpoint: .reasoning(), path: "/api/reasoning"),
            .init(
                name: "reasoning read scoped to model",
                method: "GET",
                endpoint: .reasoning(model: "gpt-5.4", provider: "openai"),
                path: "/api/reasoning",
                query: ["model": "gpt-5.4", "provider": "openai"]
            ),
            .init(name: "reasoning save", method: "POST", endpoint: .reasoning(), path: "/api/reasoning"),
            .init(name: "personalities", method: "GET", endpoint: .personalities, path: "/api/personalities"),
            .init(name: "set personality", method: "POST", endpoint: .setPersonality, path: "/api/personality/set"),
            .init(name: "profiles", method: "GET", endpoint: .profiles, path: "/api/profiles"),
            .init(name: "switch profile", method: "POST", endpoint: .switchProfile, path: "/api/profile/switch"),
            .init(name: "create profile", method: "POST", endpoint: .createProfile, path: "/api/profile/create"),
            .init(name: "providers", method: "GET", endpoint: .providers, path: "/api/providers"),
            .init(name: "settings", method: "GET", endpoint: .settings, path: "/api/settings"),
            .init(
                name: "insights",
                method: "GET",
                endpoint: .insights(days: 30),
                path: "/api/insights",
                query: ["days": "30"]
            ),
            .init(name: "crons", method: "GET", endpoint: .crons, path: "/api/crons"),
            .init(name: "cron create", method: "POST", endpoint: .cronCreate, path: "/api/crons/create"),
            .init(name: "cron update", method: "POST", endpoint: .cronUpdate, path: "/api/crons/update"),
            .init(name: "cron delete", method: "POST", endpoint: .cronDelete, path: "/api/crons/delete"),
            .init(name: "cron run", method: "POST", endpoint: .cronRun, path: "/api/crons/run"),
            .init(name: "cron pause", method: "POST", endpoint: .cronPause, path: "/api/crons/pause"),
            .init(name: "cron resume", method: "POST", endpoint: .cronResume, path: "/api/crons/resume"),
            .init(name: "cron status all", method: "GET", endpoint: .cronStatus(jobID: nil), path: "/api/crons/status"),
            .init(
                name: "cron status job",
                method: "GET",
                endpoint: .cronStatus(jobID: "job-123"),
                path: "/api/crons/status",
                query: ["job_id": "job-123"]
            ),
            .init(
                name: "cron output",
                method: "GET",
                endpoint: .cronOutput(jobID: "job-123", limit: 5),
                path: "/api/crons/output",
                query: ["job_id": "job-123", "limit": "5"]
            ),
            .init(
                name: "cron delivery options",
                method: "GET",
                endpoint: .cronDeliveryOptions,
                path: "/api/crons/delivery-options"
            ),
            .init(name: "memory", method: "GET", endpoint: .memory, path: "/api/memory"),
            .init(name: "memory write", method: "POST", endpoint: .memoryWrite, path: "/api/memory/write"),
            .init(name: "skills", method: "GET", endpoint: .skills, path: "/api/skills"),
            .init(
                name: "skill content",
                method: "GET",
                endpoint: .skillContent(name: "swiftui-ui-patterns", file: nil),
                path: "/api/skills/content",
                query: ["name": "swiftui-ui-patterns"]
            ),
            .init(
                name: "skill linked file",
                method: "GET",
                endpoint: .skillContent(name: "swiftui-ui-patterns", file: "references/navigation.md"),
                path: "/api/skills/content",
                query: ["name": "swiftui-ui-patterns", "file": "references/navigation.md"]
            ),
            .init(name: "upload", method: "POST", endpoint: .upload, path: "/api/upload")
        ]

        let baseURL = URL(string: "https://example.test")!

        for contract in contracts {
            let url = contract.endpoint.url(relativeTo: baseURL)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false), contract.name)

            XCTAssertEqual(components.path, contract.path, contract.name)
            XCTAssertEqual(queryDictionary(from: components), contract.query, contract.name)
            XCTAssertTrue(["GET", "POST"].contains(contract.method), contract.name)
        }
    }

    func testJSONPostRequestsOmitBrowserCSRFHeaders() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/pin")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "pinned": true
              }
            }
            """, for: request)
        }

        let response = try await client.pinSession(id: "abc123", pinned: true)

        XCTAssertEqual(response.ok, true)
    }

    func testMultipartPostRequestsOmitBrowserCSRFHeaders() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)

            return apiTestJSONResponse("""
            {
              "filename": "contract.txt",
              "path": "/tmp/workspace/contract.txt",
              "size": 8,
              "mime": "text/plain",
              "is_image": false
            }
            """, for: request)
        }

        let response = try await client.uploadFile(sessionID: "abc123", data: Data("contract".utf8), filename: "contract.txt")

        XCTAssertEqual(response.filename, "contract.txt")
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }

    private func queryDictionary(from components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private struct EndpointContract {
    let name: String
    let method: String
    let endpoint: Endpoint
    let path: String
    let query: [String: String]

    init(name: String, method: String, endpoint: Endpoint, path: String, query: [String: String] = [:]) {
        self.name = name
        self.method = method
        self.endpoint = endpoint
        self.path = path
        self.query = query
    }
}
