import XCTest
import HermexWatchRoot
@testable import HermexWatchApp

final class HermexWatchAppTests: XCTestCase {
    @MainActor
    func testFirstRunCopyRemainsTruthful() {
        let model = WatchRootModel()

        XCTAssertEqual(model.primaryMessage, "Set up on iPhone")
    }
}
