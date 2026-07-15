import XCTest
@testable import HermesMobile

final class APIClientKanbanTests: APIClientTestCase {
    func testCompatibilityHandshakeUsesOnlyVerifiedGETRequests() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            XCTAssertNil(request.httpBody)

            switch request.url?.path {
            case "/api/kanban/config":
                XCTAssertNil(request.url?.query)
                return apiTestJSONResponse(Self.configurationJSON, for: request)
            case "/api/kanban/boards":
                XCTAssertNil(request.url?.query)
                return apiTestJSONResponse(Self.boardsJSON, for: request)
            case "/api/kanban/board":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "board", value: "main board")])
                return apiTestJSONResponse(Self.boardJSON, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        _ = try await client.kanbanConfiguration()
        _ = try await client.kanbanBoards()
        let board = try await client.kanbanBoard(board: "main board")

        XCTAssertEqual(board.changed, true)
        XCTAssertEqual(board.columns?.first?.cards?.first?.cardID, "card-1")
    }

    func testKanbanCarriesConfiguredCustomHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Proxy"), "enabled")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            return apiTestJSONResponse(Self.configurationJSON, for: request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(
            baseURL: serverURL,
            session: URLSession(configuration: configuration),
            customHeaderProvider: { [CustomHeader(name: "X-Hermes-Proxy", value: "enabled")] }
        )

        _ = try await client.kanbanConfiguration()
    }

    func testNonJSONAndMalformedJSONAreNotAcceptedAsKanban() async throws {
        let nonJSONClient = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>login</html>".utf8))
        }
        await XCTAssertThrowsErrorAsync(try await nonJSONClient.kanbanConfiguration()) { error in
            XCTAssertEqual(error as? KanbanResponseError, .nonJSONContentType)
        }

        let malformedClient = makeClient { request in
            apiTestJSONResponse("{not valid json", for: request)
        }
        await XCTAssertThrowsErrorAsync(try await malformedClient.kanbanConfiguration()) { error in
            guard case APIError.decoding = error else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        }
    }

    func testTolerantModelsKeepUnknownStatusAndIgnoreUnknownFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {
          "changed": true,
          "columns": [{
            "name": "future-status",
            "tasks": [{"id": "card-1", "status": "future-status", "new_field": {"nested": true}}]
          }],
          "new_envelope_field": 17
        }
        """.utf8))

        XCTAssertEqual(snapshot.columns?.first?.cards?.first?.status?.rawValue, "future-status")
        XCTAssertFalse(snapshot.columns?.first?.cards?.first?.status?.isSupported ?? true)
    }

    func testSemanticValidationRejectsMissingSafetyCriticalDataAndMarksUnknownStatusPartial() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(KanbanConfiguration.self, from: Data(Self.configurationJSON.utf8))
        let boards = try decoder.decode(KanbanBoardsResponse.self, from: Data(Self.boardsJSON.utf8))
        let snapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data(Self.boardJSON.utf8))

        let report = try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boards,
            snapshot: snapshot
        )
        XCTAssertFalse(report.isPartial)

        let missingCurrent = try decoder.decode(KanbanBoardsResponse.self, from: Data(#"{"boards": []}"#.utf8))
        XCTAssertThrowsError(
            try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: missingCurrent,
                snapshot: snapshot
            )
        ) { error in
            XCTAssertEqual(error as? KanbanContractViolation, .missingCurrentBoard)
        }

        let futureSnapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {"changed":true,"read_only":false,"columns":[{"name":"future","tasks":[{"id":"card-1","status":"future"}]}]}
        """.utf8))
        let partialReport = try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boards,
            snapshot: futureSnapshot
        )
        XCTAssertEqual(partialReport.warnings, [.unsupportedStatus("future")])

        let incompleteSnapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {"read_only":false,"columns":[{"name":"triage","tasks":[]}]}
        """.utf8))
        XCTAssertThrowsError(
            try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: boards,
                snapshot: incompleteSnapshot
            )
        ) { error in
            XCTAssertEqual(error as? KanbanContractViolation, .missingBoardSnapshot)
        }

        let caseMismatchedSnapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {"changed":true,"read_only":false,"columns":[{"name":"TRIAGE","tasks":[{"id":"card-1","status":"TRIAGE"}]}]}
        """.utf8))
        let exactStatusReport = try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boards,
            snapshot: caseMismatchedSnapshot
        )
        XCTAssertEqual(exactStatusReport.warnings, [.unsupportedStatus("TRIAGE")])
    }

    private static let configurationJSON = """
    {"columns":["triage","todo","ready"],"assignees":["work"],"read_only":false}
    """

    private static let boardsJSON = """
    {"boards":[{"slug":"main board","name":"Main","is_current":true,"total":1}],"current":"main board","read_only":false}
    """

    private static let boardJSON = """
    {"changed":true,"latest_event_id":7,"read_only":false,"columns":[{"name":"triage","tasks":[{"id":"card-1","title":"Safe read","status":"triage"}]}]}
    """
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error, but none was thrown")
    } catch {
        errorHandler(error)
    }
}
