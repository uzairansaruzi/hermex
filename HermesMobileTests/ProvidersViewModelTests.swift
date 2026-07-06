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
    func testLoadFailureSetsErrorMessageAndKeepsEmptyList() async {
        let client = makeClient { request in
            (HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!, Data())
        }
        let model = ProvidersViewModel(server: Self.serverURL, client: client)

        await model.load()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    /// A failed pull-to-refresh must keep the cached providers *and* surface the
    /// error — the view shows a refresh-failure banner above the stale rows.
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

    /// `load()` has three overlapping entry points (`.task`, `.refreshable`,
    /// "Try Again"). When two loads race and their responses land out of order,
    /// the older response must be discarded: it may not overwrite newer provider
    /// data or the newer load's state (#42 Codex review).
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

        // A newer load starts while the first request is still in flight …
        let freshLoad = Task { await model.load() }
        await fulfillment(of: [secondRequestArrived], timeout: 5)

        // … and its response lands first.
        requests.request(at: 1).complete(withJSON: """
        { "active_provider": "fresh", "providers": [ { "id": "fresh" } ] }
        """)
        await freshLoad.value
        XCTAssertEqual(model.providers.map(\.id), ["fresh"])
        XCTAssertFalse(model.isLoading)

        // The stale response lands afterwards — it must be discarded.
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
    func testActiveProviderMatchingIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(ProvidersViewModel.normalizedProviderID("  OpenAI-Codex \n"), "openai-codex")
        XCTAssertNil(ProvidersViewModel.normalizedProviderID("   "))
        XCTAssertNil(ProvidersViewModel.normalizedProviderID(nil))
    }

    @MainActor
    func testDisplayNameFallsBackFromDisplayNameToIDToPlaceholder() {
        XCTAssertEqual(
            ProvidersViewModel.displayName(for: ProviderSummary(id: "openai", displayName: "OpenAI")),
            "OpenAI"
        )
        XCTAssertEqual(
            ProvidersViewModel.displayName(for: ProviderSummary(id: "openai", displayName: "  ")),
            "openai"
        )
        XCTAssertEqual(
            ProvidersViewModel.displayName(for: ProviderSummary(id: nil)),
            String(localized: "Unknown provider")
        )
    }

    @MainActor
    func testKeySourceBadgeCollapsesUpstreamVocabulary() {
        func badge(_ keySource: String?, hasKey: Bool? = true) -> String? {
            ProvidersViewModel.keySourceBadge(
                for: ProviderSummary(id: "p", hasKey: hasKey, keySource: keySource)
            )
        }

        XCTAssertEqual(badge("env_file"), "env")
        XCTAssertEqual(badge("env_var"), "env")
        XCTAssertEqual(badge("env"), "env")
        XCTAssertEqual(badge("oauth"), "OAuth")
        XCTAssertEqual(badge("token"), "OAuth")
        XCTAssertEqual(badge("config_yaml"), "config")
        XCTAssertEqual(badge("config"), "config")
        XCTAssertEqual(badge(" OAuth "), "OAuth")

        // Unknown future sources pass through instead of being hidden.
        XCTAssertEqual(badge("keychain"), "keychain")

        // No badge without a key, or when the source is missing/none.
        XCTAssertNil(badge("none"))
        XCTAssertNil(badge(nil))
        XCTAssertNil(badge("oauth", hasKey: false))
        XCTAssertNil(badge("oauth", hasKey: nil))
    }

    @MainActor
    func testAuthErrorTextTrimsAndDropsEmptyValues() {
        XCTAssertEqual(
            ProvidersViewModel.authErrorText(
                for: ProviderSummary(id: "p", authError: "  token expired \n")
            ),
            "token expired"
        )
        XCTAssertNil(ProvidersViewModel.authErrorText(for: ProviderSummary(id: "p", authError: "   ")))
        XCTAssertNil(ProvidersViewModel.authErrorText(for: ProviderSummary(id: "p", authError: nil)))
    }

    @MainActor
    func testExpansionKeyPrefersStableProviderIDWithIndexFallback() {
        XCTAssertEqual(ProvidersView.expansionKey(for: ProviderSummary(id: " openai "), at: 3), "openai")
        XCTAssertEqual(ProvidersView.expansionKey(for: ProviderSummary(id: "   "), at: 3), "#3")
        XCTAssertEqual(ProvidersView.expansionKey(for: ProviderSummary(id: nil), at: 0), "#0")
    }

    @MainActor
    func testModelCountPrefersModelsTotalWhenListIsTrimmed() {
        let trimmed = ProviderSummary(
            id: "nous",
            models: [ProviderModel(id: "a"), ProviderModel(id: "b")],
            modelsTotal: 396
        )
        XCTAssertEqual(ProvidersViewModel.modelCount(for: trimmed), 396)
        let info = ProvidersViewModel.truncatedModelInfo(for: trimmed)
        XCTAssertEqual(info?.shown, 2)
        XCTAssertEqual(info?.total, 396)

        let complete = ProviderSummary(
            id: "openai",
            models: [ProviderModel(id: "a"), ProviderModel(id: "b")],
            modelsTotal: 2
        )
        XCTAssertEqual(ProvidersViewModel.modelCount(for: complete), 2)
        XCTAssertNil(ProvidersViewModel.truncatedModelInfo(for: complete))

        // No visible models -> no truncation footer even if a total is reported.
        let hidden = ProviderSummary(id: "p", models: [], modelsTotal: 4)
        XCTAssertNil(ProvidersViewModel.truncatedModelInfo(for: hidden))

        let bare = ProviderSummary(id: "p")
        XCTAssertEqual(ProvidersViewModel.modelCount(for: bare), 0)
        XCTAssertNil(ProvidersViewModel.truncatedModelInfo(for: bare))
    }
}

/// URLProtocol whose responses are completed manually by the test, so two
/// in-flight requests can be answered out of order (the shared
/// `MockURLProtocol` answers synchronously inside `startLoading`, which
/// serializes responses in request order).
private final class DeferredProvidersMockURLProtocol: URLProtocol {
    /// Called (on a URLSession worker thread) whenever a request starts loading.
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

/// Thread-safe collector for the deferred requests above (`onRequest` fires on
/// URLSession worker threads).
private final class DeferredProvidersRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DeferredProvidersMockURLProtocol] = []

    /// Appends the request and returns its 1-based arrival order.
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
