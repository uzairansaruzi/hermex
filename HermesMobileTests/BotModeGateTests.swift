import XCTest
@testable import HermesMobile

/// The Bot Mode preview gate (#496): default off, and a webui server's Bots row plus
/// its Bots inbox stay unreachable until it is on.
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

    /// Hermes is the default kind (#712): adding a Hermes server never needs the gate.
    @MainActor func testAddingAHermesServerNeverNeedsTheGate() throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry.inMemory(keychain: keychain)
        let hermes = try XCTUnwrap(URL(string: "https://hermes.example"))
        let record = BotConnection(id: UUID(), name: "Studio", address: hermes, username: "me", password: "secret")
        let manager = AuthManager(keychain: keychain, headerStore: CustomHeaderStore(), serverRegistry: registry,
                                  hermesConnections: HermesConnections(), preferences: defaults)

        XCTAssertFalse(BotModeGate.isEnabled(in: defaults))
        XCTAssertTrue(manager.addHermesServer(record))
        XCTAssertEqual(manager.state, .loggedIn(server: hermes))
    }
}
