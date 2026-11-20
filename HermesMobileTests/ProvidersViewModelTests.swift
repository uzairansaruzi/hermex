import XCTest
@testable import HermesMobile

final class ProvidersViewModelTests: APIClientTestCase {
    private static let serverURL = URL(string: "https://example.test")!

    @MainActor
    func testLoadPopulatesProvidersPreservingServerOrder() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/providers")
            return apiTestJSONResponse("""
            {
              "active_provider": "openai-codex",
              "providers": [
                { "id": "openai-codex", "display_name": "OpenAI Codex", "has_key": true },
                { "id": "anthropic", "display_name": "Anthropic", "has_key": false },
                { "id": "custom:glmcode", "display_name": "glmcode", "has_key": true }
              ]
            }
            """, for: request)
        }
        let model = ProvidersViewModel(server: Self.serverURL, client: client)

        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.providers.map(\.id), ["openai-codex", "anthropic", "custom:glmcode"])
        XCTAssertEqual(model.activeProviderID, "openai-codex")
        XCTAssertTrue(model.isActive(model.providers[0]))
        XCTAssertFalse(model.isActive(model.providers[1]))
    }

    @MainActor
    func testRefreshFailureKeepsCachedProvidersAndSetsErrorMessage() async {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "active_provider": "anthropic",
              "providers": [
                { "id": "anthropic", "display_name": "Anthropic", "has_key": true }
              ]
            }
            """, for: request)
        }
        let model = ProvidersViewModel(server: Self.serverURL, client: client)

        await model.load()
        XCTAssertEqual(model.providers.map(\.id), ["anthropic"])
        XCTAssertNil(model.errorMessage)

        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!, Data())
        }

        await model.load()

        XCTAssertEqual(model.providers.map(\.id), ["anthropic"], "cached providers must survive a failed refresh")
        XCTAssertNotNil(model.errorMessage, "the failed refresh must be surfaced")
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testStaleOverlappingLoadDoesNotOverwriteNewerResponse() async throws {
        let firstRequestArrived = expectation(description: "stale request arrived")
        let secondRequestArrived = expectation(description: "fresh request arrived")
        let requests = DeferredProvidersRequests()

        DeferredProvidersMockURLProtocol.onRequest = { pendingRequest in
            switch requests.append(pendingRequest) {
            case 1: firstRequestArrived.fulfill()
            case 2: secondRequestArrived.fulfill()
            default: XCTFail("unexpected extra providers request")
            }
        }
        defer { DeferredProvidersMockURLProtocol.onRequest = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredProvidersMockURLProtocol.self]
        let client = APIClient(baseURL: Self.serverURL, session: URLSession(configuration: configuration))
        let model = ProvidersViewModel(server: Self.serverURL, client: client)

        let staleLoad = Task { await model.load() }
        await fulfillment(of: [firstRequestArrived], timeout: 5)

        let freshLoad = Task { await model.load() }
        await fulfillment(of: [secondRequestArrived], timeout: 5)

        requests.request(at: 1).complete(withJSON: """
        { "active_provider": "fresh", "providers": [ { "id": "fresh" } ] }
        """)
        await freshLoad.value
        XCTAssertEqual(model.providers.map(\.id), ["fresh"])
        XCTAssertFalse(model.isLoading)

        requests.request(at: 0).complete(withJSON: """
        { "active_provider": "stale", "providers": [ { "id": "stale" } ] }
        """)
        await staleLoad.value

        XCTAssertEqual(model.providers.map(\.id), ["fresh"], "a stale response must not overwrite newer data")
        XCTAssertEqual(model.activeProviderID, "fresh")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testExpansionKeyPrefersStableProviderIDWithIndexFallback() {
        XCTAssertEqual(ProvidersView.expansionKey(for: ProviderSummary(id: " openai "), at: 3), "openai")
        XCTAssertEqual(ProvidersView.expansionKey(for: ProviderSummary(id: "   "), at: 3), "#3")
        XCTAssertEqual(ProvidersView.expansionKey(for: ProviderSummary(id: nil), at: 0), "#0")
    }

    @MainActor
    func testModelCountLabelShowsShownOverTotalOnlyWhenTrimmed() {
        let trimmed = ProviderSummary(
            id: "nous",
            models: [ProviderModel(id: "a"), ProviderModel(id: "b")],
            modelsTotal: 396
        )
        XCTAssertEqual(ProvidersViewModel.modelCountLabel(for: trimmed), "2 / 396")

        let complete = ProviderSummary(
            id: "openai",
            models: [ProviderModel(id: "a"), ProviderModel(id: "b")],
            modelsTotal: 2
        )
        XCTAssertEqual(ProvidersViewModel.modelCountLabel(for: complete), "2")

        let hidden = ProviderSummary(id: "p", models: [], modelsTotal: 4)
        XCTAssertEqual(ProvidersViewModel.modelCountLabel(for: hidden), "4")

        XCTAssertNil(ProvidersViewModel.modelCountLabel(for: ProviderSummary(id: "p")))
    }
}

private final class DeferredProvidersMockURLProtocol: URLProtocol {
    static var onRequest: ((DeferredProvidersMockURLProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let onRequest = Self.onRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        onRequest(self)
    }

    override func stopLoading() {}

    func complete(withJSON json: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DeferredProvidersRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DeferredProvidersMockURLProtocol] = []

    func append(_ request: DeferredProvidersMockURLProtocol) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pending.append(request)
        return pending.count
    }

    func request(at index: Int) -> DeferredProvidersMockURLProtocol {
        lock.lock()
        defer { lock.unlock() }
        return pending[index]
    }
}
