import Network
import XCTest
@testable import HermesMobile

final class NetworkPathMonitorTests: XCTestCase {
    private let wifi = NetworkPathSnapshot(isSatisfied: true, interfaces: ["en0", "pdp_ip0"])
    private let cellular = NetworkPathSnapshot(isSatisfied: true, interfaces: ["pdp_ip0"])
    private let offline = NetworkPathSnapshot(isSatisfied: false, interfaces: [])

    func testRepeatedIdenticalPathDoesNotPublish() {
        XCTAssertFalse(NetworkPathSnapshot.publishesChange(from: wifi, to: wifi))
        XCTAssertFalse(NetworkPathSnapshot.publishesChange(from: offline, to: offline))
    }

    func testReachabilityFlipPublishes() {
        XCTAssertTrue(NetworkPathSnapshot.publishesChange(from: wifi, to: offline))
        XCTAssertTrue(NetworkPathSnapshot.publishesChange(from: offline, to: cellular))
    }

    func testInterfaceChangePublishesOnlyWhileSatisfied() {
        XCTAssertTrue(NetworkPathSnapshot.publishesChange(from: wifi, to: cellular))
        XCTAssertTrue(NetworkPathSnapshot.publishesChange(from: cellular, to: wifi))

        let offlineWithInterface = NetworkPathSnapshot(isSatisfied: false, interfaces: ["en0"])
        XCTAssertFalse(NetworkPathSnapshot.publishesChange(from: offline, to: offlineWithInterface))
    }

    func testUnknownPathCountsAsSatisfied() {
        // Before the first update the monitor reports satisfied, so only an
        // offline first path is news.
        XCTAssertFalse(NetworkPathSnapshot.publishesChange(from: nil, to: wifi))
        XCTAssertTrue(NetworkPathSnapshot.publishesChange(from: nil, to: offline))
    }

    func testOnlyAnUnsatisfiedStatusCountsAsOffline() {
        // A probe is what brings a `requiresConnection` path (an on-demand VPN)
        // up, so waiting on it would never end.
        XCTAssertTrue(NetworkPathSnapshot(status: .requiresConnection, interfaces: []).isSatisfied)
        XCTAssertTrue(NetworkPathSnapshot(status: .satisfied, interfaces: ["en0"]).isSatisfied)
        XCTAssertFalse(NetworkPathSnapshot(status: .unsatisfied, interfaces: []).isSatisfied)
    }
}
