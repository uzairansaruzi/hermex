import XCTest
@testable import HermesMobile

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
