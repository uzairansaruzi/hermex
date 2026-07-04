import XCTest
@testable import HermesMobile

// MARK: - Model, storage, and store

final class CustomHeaderModelTests: XCTestCase {
    func testStorageRoundTripPreservesNameAndValueAndOrder() throws {
        let headers = [
            CustomHeader(name: "Authorization", value: "Bearer abc"),
            CustomHeader(name: "X-Api-Key", value: "k1")
        ]

        let encoded = try XCTUnwrap(headers.encodedForStorage())
        let decoded = [CustomHeader].decodeFromStorage(encoded)

        XCTAssertEqual(decoded, headers)
        XCTAssertEqual(decoded.map(\.name), ["Authorization", "X-Api-Key"])
        XCTAssertEqual(decoded.map(\.value), ["Bearer abc", "k1"])
    }

    func testEmptyListEncodesToNilAndGarbageDecodesToEmpty() {
        XCTAssertNil([CustomHeader]().encodedForStorage())
        XCTAssertEqual([CustomHeader].decodeFromStorage(nil), [])
        XCTAssertEqual([CustomHeader].decodeFromStorage("not json"), [])
        XCTAssertEqual([CustomHeader].decodeFromStorage(#"{"unexpected":true}"#), [])
    }

    func testDecodeIsTolerantOfMissingField() {
        // A row missing "value" decodes with an empty value rather than dropping
        // the whole list (tolerant decoding rule).
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
        XCTAssertFalse(CustomHeader(name: "X Bad", value: "v").isApplicable)        // space
        XCTAssertFalse(CustomHeader(name: "X:Bad", value: "v").isApplicable)        // colon
        XCTAssertFalse(CustomHeader(name: "Aut\u{007F}h", value: "v").isApplicable) // control char
        XCTAssertTrue(CustomHeader(name: "X-Api-Key", value: "v").isApplicable)
        // Internal spaces are fine in a value (e.g. "Bearer <token>").
        XCTAssertTrue(CustomHeader(name: "Authorization", value: "Bearer a b c").isApplicable)
    }

    func testSanitizedForStorageDropsBlankNameRowsOnly() {
        let headers = [
            CustomHeader(name: "X-Keep", value: "1"),
            CustomHeader(name: "   ", value: "ghost"),
            CustomHeader(name: "", value: "")
        ]

        XCTAssertEqual(headers.sanitizedForStorage().map(\.name), ["X-Keep"])
    }

    func testStoreSnapshotReflectsReplace() {
        let store = CustomHeaderStore()
        XCTAssertEqual(store.snapshot(), [])

        store.replace(with: [CustomHeader(name: "A", value: "1")])
        XCTAssertEqual(store.snapshot().map(\.name), ["A"])

        store.replace(with: [])
        XCTAssertEqual(store.snapshot(), [])
    }

    func testMergedUnderBuiltInsLetsBuiltInsWin() {
        let merged = [
            CustomHeader(name: "Accept", value: "application/evil"),
            CustomHeader(name: "Authorization", value: "Bearer abc")
        ].merged(under: ["Accept": "text/event-stream"])

        XCTAssertEqual(merged["Accept"], "text/event-stream")
        XCTAssertEqual(merged["Authorization"], "Bearer abc")
    }
}

// MARK: - AuthStatusResponse tolerant decode

final class CustomHeaderAuthStatusDecodeTests: XCTestCase {
    private func decode(_ json: String) throws -> AuthStatusResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AuthStatusResponse.self, from: Data(json.utf8))
    }

    func testDecodesNewCapabilityFlags() throws {
        let status = try decode(
            """
            {
              "auth_enabled": true,
              "password_auth_enabled": false,
              "passkeys_enabled": true,
              "passwordless_enabled": true
            }
            """
        )

        XCTAssertEqual(status.authEnabled, true)
        XCTAssertEqual(status.passwordAuthEnabled, false)
        XCTAssertEqual(status.passkeysEnabled, true)
        XCTAssertEqual(status.passwordlessEnabled, true)
    }

    func testMissingNewFlagsDecodeToNil() throws {
        let status = try decode(#"{"auth_enabled": true}"#)

        XCTAssertEqual(status.authEnabled, true)
        XCTAssertNil(status.passwordAuthEnabled)
        XCTAssertNil(status.passkeysEnabled)
        XCTAssertNil(status.passwordlessEnabled)
    }

    func testUnknownFieldsAreIgnored() throws {
        let status = try decode(#"{"auth_enabled": false, "future_field": "x"}"#)

        XCTAssertEqual(status.authEnabled, false)
        XCTAssertNil(status.passwordAuthEnabled)
    }
}

// MARK: - APIClient request injection

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
            // Built-in Accept is set after the custom headers, so it wins its key.
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return try self.ok(request)
        }

        _ = try? await client.sessions()
    }

    func testEmptyHeaderListIsANoOp() async throws {
        let (client, _) = makeHeaderClient([]) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return try self.ok(request)
        }

        _ = try? await client.sessions()
    }

    func testWhitespaceOnlyHeaderNameIsSkipped() async throws {
        let (client, _) = makeHeaderClient([
            CustomHeader(name: "   ", value: "ghost"),
            CustomHeader(name: "X-Real", value: "ok")
        ]) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Real"), "ok")
            // The blank-named row contributes nothing.
            XCTAssertEqual(request.allHTTPHeaderFields?.values.contains("ghost"), false)
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
            // The built-in multipart Content-Type is set after the custom
            // headers, so it wins its key.
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary="),
                true
            )
            return try self.ok(request)
        }

        _ = try? await client.uploadFile(sessionID: "s1", data: Data("bytes".utf8), filename: "a.png")
    }

    func testTranscribeRequestCarriesCustomHeaders() async throws {
        let (client, _) = makeHeaderClient([
            CustomHeader(name: "Authorization", value: "Bearer stt")
        ]) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stt")
            return try self.ok(request)
        }

        _ = try? await client.transcribeAudio(data: Data("clip".utf8), filename: "v.m4a")
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
            // A third-party transcript image must never receive the (possibly
            // secret) custom headers — off-origin leak guard.
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

// MARK: - SSE stream injection

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
            // Built-in Accept must win over a user-supplied Accept.
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

    /// The default SSE header provider reads `CustomHeaderStore.shared`, which holds
    /// only the active server's headers (#16) — so the stream carries the active
    /// server's proxy header, never another configured server's.
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
        // No explicit provider → uses the default active-server store.
        let client = SSEClient(urlSessionConfiguration: configuration)

        client.start(url: URL(string: "https://a.test/api/chat/stream?stream_id=s1")!) { _ in }
        await fulfillment(of: [captured], timeout: 2)
        client.stop()
    }

    /// SSE streams against `HTTPCookieStorage.shared`, the same jar as `APIClient`.
    /// Verify that jar only surfaces a server's own cookie for its stream URL, so
    /// domain isolation covers the SSE stream too (#16).
    func testSSESharedCookieJarIsDomainIsolatedPerStreamURL() throws {
        let storage = HTTPCookieStorage.shared
        storage.cookies?.forEach { storage.deleteCookie($0) }
        defer { storage.cookies?.forEach { storage.deleteCookie($0) } }

        func sessionCookie(host: String, value: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [
                .domain: host, .path: "/", .name: "hermes_session", .value: value
            ]))
        }
        storage.setCookie(try sessionCookie(host: "a.test", value: "a-cookie"))
        storage.setCookie(try sessionCookie(host: "b.test", value: "b-cookie"))

        let streamA = try XCTUnwrap(URL(string: "https://a.test/api/chat/stream?stream_id=s1"))
        XCTAssertEqual(storage.cookies(for: streamA)?.map(\.value), ["a-cookie"])
    }
}

// MARK: - AuthManager configure / lifecycle

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
        // Headers persist under this server's scoped key, not a global one (#16).
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

    func testMissingPasswordFlagFallsThroughToPasswordLogin() async throws {
        let keychain = InMemoryKeychainStore()
        // authEnabled true but passwordAuthEnabled nil (older server) must NOT be
        // treated as passkey-only — the regression-safety rule from #255.
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = makeManager(keychain: keychain, store: CustomHeaderStore(), client: client)

        await manager.configure(serverURLString: "https://example.test", password: "secret")

        XCTAssertEqual(client.loginPasswords, ["secret"])
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://example.test"))))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testNoHeaderConfigureDoesNotPersistHeaderEntry() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = makeManager(keychain: keychain, store: CustomHeaderStore(), client: client)

        await manager.configure(serverURLString: "https://example.test", password: "secret")

        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://example.test"))))
        XCTAssertNil(keychain.scopedValue(.customHeaders, scope: "https://example.test"))
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

        // Session-expiry keeps the headers so re-login behind the proxy still works.
        manager.handleAPIError(APIError.unauthorized)
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://proxy.test"))
        XCTAssertEqual(store.snapshot().map(\.name), ["Authorization"])

        // Full sign-out forgets the server and its scoped headers.
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
        // The editor is reachable only while signed in, so establish an active
        // server first; headers then persist under that server's scoped key (#16).
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

    func testUpdateCustomHeadersWithoutPersistSkipsKeychain() async throws {
        let keychain = InMemoryKeychainStore()
        let store = CustomHeaderStore()
        let manager = makeManager(
            keychain: keychain,
            store: store,
            client: MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        )
        await manager.configure(serverURLString: "https://example.test", password: "")

        // persist:false → live store refresh but no (slow) Keychain write.
        manager.updateCustomHeaders([CustomHeader(name: "X-Live", value: "1")], persist: false)
        XCTAssertEqual(store.snapshot().map(\.name), ["X-Live"])
        XCTAssertNil(keychain.scopedValue(.customHeaders, scope: "https://example.test"))

        // persist:true (editor dismissed) → now written to the Keychain.
        manager.updateCustomHeaders([CustomHeader(name: "X-Live", value: "1")], persist: true)
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://example.test"))
    }

    func testLaunchMigratesLegacyGlobalHeadersToActiveServerScope() throws {
        let keychain = InMemoryKeychainStore()
        let encoded = try XCTUnwrap([CustomHeader(name: "Authorization", value: "Bearer saved")].encodedForStorage())
        // Pre-#16 state: one global header blob alongside the single saved server.
        try keychain.save(encoded, forKey: .customHeaders)
        try keychain.save("https://legacy.test", forKey: .serverURL)
        let store = CustomHeaderStore()

        _ = makeManager(
            keychain: keychain,
            store: store,
            client: MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        )

        // On launch the blob is hydrated into the live snapshot, moved under the
        // saved server's scoped key, and the global remnant is removed (#16).
        XCTAssertEqual(store.snapshot().map(\.value), ["Bearer saved"])
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://legacy.test"))
        XCTAssertNil(keychain.savedValues[.customHeaders])
    }
}

// MARK: - Cross-origin redirect header stripping (#277)

/// A `URLProtocol` that issues exactly one 3xx redirect for a configured source
/// path, then serves a 200 for every other request — capturing the request of
/// the hop *after* the redirect ("second hop") so a test can assert which headers
/// survived. It carries the first request's headers onto the follow-up to mimic a
/// server redirect; `URLSession` then consults the session's redirect delegate
/// (the system under test), which is what must strip them.
final class RedirectingMockURLProtocol: URLProtocol {
    struct Redirect {
        let fromPath: String
        let to: URL
    }

    static var redirect: Redirect?
    /// The request `URLSession` issued for the hop after the redirect.
    static var secondHopRequest: URLRequest?

    static func reset() {
        redirect = nil
        secondHopRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let redirect = Self.redirect, request.url?.path == redirect.fromPath {
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

    /// Drives the production guard's redirect decision directly: hands it a
    /// synthetic `newRequest` and returns the request the guard passes back to the
    /// URL loading system (what it intends for the next hop). The guard invokes the
    /// completion handler synchronously.
    private func redirectOutcome(
        guardHeaders: [CustomHeader],
        destination: String,
        requestHeaders: [String: String]
    ) throws -> URLRequest {
        let stripper = CrossOriginHeaderStripper(baseURL: baseURL, customHeaderProvider: { guardHeaders })
        var newRequest = URLRequest(url: try XCTUnwrap(URL(string: destination)))
        for (name, value) in requestHeaders {
            newRequest.setValue(value, forHTTPHeaderField: name)
        }
        let response = try XCTUnwrap(
            HTTPURLResponse(url: newRequest.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        let dummy = URLSession(configuration: .ephemeral)
        let task = dummy.dataTask(with: try XCTUnwrap(URL(string: "https://example.test")))
        var result: URLRequest?
        stripper.urlSession(dummy, task: task, willPerformHTTPRedirection: response, newRequest: newRequest) {
            result = $0
        }
        return try XCTUnwrap(result, "guard did not call the completion handler")
    }

    // AC1: same-origin → cross-origin carries none of the custom headers.
    func testStripsCustomHeadersOnCrossOriginRedirect() throws {
        let outgoing = try redirectOutcome(
            guardHeaders: [
                CustomHeader(name: "Authorization", value: "Bearer secret"),
                CustomHeader(name: "X-Api-Key", value: "k1")
            ],
            destination: "https://third-party.example/leak",
            requestHeaders: ["Authorization": "Bearer secret", "X-Api-Key": "k1", "Accept": "*/*"]
        )

        XCTAssertNil(outgoing.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(outgoing.value(forHTTPHeaderField: "Authorization"))
        // Only the *configured* header names are stripped — a built-in like Accept
        // is left alone.
        XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Accept"), "*/*")
    }

    // AC2: same-origin → same-origin keeps the headers (e.g. a proxy path rewrite).
    func testKeepsCustomHeadersOnSameOriginRedirect() throws {
        let outgoing = try redirectOutcome(
            guardHeaders: [CustomHeader(name: "X-Api-Key", value: "k1")],
            destination: "https://example.test/api/media-final",
            requestHeaders: ["X-Api-Key": "k1"]
        )

        XCTAssertEqual(outgoing.value(forHTTPHeaderField: "X-Api-Key"), "k1")
    }

    // AC3: no custom headers configured → a cross-origin redirect is left unchanged.
    func testNoCustomHeadersLeavesCrossOriginRedirectUnchanged() throws {
        let outgoing = try redirectOutcome(
            guardHeaders: [],
            destination: "https://third-party.example/leak",
            requestHeaders: ["Accept": "*/*"]
        )

        XCTAssertEqual(outgoing.value(forHTTPHeaderField: "Accept"), "*/*")
        XCTAssertNil(outgoing.value(forHTTPHeaderField: "X-Api-Key"))
    }

    // AC4: end-to-end via a redirect-emitting URLProtocol — the production guard,
    // wired into the client's session, strips the custom header so the actual
    // second hop on the wire (cross-origin) never carries it. Exercises the real
    // `downloadData` path: the header is applied on the same-origin first hop and
    // removed when the server redirects off-origin.
    func testStripsCustomHeaderEndToEndOnURLProtocolRedirect() async throws {
        RedirectingMockURLProtocol.redirect = .init(
            fromPath: "/api/media",
            to: try XCTUnwrap(URL(string: "https://third-party.example/leak"))
        )
        let client = APIClient(baseURL: baseURL, customHeaderProvider: {
            [CustomHeader(name: "X-Api-Key", value: "k1")]
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingMockURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: client.redirectHeaderStripper,
            delegateQueue: nil
        )

        _ = try? await client.downloadData(
            from: try XCTUnwrap(URL(string: "https://example.test/api/media?path=/x.png")),
            using: session,
            mapsUnauthorized: false
        )

        let secondHop = try XCTUnwrap(RedirectingMockURLProtocol.secondHopRequest)
        XCTAssertEqual(secondHop.url?.host, "third-party.example")
        XCTAssertNil(secondHop.value(forHTTPHeaderField: "X-Api-Key"))
    }
}
