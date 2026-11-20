import XCTest
@testable import HermesMobile

@MainActor
final class ServerRegistryTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRegistry(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        identityDefaults: UserDefaults = .ephemeral()
    ) -> ServerRegistry {
        let stamp = fixedDate
        return ServerRegistry(keychain: keychain, identityDefaults: identityDefaults, now: { stamp })
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    func testActivateAddsServerAndMarksItActive() throws {
        let registry = makeRegistry()
        let server = try url("https://example.test")

        let account = registry.activate(url: server)

        XCTAssertEqual(account.id, "https://example.test")
        XCTAssertEqual(account.urlString, "https://example.test")
        XCTAssertEqual(registry.servers.map(\.id), ["https://example.test"])
        XCTAssertEqual(registry.activeServerID, "https://example.test")
        XCTAssertEqual(registry.activeServer, account)
    }

    func testActivateDeduplicatesURLsThatNormalizeToTheSameServer() throws {
        let registry = makeRegistry()
        let first = try AuthManager.normalizedServerURL(from: "https://www.webui.example.test")
        let second = try AuthManager.normalizedServerURL(from: "www.webui.example.test/some/path")

        registry.activate(url: first)
        registry.activate(url: second)

        XCTAssertEqual(registry.servers.count, 1)
        XCTAssertEqual(registry.activeServer?.id, "https://webui.example.test")
    }

    func testActiveServerPersistsToKeychainAndHydratesIntoAFreshRegistry() throws {
        let keychain = InMemoryKeychainStore()
        let writer = makeRegistry(keychain: keychain)
        writer.activate(url: try url("https://example.test"))

        XCTAssertNotNil(keychain.savedValues[.servers])
        let reader = ServerRegistry(keychain: keychain)
        XCTAssertEqual(reader.servers.count, 1)
        XCTAssertEqual(reader.activeServer?.id, "https://example.test")
    }

    func testActivatingTheAlreadyActiveServerDoesNotRewriteTheKeychain() throws {
        let keychain = InMemoryKeychainStore()
        let registry = makeRegistry(keychain: keychain)
        let server = try url("https://example.test")

        registry.activate(url: server)
        let writesAfterFirstActivate = keychain.saveCounts[.servers]

        registry.activate(url: server)

        XCTAssertEqual(keychain.saveCounts[.servers], writesAfterFirstActivate)
        XCTAssertEqual(registry.activeServerID, "https://example.test")
    }

    func testActivateSeedsIdentityFromGlobalDefaultsOnFirstInsert() throws {
        let defaults = UserDefaults.ephemeral()
        defaults.set("Alice", forKey: SessionIdentitySettings.displayNameKey)
        defaults.set("AL", forKey: SessionIdentitySettings.initialsKey)
        defaults.set("#5B7CFF", forKey: HeaderLogoColor.storageKey)
        let registry = makeRegistry(identityDefaults: defaults)

        let account = registry.activate(url: try url("https://example.test"))

        XCTAssertEqual(account.displayName, "Alice")
        XCTAssertEqual(account.initials, "AL")
        XCTAssertEqual(account.headerLogoColorHex, "#5B7CFF")
        XCTAssertEqual(account.createdAt, fixedDate)
        XCTAssertEqual(account.updatedAt, fixedDate)
    }

    func testActivateDoesNotReseedIdentityWhenServerAlreadyExists() throws {
        let defaults = UserDefaults.ephemeral()
        defaults.set("Alice", forKey: SessionIdentitySettings.displayNameKey)
        let registry = makeRegistry(identityDefaults: defaults)
        let server = try url("https://example.test")
        registry.activate(url: server)

        defaults.set("Bob", forKey: SessionIdentitySettings.displayNameKey)
        let reactivated = registry.activate(url: server)

        XCTAssertEqual(reactivated.displayName, "Alice")
        XCTAssertEqual(registry.servers.count, 1)
    }

    func testForgetActiveServerRemovesItAndClearsActive() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://example.test"))

        registry.forgetActiveServer()

        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.activeServerID)
        XCTAssertNil(registry.activeServer)
    }

    func testSetActiveSwitchesToAnExistingServer() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test"))
        registry.activate(url: try url("https://b.test"))
        XCTAssertEqual(registry.activeServerID, "https://b.test")

        let result = registry.setActive(id: "https://a.test")

        XCTAssertEqual(result?.id, "https://a.test")
        XCTAssertEqual(registry.activeServerID, "https://a.test")
    }

    func testSetActiveMirrorsTheNewActiveIdentityToDefaults() throws {
        let defaults = UserDefaults.ephemeral()
        let registry = makeRegistry(identityDefaults: defaults)
        registry.activate(url: try url("https://a.test"))
        var alpha = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })
        alpha.displayName = "Alpha"
        alpha.initials = "AL"
        alpha.headerLogoColorHex = "#FF3B30"
        registry.update(alpha)
        registry.activate(url: try url("https://b.test"))

        registry.setActive(id: "https://a.test")

        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "Alpha")
        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.initialsKey), "AL")
        XCTAssertEqual(defaults.string(forKey: HeaderLogoColor.storageKey), "#FF3B30")
    }

    func testRemoveActiveServerAutoSelectsTheNextRemaining() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test"))
        registry.activate(url: try url("https://b.test"))

        let newActive = registry.remove(id: "https://b.test")

        XCTAssertEqual(newActive?.id, "https://a.test")
        XCTAssertEqual(registry.activeServerID, "https://a.test")
        XCTAssertEqual(registry.servers.map(\.id), ["https://a.test"])
    }

    func testRemoveActiveServerWithNoOthersClearsActiveAndReturnsNil() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test"))

        let newActive = registry.remove(id: "https://a.test")

        XCTAssertNil(newActive)
        XCTAssertNil(registry.activeServerID)
        XCTAssertTrue(registry.servers.isEmpty)
    }

    func testRemoveNonActiveServerLeavesActiveSelectionUntouched() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test"))
        registry.activate(url: try url("https://b.test"))

        let active = registry.remove(id: "https://a.test")

        XCTAssertEqual(active?.id, "https://b.test")
        XCTAssertEqual(registry.activeServerID, "https://b.test")
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
    }

    func testUpdateMirrorsToDefaultsOnlyWhenServerIsActive() throws {
        let defaults = UserDefaults.ephemeral()
        let registry = makeRegistry(identityDefaults: defaults)
        registry.activate(url: try url("https://a.test"))
        registry.activate(url: try url("https://b.test"))
        let before = defaults.string(forKey: SessionIdentitySettings.displayNameKey)

        var inactiveA = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })
        inactiveA.displayName = "ShouldNotMirror"
        registry.update(inactiveA)

        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), before)

        var activeB = try XCTUnwrap(registry.servers.first { $0.id == "https://b.test" })
        activeB.displayName = "MirrorsThis"
        registry.update(activeB)

        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "MirrorsThis")
    }

    func testReactivatingAnExistingServerMirrorsItsIdentityToDefaults() throws {
        let defaults = UserDefaults.ephemeral()
        let registry = makeRegistry(identityDefaults: defaults)
        registry.activate(url: try url("https://a.test"))
        var alpha = try XCTUnwrap(registry.servers.first)
        alpha.displayName = "Alpha"
        registry.update(alpha)
        registry.activate(url: try url("https://b.test"))

        registry.activate(url: try url("https://a.test"))

        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "Alpha")
        XCTAssertEqual(registry.activeServerID, "https://a.test")
    }

    func testActivatingANewServerDoesNotMirrorIntoEmptyDefaults() throws {
        let defaults = UserDefaults.ephemeral()
        let registry = makeRegistry(identityDefaults: defaults)

        registry.activate(url: try url("https://webui.example.com"))

        XCTAssertNil(defaults.string(forKey: SessionIdentitySettings.displayNameKey))
        XCTAssertNil(defaults.string(forKey: SessionIdentitySettings.initialsKey))
    }

    func testCorruptStoredBlobHydratesToEmptyRegistry() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("not json", forKey: .servers)
        let registry = ServerRegistry(keychain: keychain)

        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.activeServer)
    }

    func testOneUnreadableEntryLeavesTheRestOfTheListLoaded() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(#"{"servers":[{"displayName":"no id"},{"id":"https://a.test"}],"activeServerID":"https://a.test"}"#,
                          forKey: .servers)

        let registry = ServerRegistry(keychain: keychain)

        XCTAssertEqual(registry.servers.map(\.id), ["https://a.test"])
        XCTAssertEqual(registry.activeServerID, "https://a.test")
    }

    func testAMissingOrUnknownKindLoadsAsAWebuiServer() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(#"{"servers":[{"id":"https://a.test"},{"id":"https://b.test","kind":"satellite"},{"id":"https://c.test","kind":7},{"id":"https://d.test","kind":"hermes"}]}"#,
                          forKey: .servers)

        let registry = ServerRegistry(keychain: keychain)

        XCTAssertEqual(registry.servers.map(\.kind), [.webui, .webui, .webui, .hermes])
    }

    func testAMoveQuestionStageLoadsAndAnUnknownOneReadsAsUnasked() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(#"{"servers":[{"id":"https://a.test","moveToHermesPrompt":"dismissed"},{"id":"https://b.test","moveToHermesPrompt":"asked"},{"id":"https://c.test","moveToHermesPrompt":"snoozed"},{"id":"https://d.test","moveToHermesPrompt":3},{"id":"https://e.test"}]}"#,
                          forKey: .servers)

        let registry = ServerRegistry(keychain: keychain)

        XCTAssertEqual(registry.servers.map(\.moveToHermesPrompt), [.dismissed, .asked, nil, nil, nil])
    }

    func testAHermesServersKindAndVersionSurviveARelaunch() throws {
        let keychain = InMemoryKeychainStore()
        let registry = makeRegistry(keychain: keychain)
        registry.activate(url: try url("https://webui.test"))

        registry.activate(url: try url("http://127.0.0.1:9199"), kind: .hermes, serverVersion: "0.21.5")
        registry.activate(url: try url("http://127.0.0.1:9199"))

        let relaunched = ServerRegistry(keychain: keychain)
        XCTAssertEqual(relaunched.servers.map(\.kind), [.webui, .hermes])
        XCTAssertEqual(relaunched.servers.map(\.serverVersion), [nil, "0.21.5"])
        XCTAssertEqual(relaunched.activeServerID, "http://127.0.0.1:9199")
    }

    func testServerAccountDecodesWithOnlyAnIdPresent() throws {
        let json = Data(#"{"id":"https://example.test","customHeadersRef":"https://example.test"}"#.utf8)
        let account = try JSONDecoder().decode(ServerAccount.self, from: json)

        XCTAssertEqual(account.id, "https://example.test")
        XCTAssertEqual(account.urlString, "https://example.test")
        XCTAssertEqual(account.displayName, "")
        XCTAssertEqual(account.headerLogoColorHex, HeaderLogoColor.defaultHex)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        XCTAssertNil(encoded?["customHeadersRef"])
    }

    func testLegacyServerURLMigratesIntoRegistryOnLaunch() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("https://legacy.test", forKey: .serverURL)
        let defaults = UserDefaults.ephemeral()
        defaults.set("Casey", forKey: SessionIdentitySettings.displayNameKey)
        defaults.set("#34C759", forKey: HeaderLogoColor.storageKey)
        let stamp = fixedDate
        let registry = ServerRegistry(keychain: keychain, identityDefaults: defaults, now: { stamp })

        _ = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false)) },
            serverRegistry: registry
        )

        XCTAssertEqual(registry.activeServer?.id, "https://legacy.test")
        XCTAssertEqual(registry.activeServer?.displayName, "Casey")
        XCTAssertEqual(registry.activeServer?.headerLogoColorHex, "#34C759")
    }

    func testFullSignOutForgetsServerFromRegistry() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "example.test", password: "")

        await manager.signOut()

        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.activeServer)
    }

    func testSessionExpiryKeepsServerInRegistry() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false)) },
            serverRegistry: registry
        )
        await manager.configure(serverURLString: "example.test", password: "")

        manager.handleAPIError(APIError.unauthorized)

        XCTAssertEqual(registry.activeServer?.urlString, "https://example.test")
    }

    func testNormalizationDefaultsSchemelessHostToHTTPS() throws {
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "example.com"),
            URL(string: "https://example.com")
        )
    }

    func testNormalizationDefaultsLocalhostToHTTP() throws {
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "localhost:8080"),
            URL(string: "http://localhost:8080")
        )
    }
}

extension UserDefaults {
    static func ephemeral(_ suiteName: String = "test.hermes.\(UUID().uuidString)") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

extension ServerRegistry {
    static func inMemory(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        identityDefaults: UserDefaults = .ephemeral()
    ) -> ServerRegistry {
        ServerRegistry(keychain: keychain, identityDefaults: identityDefaults)
    }
}
