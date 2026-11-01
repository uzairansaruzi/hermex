import XCTest
@testable import HermesMobile

final class AppIconChoiceTests: XCTestCase {
    /// Every choice reads back from the icon name iOS reports, and a name the app
    /// no longer ships falls back to the system icon.
    func testResolvedRoundTripsEveryChoiceAndFallsBackToSystem() {
        for choice in AppIconChoice.allCases {
            XCTAssertEqual(AppIconChoice.resolved(from: choice.alternateIconName), choice)
        }
        XCTAssertEqual(AppIconChoice.resolved(from: "UnknownIcon"), .system)
    }
}
