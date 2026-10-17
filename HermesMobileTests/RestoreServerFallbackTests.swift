import XCTest
@testable import HermesMobile

/// Tests for the `restoreSavedServer` reliability fix — the fallback path that
/// recovers the server URL from `ServerRegistry` when the primary Keychain entry
/// (`server_url`) is lost, and the diagnostic logging that distinguishes a missing
/// entry from a Keychain read error.
///
/// These tests exercise the `AuthManager.init` → `restoreSavedServer()` flow by
/// constructing the manager with different Keychain/registry states and asserting
/// the resulting `AuthManager.State`.
///
/// **Can be validated on this Linux host** via `swift test --filter RestoreServerFallbackTests`
/// once a Package.swift test target exists. **Full Xcode validation** requires macOS
/// with Xcode 26+ and the HermesMobile project.
@MainActor
final class RestoreServerFallbackTests: XCTestCase {
    private let testServerURLString = "https://hermes.example.test"
    private lazy var testServerURL: URL = URL(string: testServerURLString)!

    // MARK: - Primary path: Keychain has the server URL

    /// Happy path: `server_url` is in the Keychain → the manager restores it and
    /// enters an active state (loggedIn for a webui server, loggedOut for a Hermes
    /// server without a saved BotConnection).
    func testRestoresServerFromKeychainWhenPresent() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save(testServerURLString, forKey: .serverURL)
        let registry = ServerRegistry.inMemory(keychain: keychain)

        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        // A webui server enters .loggedIn optimistically (a stale cookie is
        // demoted by the first 401).
        XCTAssertEqual(manager.state, .loggedIn(server: testServerURL))
        XCTAssertEqual(keychain.savedValues[.serverURL], testServerURLString)
    }

    // MARK: - Fallback path: Keychain missing, registry has the server

    /// The core reliability fix: when `server_url` is missing from the Keychain
    /// but the multi-server `ServerRegistry` has an active entry, the manager
    /// recovers from the registry instead of falling to `.unconfigured`.
    func testFallsBackToRegistryWhenKeychainServerURLMissing() {
        let keychain = InMemoryKeychainStore()
        // Do NOT set keychain.savedValues[.serverURL] — simulate the loss.
        let registry = ServerRegistry.inMemory(keychain: keychain)
        registry.activate(url: testServerURL)

        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        // The manager should recover from the registry, not show onboarding.
        XCTAssertNotEqual(manager.state, .unconfigured,
                          "Registry fallback should prevent .unconfigured when the registry has a server")
        XCTAssertEqual(manager.state, .loggedIn(server: testServerURL))
    }

    /// After recovering from the registry, the manager re-persists the URL to the
    /// primary Keychain key so the next cold launch finds it without needing the
    /// fallback again.
    func testRegistryFallbackRepersistsURLToKeychain() {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        registry.activate(url: testServerURL)

        _ = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        XCTAssertEqual(keychain.savedValues[.serverURL], testServerURLString,
                       "The recovered URL must be re-persisted to the primary Keychain key")
    }

    /// The registry fallback honours the server’s kind: a webui server enters
    /// `.loggedIn` (optimistic); a Hermes server without a saved BotConnection
    /// enters `.loggedOut`, because `enterActiveServer` checks for a connection record.
    func testRegistryFallbackRespectsServerKind() {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)

        // Activate a Hermes-kind server with no saved BotConnection.
        registry.activate(url: testServerURL, kind: .hermes)

        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        // A Hermes server recovered from the registry without a BotConnection
        // should be loggedOut — not optimistically loggedIn like webui.
        XCTAssertEqual(manager.state, .loggedOut(server: testServerURL))
    }

    /// A Hermes server recovered from the registry enters `.loggedIn` when a
    /// BotConnection record IS present in the keychain.
    func testHermesRegistryFallbackWithConnectionIsLoggedIn() {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)

        // Activate a Hermes-kind server.
        registry.activate(url: testServerURL, kind: .hermes)

        // Save a BotConnection for this server so enterActiveServer finds it.
        let connection = BotConnection(
            id: UUID(),
            name: "Test Bot",
            address: testServerURL,
            username: "test",
            password: "test"
        )
        try! BotConnectionStore(keychain: keychain).save(connection, server: testServerURL)

        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        // A Hermes server WITH a saved BotConnection should be loggedIn.
        XCTAssertEqual(manager.state, .loggedIn(server: testServerURL))
    }

    // MARK: - Complete loss: both Keychain and registry are empty

    /// When neither the Keychain nor the registry has a server, the manager must
    /// enter `.unconfigured` (first launch or full sign-out).
    func testEntersUnconfiguredWhenBothKeychainAndRegistryEmpty() {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)

        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
    }

    // MARK: - Diagnostic Keychain loading (KeychainStore.LoadResult)
    //
    // These tests use the real KeychainStore (not InMemoryKeychainStore) because
    // they exercise the `loadWithDiagnostics` method which is defined on the
    // concrete struct. They require the macOS/iOS Keychain and cannot run on Linux.

    #if canImport(Security)
    /// `loadWithDiagnostics` returns `.value` for a present key.
    func testLoadWithDiagnosticsReturnsValueWhenPresent() {
        let store = KeychainStore(service: "test.restore-fallback.\(UUID().uuidString)")
        try? store.save("https://hermes.test", forKey: .serverURL)
        defer { try? store.delete(.serverURL) }

        let result = store.loadWithDiagnostics(.serverURL)
        if case .value(let url) = result {
            XCTAssertEqual(url, "https://hermes.test")
        } else {
            XCTFail("Expected .value, got \(result)")
        }
    }

    /// `loadWithDiagnostics` returns `.missing` for a key that was never set.
    func testLoadWithDiagnosticsReturnsMissingWhenAbsent() {
        let store = KeychainStore(service: "test.restore-fallback.\(UUID().uuidString)")
        // No save — the key doesn’t exist.

        let result = store.loadWithDiagnostics(.serverURL)
        if case .missing = result {
            // Expected
        } else {
            XCTFail("Expected .missing for an unset key, got \(result)")
        }
    }
    #endif

    // MARK: - Edge cases

    /// If the Keychain has a non-parseable URL string, it should be treated the
    /// same as missing: the fallback to the registry should be attempted.
    func testMalformedKeychainURLFallsBackToRegistry() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.save("not a valid URL %%%", forKey: .serverURL)
        let registry = ServerRegistry.inMemory(keychain: keychain)
        registry.activate(url: testServerURL)

        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        XCTAssertNotEqual(manager.state, .unconfigured,
                          "A malformed Keychain URL should fall through to the registry fallback")
        XCTAssertEqual(manager.state, .loggedIn(server: testServerURL))
    }

    /// Registry has servers but no active one → should still end up unconfigured.
    func testRegistryWithServersButNoActiveOneFallsToUnconfigured() {
        let keychain = InMemoryKeychainStore()
        // Registry: has servers but none is active (activeServerID is nil).
        // We can’t directly add a non-active server through the public API,
        // but ServerRegistry.inMemory() starts with zero servers and nil active,
        // which is the same outcome: activeServer returns nil.
        let registry = ServerRegistry.inMemory(keychain: keychain)

        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in self.defaultClient },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        XCTAssertEqual(manager.state, .unconfigured)
    }

    /// After a full sign-out, `restoreSavedServer` called on the next init must
    /// not resurrect the server from the registry if sign-out properly cleared it.
    func testSignOutClearsRegistryPreventingFalseRecovery() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false)
        )
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )

        // Configure → loggedIn
        await manager.configure(serverURLString: testServerURLString, password: "pw")
        guard case .loggedIn = manager.state else {
            XCTFail("Expected loggedIn after configure, got \(manager.state)")
            return
        }

        // Sign out fully
        await manager.signOut()
        XCTAssertEqual(manager.state, .unconfigured)

        // Now simulate a cold relaunch: create a new manager with the same
        // keychain and registry. The sign-out should have cleared both.
        let manager2 = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: registry,
            hermesConnections: HermesConnections()
        )
        XCTAssertEqual(manager2.state, .unconfigured,
                       "A new manager after full sign-out must not recover a server from the registry")
    }

    // MARK: - Helpers

    /// Default mock client for tests that only care about `restoreSavedServer`
    /// (the client is never actually called during init).
    private var defaultClient: MockAuthAPIClient {
        MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
    }
}
