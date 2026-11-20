import XCTest
@testable import HermesMobile

@MainActor
final class AuthManagerStateTests: XCTestCase {
    private struct PreconditionFailure: Error {}

    private static let sessionExpiredMessage = "Your session expired. Sign in again."

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
        XCTAssertEqual(client.logoutCallCount, 1)
    }

    func testSignOutClearsLocalAuthWhenServerLogoutFails() async throws {
        let keychain = InMemoryKeychainStore()
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

    func testSignOutClearsOnlyActiveServerCookies() async throws {
        let keychain = InMemoryKeychainStore()
        let serverA = try XCTUnwrap(URL(string: "https://a.test"))
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        let manager = try await makeLoggedInManager(keychain: keychain, serverURLString: "https://a.test")
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverA, value: "a-cookie"))
        HTTPCookieStorage.shared.setCookie(try makeSessionCookie(for: serverB, value: "b-cookie"))

        await manager.signOut()

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

        XCTAssertEqual(manager.state, .loggedOut(server: serverA))
        XCTAssertTrue(HTTPCookieStorage.shared.cookies(for: serverA)?.isEmpty ?? true)
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: serverB)?.map(\.value), ["b-cookie"])
    }

    func testSignOutLeavesOtherServerHeadersAndRegistryIntact() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory()
        let serverB = try XCTUnwrap(URL(string: "https://b.test"))
        registry.activate(url: serverB)
        let bHeaders = try XCTUnwrap([CustomHeader(name: "X-B", value: "b-token")].encodedForStorage())
        try keychain.save(bHeaders, forKey: .customHeaders, scope: "https://b.test")

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

        XCTAssertNil(keychain.scopedValue(.customHeaders, scope: "https://a.test"))
        XCTAssertNotNil(keychain.scopedValue(.customHeaders, scope: "https://b.test"))
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
    }

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

    func testServerRemovalClearsOnlyItsModelLists() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let (manager, _, bAccount) = try await makeTwoServerManager(keychain: keychain, registry: registry)
        let first = try XCTUnwrap(URL(string: "https://a.test"))
        let second = try XCTUnwrap(URL(string: "https://b.test"))
        let option = ModelCatalogOption(id: "gpt", displayName: "GPT", providerID: "openai")
        defer {
            for server in [first, second] {
                ModelFavoritesStore.remove(for: server)
                ModelRecentsStore.remove(for: server)
                ModelPresetStore.remove(for: server)
            }
        }
        for server in [first, second] {
            ModelFavoritesStore(server: server).toggleFavorite(for: option)
            ModelRecentsStore(server: server).recordRecent(option)
            ModelPresetStore(server: server).record(effort: "high", for: option.favoriteKey)
        }

        await manager.removeServer(bAccount)

        XCTAssertEqual(ModelFavoritesStore(server: second).favoriteKeys, [])
        XCTAssertEqual(ModelRecentsStore(server: second).recentKeys, [])
        XCTAssertNil(ModelPresetStore(server: second).preset(for: option.favoriteKey))
        XCTAssertEqual(ModelFavoritesStore(server: first).favoriteKeys, [option.favoriteKey])
        XCTAssertEqual(ModelRecentsStore(server: first).recentKeys, [option.favoriteKey])
        XCTAssertEqual(ModelPresetStore(server: first).preset(for: option.favoriteKey)?.effort, "high")
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

        XCTAssertEqual(outcome, .failed(serverAnswered: false))
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

        XCTAssertEqual(outcome, .failed(serverAnswered: true))
        XCTAssertEqual(manager.state, .loggedIn(server: try XCTUnwrap(URL(string: "https://a.test"))))
        XCTAssertEqual(manager.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(manager.currentCustomHeaders.map(\.name), ["X-A"])
        XCTAssertEqual(manager.currentCustomHeaders.map(\.value), ["a-token"])
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
        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "Work")
        XCTAssertEqual(defaults.string(forKey: HeaderLogoColor.storageKey), "#5B7CFF")
    }

    private func makeTwoServerManager(
        keychain: InMemoryKeychainStore,
        registry: ServerRegistry
    ) async throws -> (AuthManager, ServerAccount, ServerAccount) {
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

    private let hermesServer = URL(string: "https://hermes.example")!
    private let webuiServer = URL(string: "https://a.test")!

    func testAddingOrSwitchingServersHandsBackTheDepartingServersScreens() async throws {
        let manager = try await makeHermesManager()
        var handedBack: [URL] = []
        manager.handBackScreenHolds = { handedBack.append($0) }
        let next = URL(string: "https://next.test")!
        XCTAssertTrue(manager.addHermesServer(BotConnection(id: UUID(), name: "Next", address: next, username: "me",
                                                            password: "secret", hermesVersion: "0.21.5")))
        XCTAssertEqual(handedBack, [hermesServer])

        let account = try XCTUnwrap(manager.servers.first { $0.id == hermesServer.absoluteString })
        manager.switchActiveServer(to: account)
        XCTAssertEqual(handedBack, [hermesServer, next])
    }

    private func hermesRecord(password: String = "secret") -> BotConnection {
        BotConnection(id: UUID(), name: "Studio", address: hermesServer, username: "me", password: password,
                      hermesVersion: "0.21.5")
    }

    private func makeHermesManager(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        registry: ServerRegistry? = nil,
        connections: HermesConnections? = nil,
        headerStore: CustomHeaderStore = CustomHeaderStore(),
        preferences: UserDefaults = .ephemeral(),
        forgetPush: @escaping @MainActor (URL) async -> Void = { _ in }
    ) async throws -> AuthManager {
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            headerStore: headerStore,
            serverRegistry: registry ?? ServerRegistry.inMemory(keychain: keychain),
            hermesConnections: connections ?? HermesConnections(),
            preferences: preferences,
            forgetPush: forgetPush
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

        try BotConnectionStore(keychain: keychain).save(hermesRecord(password: "changed"), server: hermesServer)
        manager.hermesSignInSaved(server: hermesServer)
        XCTAssertEqual(manager.state, .loggedIn(server: hermesServer))
        XCTAssertNil(manager.lastErrorMessage)

        let webui = try XCTUnwrap(manager.servers.first { $0.id == webuiServer.absoluteString })
        manager.switchActiveServer(to: webui)
        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "secret")
        do { try await connections.connection(for: side, server: webuiServer).signIn(); XCTFail("The login was refused") } catch {}
        XCTAssertEqual(manager.state, .loggedIn(server: webuiServer))
    }

    func testASignInRecordsTheGatewayOnlyOnTheHermesServer() async throws {
        defer { HermesHostFixture.reset() }
        var statuses = 0
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/status" else { return nil }
            statuses += 1
            guard statuses == 1 else { return nil }
            return .json(200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                       "version": .string("0.21.5")]))
        } })
        let keychain = InMemoryKeychainStore()
        let manager = try await makeHermesManager(keychain: keychain, connections: connections)
        let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer))

        try await connections.connection(for: saved, server: hermesServer).signIn()
        XCTAssertEqual(manager.activeServer?.hermesGateway, .webapp)

        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "secret")
        try await connections.connection(for: side, server: webuiServer).signIn()
        XCTAssertNil(manager.servers.first { $0.id == webuiServer.absoluteString }?.hermesGateway)
    }

    func testAnExpiredBrowserSignInSignsAHermesServerOutAsExpired() async throws {
        defer { HermesHostFixture.reset() }
        let keychain = InMemoryKeychainStore()
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            request.url?.path == "/auth/native/refresh" ? .json(401, .object(["error": .string("session_expired")])) : nil
        } }, keychain: keychain)
        let manager = try await makeHermesManager(keychain: keychain, connections: connections)
        var saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer))
        saved.oauth = HermesOAuth(provider: "nous", userID: "me", refreshToken: "refresh")
        try BotConnectionStore(keychain: keychain).save(saved, server: hermesServer)

        do { try await connections.connection(for: saved, server: hermesServer).signIn(); XCTFail("The refresh was refused") } catch {}

        XCTAssertEqual(manager.state, .loggedOut(server: hermesServer))
        XCTAssertEqual(manager.lastErrorMessage, "Your Hermes sign-in expired. Sign in again.")
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

        manager.handleAPIError(APIError.unauthorized)
        XCTAssertEqual(manager.state, .loggedIn(server: hermesServer))
        XCTAssertNil(manager.lastErrorMessage)

        let webui = try XCTUnwrap(manager.servers.first { $0.id == webuiServer.absoluteString })
        manager.switchActiveServer(to: webui)
        manager.hermesSignInRejected(server: hermesServer)
        XCTAssertEqual(manager.state, .loggedIn(server: webuiServer))
        manager.handleAPIError(APIError.unauthorized)
        XCTAssertEqual(manager.state, .loggedOut(server: webuiServer))
    }

    func testSigningOutOfAHermesServerDeletesOnlyItsSignInAndShowsItsForm() async throws {
        let keychain = InMemoryKeychainStore()
        let preferences = UserDefaults.ephemeral()
        var forgottenPush: [URL] = []
        let manager = try await makeHermesManager(keychain: keychain, preferences: preferences,
                                                  forgetPush: { forgottenPush.append($0) })
        HermesProfilePreference.save("work", for: hermesServer, in: preferences)
        HermesProfilePreference.save("work", for: webuiServer, in: preferences)
        HermesProfilePreference.saveLastListed("work", for: hermesServer, in: preferences)
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
        XCTAssertNil(preferences.string(forKey: HermesProfilePreference.key(for: hermesServer)),
                     "the remembered Profile goes with the sign-in (#1015)")
        XCTAssertNil(HermesProfilePreference.lastListed(for: hermesServer, in: preferences))
        XCTAssertEqual(preferences.string(forKey: HermesProfilePreference.key(for: webuiServer)), "work")
        XCTAssertEqual(forgottenPush, [hermesServer], "this iPhone stops getting the host's pushes")
    }

    func testSignOutAndRemovalLeaveNoCachedBotRoster() async throws {
        let paths: [(String, URL, (AuthManager) async -> Void)] = [
            ("Hermes sign-out", hermesServer, { await $0.signOut() }),
            ("Hermes removal", hermesServer, { manager in
                guard let active = manager.activeServer else { return }
                await manager.removeServer(active)
            }),
            ("webui sign-out", webuiServer, { await $0.signOut() })
        ]
        for (path, server, leave) in paths {
            let keychain = InMemoryKeychainStore()
            var scope: BotRosterCache.Scope?
            let manager = try await makeHermesManager(keychain: keychain, forgetPush: { _ in
                guard let scope else { return }
                await BotRosterCache.shared.save([.object(["name": .string("late")])], scope: scope, readAt: .now)
            })
            let store = BotConnectionStore(keychain: keychain)
            if server == webuiServer {
                try store.save(BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "secret"),
                               server: webuiServer)
                manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.id == webuiServer.absoluteString }))
            }
            scope = .init(server: server, connectionID: try XCTUnwrap(store.load(server: server)).id)

            await leave(manager)

            let left = await BotRosterCache.shared.load(try XCTUnwrap(scope))
            XCTAssertNil(left, path)
        }
    }

    func testRemovingAHermesServerForgetsItsPushPairing() async throws {
        var forgottenPush: [URL] = []
        let manager = try await makeHermesManager(forgetPush: { forgottenPush.append($0) })
        let account = try XCTUnwrap(manager.activeServer)

        await manager.removeServer(account)

        XCTAssertEqual(forgottenPush, [hermesServer])
    }

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

    private func makeFormManager(keychain: InMemoryKeychainStore, headerStore: CustomHeaderStore = CustomHeaderStore()) -> AuthManager {
        let webui = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false))
        return AuthManager(keychain: keychain, clientFactory: { _ in webui }, probeClientFactory: { _, _ in webui },
                           headerStore: headerStore, serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                           hermesConnections: HermesConnections(), preferences: .ephemeral())
    }

    private func makeForm(entry: OnboardingViewModel.Entry, moveSource: OnboardingViewModel.MoveSource? = nil,
                          socket: @escaping () -> BotScriptedSocket = { BotScriptedSocket() },
                          host script: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) -> OnboardingViewModel {
        OnboardingViewModel(entry: entry, moveSource: moveSource, hermesConfiguration: { HermesHostFixture.configuration(script) },
                            hermesGateway: .init(socketFactory: { _ in socket() }))
    }

    func testTheConnectFormAddsAHermesServerFromOnboardingAndFromAddServer() async throws {
        defer { HermesHostFixture.reset() }
        for entry in [OnboardingViewModel.Entry.onboarding, .addServer] {
            HermesHostFixture.reset()
            let keychain = InMemoryKeychainStore()
            let headers = CustomHeaderStore()
            let manager = makeFormManager(keychain: keychain, headerStore: headers)
            let form = makeForm(entry: entry)
            if entry == .addServer {
                await manager.configure(serverURLString: webuiServer.absoluteString, password: "",
                                        customHeaders: [CustomHeader(name: "X-Webui", value: "token")])
            }
            form.serverURLString = "hermes.example"
            let found = await form.connect(authManager: manager)
            XCTAssertNil(found, "\(entry): the first Connect only finds the dashboard")
            form.username = " me "
            form.password = "secret"

            let added = await form.connect(authManager: manager)

            XCTAssertEqual(added, hermesServer, "\(entry)")
            XCTAssertEqual(manager.state, .loggedIn(server: hermesServer), "\(entry)")
            XCTAssertEqual(manager.kind(of: hermesServer), .hermes, "\(entry)")
            XCTAssertEqual(manager.activeServer?.serverVersion, "0.21.5", "\(entry)")
            let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer), "\(entry)")
            XCTAssertEqual(saved.username, "me", "\(entry)")
            XCTAssertEqual(saved.password, "secret", "\(entry)")
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1, "\(entry): one sign-in")
            XCTAssertTrue(headers.snapshot().isEmpty, "\(entry): the webui's headers never go to a Hermes server")
        }
    }

    func testAddServerSavesNothingAfterAFailedLiveCheck() async throws {
        defer { HermesHostFixture.reset() }
        HermesHostFixture.reset()
        let keychain = InMemoryKeychainStore()
        let manager = makeFormManager(keychain: keychain)
        await manager.configure(serverURLString: webuiServer.absoluteString, password: "")
        let form = makeForm(entry: .addServer, socket: { BotScriptedSocket(ready: #"{"session_authority":true}"#) })
        form.serverURLString = "hermes.example"
        _ = await form.connect(authManager: manager)
        form.username = "me"
        form.password = "secret"

        let added = await form.connect(authManager: manager)

        XCTAssertNil(added)
        XCTAssertEqual(form.errorMessage, BotConnectionAdvice.message(for: BotFailure.unsupported, address: hermesServer))
        XCTAssertFalse(manager.servers.contains { $0.id == hermesServer.absoluteString }, "No server is saved")
        XCTAssertNil(try BotConnectionStore(keychain: keychain).load(server: hermesServer))
    }

    func testTheFormOpenedFromAMoveAddsTheHermesServerWithoutSwitching() async throws {
        defer { HermesHostFixture.reset() }
        HermesHostFixture.reset()
        let keychain = InMemoryKeychainStore()
        let manager = makeFormManager(keychain: keychain)
        await manager.configure(serverURLString: webuiServer.absoluteString, password: "")
        let webuiHeaders = [CustomHeader(name: "CF-Access-Client-Id", value: "id.access"),
                            CustomHeader(name: "CF-Access-Client-Secret", value: "secret.access")]
        let form = makeForm(entry: .addServer, moveSource: .init(name: "Home", headers: webuiHeaders))
        XCTAssertTrue(form.offersMoveSourceHeaders)
        XCTAssertTrue(form.customHeaders.isEmpty, "Never filled in on its own")

        form.useMoveSourceHeaders()

        XCTAssertEqual(form.customHeaders.map { [$0.name, $0.value] },
                       [["CF-Access-Client-Id", "id.access"], ["CF-Access-Client-Secret", "secret.access"]])
        XCTAssertFalse(form.offersMoveSourceHeaders, "The row goes once used")
        XCTAssertEqual(form.serverURLString, "", "The address stays blank")
        form.serverURLString = "hermes.example"
        let found = await form.connect(authManager: manager)
        XCTAssertNil(found, "The first Connect only finds the dashboard")
        form.username = "me"
        form.password = "secret"

        let added = await form.connect(authManager: manager)

        XCTAssertEqual(added, hermesServer)
        XCTAssertEqual(manager.state, .loggedIn(server: webuiServer), "The move's sheet stays on the webui server")
        XCTAssertEqual(manager.kind(of: hermesServer), .hermes)
        XCTAssertNil(manager.moveOffer, "The move goes on by itself")
        let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer))
        XCTAssertEqual(saved.headers?.map(\.value), ["id.access", "secret.access"])
        let login = HermesHostFixture.requests.first { $0.url?.path == "/auth/password-login" }
        XCTAssertEqual(login?.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "secret.access")

        HermesHostFixture.reset()
        let webuiForm = makeForm(entry: .addServer, moveSource: .init(name: "Home", headers: [])) {
            $0.url?.path == "/api/status" ? .json(404, .object([:])) : nil
        }
        XCTAssertFalse(webuiForm.offersMoveSourceHeaders, "No headers, no row")
        webuiForm.serverURLString = "webui.example:8787"
        let refused = await webuiForm.connect(authManager: manager)
        XCTAssertNil(refused)
        XCTAssertNotNil(webuiForm.errorMessage, "Only a Hermes dashboard can be a destination")
        XCTAssertEqual(manager.servers.count, 2)
    }

    func testASavedSignInIsOfferedOnlyAtExactlyTheSameAddress() async throws {
        defer { HermesHostFixture.reset() }
        let status = BotJSON.object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                     "auth_flows": .array([.string("native_pkce")]),
                                     "version": .string("0.21.5"), "install_id": .string("install-1")])
        let keychain = InMemoryKeychainStore()
        let manager = makeFormManager(keychain: keychain)
        await manager.configure(serverURLString: webuiServer.absoluteString, password: "")
        let webui = try XCTUnwrap(manager.activeServer)
        manager.updateServerIdentity(webui, displayName: "Studio Mac", initials: "SM", headerLogoColorHex: webui.headerLogoColorHex)
        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "saved",
                                 installID: "install-1", headers: [CustomHeader(name: "CF-Access-Client-Id", value: "id.access")])
        try BotConnectionStore(keychain: keychain).save(side, server: webuiServer)
        func form() -> OnboardingViewModel {
            makeForm(entry: .addServer) { $0.url?.path == "/api/status" ? .json(200, status) : nil }
        }

        let elsewhere = form()
        elsewhere.serverURLString = "https://other.example"
        await elsewhere.connect(authManager: manager)
        XCTAssertEqual(elsewhere.detectedKind, .hermes)
        XCTAssertTrue(elsewhere.savedSignIns.isEmpty, "The same install id at another address is never offered")

        let same = form()
        same.serverURLString = "HERMES.example/"
        await same.connect(authManager: manager)
        XCTAssertEqual(same.savedSignIns.map(\.serverName), ["Studio Mac"])
        same.useSavedSignIn(try XCTUnwrap(same.savedSignIns.first))
        XCTAssertEqual(same.username, "me")
        XCTAssertEqual(same.password, "saved")
        XCTAssertEqual(same.customHeaders, side.headers)
        XCTAssertTrue(same.showsHermesSignIn, "Filling in the saved headers keeps the dashboard found")
        XCTAssertTrue(same.offersSignInChoice, "Filling in the saved headers keeps the Password | Browser picker")

        let added = await same.connect(authManager: manager)

        XCTAssertEqual(added, hermesServer)
        let copy = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: hermesServer))
        XCTAssertNotEqual(copy.id, side.id, "The new server's record gets its own UUID")
        XCTAssertEqual(copy.password, "saved")
        XCTAssertEqual(copy.headers, side.headers)
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: webuiServer), side,
                       "The webui server's side connection is untouched")
        let login = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/auth/password-login" })
        XCTAssertEqual(login.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id.access")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1)
    }

    func testADashboardAtASavedWebuiAddressReplacesItOnlyAfterItsSignInSucceeds() async throws {
        defer { HermesHostFixture.reset() }
        for entry in [OnboardingViewModel.Entry.onboarding, .addServer] {
            HermesHostFixture.reset()
            let keychain = InMemoryKeychainStore()
            let headers = CustomHeaderStore()
            let manager = makeFormManager(keychain: keychain, headerStore: headers)
            await manager.configure(serverURLString: hermesServer.absoluteString, password: "",
                                    customHeaders: [CustomHeader(name: "X-Webui", value: "token")])
            let webui = try XCTUnwrap(manager.activeServer)
            manager.updateServerIdentity(webui, displayName: "Studio Mac", initials: "SM", headerLogoColorHex: "#34C759")
            if entry == .onboarding { manager.handleAPIError(APIError.unauthorized) }
            var refusesSignIn = true
            let form = makeForm(entry: entry) { request in
                request.url?.path == "/auth/password-login" && refusesSignIn
                    ? .json(401, .object(["error": .string("invalid_credentials")])) : nil
            }
            form.serverURLString = "hermes.example"
            await form.connect(authManager: manager)
            form.username = "me"
            form.password = "secret"

            let offered = await form.connect(authManager: manager)
            XCTAssertNil(offered, "\(entry)")
            XCTAssertTrue(form.offersWebuiReplace, "\(entry)")
            XCTAssertEqual(form.errorMessage, "A webui server is saved at this address.", "\(entry)")
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0, "\(entry): no sign-in before Replace")

            let refused = await form.connect(authManager: manager, replacingWebuiServer: true)
            XCTAssertNil(refused, "\(entry)")
            XCTAssertEqual(form.errorMessage, "Hermes didn't accept the username or password.", "\(entry)")
            XCTAssertEqual(manager.servers.map(\.kind), [.webui], "\(entry): a refused sign-in keeps the webui server")
            XCTAssertNil(try BotConnectionStore(keychain: keychain).load(server: hermesServer), "\(entry)")

            refusesSignIn = false
            let replaced = await form.connect(authManager: manager, replacingWebuiServer: true)

            XCTAssertEqual(replaced, hermesServer, "\(entry)")
            XCTAssertEqual(manager.state, .loggedIn(server: hermesServer), "\(entry)")
            XCTAssertEqual(manager.servers.map(\.kind), [.hermes], "\(entry)")
            XCTAssertEqual(manager.activeServer?.displayName, "Studio Mac", "\(entry)")
            XCTAssertEqual(manager.activeServer?.headerLogoColorHex, "#34C759", "\(entry)")
            XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: hermesServer)?.username, "me", "\(entry)")
            XCTAssertTrue(headers.snapshot().isEmpty, "\(entry): the webui's headers never go to a Hermes server")
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 2, "\(entry)")
        }
    }

    func testASavedHermesServerIsNeverReplaced() async throws {
        defer { HermesHostFixture.reset() }
        let keychain = InMemoryKeychainStore()
        let manager = try await makeHermesManager(keychain: keychain)
        let form = makeForm(entry: .addServer)
        form.serverURLString = "hermes.example"
        await form.connect(authManager: manager)
        form.username = "me"
        form.password = "other"

        for replacing in [false, true] {
            let added = await form.connect(authManager: manager, replacingWebuiServer: replacing)
            XCTAssertNil(added)
            XCTAssertFalse(form.offersWebuiReplace)
            XCTAssertEqual(form.errorMessage, "This server is already configured.")
        }
        let replaced = await manager.replaceWebuiServer(with: hermesRecord(password: "other"))
        XCTAssertFalse(replaced)
        XCTAssertEqual(manager.lastErrorMessage, "This server is already configured.")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0)
        XCTAssertEqual(manager.servers.map(\.kind), [.webui, .hermes])
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: hermesServer)?.password, "secret")
    }

    func testOnboardingOpensASavedHermesServer() async throws {
        defer { HermesHostFixture.reset() }
        for isSignedIn in [true, false] {
            HermesHostFixture.reset()
            let keychain = InMemoryKeychainStore()
            let manager = try await makeHermesManager(keychain: keychain)
            let store = BotConnectionStore(keychain: keychain)
            let saved = try XCTUnwrap(store.load(server: hermesServer))
            if !isSignedIn { try store.remove(server: hermesServer) }
            manager.switchActiveServer(to: try XCTUnwrap(manager.servers.first { $0.kind == .webui }))
            manager.handleAPIError(APIError.unauthorized)
            XCTAssertEqual(manager.state, .loggedOut(server: webuiServer))
            let form = makeForm(entry: .onboarding)
            form.serverURLString = "HERMES.example/"

            await form.connect(authManager: manager)

            XCTAssertNil(form.errorMessage, "signed in: \(isSignedIn)")
            XCTAssertEqual(manager.state, isSignedIn ? .loggedIn(server: hermesServer) : .loggedOut(server: hermesServer))
            XCTAssertEqual(manager.servers.map(\.kind), [.webui, .hermes])
            XCTAssertEqual(try store.load(server: hermesServer), isSignedIn ? saved : nil)
            XCTAssertTrue(HermesHostFixture.requests.isEmpty, "signed in: \(isSignedIn)")
        }
    }

    func testASavedPasswordLeavesTheFormWhenTheAddressChanges() async throws {
        defer { HermesHostFixture.reset() }
        let rows: [(saved: String, typed: String, edited: String)] = [
            ("https://hermes.example", "hermes.example", "other.example"),
            ("http://hermes.local:9119", "hermes.local:9119", "https://hermes.local:9119")
        ]
        for row in rows {
            HermesHostFixture.reset()
            let keychain = InMemoryKeychainStore()
            let manager = makeFormManager(keychain: keychain)
            await manager.configure(serverURLString: webuiServer.absoluteString, password: "")
            let side = BotConnection(id: UUID(), name: "Side", address: URL(string: row.saved)!, username: "me", password: "saved",
                                     headers: [CustomHeader(name: "CF-Access-Client-Secret", value: "secret.access")])
            try BotConnectionStore(keychain: keychain).save(side, server: webuiServer)
            let form = makeForm(entry: .addServer)
            form.serverURLString = row.typed
            await form.connect(authManager: manager)
            form.useSavedSignIn(try XCTUnwrap(form.savedSignIns.first, row.typed))
            form.customHeaders[0].name = "X-Renamed"

            form.serverURLString = row.edited

            XCTAssertEqual(form.password, "", "\(row.edited): a saved password only goes to the address it was saved for")
            XCTAssertEqual(form.username, "", row.edited)
            XCTAssertTrue(form.customHeaders.isEmpty, "\(row.edited): so does its Access secret, renamed or not")
            XCTAssertNil(form.reusedSignIn, row.edited)
            XCTAssertNil(form.detectedKind, row.edited)
        }
    }

    func testAReusedSignInStillChecksTheSavedInstallBeforeThePassword() async throws {
        defer { HermesHostFixture.reset() }
        let status = BotJSON.object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                     "version": .string("0.21.5"), "install_id": .string("another-install")])
        let keychain = InMemoryKeychainStore()
        let manager = makeFormManager(keychain: keychain)
        let form = makeForm(entry: .addServer) { $0.url?.path == "/api/status" ? .json(200, status) : nil }
        await manager.configure(serverURLString: webuiServer.absoluteString, password: "")
        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "saved",
                                 installID: "install-1")
        try BotConnectionStore(keychain: keychain).save(side, server: webuiServer)
        form.serverURLString = "hermes.example"
        await form.connect(authManager: manager)
        form.useSavedSignIn(try XCTUnwrap(form.savedSignIns.first))

        let added = await form.connect(authManager: manager)

        XCTAssertNil(added)
        XCTAssertEqual(form.errorMessage, "The Hermes host at this address reports a different identity than the one you connected to. Check the address in the Hermes connection.")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0)
        XCTAssertEqual(manager.servers.map(\.id), [webuiServer.absoluteString])
    }

    func testASavedSignInNeverGoesDownTheWebuiPath() async throws {
        defer { HermesHostFixture.reset() }
        let keychain = InMemoryKeychainStore()
        let preferences = UserDefaults.ephemeral()
        let webui = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = AuthManager(keychain: keychain, clientFactory: { _ in webui }, probeClientFactory: { _, _ in webui },
                                  headerStore: CustomHeaderStore(), serverRegistry: ServerRegistry.inMemory(keychain: keychain),
                                  hermesConnections: HermesConnections(), preferences: preferences)
        await manager.configure(serverURLString: webuiServer.absoluteString, password: "webui-pw")
        let side = BotConnection(id: UUID(), name: "Side", address: hermesServer, username: "me", password: "saved",
                                 headers: [CustomHeader(name: "CF-Access-Client-Secret", value: "secret.access")])
        try BotConnectionStore(keychain: keychain).save(side, server: webuiServer)
        var statusReads = 0
        let form = makeForm(entry: .addServer) { request in
            guard request.url?.path == "/api/status" else { return nil }
            statusReads += 1
            return statusReads == 1 ? nil : .json(404, .object([:]))
        }
        form.serverURLString = "hermes.example"
        await form.connect(authManager: manager)
        form.useSavedSignIn(try XCTUnwrap(form.savedSignIns.first))
        form.customHeaders.append(CustomHeader(name: "X-Extra", value: "1"))
        let webuiLogins = webui.loginPasswords

        let added = await form.connect(authManager: manager)

        XCTAssertNil(added)
        XCTAssertEqual(webui.loginPasswords, webuiLogins, "The saved Hermes password never reaches the webui")
        XCTAssertTrue(form.showsPasswordField, "The webui asks for its own password")
        XCTAssertEqual(form.password, "")
        XCTAssertEqual(form.customHeaders.map(\.name), ["X-Extra"], "Nor does its Access secret")
        XCTAssertNil(form.reusedSignIn)
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
