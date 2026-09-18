import XCTest
@testable import HermesMobile

@MainActor
final class ServerRegistryTests: XCTestCase {
    /// Fixed timestamp so seeded `createdAt`/`updatedAt` are deterministic.
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

    // MARK: - activate: add + mark active

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

    // MARK: - Duplicate prevention

    func testActivateDeduplicatesTheSameURL() throws {
        let registry = makeRegistry()
        let server = try url("https://example.test")

        registry.activate(url: server)
        registry.activate(url: server)

        XCTAssertEqual(registry.servers.count, 1)
        XCTAssertEqual(registry.activeServerID, "https://example.test")
    }

    func testActivateDeduplicatesURLsThatNormalizeToTheSameServer() throws {
        let registry = makeRegistry()
        // Two raw inputs the onboarding normalizer collapses to one server.
        let first = try AuthManager.normalizedServerURL(from: "https://www.webui.example.test")
        let second = try AuthManager.normalizedServerURL(from: "www.webui.example.test/some/path")

        registry.activate(url: first)
        registry.activate(url: second)

        XCTAssertEqual(registry.servers.count, 1)
        XCTAssertEqual(registry.activeServer?.id, "https://webui.example.test")
    }

    // MARK: - Keychain persistence + hydration

    func testActiveServerPersistsToKeychainAndHydratesIntoAFreshRegistry() throws {
        let keychain = InMemoryKeychainStore()
        let writer = makeRegistry(keychain: keychain)
        writer.activate(url: try url("https://example.test"))

        // The blob is in the Keychain, not UserDefaults...
        XCTAssertNotNil(keychain.savedValues[.servers])
        // ...and a brand-new registry over the same Keychain hydrates from it.
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

        // Re-activating the already-active server (e.g. every launch via
        // restoreSavedServer) must not write the Keychain again.
        registry.activate(url: server)

        XCTAssertEqual(keychain.saveCounts[.servers], writesAfterFirstActivate)
        XCTAssertEqual(registry.activeServerID, "https://example.test")
    }

    // MARK: - Identity seeding

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

    func testActivateDerivesIdentityFromHostWhenGlobalsAreEmpty() throws {
        let registry = makeRegistry() // empty identity defaults

        let account = registry.activate(url: try url("https://webui.example.com"))

        XCTAssertEqual(account.displayName, "webui.example.com")
        XCTAssertEqual(account.initials, "W") // derived from the host
        XCTAssertEqual(account.headerLogoColorHex, HeaderLogoColor.defaultHex)
    }

    func testActivateDoesNotReseedIdentityWhenServerAlreadyExists() throws {
        let defaults = UserDefaults.ephemeral()
        defaults.set("Alice", forKey: SessionIdentitySettings.displayNameKey)
        let registry = makeRegistry(identityDefaults: defaults)
        let server = try url("https://example.test")
        registry.activate(url: server)

        // An identity change after the first insert must not overwrite the entry
        // (per-server edits from #17 must survive relaunch / re-activation).
        defaults.set("Bob", forKey: SessionIdentitySettings.displayNameKey)
        let reactivated = registry.activate(url: server)

        XCTAssertEqual(reactivated.displayName, "Alice")
        XCTAssertEqual(registry.servers.count, 1)
    }

    // MARK: - forgetActiveServer

    func testForgetActiveServerRemovesItAndClearsActive() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://example.test"))

        registry.forgetActiveServer()

        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.activeServerID)
        XCTAssertNil(registry.activeServer)
    }

    func testForgetActiveServerWithNoActiveServerIsANoOp() {
        let registry = makeRegistry()
        registry.forgetActiveServer()
        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.activeServerID)
    }

    // MARK: - setActive / remove / update (#17)

    func testSetActiveSwitchesToAnExistingServer() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test"))
        registry.activate(url: try url("https://b.test")) // b is now active
        XCTAssertEqual(registry.activeServerID, "https://b.test")

        let result = registry.setActive(id: "https://a.test")

        XCTAssertEqual(result?.id, "https://a.test")
        XCTAssertEqual(registry.activeServerID, "https://a.test")
    }

    func testSetActiveIsNoOpForUnregisteredOrAlreadyActiveServer() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test")) // active

        XCTAssertNil(registry.setActive(id: "https://a.test"))      // already active
        XCTAssertNil(registry.setActive(id: "https://missing.test")) // not registered
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
        registry.activate(url: try url("https://b.test")) // b active

        registry.setActive(id: "https://a.test")

        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "Alpha")
        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.initialsKey), "AL")
        XCTAssertEqual(defaults.string(forKey: HeaderLogoColor.storageKey), "#FF3B30")
    }

    func testRemoveActiveServerAutoSelectsTheNextRemaining() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test"))
        registry.activate(url: try url("https://b.test")) // b active, list [a, b]

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
        registry.activate(url: try url("https://b.test")) // b active

        let active = registry.remove(id: "https://a.test") // remove the non-active one

        XCTAssertEqual(active?.id, "https://b.test")
        XCTAssertEqual(registry.activeServerID, "https://b.test")
        XCTAssertEqual(registry.servers.map(\.id), ["https://b.test"])
    }

    func testRemoveUnregisteredIdIsANoOp() throws {
        let registry = makeRegistry()
        registry.activate(url: try url("https://a.test"))

        let active = registry.remove(id: "https://missing.test")

        XCTAssertEqual(active?.id, "https://a.test")
        XCTAssertEqual(registry.servers.map(\.id), ["https://a.test"])
    }

    func testUpdateReplacesEntryAndBumpsUpdatedAt() throws {
        var clock = fixedDate
        let registry = ServerRegistry(
            keychain: InMemoryKeychainStore(),
            identityDefaults: .ephemeral(),
            now: { clock }
        )
        registry.activate(url: try url("https://a.test"))
        var account = try XCTUnwrap(registry.servers.first)
        account.displayName = "Renamed"

        let later = fixedDate.addingTimeInterval(60)
        clock = later
        registry.update(account)

        let updated = try XCTUnwrap(registry.servers.first)
        XCTAssertEqual(updated.displayName, "Renamed")
        XCTAssertEqual(updated.updatedAt, later)
        XCTAssertEqual(updated.createdAt, fixedDate) // unchanged
    }

    func testUpdateMirrorsToDefaultsOnlyWhenServerIsActive() throws {
        let defaults = UserDefaults.ephemeral()
        let registry = makeRegistry(identityDefaults: defaults)
        registry.activate(url: try url("https://a.test"))
        registry.activate(url: try url("https://b.test")) // b active
        let before = defaults.string(forKey: SessionIdentitySettings.displayNameKey)

        var inactiveA = try XCTUnwrap(registry.servers.first { $0.id == "https://a.test" })
        inactiveA.displayName = "ShouldNotMirror"
        registry.update(inactiveA)

        // a is not active, so editing it must not touch the global mirror.
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
        registry.update(alpha) // a active → mirrors "Alpha"
        registry.activate(url: try url("https://b.test")) // b active (insert, no mirror)

        // Switching back to a via activate must mirror a's identity.
        registry.activate(url: try url("https://a.test"))

        XCTAssertEqual(defaults.string(forKey: SessionIdentitySettings.displayNameKey), "Alpha")
        XCTAssertEqual(registry.activeServerID, "https://a.test")
    }

    func testActivatingANewServerDoesNotMirrorIntoEmptyDefaults() throws {
        let defaults = UserDefaults.ephemeral() // empty
        let registry = makeRegistry(identityDefaults: defaults)

        // A new entry is *seeded from* the defaults (host-derived when empty); it
        // must not write back, so first-run avatar fallback stays unchanged (#17).
        registry.activate(url: try url("https://webui.example.com"))

        XCTAssertNil(defaults.string(forKey: SessionIdentitySettings.displayNameKey))
        XCTAssertNil(defaults.string(forKey: SessionIdentitySettings.initialsKey))
    }

    // MARK: - Tolerant decoding

    func testCorruptStoredBlobHydratesToEmptyRegistry() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("not json", forKey: .servers)
        let registry = ServerRegistry(keychain: keychain)

        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.activeServer)
    }

    func testServerAccountDecodesWithOnlyAnIdPresent() throws {
        // A minimal blob must still decode, defaulting the rest (CLAUDE.md rule 3).
        // Legacy blobs may still carry `customHeadersRef`; ignore it on decode
        // and never write it back (headers are scoped by URL in Keychain).
        let json = Data(#"{"id":"https://example.test","customHeadersRef":"https://example.test"}"#.utf8)
        let account = try JSONDecoder().decode(ServerAccount.self, from: json)

        XCTAssertEqual(account.id, "https://example.test")
        XCTAssertEqual(account.urlString, "https://example.test")
        XCTAssertEqual(account.displayName, "")
        XCTAssertEqual(account.headerLogoColorHex, HeaderLogoColor.defaultHex)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        XCTAssertNil(encoded?["customHeadersRef"])
    }

    // MARK: - Migration + lifecycle through AuthManager

    func testLegacyServerURLMigratesIntoRegistryOnLaunch() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("https://legacy.test", forKey: .serverURL)
        let defaults = UserDefaults.ephemeral()
        defaults.set("Casey", forKey: SessionIdentitySettings.displayNameKey)
        defaults.set("#34C759", forKey: HeaderLogoColor.storageKey)
        let stamp = fixedDate
        let registry = ServerRegistry(keychain: keychain, identityDefaults: defaults, now: { stamp })

        // Constructing AuthManager runs restoreSavedServer() → the one-time migration.
        _ = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false)) },
            serverRegistry: registry
        )

        XCTAssertEqual(registry.activeServer?.id, "https://legacy.test")
        XCTAssertEqual(registry.activeServer?.displayName, "Casey")
        XCTAssertEqual(registry.activeServer?.headerLogoColorHex, "#34C759")
    }

    func testNoSavedServerLeavesRegistryEmptyOnLaunch() {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())

        _ = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false)) },
            serverRegistry: registry
        )

        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.activeServer)
    }

    func testConfigureRegistersServerAsActive() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false)) },
            serverRegistry: registry
        )

        await manager.configure(serverURLString: "example.test", password: "")

        XCTAssertEqual(registry.activeServer?.urlString, "https://example.test")
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

        // A stale session cookie must not forget the server (re-login keeps it).
        manager.handleAPIError(APIError.unauthorized)

        XCTAssertEqual(registry.activeServer?.urlString, "https://example.test")
    }

    // MARK: - URL normalization characterization (dedup depends on this)

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

    func testNormalizationStripsPathQueryAndFragment() throws {
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "https://example.com/api?x=1#frag"),
            URL(string: "https://example.com")
        )
    }

    func testNormalizationRejectsBlankInput() {
        XCTAssertThrowsError(try AuthManager.normalizedServerURL(from: "   "))
    }
}

extension UserDefaults {
    /// Test-only: an isolated, empty defaults suite for the global identity seed
    /// values. Each call returns a fresh, cleared suite.
    static func ephemeral(_ suiteName: String = "test.hermes.\(UUID().uuidString)") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

extension ServerRegistry {
    /// Test-only: a registry backed by a throwaway in-memory Keychain + identity
    /// defaults, so it never touches the real Keychain or `.standard`.
    static func inMemory(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        identityDefaults: UserDefaults = .ephemeral()
    ) -> ServerRegistry {
        ServerRegistry(keychain: keychain, identityDefaults: identityDefaults)
    }
}
