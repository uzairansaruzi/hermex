import XCTest
@testable import HermesMobile

@MainActor
final class AuthManagerStateTests: XCTestCase {
    private struct PreconditionFailure: Error {}

    private static let sessionExpiredMessage = "Your session expired. Sign in again."

    // These tests assert against the global HTTPCookieStorage; reset it on both
    // sides so pre-existing cookies or a mid-test failure can't leak across tests.
    nonisolated override func setUp() {
        super.setUp()
        Self.clearSharedCookies()
    }

    nonisolated override func tearDown() {
        Self.clearSharedCookies()
        super.tearDown()
    }

    private nonisolated static func clearSharedCookies() {
        HTTPCookieStorage.shared.cookies?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }

    func testUnauthorizedWhileLoggedInKeepsServerAndMovesToLoggedOut() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://example.test")
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let cookieStorage = HTTPCookieStorage.shared
        cookieStorage.setCookie(try makeSessionCookie(for: server))

        manager.handleAPIError(APIError.unauthorized)

        XCTAssertEqual(manager.state, .loggedOut(server: server))
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
        XCTAssertEqual(cookieStorage.cookies?.isEmpty, true)
        XCTAssertEqual(manager.lastErrorMessage, Self.sessionExpiredMessage)
    }

    func testUnauthorizedWhileAlreadyLoggedOutStaysLoggedOutWithServer() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://example.test")
        let server = try XCTUnwrap(URL(string: "https://example.test"))

        manager.handleAPIError(APIError.unauthorized)
        manager.handleAPIError(APIError.unauthorized)

        XCTAssertEqual(manager.state, .loggedOut(server: server))
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
    }

    func testUnauthorizedWhileUnconfiguredKeepsFullClearBehavior() {
        let keychain = InMemoryKeychainStore()
        let manager = AuthManager(keychain: keychain) { _ in
            MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        }

        manager.handleAPIError(APIError.unauthorized)

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(manager.lastErrorMessage, Self.sessionExpiredMessage)
    }

    func testNonUnauthorizedErrorDoesNotChangeState() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://example.test")
        let server = try XCTUnwrap(URL(string: "https://example.test"))

        manager.handleAPIError(APIError.http(statusCode: 502, body: ""))

        XCTAssertEqual(manager.state, .loggedIn(server: server))
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
    }

    func testSignOutFullyClearsServerAndReturnsToUnconfigured() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client
        )

        await manager.signOut()

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        // Server-side logout is still attempted best-effort when reachable.
        XCTAssertEqual(client.logoutCallCount, 1)
    }

    func testSignOutClearsLocalAuthWhenServerLogoutFails() async throws {
        let keychain = InMemoryKeychainStore()
        // Server unreachable: the best-effort logout throws, but local sign-out
        // must still succeed so the user can reach onboarding (issue #249).
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            logoutBehavior: .fail(APIError.network(underlying: URLError(.notConnectedToInternet)))
        )
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client
        )

        await manager.signOut()

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(client.logoutCallCount, 1)
    }

    func testSignOutCompletesWhenServerLogoutHangs() async throws {
        let keychain = InMemoryKeychainStore()
        // Server accepts the connection but never responds: sign-out must still
        // finish once the bounded logout times out, not hang indefinitely.
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            logoutBehavior: .hang
        )
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client,
            logoutTimeout: .milliseconds(50)
        )

        await manager.signOut()

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(client.logoutCallCount, 1)
    }

    func testSignOutClearsSessionCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = try await makeLoggedInManager(
            keychain: keychain,
            serverURLString: "https://example.test",
            client: client
        )
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: server))

        await manager.signOut()

        XCTAssertEqual(HTTPCookieStorage.shared.cookies?.isEmpty, true)
        XCTAssertEqual(manager.state, .unconfigured)
    }

    // MARK: - Per-server isolation (#16)

    func testSignOutClearsOnlyActiveServerCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://a.test")
        // Both servers hold a session cookie in the shared jar (which both APIClient
        // and SSEClient stream against).
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverA, value: "a-cookie"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverB, value: "b-cookie"))

        await manager.signOut()

        // A's cookie is cleared; B (a different host) is untouched.
        XCTAssertTrue(HTTPCookieStorage.shared.cookies(for: serverA)?.isEmpty ?? true)
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: serverB)?.map(\.value), ["b-cookie"])
    }

    func testUnauthorizedClearsOnlyActiveServerCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://a.test")
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverA, value: "a-cookie"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverB, value: "b-cookie"))

        manager.handleAPIError(APIError.unauthorized)

        // Only the active server's auth is affected by its 401.
        XCTAssertEqual(manager.state, .loggedOut(server: serverA))
        XCTAssertTrue(HTTPCookieStorage.shared.cookies(for: serverA)?.isEmpty ?? true)
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: serverB)?.map(\.value), ["b-cookie"])
    }

    func testSignOutLeavesOtherServerHeadersAndRegistryIntact() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory()
        // Pre-seed server B: a registry entry plus its scoped custom headers.
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        registry.activate(url: serverB)
        let bHeaders = try XCTUnwrap([CustomHeader(name: "X-B", value: "b-token")].encodedForStorage())
        try keychain.save(bHeaders, forKey: .customHeaders, scope: "https://b.test")

        // Sign in to server A as the active server, with its own scoped headers.
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            headerStore: CustomHeaderStore(),
            serverRegistry: registry
        )
        await manager.configure(
            serverURLString: "https://a.test",
            password: "",
            customHeaders: [CustomHeader(name: "X-A", value: "a-token")]
        )
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://a.test"))

        await manager.signOut()

        // A's scoped headers + registry entry are gone; B's are untouched.
        XCTAssertNil(keychain.scopedValue(.customHeaders, scope: "https://a.test"))
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://b.test"))
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
    }

    // MARK: - Multi-server switch / remove / identity (#17)

    func testSwitchActiveServerMakesItActiveAndOptimisticallyLoggedIn() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))

        manager.switchActiveServer(to: bAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverB))
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://b.test")
        XCTAssertEqual(registry.activeServerID, "https://b.test")
        XCTAssertEqual(manager.activeServerID, "https://b.test")
    }

    func testSwitchToTheAlreadyActiveServerIsANoOp() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, aAccount, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))

        manager.switchActiveServer(to: aAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverA))
        XCTAssertEqual(registry.activeServerID, "https://a.test")
    }

    func testRemoveActiveServerAutoSwitchesToRemaining() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, aAccount, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))

        await manager.removeServer(aAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverB))
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://b.test")
    }

    func testRemoveLastServerReturnsToOnboarding() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")
        let aAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })

        await manager.removeServer(aAccount)

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(keychain.savedValues[.serverURL])
    }

    func testRemoveNonActiveServerLeavesActiveLoggedIn() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))

        await manager.removeServer(bAccount)

        XCTAssertEqual(manager.state, .loggedIn(server: serverA))
        XCTAssertEqual(registry.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://a.test")
    }

    func testRemoveNonActiveServerClearsOnlyItsCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverA, value: "a-cookie"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverB, value: "b-cookie"))

        await manager.removeServer(bAccount)

        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: serverA)?.map(\.value), ["a-cookie"])
        XCTAssertTrue(HTTPCookieStorage.shared.cookies(for: serverB)?.isEmpty ?? true)
    }

    func testRemovingAServerPurgesItsBotConnectionAvatars() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        let connection = BotConnection(id: UUID(), name: "B", address: try XCTUnwrap(URL(string: "http://b.local:9120")), username: "u", password: "p")
        try BotConnectionStore(keychain: keychain).save(connection, server: serverB)
        let profile = try XCTUnwrap(BotProfile(.object(["name": .string("default"), "has_avatar": .bool(true)])))
        let wire = BotAvatarFixtureWire()
        wire.assets = ["default": .object(["found": .bool(true), "data": .string(botAvatarDataURL(side: 4))])]
        await BotAvatarStore.shared.refresh([profile], connectionID: connection.id, using: wire) {}
        XCTAssertEqual(BotAvatarStore.shared.images(connectionID: connection.id).count, 1)

        await manager.removeServer(bAccount)

        XCTAssertTrue(BotAvatarStore.shared.images(connectionID: connection.id).isEmpty)
        XCTAssertNil(try BotConnectionStore(keychain: keychain).load(server: serverB))
    }

    /// The shared Bot connection signs in with the active server's saved credentials, so
    /// each change here retires it at once, not when the next Bot screen looks it up.
    func testServerAndBotCredentialChangesRetireTheSharedBotConnectionAtOnce() async throws {
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let saved = BotConnection(id: UUID(), name: "Host", address: try XCTUnwrap(URL(string: "https://hermes.example")),
                                  username: "u", password: "p", headers: [CustomHeader(name: "X-Access", value: "token")])
        var renamed = saved
        renamed.name = "Renamed"
        renamed.installID = String(repeating: "a", count: 32)
        var rotated = saved
        rotated.password = "rotated"
        var reheadered = saved
        reheadered.headers = [CustomHeader(name: "X-Access", value: "rotated")]
        var headerless = saved
        headerless.headers = nil
        let changes: [(String, Bool, (AuthManager, ServerAccount, ServerAccount, BotConnectionStore) async throws -> Void)] = [
            ("server switch", true, { manager, _, b, _ in manager.switchActiveServer(to: b) }),
            ("sign-out", true, { manager, _, _, _ in await manager.signOut() }),
            ("server removal", true, { manager, a, _, _ in await manager.removeServer(a) }),
            ("replaced credentials", true, { _, _, _, store in try store.save(rotated, server: serverA) }),
            ("removed credentials", true, { _, _, _, store in try store.remove(server: serverA) }),
            ("changed headers", true, { _, _, _, store in try store.save(reheadered, server: serverA) }),
            ("removed headers", true, { _, _, _, store in try store.save(headerless, server: serverA) }),
            ("rename and install id backfill, same headers", false, { _, _, _, store in try store.save(renamed, server: serverA) })
        ]
        for (change, retires, apply) in changes {
            let keychain = InMemoryKeychainStore()
            let (manager, aAccount, bAccount) = try await makeTwoServerManager(keychain: keychain,
                                                                               registry: ServerRegistry.inMemory(keychain: keychain))
            let store = BotConnectionStore(keychain: keychain)
            try store.save(saved, server: serverA)
            let shared = HermesConnections.shared.connection(for: saved, server: serverA)
            try await apply(manager, aAccount, bAccount, store)
            XCTAssertEqual(shared.isRetired, retires, change)
        }
    }

    func testSignOutWithRemainingServerAutoSwitches() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))

        await manager.signOut()

        XCTAssertEqual(manager.state, .loggedIn(server: serverB))
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
    }

    func testSignOutAndServerRemovalClearOnlyTheirUnreadMarks() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let first = try XCTUnwrap(URL(string: "https://a.test"))
        let second = try XCTUnwrap(URL(string: "https://b.test"))
        let store = SessionUnreadStore()
        defer {
            store.remove(for: first)
            store.remove(for: second)
        }
        store.save(["same": 100], for: first)
        store.save(["same": 200], for: second)

        await manager.signOut()
        XCTAssertTrue(store.load(for: first).isEmpty)
        XCTAssertEqual(store.load(for: second), ["same": 200])

        await manager.removeServer(bAccount)
        XCTAssertTrue(store.load(for: second).isEmpty)
    }

    func testConfiguringASecondServerAddsItAndMakesItActive() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )

        await manager.configure(serverURLString: "https://a.test", password: "")
        await manager.configure(serverURLString: "https://b.test", password: "")

        XCTAssertEqual(Set(manager.servers.map(\.id)), ["https://a.test", "https://b.test"])
        XCTAssertEqual(manager.activeServerID, "https://b.test")
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://b.test"))))
    }

    func testAddServerNeedsPasswordWhenAuthEnabledAndNoPassword() async {
        let manager = AuthManager(
            keychain: InMemoryKeychainStore(),
            probeClientFactory: { _, _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false)) },
            serverRegistry: ServerRegistry.inMemory()
        )

        let outcome = await manager.addServer(serverURLString: "https://needs-pw.test", password: "")

        XCTAssertEqual(outcome, .needsPassword)
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertTrue(manager.servers.isEmpty)
    }

    func testAddServerRejectsAnAlreadyConfiguredURL() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")

        let outcome = await manager.addServer(serverURLString: "https://a.test", password: "")

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(manager.lastErrorMessage, "This server is already configured.")
        XCTAssertEqual(manager.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://a.test"))))
    }

    func testAddServerSucceedsAndSwitchesActive() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            probeClientFactory: { _, _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")

        let outcome = await manager.addServer(serverURLString: "https://b.test", password: "")

        XCTAssertEqual(outcome, .added(try XCTUnwrap(URL(string: "https://b.test"))))
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://b.test"))))
        XCTAssertEqual(Set(manager.servers.map(\.id)), ["https://a.test", "https://b.test"])
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://b.test")
    }

    func testAddServerFailureKeepsActiveServerAndItsHeaders() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let clientA = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let clientB = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
            loginResponse: LoginResponse(ok: false, message: nil, error: "nope")
        )
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { $0.absoluteString.contains("a.test") ? clientA : clientB },
            probeClientFactory: { url, _ in url.absoluteString.contains("a.test") ? clientA : clientB },
            headerStore: CustomHeaderStore(),
            serverRegistry: registry
        )
        await manager.configure(
            serverURLString: "https://a.test",
            password: "secret",
            customHeaders: [CustomHeader(name: "X-A", value: "a-token")]
        )
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://a.test"))))

        let outcome = await manager.addServer(
            serverURLString: "https://b.test",
            password: "wrong",
            customHeaders: [CustomHeader(name: "X-B", value: "b-token")]
        )

        XCTAssertEqual(outcome, .failed)
        // The active server, its state, registry, and live headers are untouched.
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://a.test"))))
        XCTAssertEqual(manager.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(manager.currentCustomHeaders.map(\.name), ["X-A"])
        XCTAssertEqual(manager.currentCustomHeaders.map(\.value), ["a-token"])
    }

    func testServersSnapshotMirrorsRegistry() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, _) = try await makeTwoServerManager(keychain: keychain, registry: registry)

        XCTAssertEqual(Set(manager.servers.map(\.id)), ["https://a.test", "https://b.test"])
        XCTAssertEqual(manager.activeServerID, "https://a.test")
    }

    func testUpdateServerIdentityPersistsAndMirrorsTheActiveServer() async throws {
        let keychain = InMemoryKeychainStore()
        let defaults = UserDefaults.ephemeral()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: defaults)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")
        let aAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })

        manager.updateServerIdentity(
            aAccount,
            displayName: "Work",
            initials: "WK",
            headerLogoColorHex: "#5B7CFF"
        )

        let updated = try XCTUnwrap(manager.servers.first { $0.id == "https://a.test" })
        XCTAssertEqual(updated.displayName, "Work")
        XCTAssertEqual(updated.initials, "WK")
        XCTAssertEqual(updated.headerLogoColorHex, "#5B7CFF")
        // The active server's identity is mirrored into the global defaults.
        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "Work")
        XCTAssertEqual(defaults.string(forKey: HeaderLogoColor.storageKey), "#5B7CFF")
    }

    /// Builds a manager with two registered servers: `a.test` signed in + active,
    /// `b.test` present but inactive. Returns the manager and both accounts.
    private func makeTwoServerManager(
        keychain: InMemoryKeychainStore,
        registry: ServerRegistry
    ) async throws -> (AuthManager, ServerAccount, ServerAccount) {
        // Pre-seed B (becomes inactive once A signs in), then sign in to A.
        registry.activate(url: try XCTUnwrap(URL(string: "https://b.test")))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "https://a.test", password: "")

        guard case .loggedIn = manager.state else {
            XCTFail("Expected loggedIn after configure, got \(manager.state)")
            throw PreconditionFailure()
        }

        let aAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })
        let bAccount = try XCTUnwrap(registry.servers.first { $0.id == "https://b.test" })
        return (manager, aAccount, bAccount)
    }

    func testDevAutoLoginSignsInFromLaunchEnvironment() async throws {
        let manager = AuthManager(
            keychain: InMemoryKeychainStore(),
            clientFactory: { _ in
                MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
            },
            serverRegistry: ServerRegistry.inMemory()
        )

        await DevAutoLogin.run(authManager: manager, environment: [:])
        XCTAssertEqual(manager.state, .unconfigured)

        await DevAutoLogin.run(authManager: manager, environment: [
            "HERMEX_DEV_SERVER_URL": "https://example.test",
            "HERMEX_DEV_PASSWORD": "secret"
        ])
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://example.test"))))
    }

    // MARK: - Hermes servers (#899)

    private let hermesServer = URL(string: "https://hermes.example")!
    private let webuiServer = URL(string: "https://a.test")!

    private func hermesRecord(password: String = "secret") -> BotConnection {
        BotConnection(id: UUID(), name: "Studio", address: hermesServer, username: "me", password: password,
                      hermesVersion: "0.21.5")
    }

    /// The webui server `a.test` signed in, then the Hermes server added, which makes it
    /// active. `connections` stands in for the app's shared Hermes connections.
    private func makeHermesManager(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        registry: ServerRegistry? = nil,
        connections: HermesConnections? = nil,
        headerStore: CustomHeaderStore = CustomHeaderStore()
    ) async throws -> AuthManager {
        let preferences = UserDefaults.ephemeral()
        preferences.set(true, forKey: BotModeGate.isEnabledKey)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            headerStore: headerStore,
            serverRegistry: registry ?? ServerRegistry.inMemory(keychain: keychain),
            hermesConnections: connections ?? HermesConnections(),
            preferences: preferences
        )
        await manager.configure(
            serverURLString: webuiServer.absoluteString, password: "",
            customHeaders: [CustomHeader(name: "X-Webui", value: "token")]
        )
        guard manager.addHermesServer(hermesRecord()) else {
            XCTFail("Expected the Hermes server to be added: \(manager.lastErrorMessage ?? "gate off")")
            throw PreconditionFailure()
        }
        return manager
    }

    func testAddingAHermesServerSavesItsOwnSignInUnderItsAddressAndOpensIt() async throws {
        let keychain = InMemoryKeychainStore()
        let headers = CustomHeaderStore()
        let manager = try await makeHermesManager(keychain: keychain, headerStore: headers)

        XCTAssertEqual(manager.state, .loggedIn(server: hermesServer))
        XCTAssertEqual(manager.servers.map(\.kind), [.webui, .hermes])
        XCTAssertEqual(manager.activeServer?.serverVersion, "0.21.5")
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: hermesServer)?.username, "me")
        XCTAssertEqual(keychain.savedValues[.serverURL], hermesServer.absoluteString)
        XCTAssertTrue(headers.snapshot().isEmpty, "The webui server's headers never go to a Hermes server")

        // The id is the address as the Hermes connection form normalizes it.
        let unnormalized = BotConnection(id: UUID(), name: "Other", address: URL(string: "https://Other.Example:9119/")!,
                                         username: "me", password: "secret")
        XCTAssertTrue(manager.addHermesServer(unnormalized))
        XCTAssertEqual(manager.activeServerID, "https://other.example:9119")
        XCTAssertNotNil(try BotConnectionStore(keychain: keychain).load(server: URL(string: "https://other.example:9119")!))
    }

    func testAHermesServerCannotTakeAnAddressAlreadyInTheRegistry() async throws {
        let manager = try await makeHermesManager()

        for address in [webuiServer, hermesServer] {
            let duplicate = BotConnection(id: UUID(), name: "Again", address: address, username: "me", password: "secret")
            XCTAssertFalse(manager.addHermesServer(duplicate), address.absoluteString)
            XCTAssertEqual(manager.lastErrorMessage, "This server is already configured.")
        }
        XCTAssertEqual(manager.servers.map(\.id), [webuiServer.absoluteString, hermesServer.absoluteString])

        // Nor can onboarding sign a webui server in at a Hermes server's address.
        await manager.configure(serverURLString: hermesServer.absoluteString, password: "")
        XCTAssertEqual(manager.kind(of: hermesServer), .hermes)
        XCTAssertEqual(manager.lastErrorMessage, "This server is already configured.")
    }

    func testAHermesServerRestoresSignedInOnlyWhileItsRecordExists() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        _ = try await makeHermesManager(keychain: keychain, registry: registry)

        let relaunched = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(), serverRegistry: registry,
                                     hermesConnections: HermesConnections())
        XCTAssertEqual(relaunched.state, .loggedIn(server: hermesServer))

        try BotConnectionStore(keychain: keychain).remove(server: hermesServer)
        let withoutRecord = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(), serverRegistry: registry,
                                        hermesConnections: HermesConnections())
        XCTAssertEqual(withoutRecord.state, .loggedOut(server: hermesServer))
    }

    /// The host answers the login step with 401: on the active Hermes server's shared
    /// connection that shows the server's sign-in form; on a webui server's own Hermes
    /// connection it changes nothing here (#884's per-screen flag handles it).
    func testOnlyAHermesServersRefusedLoginSignsItOut() async throws {
        defer { HermesHostFixture.reset() }
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            request.url?.path == "/auth/password-login" ? .json(401, .object(["error": .string("invalid_credentials")])) : nil
        } })
        let keychain = InMemoryKeychainStore()
        let manager = try await makeHermesManager(keychain: keychain, connections: connections)
        let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer))

        do { try await connections.connection(for: saved, server: hermesServer).signIn(); XCTFail("The login was refused") } catch {}

        XCTAssertEqual(manager.state, .loggedOut(server: hermesServer))
        XCTAssertEqual(manager.lastErrorMessage, "Hermes didn't accept the username or password.")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1)

        // A changed record saved from the sign-in form signs the server back in.
        try BotConnectionStore(keychain: keychain).save(hermesRecord(password: "changed"), server: hermesServer)
        manager.hermesSignInSaved(server: hermesServer)
        XCTAssertEqual(manager.state, .loggedIn(server: hermesServer))
        XCTAssertNil(manager.lastErrorMessage)

        // A webui server's own Hermes connection refused the same way leaves it signed in.
        let webui = try XCTUnwrap(manager.servers.first { $0.id == webuiServer.absoluteString })
        manager.switchActiveServer(to: webui)
        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "secret")
        do { try await connections.connection(for: side, server: webuiServer).signIn(); XCTFail("The login was refused") } catch {}
        XCTAssertEqual(manager.state, .loggedIn(server: webuiServer))
    }

    func testOtherSignInFailuresKeepAHermesServerSignedIn() async throws {
        defer { HermesHostFixture.reset() }
        var login: HermesHostFixture.Reply = .json(200, .object([:]))
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            request.url?.path == "/auth/password-login" ? login : nil
        } })
        let keychain = InMemoryKeychainStore()
        let manager = try await makeHermesManager(keychain: keychain, connections: connections)
        let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer))

        for reply in [HermesHostFixture.Reply.json(429, .object([:])), .json(503, .object([:])), .fail(URLError(.timedOut))] {
            HermesHostFixture.script { login = reply }
            do { try await connections.connection(for: saved, server: hermesServer).signIn(); XCTFail("\(reply)") } catch {}
            XCTAssertEqual(manager.state, .loggedIn(server: hermesServer), "\(reply)")
        }
    }

    func testWebuiAndHermesSignOutsStayWithTheirOwnServer() async throws {
        let manager = try await makeHermesManager()

        // A late webui 401, such as from a screen a switch left behind, is not about the Hermes server.
        manager.handleAPIError(APIError.unauthorized)
        XCTAssertEqual(manager.state, .loggedIn(server: hermesServer))
        XCTAssertNil(manager.lastErrorMessage)

        // A refused Hermes sign-in for a server that is not active changes nothing.
        let webui = try XCTUnwrap(manager.servers.first { $0.id == webuiServer.absoluteString })
        manager.switchActiveServer(to: webui)
        manager.hermesSignInRejected(server: hermesServer)
        XCTAssertEqual(manager.state, .loggedIn(server: webuiServer))
        manager.handleAPIError(APIError.unauthorized)
        XCTAssertEqual(manager.state, .loggedOut(server: webuiServer))
    }

    func testSigningOutOfAHermesServerDeletesOnlyItsSignInAndShowsItsForm() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = try await makeHermesManager(keychain: keychain)
        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "secret")
        try BotConnectionStore(keychain: keychain).save(side, server: webuiServer)
        let cookies = HTTPCookieStorage.shared
        cookies.setCookie(try makeSessionCookie(for: webuiServer))

        await manager.signOut()

        XCTAssertEqual(manager.state, .loggedOut(server: hermesServer))
        XCTAssertEqual(manager.servers.map(\.id), [webuiServer.absoluteString, hermesServer.absoluteString])
        XCTAssertNil(try BotConnectionStore(keychain: keychain).load(server: hermesServer))
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: webuiServer), side)
        XCTAssertEqual(cookies.cookies(for: webuiServer)?.count, 1)
    }

    /// The Hermes server shares the webui server's host on another port, where cookies
    /// would collide: its removal leaves the webui server's cookie, record and headers.
    func testRemovingAHermesServerDeletesOnlyItsRecord() async throws {
        let keychain = InMemoryKeychainStore()
        let manager = try await makeHermesManager(keychain: keychain)
        let sameHost = BotConnection(id: UUID(), name: "Same host", address: URL(string: "https://a.test:9119")!,
                                     username: "me", password: "secret")
        XCTAssertTrue(manager.addHermesServer(sameHost))
        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "secret")
        try BotConnectionStore(keychain: keychain).save(side, server: webuiServer)
        let cookies = HTTPCookieStorage.shared
        cookies.setCookie(try makeSessionCookie(for: webuiServer))
        let account = try XCTUnwrap(manager.activeServer)

        await manager.removeServer(account)

        XCTAssertEqual(manager.servers.map(\.id), [webuiServer.absoluteString, hermesServer.absoluteString])
        XCTAssertEqual(manager.state, .loggedIn(server: webuiServer), "The next server in the registry opens")
        XCTAssertNil(try BotConnectionStore(keychain: keychain).load(server: URL(string: "https://a.test:9119")!))
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: webuiServer), side)
        XCTAssertNotNil(try BotConnectionStore(keychain: keychain).load(server: hermesServer))
        XCTAssertEqual(cookies.cookies(for: webuiServer)?.count, 1)
        XCTAssertEqual(manager.currentCustomHeaders.map(\.name), ["X-Webui"])
    }

    func testSwitchingAwayFromAHermesServerRetiresItsConnectionAndRestoresWebuiHeaders() async throws {
        let connections = HermesConnections()
        let headers = CustomHeaderStore()
        let keychain = InMemoryKeychainStore()
        let manager = try await makeHermesManager(keychain: keychain, connections: connections, headerStore: headers)
        let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer))
        let live = connections.connection(for: saved, server: hermesServer)

        manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.kind == .webui }))

        XCTAssertTrue(live.isRetired)
        XCTAssertEqual(headers.snapshot().map(\.name), ["X-Webui"])

        manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.kind == .hermes }))
        XCTAssertEqual(manager.state, .loggedIn(server: hermesServer))
        XCTAssertTrue(headers.snapshot().isEmpty)
    }

    private func makeLoggedInManager(
        keychain: InMemoryKeychainStore,
        serverURLString: String,
        client providedClient: MockAuthAPIClient? = nil,
        logoutTimeout: Duration = .seconds(5)
    ) async throws -> AuthManager {
        let client = providedClient
            ?? MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            logoutTimeout: logoutTimeout,
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: serverURLString, password: "secret")

        guard case .loggedIn = manager.state else {
            XCTFail("Expected loggedIn state after configure, got \(manager.state)")
            throw PreconditionFailure()
        }

        return manager
    }

    private func makeSessionCookie(for server: URL, value: String = "stale-session-token") throws -> HTTPCookie {
        try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: try XCTUnwrap(server.host),
                .path: "/",
                .name: "hermes_session",
                .value: value,
            ])
        )
    }
}
