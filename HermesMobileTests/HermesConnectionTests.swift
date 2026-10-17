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
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil },
                                    gateway: .init { _ in BotScriptedSocket() })
        let chat = BotClient(http: http)
        let inbox = BotClient(http: http)
        let provisioning = BotDashboardClient(http: http)
        async let chatConnected: Void = chat.connect()
        async let inboxConnected: Void = inbox.connect()
        async let provisioningSignedIn: Void = provisioning.signIn()
        _ = try await (chatConnected, inboxConnected, provisioningSignedIn)
        try await provisioning.setPlugin("hermex-push", enabled: false)
        defer { chat.close(); inbox.close() }

        XCTAssertEqual(["/api/status", "/auth/password-login", "/api/auth/me"].map(HermesHostFixture.count), [1, 1, 1])
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 1, "They share one socket and its ticket")
        XCTAssertEqual(HermesHostFixture.count("/api/dashboard/agent-plugins/hermex-push/disable"), 1)
        let jar = try XCTUnwrap(http.session.configuration.httpCookieStorage)
        XCTAssertTrue(http.provisioningSession.configuration.httpCookieStorage === jar)
    }

    /// Only a 401 from the login step reports a refused sign-in, the re-login a signed-in 401
    /// starts included, naming the configured server whose record it was (#899). A rate
    /// limit, a server error, a dropped request and a proxy's own 401 leave the sign-in to
    /// the screens' retry rules.
    func testOnlyALoginRefusalReportsARejectedSignIn() async throws {
        let server = URL(string: "https://webui-or-hermes.example")!
        let rows: [(path: String, reply: HermesHostFixture.Reply, reports: Int)] = [
            ("/auth/password-login", .json(401, .object(["error": .string("invalid_credentials")])), 1),
            ("/auth/password-login", .json(429, .object([:])), 0),
            ("/auth/password-login", .json(503, .object([:])), 0),
            ("/auth/password-login", .fail(URLError(.timedOut)), 0),
            ("/api/status", .json(401, .string("Access denied")), 0)
        ]
        for row in rows {
            HermesHostFixture.reset()
            let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
                request.url?.path == row.path ? row.reply : nil
            } })
            var rejected: [URL] = []
            connections.onSignInRejected = { server, _ in rejected.append(server) }
            do { try await connections.connection(for: record, server: server).signIn(); XCTFail("\(row.reply)") } catch {}
            XCTAssertEqual(rejected, Array(repeating: server, count: row.reports), "\(row.path) \(row.reply)")
        }

        HermesHostFixture.reset()
        var logins = 0
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/auth/password-login":
                logins += 1
                return logins == 1 ? nil : .json(401, .object(["error": .string("invalid_credentials")]))
            case "/api/plugins/hermex-push/pairing": return .json(401, .object(["error": .string("session_expired")]))
            default: return nil
            }
        } })
        var rejected: [URL] = []
        connections.onSignInRejected = { server, _ in rejected.append(server) }
        let http = connections.connection(for: record, server: server)
        try await http.signIn()
        XCTAssertEqual(rejected, [])
        do { _ = try await http.data(.pushPairing); XCTFail("The re-login was refused") } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(401))
        }
        XCTAssertEqual(rejected, [server])
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 2)
    }

    /// Each step runs on a fresh connection, and its request is held at the host while the
    /// sessions' in-flight tasks are read, so the test sees the session it went out on.
    func testOnlyProvisioningAndItsSignInGoOutOnTheLongDeadlineSession() async throws {
        var parking: String?
        let configuration = HermesHostFixture.configuration { request in request.url?.path == parking ? .park : nil }
        let connect: (HermesConnection) async throws -> Void = { http in
            let chat = BotClient(http: http)
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
            let http = HermesConnection(connection: record, configuration: configuration, gateway: .init { _ in BotScriptedSocket() })
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
        }, gateway: .init { _ in BotScriptedSocket() })
        let leaving = BotClient(http: http)
        let staying = BotClient(http: http)
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
            }, gateway: .init { _ in BotScriptedSocket() })
            let screen = BotClient(http: http)
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
                                                                 username: $0.username, password: $0.password, installID: $0.installID) }),
            ("headers", { $0.headers = [self.access] })
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

    /// The release gate reads the public status before any password goes out. Only a
    /// readable release older than the minimum is refused; a canary reads as its base
    /// release, and a missing or unreadable version proceeds.
    func testOnlyAReleaseOlderThanTheMinimumIsRefusedAndBeforeThePassword() async throws {
        let releases: [(version: String?, refused: Bool)] = [
            ("0.21.2", true), ("0.21.3", false), ("0.21.5", false),
            ("0.21.4+canary.20260928T071354Z", false), (nil, false), ("dev", false)
        ]
        for release in releases {
            let label = release.version ?? "missing"
            var status: [String: BotJSON] = ["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]
            status["version"] = release.version.map(BotJSON.string)
            HermesHostFixture.reset()
            let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
                request.url?.path == "/api/status" ? .json(200, .object(status)) : nil
            })
            do {
                try await http.signIn()
                XCTAssertFalse(release.refused, "\(label) must be refused")
            } catch {
                XCTAssertTrue(release.refused, "\(label) must sign in, not \(error)")
                XCTAssertEqual(error as? BotFailure, .outdated(label))
            }
            XCTAssertEqual(HermesHostFixture.requests.map { $0.url?.path },
                           release.refused ? ["/api/status"] : ["/api/status", "/auth/password-login", "/api/auth/me"], label)
        }
    }

    /// A -32601 (method not found) to one screen's call is the connection's to remember, past
    /// the socket that carried it. The handshake's own `client.capabilities` and an ordinary
    /// rejection are not recorded.
    func testAMissingMethodIsRememberedForEveryScreenOnTheConnection() async throws {
        let socket = BotScriptedSocket()
        let error: (BotJSON, Int) -> BotJSON = { request, code in
            .object(["id": request["id"], "error": .object(["code": .number(Double(code)), "message": .string("refused")])])
        }
        socket.capabilitiesReply = { error($0, -32601) }
        socket.reply = { request in
            switch request["method"].text {
            case "session.cwd.set": return error(request, -32601)
            case "model.options": return error(request, 4000)
            default: return .object(["id": request["id"], "result": .object([:])])
            }
        }
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil },
                                    gateway: .init { _ in socket })
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        for call in [HermesCall.sessionCwdSet(sessionID: "runtime", profile: "bot", cwd: "/new"),
                     .modelOptions(sessionID: "runtime", profile: "bot")] {
            do { _ = try await chat.call(call); XCTFail("\(call.method) is refused") } catch {}
        }
        XCTAssertEqual(inbox.unavailableMethods, ["session.cwd.set"])
        chat.close(); inbox.close()
        XCTAssertEqual(BotClient(http: http).unavailableMethods, ["session.cwd.set"], "A later socket on the connection keeps it")
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

    /// The saved record's headers, as `HermesConnections` and the connection form's
    /// candidate pass it. The active webui server's custom headers are loaded too, and
    /// never reach Hermes.
    func testSavedHeadersReachEveryRequestToTheOriginAndTheGatewayUpgradeUnderItsBuiltIns() async throws {
        let previous = CustomHeaderStore.shared.snapshot()
        defer { CustomHeaderStore.shared.replace(with: previous) }
        CustomHeaderStore.shared.replace(with: [CustomHeader(name: "X-Webui-Token", value: "webui")])
        var saved = record
        saved.headers = [cloudflare, access, CustomHeader(name: "Content-Type", value: "text/plain")]
        var upgrade: URLRequest?
        let http = HermesConnection(connection: saved, configuration: HermesHostFixture.configuration { _ in nil },
                                    gateway: .init { request in upgrade = request; return BotScriptedSocket() })
        let client = BotClient(http: http)
        try await client.connect()
        defer { client.close() }
        let context = BotArtifactContext(connectionID: record.id, profile: "inbox-triage", sessionID: "tip", generation: 1)
        _ = try await client.artifactData(path: "report.pdf", context: context)
        _ = try await client.uploadImage(data: Data([1, 2, 3]), filename: "a.png", context: context)
        try await client.deleteProfile("old-bot")
        let dashboard = BotDashboardClient(http: http)
        try await dashboard.installPlugin(identifier: "hermex-push")
        try await dashboard.setPlugin("hermex-push", enabled: true)
        _ = try await dashboard.loadedPluginVersion()

        let requests = HermesHostFixture.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/status", "/auth/password-login", "/api/auth/me", "/api/auth/ws-ticket",
                                                       "/api/fs/download", "/api/chat/image-upload", "/api/profiles/old-bot",
                                                       "/api/dashboard/agent-plugins/install",
                                                       "/api/dashboard/agent-plugins/hermex-push/enable",
                                                       "/api/plugins/hermex-push/pairing"])
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
    /// would, so only the connection's redirect guard can remove them. A reply from another
    /// host then ends the sign-in as `.blocked` before the password goes out.
    func testACrossOriginRedirectDropsTheHeadersBeforeTheRelay() async throws {
        let relay = HermexPushPlugin.defaultRelayURL.appendingPathComponent("api/status")
        var saved = record
        saved.headers = [cloudflare, access]
        let http = HermesConnection(connection: saved, configuration: HermesHostFixture.configuration { request in
            request.url?.host == "hermes.example" && request.url?.path == "/api/status" ? .redirect(relay) : nil
        })
        do { try await http.signIn(); XCTFail("Expected a reply from another host to be blocked") }
        catch { XCTAssertEqual(error as? BotFailure, .blocked) }
        let hop = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.host == relay.host })
        XCTAssertNil(hop.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(hop.value(forHTTPHeaderField: "X-Access"))
        let status = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.host == "hermes.example" })
        XCTAssertEqual(status.value(forHTTPHeaderField: "X-Access"), "token", "Requests to the origin keep them")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0)
    }

    /// A browser sign-in's connection (#708) starts from the refresh token in the Keychain, not
    /// a stale copy of the record, saves each rotated one before its access token goes out, and
    /// sends that token as a bearer. A signed-in 401 refreshes once more and resends; a copy of
    /// the record with an older token is still the same connection.
    func testABrowserSignInRefreshesFromTheKeychainAndSavesTheRotatedTokenBeforeItsBearer() async throws {
        let server = URL(string: "https://hermes.example")!
        let keychain = InMemoryKeychainStore()
        let saved = oauthRecord(refreshToken: "refresh-0")
        try BotConnectionStore(keychain: keychain).save(saved, server: server)
        // Read off the main actor, where the host answers.
        let stored = { () -> String? in
            let value = keychain.scopedValue(.botConnection, scope: server.absoluteString) ?? ""
            return (try? JSONDecoder().decode(BotConnection.self, from: Data(value.utf8)))?.oauth?.refreshToken
        }
        var sent: [String] = [], storedAtIdentity: [String?] = [], pairings = 0
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/auth/native/refresh":
                let body = try? JSONDecoder().decode(BotJSON.self, from: apiTestBodyData(from: request) ?? Data())
                XCTAssertEqual(body?["provider"].text, "nous")
                sent.append(body?["refresh_token"].text ?? "")
                return .json(200, .object(["access_token": .string("access-\(sent.count)"),
                                           "refresh_token": .string("refresh-\(sent.count)"),
                                           "provider": .string("nous"), "user_id": .string("u1")]))
            case "/api/auth/me":
                storedAtIdentity.append(stored())
                return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            case "/api/plugins/hermex-push/pairing":
                pairings += 1
                return pairings == 1 ? .json(401, .object(["error": .string("session_expired")])) : nil
            default: return nil
            }
        } }, keychain: keychain)

        let http = connections.connection(for: oauthRecord(refreshToken: "stale-copy"), server: server)
        _ = try await http.data(.pushPairing)

        XCTAssertEqual(sent, ["refresh-0", "refresh-1"], "The Keychain's token, then the rotated one")
        XCTAssertEqual(storedAtIdentity, ["refresh-1", "refresh-2"], "Each rotated token is saved before its bearer is used")
        XCTAssertEqual(stored(), "refresh-2")
        let bearers = HermesHostFixture.requests.filter { $0.url?.path == "/api/plugins/hermex-push/pairing" }
            .map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(bearers, ["Bearer access-1", "Bearer access-2"])
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0)
        XCTAssertTrue(connections.connection(for: saved, server: server) === http)
    }

    /// The host refusing the refresh token signs the server out as expired, and a rotated token
    /// never lands on a record removed or signed in again meanwhile.
    func testAnExpiredBrowserSignInSignsOutAndARotatedTokenNeverOverwritesANewerRecord() async throws {
        let server = URL(string: "https://hermes.example")!
        let keychain = InMemoryKeychainStore()
        let store = BotConnectionStore(keychain: keychain)
        let saved = oauthRecord(refreshToken: "refresh-0")
        try store.save(saved, server: server)
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            request.url?.path == "/auth/native/refresh" ? .json(401, .object(["error": .string("session_expired")])) : nil
        } }, keychain: keychain)
        var rejected: [BotFailure] = []
        connections.onSignInRejected = { _, failure in rejected.append(failure) }
        do { try await connections.connection(for: saved, server: server).signIn(); XCTFail("The refresh was refused") } catch {
            XCTAssertEqual(error as? BotFailure, .signInExpired)
        }
        XCTAssertEqual(rejected, [.signInExpired])
        XCTAssertEqual(HermesHostFixture.count("/api/auth/me"), 0)

        let newer = oauthRecord(refreshToken: "new-sign-in")
        try store.save(newer, server: server)
        try store.saveRotatedRefreshToken("late", replacing: "refresh-0", connection: saved.id, server: server)
        XCTAssertEqual(try store.load(server: server)?.oauth?.refreshToken, "new-sign-in")
        try store.remove(server: server)
        try store.saveRotatedRefreshToken("late", replacing: "new-sign-in", connection: newer.id, server: server)
        XCTAssertNil(try store.load(server: server))
    }

    /// A Keychain read that fails stops the sign-in before the token is spent. A write that
    /// fails leaves the rotated token in memory, and the next rotation saves over the token
    /// the Keychain still holds.
    func testARotatedTokenTheKeychainRefusedIsSavedAtTheNextRotation() async throws {
        let server = URL(string: "https://hermes.example")!
        let keychain = RefusingKeychain()
        try BotConnectionStore(keychain: keychain).save(oauthRecord(refreshToken: "refresh-0"), server: server)
        var refreshes = 0, pairings = 0
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/auth/native/refresh":
                refreshes += 1
                return .json(200, .object(["access_token": .string("access-\(refreshes)"),
                                           "refresh_token": .string("refresh-\(refreshes)")]))
            case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            case "/api/plugins/hermex-push/pairing":
                pairings += 1
                return pairings == 1 ? .json(401, .object(["error": .string("session_expired")])) : nil
            default: return nil
            }
        } }, keychain: keychain)
        keychain.refusesScopedSaves = 1

        let http = connections.connection(for: oauthRecord(refreshToken: "refresh-0"), server: server)
        // A read that fails spends nothing; the next sign-in reads again.
        keychain.refusesScopedLoads = 1
        do { try await http.signIn(); XCTFail("Expected the Keychain read to fail") } catch {}
        XCTAssertEqual(refreshes, 0)
        _ = try await http.data(.pushPairing)

        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: server)?.oauth?.refreshToken, "refresh-2")
    }

    /// Switching away during a refresh retires its connection but never cancels the refresh:
    /// the host may already have rotated the token. The next connection on that server waits
    /// for it to save the new token and sends that one, not the spent one.
    func testARefreshInFlightOutlivesItsRetiredConnectionAndHandsOnItsToken() async throws {
        let server = URL(string: "https://hermes.example")!
        let keychain = InMemoryKeychainStore()
        let saved = oauthRecord(refreshToken: "refresh-0")
        try BotConnectionStore(keychain: keychain).save(saved, server: server)
        var sent: [String] = []
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/auth/native/refresh":
                let body = try? JSONDecoder().decode(BotJSON.self, from: apiTestBodyData(from: request) ?? Data())
                sent.append(body?["refresh_token"].text ?? "")
                return sent.count == 1 ? .park : .json(200, .object(["access_token": .string("access-2"),
                                                                     "refresh_token": .string("refresh-2")]))
            case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            default: return nil
            }
        } }, keychain: keychain)
        let parked = expectation(description: "first refresh at the host")
        HermesHostFixture.onPark = { parked.fulfill() }
        let first = connections.connection(for: saved, server: server)
        let retired = Task { try await first.signIn() }
        await fulfillment(of: [parked], timeout: 2)

        connections.retire(server: server)
        let next = Task { try await connections.connection(for: saved, server: server).signIn() }
        HermesHostFixture.releaseParked(.json(200, .object(["access_token": .string("access-1"),
                                                            "refresh_token": .string("refresh-1")])))
        await assertStale("The retired sign-in") { try await retired.value }
        try await next.value

        XCTAssertEqual(sent, ["refresh-0", "refresh-1"])
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: server)?.oauth?.refreshToken, "refresh-2")
    }

    /// Move to Hermes's destination connection (#1265) saves the token it rotates, as the server's
    /// own connection does, and closing it leaves that connection alone. The server's own
    /// connection, still signed in meanwhile, refreshes next from the saved token, not the one it
    /// held, which the host has retired.
    func testAMoveSavesTheTokenItRotatesForTheServersOwnConnection() async throws {
        let server = URL(string: "https://hermes.example")!
        let keychain = InMemoryKeychainStore()
        let store = BotConnectionStore(keychain: keychain)
        try store.save(oauthRecord(refreshToken: "refresh-0"), server: server)
        var sent: [String] = []
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/auth/native/refresh":
                let body = try? JSONDecoder().decode(BotJSON.self, from: apiTestBodyData(from: request) ?? Data())
                sent.append(body?["refresh_token"].text ?? "")
                return .json(200, .object(["access_token": .string("access-\(sent.count)"),
                                           "refresh_token": .string("refresh-\(sent.count)")]))
            case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            case "/api/plugins/hermex-push/pairing":
                // The host has since expired the own connection's first access token.
                let expired = request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1"
                return expired ? .json(401, .object(["error": .string("session_expired")])) : nil
            default: return nil
            }
        } }, keychain: keychain)
        let own = connections.connection(for: try XCTUnwrap(store.load(server: server)), server: server)
        try await own.signIn()

        let move = MoveToHermesDestination.live(try XCTUnwrap(store.load(server: server)), connections: connections)
        _ = try? await move.readPairing()
        move.close()
        XCTAssertEqual(try store.load(server: server)?.oauth?.refreshToken, "refresh-2", "The move's rotated token is saved")
        XCTAssertFalse(own.isRetired)

        _ = try await own.data(.pushPairing)
        XCTAssertEqual(sent, ["refresh-0", "refresh-1", "refresh-2"])
        XCTAssertEqual(try store.load(server: server)?.oauth?.refreshToken, "refresh-3")
    }

    /// A move's connection, made before the server's own is retired mid-refresh, still waits for
    /// that refresh and sends the token it rotated to, not the one it spent (#1265).
    func testAMovesConnectionWaitsForARefreshRetiredAfterItWasMade() async throws {
        try await assertWaitsForARefreshRetiredLater { connections, saved, server in
            let current = connections.connection(for: saved, server: server)
            let own = connections.ownConnection(for: saved, server: server)
            return (current, { connections.retire(server: server) }, own)
        }
    }

    /// The server's own connection, made before a move's is closed mid-refresh, still waits for
    /// that refresh and sends the token it rotated to (#1265).
    func testTheServersOwnConnectionWaitsForAMovesRefreshClosedAfterItWasMade() async throws {
        try await assertWaitsForARefreshRetiredLater { connections, saved, server in
            let own = connections.ownConnection(for: saved, server: server)
            let current = connections.connection(for: saved, server: server)
            return (own, { connections.retire(own: own, server: server) }, current)
        }
    }

    /// A browser sign-in's own bearer is its `Authorization`, so no custom one is admitted there:
    /// Cloudflare Access takes its two-header form. A password connection keeps the JSON form.
    func testABrowserSignInRefusesACustomAuthorizationHeader() throws {
        XCTAssertThrowsError(try HermesHeaders([access, cloudflare], signsInWithBrowser: true)) {
            XCTAssertEqual($0 as? HermesHeaders.Rejection, .authorization)
        }
        let accessPair = [CustomHeader(name: "CF-Access-Client-Id", value: "id"), CustomHeader(name: "CF-Access-Client-Secret", value: "s")]
        XCTAssertEqual(try HermesHeaders(accessPair, signsInWithBrowser: true).values, accessPair)
        var saved = oauthRecord(refreshToken: "refresh-0")
        saved.headers = [cloudflare, access]
        XCTAssertEqual(HermesHeaders(saved: saved).values, [], "A refused saved list sends none")
        saved.oauth = nil
        XCTAssertEqual(HermesHeaders(saved: saved).values, [cloudflare, access])
    }

    /// A Profile's config gets Hermex's note under `platform_hints.hermex` (#1278): written
    /// when it is missing or differs, through a PUT the host merges, and left alone when current.
    /// Each Profile is read once per connection.
    func testThePlatformNoteIsWrittenOnlyWhenMissingOrChanged() async throws {
        let rows: [(hints: BotJSON, writes: Int)] = [
            (.null, 1),
            (.object(["hermex": .object(["append": .string("An older note.")])]), 1),
            (.object(["hermex": .object(["append": .string(HermesREST.platformNote)])]), 0)
        ]
        for row in rows {
            HermesHostFixture.reset()
            let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
                request.url?.path == "/api/config" && request.httpMethod == "GET"
                    ? .json(200, .object(["model": .string("gpt-6"), "platform_hints": row.hints])) : nil
            })

            await http.keepPlatformNote(profile: "research")
            await http.keepPlatformNote(profile: "research")

            let config = HermesHostFixture.requests.filter { $0.url?.path == "/api/config" }
            XCTAssertEqual(config.map { $0.httpMethod ?? "" }, ["GET"] + Array(repeating: "PUT", count: row.writes), "\(row.hints)")
            for request in config {
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "profile", value: "research")])
            }
            if let write = config.first(where: { $0.httpMethod == "PUT" }) {
                XCTAssertEqual(HermesCronFixture.body(write), .object(["config": .object(["platform_hints": .object([
                    "hermex": .object(["append": .string(HermesREST.platformNote)])
                ])])]))
            }
        }
    }

    /// A second chat on a Profile whose note is still being checked waits for that check, so the
    /// host does not build its agent before the note is written.
    func testASecondChatWaitsForTheNoteBeingChecked() async throws {
        let parked = expectation(description: "the config read is parked")
        HermesHostFixture.onPark = { parked.fulfill() }
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            request.url?.path == "/api/config" && request.httpMethod == "GET" ? .park : nil
        })
        let first = Task { await http.keepPlatformNote(profile: "research") }
        await fulfillment(of: [parked])

        let second = Task {
            await http.keepPlatformNote(profile: "research")
            return HermesHostFixture.requests.filter { $0.url?.path == "/api/config" }.map { $0.httpMethod ?? "" }
        }
        HermesHostFixture.releaseParked(.json(200, .object([:])))
        await first.value

        let seenBySecond = await second.value
        XCTAssertEqual(seenBySecond, ["GET", "PUT"], "The second returns only once the note is written, and reads nothing itself")
    }

    /// A config read that fails leaves the Profile unchecked, so the next chat tries again.
    func testAFailedPlatformNoteReadIsTriedAgain() async throws {
        var refusals = 1
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/config", request.httpMethod == "GET" else { return nil }
            if refusals > 0 { refusals -= 1; return .json(503, .object([:])) }
            return .json(200, .object([:]))
        })

        await http.keepPlatformNote(profile: "research")
        await http.keepPlatformNote(profile: "research")
        await http.keepPlatformNote(profile: "research")

        XCTAssertEqual(HermesHostFixture.requests.filter { $0.url?.path == "/api/config" }.map { $0.httpMethod ?? "" },
                       ["GET", "GET", "PUT"])
    }

    private func oauthRecord(refreshToken: String) -> BotConnection {
        var saved = BotConnection(id: record.id, name: "Host", address: record.address, username: "u1", password: "")
        saved.oauth = HermesOAuth(provider: "nous", userID: "u1", refreshToken: refreshToken)
        return saved
    }

    /// `make` returns two connections to one browser sign-in's server and how to retire the first.
    /// The first signs in until its refresh reaches the host and is retired there; the second,
    /// made before that, signs in before the reply arrives and must send the rotated token.
    private func assertWaitsForARefreshRetiredLater(
        _ make: (HermesConnections, BotConnection, URL) -> (refreshing: HermesConnection, retire: () -> Void, next: HermesConnection)
    ) async throws {
        let server = URL(string: "https://hermes.example")!
        let keychain = InMemoryKeychainStore()
        let saved = oauthRecord(refreshToken: "refresh-0")
        try BotConnectionStore(keychain: keychain).save(saved, server: server)
        let nextStarted = expectation(description: "the second connection's sign-in at the host")
        var sent: [String] = [], statuses = 0
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/api/status":
                statuses += 1
                if statuses == 2 { nextStarted.fulfill() }
                return nil
            case "/auth/native/refresh":
                let body = try? JSONDecoder().decode(BotJSON.self, from: apiTestBodyData(from: request) ?? Data())
                sent.append(body?["refresh_token"].text ?? "")
                return sent.count == 1 ? .park : .json(200, .object(["access_token": .string("access-2"),
                                                                     "refresh_token": .string("refresh-2")]))
            case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            default: return nil
            }
        } }, keychain: keychain)
        let parked = expectation(description: "first refresh at the host")
        HermesHostFixture.onPark = { parked.fulfill() }
        let (refreshing, retire, next) = make(connections, saved, server)
        let retired = Task { try await refreshing.signIn() }
        await fulfillment(of: [parked], timeout: 2)

        retire()
        let signedIn = Task { try await next.signIn() }
        await fulfillment(of: [nextStarted], timeout: 2)
        HermesHostFixture.releaseParked(.json(200, .object(["access_token": .string("access-1"),
                                                            "refresh_token": .string("refresh-1")])))
        await assertStale("The retired sign-in") { try await retired.value }
        try await signedIn.value

        XCTAssertEqual(sent, ["refresh-0", "refresh-1"])
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: server)?.oauth?.refreshToken, "refresh-2")
    }

    /// The fixture keeps the login's POST on the redirected request, as a 307 or 308 would,
    /// so the guard must refuse it before the password reaches the other host.
    func testALoginRedirectedToAnotherOriginNeverSendsThePassword() async throws {
        let elsewhere = try XCTUnwrap(URL(string: "https://elsewhere.example/auth/password-login"))
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { request in
            request.url?.host == "hermes.example" && request.url?.path.hasSuffix("password-login") == true
                ? .redirect(elsewhere) : nil
        })
        do { try await http.signIn(); XCTFail("Expected the refused redirect to be blocked") }
        catch { XCTAssertEqual(error as? BotFailure, .blocked) }
        XCTAssertNotNil(HermesHostFixture.requests.first { $0.url?.path.hasSuffix("password-login") == true })
        XCTAssertFalse(HermesHostFixture.requests.contains { $0.url?.host == elsewhere.host })
    }

    private func assertStale(_ label: String, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("\(label): expected stale") }
        catch { XCTAssertEqual(error as? BotFailure, .stale, label) }
    }
}

/// An in-memory Keychain that refuses the next `refusesScopedSaves` scoped writes and the
/// next `refusesScopedLoads` scoped reads.
private final class RefusingKeychain: KeychainStoring {
    private let base = InMemoryKeychainStore()
    var refusesScopedSaves = 0
    var refusesScopedLoads = 0

    func save(_ value: String, forKey key: KeychainStore.Key) throws { try base.save(value, forKey: key) }
    func load(_ key: KeychainStore.Key) throws -> String? { try base.load(key) }
    func delete(_ key: KeychainStore.Key) throws { try base.delete(key) }
    func save(_ value: String, forKey key: KeychainStore.Key, scope: String) throws {
        if refusesScopedSaves > 0 { refusesScopedSaves -= 1; throw URLError(.cannotWriteToFile) }
        try base.save(value, forKey: key, scope: scope)
    }
    func load(_ key: KeychainStore.Key, scope: String) throws -> String? {
        if refusesScopedLoads > 0 { refusesScopedLoads -= 1; throw URLError(.cannotOpenFile) }
        return try base.load(key, scope: scope)
    }
    func delete(_ key: KeychainStore.Key, scope: String) throws { try base.delete(key, scope: scope) }
}

/// A scripted direct Hermes host. `script` may answer a request by path; nil gives the
/// host's ordinary signed-in reply. A parked request waits for `releaseParked`. The script
/// runs under the fixture's lock, and `script(_:)` changes its state under the same lock.
/// `HermesGatewayTests` scripts its host with it too.
final class HermesHostFixture: URLProtocol {
    /// `body` answers with exactly these bytes, which `json` can't when they are empty.
    enum Reply { case json(Int, BotJSON), body(Int, Data), fail(URLError), redirect(URL), park }

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
            respond(.body(status, (try? JSONEncoder().encode(body)) ?? Data()))
        case .body(let status, let data):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .redirect(let target):
            // A 307: the follow-up keeps the method, as a 307 or 308 does on the wire.
            let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            var followUp = URLRequest(url: target)
            followUp.httpMethod = request.httpMethod
            followUp.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
            // A refused redirect ends with the 3xx itself, as it does on the wire.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .park: break
        }
    }

    /// A 0.21.5 host with the password gate, without the session write fence's snapshot route
    /// (#1300), and a plain success for every other route.
    private static func ordinary(_ request: URLRequest) -> Reply {
        switch request.url?.path {
        case "/api/status":
            return .json(200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                       "version": .string("0.21.5")]))
        case "/api/auth/me": return .json(200, .object(["provider": .string("basic")]))
        case "/api/auth/ws-ticket": return .json(200, .object(["ticket": .string("ticket")]))
        case let path? where path.hasPrefix("/api/sessions/") && path.hasSuffix("/mutation-snapshot"):
            return .json(404, .object(["detail": .string("No such API endpoint: \(path)")]))
        default: return .json(200, .object(["ok": .bool(true), "path": .string("/profile/images/a.png")]))
        }
    }
}
