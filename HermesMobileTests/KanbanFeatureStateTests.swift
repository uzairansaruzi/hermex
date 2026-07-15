import XCTest
@testable import HermesMobile

@MainActor
final class KanbanFeatureStateTests: XCTestCase {
    func testCompatibleHandshakeIsOrderedAndBoundToItsServer() async {
        let client = KanbanClientStub()
        let firstServer = URL(string: "https://first.example.test")!
        let secondServer = URL(string: "https://second.example.test")!
        let first = KanbanFeatureState(server: firstServer, client: client)
        let second = KanbanFeatureState(server: secondServer, client: client)

        await first.load()

        XCTAssertEqual(first.state, .compatible)
        XCTAssertEqual(first.server, firstServer)
        XCTAssertEqual(second.state, .idle)
        XCTAssertEqual(second.server, secondServer)
        let calls = await client.calls()
        XCTAssertEqual(calls, [.configuration, .boards, .board("main")])
    }

    func testAuthenticationForwardsToExistingHandler() async {
        let client = KanbanClientStub(configurationResult: .failure(APIError.unauthorized))
        var forwardedErrors: [Error] = []
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: client,
            onAPIError: { forwardedErrors.append($0) }
        )

        await state.load()

        XCTAssertEqual(state.state, .authenticationRequired)
        XCTAssertEqual(forwardedErrors.count, 1)
        XCTAssertTrue(forwardedErrors.first is APIError)
    }

    func testNetworkServerAndContractFailuresStayDistinct() async {
        let network = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(APIError.network(underlying: URLError(.notConnectedToInternet))))
        )
        await network.load()
        XCTAssertEqual(network.state, .networkUnavailable)

        let server = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(APIError.http(statusCode: 503, body: nil)))
        )
        await server.load()
        XCTAssertEqual(server.state, .serverUnavailable)

        let contract = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(KanbanResponseError.nonJSONContentType))
        )
        await contract.load()
        XCTAssertEqual(contract.state, .incompatibleContract)
    }

    func testCancelledHandshakeReturnsToIdle() async {
        let state = KanbanFeatureState(
            server: URL(string: "https://example.test")!,
            client: KanbanClientStub(configurationResult: .failure(CancellationError()))
        )

        await state.load()

        XCTAssertEqual(state.state, .idle)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.report)
    }

    func testStaleHandshakeCompletionCannotReplaceNewerResult() async {
        let client = DeferredFirstConfigurationClient()
        let state = KanbanFeatureState(server: URL(string: "https://example.test")!, client: client)

        let firstLoad = Task { await state.load() }
        await client.waitForFirstConfiguration()

        await state.load()
        XCTAssertEqual(state.state, .compatible)

        await client.resumeFirstConfiguration()
        await firstLoad.value

        XCTAssertEqual(state.state, .compatible)
        XCTAssertFalse(state.isLoading)
    }
}

private actor KanbanClientStub: KanbanDataClient {
    enum Call: Equatable { case configuration, boards, board(String) }

    private let configurationResult: Result<KanbanConfiguration, Error>
    private let boardsResult: Result<KanbanBoardsResponse, Error>
    private let boardResult: Result<KanbanBoardSnapshot, Error>
    private var recordedCalls: [Call] = []

    init(
        configurationResult: Result<KanbanConfiguration, Error> = .success(KanbanFixtures.configuration),
        boardsResult: Result<KanbanBoardsResponse, Error> = .success(KanbanFixtures.boards),
        boardResult: Result<KanbanBoardSnapshot, Error> = .success(KanbanFixtures.snapshot)
    ) {
        self.configurationResult = configurationResult
        self.boardsResult = boardsResult
        self.boardResult = boardResult
    }

    func kanbanConfiguration() throws -> KanbanConfiguration {
        recordedCalls.append(.configuration)
        return try configurationResult.get()
    }

    func kanbanBoards() throws -> KanbanBoardsResponse {
        recordedCalls.append(.boards)
        return try boardsResult.get()
    }

    func kanbanBoard(board: String) throws -> KanbanBoardSnapshot {
        recordedCalls.append(.board(board))
        return try boardResult.get()
    }

    func calls() -> [Call] { recordedCalls }
}

private actor DeferredFirstConfigurationClient: KanbanDataClient {
    private var configurationCalls = 0
    private var continuation: CheckedContinuation<KanbanConfiguration, Error>?

    func kanbanConfiguration() async throws -> KanbanConfiguration {
        configurationCalls += 1
        if configurationCalls == 1 {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return KanbanFixtures.configuration
    }

    func kanbanBoards() throws -> KanbanBoardsResponse { KanbanFixtures.boards }
    func kanbanBoard(board: String) throws -> KanbanBoardSnapshot { KanbanFixtures.snapshot }

    func waitForFirstConfiguration() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstConfiguration() {
        continuation?.resume(returning: KanbanFixtures.configuration)
        continuation = nil
    }
}

private enum KanbanFixtures {
    static let configuration = decode(KanbanConfiguration.self, #"{"columns":["triage"],"read_only":false}"#)
    static let boards = decode(KanbanBoardsResponse.self, #"{"boards":[{"slug":"main","name":"Main"}],"current":"main","read_only":false}"#)
    static let snapshot = decode(KanbanBoardSnapshot.self, #"{"changed":true,"read_only":false,"columns":[{"name":"triage","tasks":[]}]}"#)

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(T.self, from: Data(json.utf8))
    }
}
