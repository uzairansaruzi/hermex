import XCTest
@testable import HermesMobile

final class CustomHeaderModelTests: XCTestCase {
    func testDecodeIsTolerantOfMissingField() {
        let decoded = [CustomHeader].decodeFromStorage(#"[{"name":"X-Only-Name"}]"#)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "X-Only-Name")
        XCTAssertEqual(decoded.first?.value, "")
    }

    func testIsApplicableRejectsBlankNamesAndNewlineInjection() {
        XCTAssertFalse(CustomHeader(name: "   ", value: "x").isApplicable)
        XCTAssertFalse(CustomHeader(name: "X-Inject\nEvil", value: "x").isApplicable)
        XCTAssertFalse(CustomHeader(name: "X-Ok", value: "line1\nline2").isApplicable)
        XCTAssertTrue(CustomHeader(name: "  X-Trim  ", value: "  Bearer spaced  ").isApplicable)
    }

    func testIsApplicableRejectsNonTokenHeaderNames() {
        XCTAssertFalse(CustomHeader(name: "X Bad", value: "v").isApplicable)
        XCTAssertFalse(CustomHeader(name: "X:Bad", value: "v").isApplicable)
        XCTAssertFalse(CustomHeader(name: "Aut\u{007F}h", value: "v").isApplicable)
        XCTAssertTrue(CustomHeader(name: "X-Api-Key", value: "v").isApplicable)
        XCTAssertTrue(CustomHeader(name: "Authorization", value: "Bearer a b c").isApplicable)
    }
}

final class CustomHeaderAuthStatusDecodeTests: XCTestCase {
    private func decode(_ json: String) throws -> AuthStatusResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AuthStatusResponse.self, from: Data(json.utf8))
    }

    func testMissingNewFlagsDecodeToNil() throws {
        let status = try decode(#"{"auth_enabled": true}"#)

        XCTAssertEqual(status.authEnabled, true)
        XCTAssertNil(status.passwordAuthEnabled)
    }
}

final class CustomHeaderAPIClientInjectionTests: APIClientTestCase {
    private func makeHeaderClient(
        _ customHeaders: [CustomHeader],
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (client: APIClient, session: URLSession) {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: session,
            customHeaderProvider: { customHeaders }
        )
        return (client, session)
    }

    private func ok(_ request: URLRequest, body: String = "{}") throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
        )
        return (response, Data(body.utf8))
    }

    func testJSONRequestCarriesCustomHeadersAndBuiltInsWin() async throws {
        let (client, _) = makeHeaderClient([
            CustomHeader(name: "Authorization", value: "Bearer abc"),
            CustomHeader(name: "X-Api-Key", value: "k1"),
            CustomHeader(name: "Accept", value: "application/evil")
        ]) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "k1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return try self.ok(request)
        }

        _ = try? await client.sessions()
    }

    func testUploadRequestCarriesCustomHeadersAndMultipartContentTypeWins() async throws {
        let (client, _) = makeHeaderClient([
            CustomHeader(name: "Authorization", value: "Bearer upload"),
            CustomHeader(name: "Content-Type", value: "application/evil")
        ]) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer upload")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary="),
                true
            )
            return try self.ok(request)
        }

        _ = try? await client.uploadFile(sessionID: "s1", data: Data("bytes".utf8), filename: "a.png")
    }

    func testDownloadRequestCarriesCustomHeaders() async throws {
        let (client, session) = makeHeaderClient([
            CustomHeader(name: "Authorization", value: "Bearer media")
        ]) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer media")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
            return try self.ok(request, body: "binary")
        }

        _ = try? await client.downloadData(
            from: URL(string: "https://example.test/api/media?path=/x.png")!,
            using: session,
            mapsUnauthorized: false
        )
    }

    func testDownloadFromExternalOriginOmitsCustomHeaders() async throws {
        let (client, session) = makeHeaderClient([
            CustomHeader(name: "Authorization", value: "Bearer secret")
        ]) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return try self.ok(request, body: "img")
        }

        _ = try? await client.downloadData(
            from: URL(string: "https://third-party.example/image.png")!,
            using: session,
            mapsUnauthorized: false
        )
    }
}

@MainActor
final class CustomHeaderSSEInjectionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSSEStreamCarriesCustomHeadersUnderBuiltIns() async throws {
        let captured = expectation(description: "sse request captured")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sse")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            captured.fulfill()

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("event: stream_end\ndata: {}\n\n".utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = SSEClient(
            urlSessionConfiguration: configuration,
            customHeaderProvider: {
                [
                    CustomHeader(name: "Authorization", value: "Bearer sse"),
                    CustomHeader(name: "Accept", value: "application/evil")
                ]
            }
        )

        client.start(url: URL(string: "https://example.test/api/chat/stream?stream_id=s1")!) { _ in }
        await fulfillment(of: [captured], timeout: 2)
        client.stop()
    }

    func testSSEStreamSourcesHeadersFromActiveServerStore() async throws {
        let previous = CustomHeaderStore.shared.snapshot()
        defer { CustomHeaderStore.shared.replace(with: previous) }
        CustomHeaderStore.shared.replace(with: [CustomHeader(name: "Authorization", value: "Bearer active-a")])

        let captured = expectation(description: "sse request captured")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer active-a")
            captured.fulfill()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("event: stream_end\ndata: {}\n\n".utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = SSEClient(urlSessionConfiguration: configuration)

        client.start(url: URL(string: "https://a.test/api/chat/stream?stream_id=s1")!) { _ in }
        await fulfillment(of: [captured], timeout: 2)
        client.stop()
    }
}

@MainActor
final class CustomHeaderAuthManagerTests: XCTestCase {
    private func makeManager(
        keychain: InMemoryKeychainStore,
        store: CustomHeaderStore,
        client: MockAuthAPIClient
    ) -> AuthManager {
        AuthManager(keychain: keychain, clientFactory: { _ in client }, headerStore: store, serverRegistry: ServerRegistry.inMemory())
    }

    func testConfigurePersistsHeadersOnSuccess() async throws {
        let keychain = InMemoryKeychainStore()
        let store = CustomHeaderStore()
        let manager = makeManager(
            keychain: keychain,
            store: store,
            client: MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false))
        )

        await manager.configure(
            serverURLString: "https://proxy.test",
            password: "",
            customHeaders: [CustomHeader(name: "Authorization", value: "Bearer abc")]
        )

        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://proxy.test"))))
        XCTAssertEqual(store.snapshot().map(\.name), ["Authorization"])
        let saved = try XCTUnwrap(keychain.scopedValue(.customHeaders, scope: "https://proxy.test"))
        XCTAssertEqual([CustomHeader].decodeFromStorage(saved).map(\.value), ["Bearer abc"])
        XCTAssertNil(keychain.savedValues[.customHeaders])
    }

    func testPasskeyOnlyServerShowsSpecificMessageAndDoesNotLogIn() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, passwordAuthEnabled: false))
        let manager = makeManager(keychain: keychain, store: CustomHeaderStore(), client: client)

        await manager.configure(serverURLString: "https://example.test", password: "secret")

        XCTAssertEqual(manager.lastErrorMessage, AuthManager.passkeyOnlyMessage)
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertEqual(client.loginPasswords, [])
        XCTAssertNil(keychain.savedValues[.serverURL])
    }

    func testTrustedHeaderServerThatAlreadySignedUsInIsSavedWithoutLogin() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(
            authEnabled: true,
            loggedIn: true,
            passwordAuthEnabled: false,
            trustedAuthEnabled: true
        ))
        let manager = makeManager(keychain: keychain, store: CustomHeaderStore(), client: client)

        await manager.configure(serverURLString: "https://example.test", password: "")

        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertEqual(client.loginPasswords, [], "There is no credential to send.")
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://example.test"))))
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://example.test")
    }

    func testTrustedHeaderServerWithoutASessionExplainsTheProxy() async throws {
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(
            authEnabled: true,
            loggedIn: false,
            passwordAuthEnabled: false,
            trustedAuthEnabled: true
        ))
        let manager = makeManager(keychain: InMemoryKeychainStore(), store: CustomHeaderStore(), client: client)

        await manager.configure(serverURLString: "https://example.test", password: "")

        XCTAssertEqual(manager.lastErrorMessage, AuthManager.trustedAuthNotSignedInMessage)
        XCTAssertEqual(manager.state, .unconfigured)
    }

    func testAddServerAcceptsAServerThatAlreadySignedUsIn() async throws {
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(
            authEnabled: true,
            loggedIn: true,
            passwordAuthEnabled: false,
            trustedAuthEnabled: true
        ))
        let manager = AuthManager(
            keychain: InMemoryKeychainStore(),
            probeClientFactory: { _, _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        let outcome = await manager.addServer(serverURLString: "https://example.test", password: "")

        XCTAssertEqual(outcome, .added(try XCTUnwrap(URL(string: "https://example.test"))))
        XCTAssertEqual(client.loginPasswords, [])
    }

    func testMissingPasswordFlagFallsThroughToPasswordLogin() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = makeManager(keychain: keychain, store: CustomHeaderStore(), client: client)

        await manager.configure(serverURLString: "https://example.test", password: "secret")

        XCTAssertEqual(client.loginPasswords, ["secret"])
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://example.test"))))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testHeadersKeptOnSessionExpiryButClearedOnSignOut() async throws {
        let keychain = InMemoryKeychainStore()
        let store = CustomHeaderStore()
        let manager = makeManager(
            keychain: keychain,
            store: store,
            client: MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false))
        )

        await manager.configure(
            serverURLString: "https://proxy.test",
            password: "",
            customHeaders: [CustomHeader(name: "Authorization", value: "Bearer abc")]
        )
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://proxy.test"))

        manager.handleAPIError(APIError.unauthorized)
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://proxy.test"))
        XCTAssertEqual(store.snapshot().map(\.name), ["Authorization"])

        await manager.signOut()
        XCTAssertNil(keychain.scopedValue(.customHeaders, scope: "https://proxy.test"))
        XCTAssertEqual(store.snapshot(), [])
    }

    func testUpdateCustomHeadersDropsBlankRowsAndPersists() async throws {
        let keychain = InMemoryKeychainStore()
        let store = CustomHeaderStore()
        let manager = makeManager(
            keychain: keychain,
            store: store,
            client: MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        )
        await manager.configure(serverURLString: "https://example.test", password: "")

        manager.updateCustomHeaders([
            CustomHeader(name: "X-Keep", value: "1"),
            CustomHeader(name: "   ", value: "ghost")
        ])

        XCTAssertEqual(store.snapshot().map(\.name), ["X-Keep"])
        XCTAssertEqual(
            [CustomHeader].decodeFromStorage(
                keychain.scopedValue(.customHeaders, scope: "https://example.test")
            ).map(\.name),
            ["X-Keep"]
        )
    }

    func testLaunchMigratesLegacyGlobalHeadersToActiveServerScope() throws {
        let keychain = InMemoryKeychainStore()
        let encoded = try XCTUnwrap([CustomHeader(name: "Authorization", value: "Bearer saved")].encodedForStorage())
        try keychain.save(encoded, forKey: .customHeaders)
        try keychain.save("https://legacy.test", forKey: .serverURL)
        let store = CustomHeaderStore()

        _ = makeManager(
            keychain: keychain,
            store: store,
            client: MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        )

        XCTAssertEqual(store.snapshot().map(\.value), ["Bearer saved"])
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://legacy.test"))
        XCTAssertNil(keychain.savedValues[.customHeaders])
    }
}

final class RedirectingMockURLProtocol: URLProtocol {
    struct Redirect {
        let fromPath: String
        let to: URL
    }

    static var redirect: Redirect?
    static var beforeRedirect: (() -> Void)?
    static var secondHopRequest: URLRequest?

    static func reset() {
        redirect = nil
        beforeRedirect = nil
        secondHopRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let redirect = Self.redirect, request.url?.path == redirect.fromPath {
            Self.beforeRedirect?()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.to.absoluteString]
            )!
            var followUp = URLRequest(url: redirect.to)
            followUp.httpMethod = request.httpMethod
            followUp.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
            return
        }

        Self.secondHopRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CrossOriginRedirectHeaderTests: XCTestCase {
    private let baseURL = URL(string: "https://example.test")!

    override func tearDown() {
        RedirectingMockURLProtocol.reset()
        super.tearDown()
    }

    private func redirectOutcome(
        guardHeaders: [CustomHeader],
        destination: String,
        requestHeaders: [String: String],
        method: String = "GET"
    ) throws -> URLRequest? {
        let stripper = CrossOriginHeaderStripper(baseURL: baseURL, sentHeaders: guardHeaders)
        var newRequest = URLRequest(url: try XCTUnwrap(URL(string: destination)))
        newRequest.httpMethod = method
        for (name, value) in requestHeaders {
            newRequest.setValue(value, forHTTPHeaderField: name)
        }
        let response = try XCTUnwrap(
            HTTPURLResponse(url: newRequest.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        let dummy = URLSession(configuration: .ephemeral)
        let task = dummy.dataTask(with: try XCTUnwrap(URL(string: "https://example.test")))
        var result: URLRequest??
        stripper.urlSession(dummy, task: task, willPerformHTTPRedirection: response, newRequest: newRequest) {
            result = $0
        }
        return try XCTUnwrap(result, "guard did not call the completion handler")
    }

    func testRefusesCrossOriginRedirectOfARequestWithABody() throws {
        let outgoing = try redirectOutcome(
            guardHeaders: [],
            destination: "https://third-party.example/leak",
            requestHeaders: [:],
            method: "POST"
        )

        XCTAssertNil(outgoing)
    }

    func testFollowsSameOriginRedirectOfARequestWithABody() throws {
        let outgoing = try redirectOutcome(
            guardHeaders: [],
            destination: "https://example.test/api/auth/login/",
            requestHeaders: [:],
            method: "POST"
        )

        XCTAssertEqual(outgoing?.httpMethod, "POST")
    }

    func testKeepsCustomHeadersOnSameOriginRedirect() throws {
        let outgoing = try XCTUnwrap(redirectOutcome(
            guardHeaders: [CustomHeader(name: "X-Api-Key", value: "k1")],
            destination: "https://example.test/api/media-final",
            requestHeaders: ["X-Api-Key": "k1"]
        ))

        XCTAssertEqual(outgoing.value(forHTTPHeaderField: "X-Api-Key"), "k1")
    }

    private func delegateLessRedirectingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func clientSendingAPIKey() -> APIClient {
        APIClient(baseURL: baseURL, customHeaderProvider: {
            [CustomHeader(name: "X-Api-Key", value: "k1")]
        })
    }

    func testStripsCustomHeaderEndToEndOnURLProtocolRedirect() async throws {
        RedirectingMockURLProtocol.redirect = .init(
            fromPath: "/api/media",
            to: try XCTUnwrap(URL(string: "https://third-party.example/leak"))
        )
        let session = delegateLessRedirectingSession()
        defer { session.invalidateAndCancel() }

        _ = try? await clientSendingAPIKey().downloadData(
            from: try XCTUnwrap(URL(string: "https://example.test/api/media?path=/x.png")),
            using: session,
            mapsUnauthorized: false
        )

        let secondHop = try XCTUnwrap(RedirectingMockURLProtocol.secondHopRequest)
        XCTAssertEqual(secondHop.url?.host, "third-party.example")
        XCTAssertNil(secondHop.value(forHTTPHeaderField: "X-Api-Key"))
    }

    func testStripsSentHeaderOnRedirectAfterTheStoreIsReplaced() async throws {
        let store = CustomHeaderStore(headers: [CustomHeader(name: "X-Api-Key", value: "k1")])
        RedirectingMockURLProtocol.redirect = .init(
            fromPath: "/health",
            to: try XCTUnwrap(URL(string: "https://third-party.example/leak"))
        )
        RedirectingMockURLProtocol.beforeRedirect = { store.replace(with: []) }
        let session = delegateLessRedirectingSession()
        defer { session.invalidateAndCancel() }
        let client = APIClient(baseURL: baseURL, session: session, customHeaderProvider: { store.snapshot() })

        _ = try? await client.sendData(endpoint: .health, method: "GET")

        let secondHop = try XCTUnwrap(RedirectingMockURLProtocol.secondHopRequest)
        XCTAssertEqual(secondHop.url?.host, "third-party.example")
        XCTAssertNil(secondHop.value(forHTTPHeaderField: "X-Api-Key"))
    }

    func testDefaultClientsShareDelegateLessSessions() async {
        let first = APIClient(baseURL: baseURL)
        let second = APIClient(baseURL: URL(string: "https://other.test")!)
        let session = await first.session
        let publicMediaSession = await first.publicMediaSession

        let secondSession = await second.session
        let secondPublicMediaSession = await second.publicMediaSession
        XCTAssertTrue(session === secondSession)
        XCTAssertTrue(publicMediaSession === secondPublicMediaSession)
        XCTAssertFalse(session === publicMediaSession)
        XCTAssertNil(session.delegate)
        XCTAssertNil(publicMediaSession.delegate)
        XCTAssertTrue(session.configuration.httpCookieStorage === HTTPCookieStorage.shared)
        XCTAssertNil(publicMediaSession.configuration.httpCookieStorage)
    }
}
