import XCTest
@testable import HermesMobile

final class ReasoningSummaryFormatterTests: XCTestCase {
    func testCollapsesNewlineRunsToOneSpace() {
        XCTAssertEqual(
            ReasoningSummaryFormatter.summary(for: "First line\n\nSecond line\r\nThird"),
            "First line Second line Third"
        )
    }

    func testKeepsTextAtTheLimitIntact() {
        let text = String(repeating: "a", count: ReasoningSummaryFormatter.characterLimit)
        XCTAssertEqual(ReasoningSummaryFormatter.summary(for: text), text)
    }

    func testCutsTextPastTheLimitWithAnEllipsis() {
        let text = String(repeating: "b", count: ReasoningSummaryFormatter.characterLimit + 1)
        XCTAssertEqual(
            ReasoningSummaryFormatter.summary(for: text),
            String(repeating: "b", count: ReasoningSummaryFormatter.characterLimit) + "..."
        )
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(ReasoningSummaryFormatter.summary(for: "  \nplan  \n"), "plan")
    }

    func testStopsReadingAtTheScanLimitEvenAcrossNewlines() {
        let text = "a" + String(repeating: "\n", count: ReasoningSummaryFormatter.scanLimit) + "b"
        XCTAssertEqual(ReasoningSummaryFormatter.summary(for: text), "a")
    }
}
