import XCTest
@testable import HermesMobile

/// The Bot Mode preview gate (#496): default off, and the Bots row plus the
/// Bots inbox stay unreachable until it is on.
final class BotModeGateTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "BotModeGateTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Adding a Hermes server needs the gate; turning it off later never locks the user
    /// out of one they have (#899).
    @MainActor func testOnlyAddingAHermesServerNeedsTheGate() throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let hermes = try XCTUnwrap(URL(string: "https://hermes.example"))
        let record = BotConnection(id: UUID(), name: "Studio", address: hermes, username: "me", password: "secret")
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(), serverRegistry: registry,
                                  hermesConnections: HermesConnections(), preferences: defaults)

        XCTAssertFalse(manager.addHermesServer(record))
        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(try BotConnectionStore(keychain: keychain).load(server: hermes))

        defaults.set(true, forKey: BotModeGate.isEnabledKey)
        XCTAssertTrue(manager.addHermesServer(record))

        defaults.set(false, forKey: BotModeGate.isEnabledKey)
        let relaunched = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(), serverRegistry: registry,
                                     hermesConnections: HermesConnections(), preferences: defaults)
        XCTAssertEqual(relaunched.state, .loggedIn(server: hermes))
    }

    func testGateDefaultsOffAndPersistsWhenTurnedOn() {
        XCTAssertFalse(BotModeGate.isEnabled(in: defaults))
        defaults.set(true, forKey: BotModeGate.isEnabledKey)
        XCTAssertTrue(BotModeGate.isEnabled(in: defaults))
    }
}
