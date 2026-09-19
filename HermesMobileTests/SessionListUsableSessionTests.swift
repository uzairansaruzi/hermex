import XCTest
@testable import HermesMobile

/// Covers `SessionListViewModel.mostRecentUsableSession`, the session the Files
/// browser binds to in order to read a workspace. Picking the wrong one silently
/// browses another workspace's files, so each rule gets its own case.
final class SessionListUsableSessionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testPrefersTheNewestSessionThatCarriesAWorkspace() async throws {
        let viewModel = try makeViewModel([
            session(id: "older-with-workspace", title: "Older", workspace: "alpha", lastMessageAt: 100),
            session(id: "newer-without-workspace", title: "Newer", lastMessageAt: 200)
        ])

        await viewModel.load()

        XCTAssertEqual(viewModel.mostRecentUsableSession?.sessionId, "older-with-workspace")
    }

    @MainActor
    func testFallsBackToTheNewestSessionWhenNoSessionCarriesAWorkspace() async throws {
        let viewModel = try makeViewModel([
            session(id: "older", title: "Older", lastMessageAt: 100),
            session(id: "newer", title: "Newer", lastMessageAt: 200)
        ])

        await viewModel.load()

        XCTAssertEqual(viewModel.mostRecentUsableSession?.sessionId, "newer")
    }

    @MainActor
    func testOrdersCandidatesByLastMessageThenUpdatedThenCreated() async throws {
        let viewModel = try makeViewModel([
            session(id: "created-only", title: "Created", workspace: "alpha", createdAt: 500),
            session(id: "updated", title: "Updated", workspace: "alpha", createdAt: 100, updatedAt: 600),
            session(
                id: "messaged",
                title: "Messaged",
                workspace: "alpha",
                createdAt: 100,
                updatedAt: 200,
                lastMessageAt: 700
            )
        ])

        await viewModel.load()

        XCTAssertEqual(viewModel.mostRecentUsableSession?.sessionId, "messaged")
    }

    @MainActor
    func testPrefersTheWorkspaceCarrierOverANewerSessionWithoutOne() async throws {
        let viewModel = try makeViewModel([
            session(id: "workspace", title: "Workspace", workspace: "alpha", createdAt: 100),
            session(id: "newer-plain", title: "Newer plain", createdAt: 900)
        ])

        await viewModel.load()

        XCTAssertEqual(viewModel.mostRecentUsableSession?.sessionId, "workspace")
    }

    @MainActor
    func testIsNilWhenNoSessionHasAnIdentifier() async throws {
        let viewModel = try makeViewModel([
            session(id: nil, title: "No identifier", workspace: "alpha", lastMessageAt: 100),
            session(id: "", title: "Blank identifier", workspace: "alpha", lastMessageAt: 200)
        ])

        await viewModel.load()

        XCTAssertNil(viewModel.mostRecentUsableSession)
    }

    @MainActor
    private func makeViewModel(_ sessionPayloads: [String]) throws -> SessionListViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = try makeClient(server: server, sessionPayloads: sessionPayloads)

        return SessionListViewModel(server: server, client: client)
    }

    private func makeClient(server: URL, sessionPayloads: [String]) throws -> APIClient {
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/api/sessions" else {
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }

            let payload = """
            {
              "sessions": [
                \(sessionPayloads.joined(separator: ",\n        "))
              ],
              "archived_count": 0
            }
            """

            return apiTestJSONResponse(payload, for: request)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        return APIClient(baseURL: server, session: URLSession(configuration: configuration))
    }

    /// One `sessions[]` entry, carrying only the fields a case cares about. An
    /// omitted `session_id` decodes to nil, which is not a usable browser session.
    private func session(
        id: String?,
        title: String,
        workspace: String? = nil,
        createdAt: Double? = nil,
        updatedAt: Double? = nil,
        lastMessageAt: Double? = nil
    ) -> String {
        var fields: [String] = []

        if let id {
            fields.append("\"session_id\": \"\(id)\"")
        }

        fields.append("\"title\": \"\(title)\"")

        if let workspace {
            fields.append("\"workspace\": \"\(workspace)\"")
        }

        if let createdAt {
            fields.append("\"created_at\": \(createdAt)")
        }

        if let updatedAt {
            fields.append("\"updated_at\": \(updatedAt)")
        }

        if let lastMessageAt {
            fields.append("\"last_message_at\": \(lastMessageAt)")
        }

        return "{ \(fields.joined(separator: ", ")) }"
    }
}
