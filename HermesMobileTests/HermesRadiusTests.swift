import XCTest
@testable import HermesMobile

final class HermesRadiusTests: XCTestCase {
    func testNumericScaleMatchesApprovedValues() {
        XCTAssertEqual(HermesRadius.r0, 0)
        XCTAssertEqual(HermesRadius.r4, 4)
        XCTAssertEqual(HermesRadius.r8, 8)
        XCTAssertEqual(HermesRadius.r12, 12)
        XCTAssertEqual(HermesRadius.r16, 16)
        XCTAssertEqual(HermesRadius.r20, 20)
        XCTAssertEqual(HermesRadius.r24, 24)
    }

    func testSemanticAliasesMatchApprovedMapping() {
        XCTAssertEqual(HermesRadius.control, HermesRadius.r8)
        XCTAssertEqual(HermesRadius.field, HermesRadius.r12)
        XCTAssertEqual(HermesRadius.card, HermesRadius.r16)
        XCTAssertEqual(HermesRadius.prominent, HermesRadius.r20)
        XCTAssertEqual(HermesRadius.chrome, HermesRadius.r24)
    }
}
