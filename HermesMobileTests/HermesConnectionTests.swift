import XCTest
@testable import HermesMobile

/// The shared HTTP side of a saved Bot connection, against a scripted host. Consumers are
/// real `BotClient`s and `BotDashboardClient`s on one `HermesConnection`.
@MainActor final class HermesConnectionTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private let cloudflare = CustomHeader(name: "Authorization",
                                          value: #"{"cf-access-client-id":"id.access","cf-access-client-secret":"secret"}"#)
    private let access = CustomHeader(name: "X-Access", value: "token")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testConsumersShareOneSignInAndOneCookieJar() async throws {
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil })
        let chat = BotClient(http: http) { _ in BotScriptedSocket() }
        let inbox = BotClient(http: http) { _ in BotScriptedSocket() }
        let provisioning = BotDashboardClient(http: http)
        async let chatConnected: Void = chat.connect()
        async let inboxConnected: Void = inbox.connect()
        async let provisioningSignedIn: Void = provisioning.signIn()
        _ = try await (chatConnected, inboxConnected, provisioningSignedIn)
        try await provisioning.setPlugin("hermex-push", enabled: false)
        defer { chat.close(); inbox.close() }

        XCTAssertEqual(["/api/status", "/auth/password-login", "/api/auth/me"].map(HermesHostFixture.count), [1, 1, 1])
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 2, "Each socket still mints its own ticket")
        XCTAssertEqual(HermesHostFixture.count("/api/dashboard/agent-plugins/hermex-push/disable"), 1)
        let jar = try XCTUnwrap(http.session.configuration.httpCookieStorage)
        XCTAssertTrue(http.provisioningSession.configuration.httpCookieStorage === jar)
    }

    /// Each step runs on a fresh connection, and its request is held at the host while the
    /// sessions' in-flight tasks are read, so the test sees the session it went out on.
    func testOnlyProvisioningAndItsSignInGoOutOnTheLongDeadlineSession() async throws {
        var parking: String?
        let configuration = HermesHostFixture.configuration { request in request.url?.path == parking ? .park : nil }
        let connect: (HermesConnection) async throws -> Void = { http in
            let chat = BotClient(http: http) { _ in BotScriptedSocket() }
            try await chat.connect()
            chat.close()
        }
        let steps: [(path: String, provisioning: Bool, run: (HermesConnection) async throws -> Void)] = [
            ("/auth/password-login", false, connect),
            ("/api/auth/ws-ticket", false, connect),
            ("/auth/password-login", true, { try await BotDashboardClient(http: $0).signIn() }),
            ("/api/dashboard/agent-plugins/install", true, { try await BotDashboardClient(http: $0).installPlugin(identifier: "hermex-push") }),
            ("/api/dashboard/agent-plugins/hermex-push/enable", true, { try await BotDashboardClient(http: $0).setPlugin("hermex-push", enabled: true) }),
            ("/api/gateway/restart", true, { try await BotDashboardClient(http: $0).restartGateway() })
        ]

        let sessions = HermesConnection(connection: record, configuration: configuration)
        let standard = sessions.session.configuration, long = sessions.provisioningSession.configuration
        XCTAssertGreaterThan(long.timeoutIntervalForRequest, standard.timeoutIntervalForRequest)
        XCTAssertGreaterThan(long.timeoutIntervalForResource, standard.timeoutIntervalForResource)

        for step in steps {
            let http = HermesConnection(connection: record, configuration: configuration)
            let parked = expectation(description: "\(step.path) in flight")
            HermesHostFixture.onPark = { parked.fulfill() }
            HermesHostFixture.script { parking = step.path }
            let running = Task { try await step.run(http) }
            await fulfillment(of: [parked], timeout: 2)
            let onStandard = await http.session.allTasks.contains { $0.originalRequest?.url?.path == step.path }
            let onLong = await http.provisioningSession.allTasks.contains { $0.originalRequest?.url?.path == step.path }
            HermesHostFixture.releaseParked()
            try await running.value
            XCTAssertEqual([onStandard, onLong], [!step.provisioning, step.provisioning], step.path)
        }
    }

    func testCancellingOneWaitingConsumerLeavesTheSignInToTheOthers() async throws {
        let parked = expectation(description: "login in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        var logins = 0
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            guard request.url?.path == "/auth/password-login" else { return nil }
            logins += 1
            return logins == 1 ? .park : nil
        })
        let leaving = BotClient(http: http) { _ in BotScriptedSocket() }
        let staying = BotClient(http: http) { _ in BotScriptedSocket() }
        let left = Task { try await leaving.connect() }
        await fulfillment(of: [parked], timeout: 2)
        let stays = Task { try await staying.connect() }
        left.cancel()
        HermesHostFixture.releaseParked(.json(200, .object([:])))
        try await stays.value
        defer { staying.close() }
        do { try await left.value; XCTFail("The cancelled consumer must not connect") } catch {}
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1)
        XCTAssertEqual(HermesHostFixture.count("/api/auth/me"), 1)
    }

    /// Both requests reach the host before either 401 is answered, so both recover from
    /// the same expired session.
    func testConcurrent401sShareOneSignInAndResendOnlyTheRejectedRequests() async throws {
        let rejected = expectation(description: "both requests in flight")
        rejected.expectedFulfillmentCount = 2
        HermesHostFixture.onPark = { rejected.fulfill() }
        var expired = false
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/auth/password-login": expired = false; return nil
            case "/api/plugins/hermex-push/pairing", "/api/profiles/old-bot": return expired ? .park : nil
            default: return nil
            }
        })
        try await http.signIn()
        HermesHostFixture.script { expired = true }
        async let pairing = http.data(.pushPairing)
        async let deletion = http.data(.deleteProfile(name: "old-bot"))
        await fulfillment(of: [rejected], timeout: 2)
        HermesHostFixture.releaseParked(.json(401, .object(["error": .string("session_expired")])))
        _ = try await (pairing, deletion)

        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 2, "One recovery for both")
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/hermex-push/pairing"), 2)
        XCTAssertEqual(HermesHostFixture.count("/api/profiles/old-bot"), 2, "A write the gate refused is resent once")
    }

    /// Each request is refused with 401 and its recovery sign-in is held at the host while
    /// the screen closes, so only an ownership check can stop the resend.
    func testAScreenClosedDuringTheSharedSignInDoesNotResendItsRequest() async throws {
        let context = BotArtifactContext(connectionID: record.id, profile: "inbox-triage", sessionID: "tip", generation: 1)
        let requests: [(path: String, send: (BotClient) async throws -> Void)] = [
            ("/api/profiles/old-bot", { try await $0.deleteProfile("old-bot") }),
            ("/api/chat/image-upload", { _ = try await $0.uploadImage(data: Data([1]), filename: "a.png", context: context) }),
            ("/api/fs/download", { _ = try await $0.artifactData(path: "report.pdf", context: context) })
        ]
        for request in requests {
            HermesHostFixture.reset()
            let parked = expectation(description: "\(request.path): recovery sign-in in flight")
            HermesHostFixture.onPark = { parked.fulfill() }
            var expired = false
            let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { sent in
                guard expired else { return nil }
                switch sent.url?.path {
                case "/auth/password-login": return .park
                case request.path: return .json(401, .object(["error": .string("session_expired")]))
                default: return nil
                }
            })
            let screen = BotClient(http: http) { _ in BotScriptedSocket() }
            try await screen.connect()
            HermesHostFixture.script { expired = true }
            let sending = Task { try await request.send(screen) }
            await fulfillment(of: [parked], timeout: 2)
            screen.close()
            HermesHostFixture.releaseParked()
            do { try await sending.value; XCTFail("\(request.path): a closed screen's request must not succeed") } catch {}
            XCTAssertEqual(HermesHostFixture.count(request.path), 1, "\(request.path) is not resent for a closed screen")
        }
    }

    func testFailuresKeepTheSignInAndOnlyRefusedCredentialsSignOut() async throws {
        var next: [String: HermesHostFixture.Reply] = [:]
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            next.removeValue(forKey: request.url?.path ?? "")
        })
        try await http.signIn()
        HermesHostFixture.script { next["/api/plugins/hermex-push/pairing"] = .json(503, .null) }
        do { _ = try await http.data(.pushPairing); XCTFail("A 5xx fails its request") }
        catch { XCTAssertEqual(error as? BotFailure, .rejected(503)) }
        HermesHostFixture.script { next["/api/dashboard/agent-plugins/hermex-push/disable"] = .fail(URLError(.networkConnectionLost)) }
        do { _ = try await http.data(.setPlugin(name: "hermex-push", enabled: false), deadline: .provisioning); XCTFail("Lost reply") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(HermesHostFixture.count("/api/dashboard/agent-plugins/hermex-push/disable"), 1, "An uncertain write is never resent")
        _ = try await http.data(.pushPairing)
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1, "Neither failure signed the connection out")

        HermesHostFixture.script {
            next["/api/plugins/hermex-push/pairing"] = .json(401, .object(["error": .string("session_expired")]))
            next["/auth/password-login"] = .json(401, .object(["detail": .string("Invalid credentials")]))
        }
        do { _ = try await http.data(.pushPairing); XCTFail("Refused credentials end the recovery") }
        catch { XCTAssertEqual(error as? BotFailure, .rejected(401)) }
        XCTAssertEqual(HermesHostFixture.count("/api/plugins/hermex-push/pairing"), 3, "The refused request is not resent")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 2)
        _ = try await http.data(.pushPairing)
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 3, "Signed out: the next request signs in first")
    }

    func testTheRegistryIsolatesServersAccountsAndCredentialsAndKeepsNothingAlive() async throws {
        let registry = HermesConnections()
        let serverA = URL(string: "https://a.example")!, serverB = URL(string: "https://b.example")!
        var saved = record
        let first = registry.connection(for: saved, server: serverA)
        saved.name = "Renamed"
        saved.installID = String(repeating: "a", count: 32)
        XCTAssertTrue(registry.connection(for: saved, server: serverA) === first, "A rename or backfilled install id is the same connection")
        XCTAssertEqual(first.connection.installID, saved.installID)

        var current = first
        let edits: [(String, (inout BotConnection) -> Void)] = [
            ("password", { $0.password = "rotated" }),
            ("account on the same install", { $0 = BotConnection(id: $0.id, name: $0.name, address: $0.address, username: "other",
                                                                 password: $0.password, installID: $0.installID) }),
            ("address on the same install", { $0 = BotConnection(id: $0.id, name: $0.name, address: URL(string: "https://tunnel.example")!,
                                                                 username: $0.username, password: $0.password, installID: $0.installID) })
        ]
        for (edit, apply) in edits {
            apply(&saved)
            let replacement = registry.connection(for: saved, server: serverA)
            XCTAssertFalse(replacement === current, edit)
            await assertStale(edit) { try await current.signIn() }
            current = replacement
        }
        let otherServer = registry.connection(for: saved, server: serverB)
        XCTAssertFalse(otherServer === current, "The same host and account under another server")
        XCTAssertFalse(otherServer.session.configuration.httpCookieStorage === current.session.configuration.httpCookieStorage)
        await assertStale("server switch") { try await current.signIn() }

        weak var released: HermesConnection?
        released = registry.connection(for: record, server: serverA)
        XCTAssertNil(released, "The registry holds its connection only while a consumer does")
    }

    /// The retirement lands while a refused write waits on its recovery sign-in.
    func testARetiredConnectionDropsItsLateSignInAndSendsNothingMore() async throws {
        let parked = expectation(description: "recovery login in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        var expired = false
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            guard expired else { return nil }
            switch request.url?.path {
            case "/auth/password-login": return .park
            case "/api/profiles/old-bot": return .json(401, .object(["error": .string("session_expired")]))
            default: return nil
            }
        })
        try await http.signIn()
        HermesHostFixture.script { expired = true }
        let deletion = Task { try await http.data(.deleteProfile(name: "old-bot")) }
        await fulfillment(of: [parked], timeout: 2)
        http.retire()
        HermesHostFixture.releaseParked(.json(200, .object([:])))
        await assertStale("late recovery") { _ = try await deletion.value }
        XCTAssertEqual(HermesHostFixture.count("/api/profiles/old-bot"), 1, "The refused write is not resent")
        XCTAssertEqual(HermesHostFixture.count("/api/auth/me"), 1, "The late login never went on to the identity read")
        let sent = HermesHostFixture.requests.count
        await assertStale("later request") { _ = try await http.data(.pushPairing) }
        XCTAssertEqual(HermesHostFixture.requests.count, sent, "Nothing more reaches the host")
    }

    func testHeaderPolicyRefusesTransportNamesAndBearerAndKeepsTheCloudflareJSONForm() throws {
        XCTAssertEqual(try HermesHeaders([cloudflare, access]).values, [cloudflare, access])
        let refused: [(CustomHeader, HermesHeaders.Rejection)] = [
            (CustomHeader(name: "Host", value: "other.example"), .reserved("Host")),
            (CustomHeader(name: "cookie", value: "hermes_session=x"), .reserved("cookie")),
            (CustomHeader(name: "Content-Length", value: "1"), .reserved("Content-Length")),
            (CustomHeader(name: "Sec-WebSocket-Protocol", value: "hermes-gateway-v1"), .reserved("Sec-WebSocket-Protocol")),
            (CustomHeader(name: "Authorization", value: "Bearer abc"), .bearer),
            (CustomHeader(name: "authorization", value: " bearer abc"), .bearer),
            (CustomHeader(name: "Bad Name", value: "x"), .malformed("Bad Name")),
            (CustomHeader(name: "X-Access", value: "a\nb"), .malformed("X-Access"))
        ]
        for (header, rejection) in refused {
            XCTAssertThrowsError(try HermesHeaders([access, header]), header.name) { XCTAssertEqual($0 as? HermesHeaders.Rejection, rejection) }
        }
    }

    /// Hermes reads these for its own checks at the pinned commit: the gateway upgrade's
    /// Origin guard, the reverse-proxy prefix that sets the session cookie's path, and the
    /// dashboard's own session token.
    func testHeaderPolicyRefusesTheNamesHermesReadsForItsOwnChecks() {
        for name in ["Origin", "origin", "X-Forwarded-Prefix", "x-forwarded-prefix", "X-Hermes-Session-Token", "X-HERMES-SESSION-TOKEN"] {
            XCTAssertThrowsError(try HermesHeaders([CustomHeader(name: name, value: "x")]), name) {
                XCTAssertEqual($0 as? HermesHeaders.Rejection, .reserved(name))
            }
        }
    }

    /// The active webui server's custom headers are loaded too, and never reach Hermes.
    func testHeadersReachEveryRequestToTheOriginAndTheGatewayUpgradeUnderItsBuiltIns() async throws {
        let previous = CustomHeaderStore.shared.snapshot()
        defer { CustomHeaderStore.shared.replace(with: previous) }
        CustomHeaderStore.shared.replace(with: [CustomHeader(name: "X-Webui-Token", value: "webui")])
        let headers = try HermesHeaders([cloudflare, access, CustomHeader(name: "Content-Type", value: "text/plain")])
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil }, headers: headers)
        var upgrade: URLRequest?
        let client = BotClient(http: http) { request in upgrade = request; return BotScriptedSocket() }
        try await client.connect()
        defer { client.close() }
        let context = BotArtifactContext(connectionID: record.id, profile: "inbox-triage", sessionID: "tip", generation: 1)
        _ = try await client.artifactData(path: "report.pdf", context: context)
        _ = try await client.uploadImage(data: Data([1, 2, 3]), filename: "a.png", context: context)
        try await BotDashboardClient(http: http).setPlugin("hermex-push", enabled: true)

        let requests = HermesHostFixture.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/status", "/auth/password-login", "/api/auth/me", "/api/auth/ws-ticket",
                                                       "/api/fs/download", "/api/chat/image-upload",
                                                       "/api/dashboard/agent-plugins/hermex-push/enable"])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), cloudflare.value, request.url?.path ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access"), "token", request.url?.path ?? "")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Webui-Token"), request.url?.path ?? "")
        }
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "application/json", "The built-in wins")
        let socket = try XCTUnwrap(upgrade)
        XCTAssertEqual(socket.url?.absoluteString, "wss://hermes.example/api/ws")
        XCTAssertEqual(socket.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "hermes-gateway-v1, hermes-gateway-ticket.ticket")
        XCTAssertEqual(socket.value(forHTTPHeaderField: "Authorization"), cloudflare.value)
        XCTAssertEqual(socket.value(forHTTPHeaderField: "X-Access"), "token")
        XCTAssertNil(socket.value(forHTTPHeaderField: "X-Webui-Token"))
    }

    /// The fixture carries the headers onto the redirected request, as a server's redirect
    /// would, so only the connection's redirect guard can remove them.
    func testACrossOriginRedirectDropsTheHeadersBeforeTheRelay() async throws {
        let relay = HermexPushPlugin.defaultRelayURL.appendingPathComponent("api/status")
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            request.url?.host == "hermes.example" && request.url?.path == "/api/status" ? .redirect(relay) : nil
        }, headers: try HermesHeaders([cloudflare, access]))
        try await http.signIn()
        let hop = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.host == relay.host })
        XCTAssertNil(hop.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(hop.value(forHTTPHeaderField: "X-Access"))
        let login = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/auth/password-login" })
        XCTAssertEqual(login.value(forHTTPHeaderField: "X-Access"), "token", "Requests to the origin keep them")
    }

    private func assertStale(_ label: String, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("\(label): expected stale") }
        catch { XCTAssertEqual(error as? BotFailure, .stale, label) }
    }
}

/// A scripted direct Hermes host. `script` may answer a request by path; nil gives the
/// host's ordinary signed-in reply. A parked request waits for `releaseParked`. The script
/// runs under the fixture's lock, and `script(_:)` changes its state under the same lock.
private final class HermesHostFixture: URLProtocol {
    enum Reply { case json(Int, BotJSON), fail(URLError), redirect(URL), park }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: ((URLRequest) -> Reply?)?
    nonisolated(unsafe) private static var log: [URLRequest] = []
    nonisolated(unsafe) private static var waiting: [HermesHostFixture] = []
    nonisolated(unsafe) static var onPark: (() -> Void)?
    private var stopped = false

    static func configuration(_ answer: @escaping (URLRequest) -> Reply?) -> URLSessionConfiguration {
        lock.withLock { self.answer = answer }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesHostFixture.self]
        return configuration
    }

    static func script(_ change: () -> Void) { lock.withLock { change() } }
    static var requests: [URLRequest] { lock.withLock { log } }
    static func count(_ path: String) -> Int { requests.filter { $0.url?.path == path }.count }

    /// Answers every parked request with `reply`, or with the host's ordinary reply when nil.
    static func releaseParked(_ reply: Reply? = nil) {
        let parked = lock.withLock { let parked = waiting; waiting = []; return parked }
        for fixture in parked where !fixture.stopped { fixture.respond(reply ?? ordinary(fixture.request)) }
    }

    static func reset() {
        lock.withLock { answer = nil; log = []; waiting = [] }
        onPark = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.log.append(request)
            return Self.answer?(request)
        } ?? Self.ordinary(request)
        guard case .park = reply else { return respond(reply) }
        Self.lock.withLock { Self.waiting.append(self) }
        Self.onPark?()
    }

    override func stopLoading() { stopped = true }

    private func respond(_ reply: Reply) {
        let url = request.url!
        switch reply {
        case .json(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(body)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            var followUp = URLRequest(url: target)
            followUp.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
        case .park: break
        }
    }

    /// A 0.21.5 host with the password gate, and a plain success for every other route.
    private static func ordinary(_ request: URLRequest) -> Reply {
        switch request.url?.path {
        case "/api/status":
            return .json(200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                       "version": .string("0.21.5")]))
        case "/api/auth/me": return .json(200, .object(["provider": .string("basic")]))
        case "/api/auth/ws-ticket": return .json(200, .object(["ticket": .string("ticket")]))
        default: return .json(200, .object(["ok": .bool(true), "path": .string("/profile/images/a.png")]))
        }
    }
}
