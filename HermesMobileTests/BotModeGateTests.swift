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

    func testGateDefaultsOffAndPersistsWhenTurnedOn() {
        XCTAssertFalse(BotModeGate.isEnabled(in: defaults))
        defaults.set(true, forKey: BotModeGate.isEnabledKey)
        XCTAssertTrue(BotModeGate.isEnabled(in: defaults))
    }
}
