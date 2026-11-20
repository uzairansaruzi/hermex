import XCTest
@testable import HermesMobile

final class AppIconChoiceTests: XCTestCase {
    func testResolvedRoundTripsEveryChoiceAndFallsBackToSystem() {
        for choice in AppIconChoice.allCases {
            XCTAssertEqual(AppIconChoice.resolved(from: choice.alternateIconName), choice)
        }
        XCTAssertEqual(AppIconChoice.resolved(from: "UnknownIcon"), .system)
    }
}
