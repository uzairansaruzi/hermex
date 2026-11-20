import UIKit
import XCTest
@testable import HermesMobile

final class UserBubbleFoldPolicyTests: XCTestCase {
    private let body = UIFont.systemFont(ofSize: 17)

    private let paragraph = String(
        String(repeating: "The quick brown fox jumps over the lazy dog near the riverbank. ", count: 20).prefix(1_200)
    )

    func testEightShortLinesShowInFullAndNineFold() {
        let eight = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let nine = (1...9).map { "line \($0)" }.joined(separator: "\n")

        let eightLines = UserBubbleFoldPolicy.lineCount(text: eight, width: 300, font: body)
        let nineLines = UserBubbleFoldPolicy.lineCount(text: nine, width: 300, font: body)

        XCTAssertEqual(eightLines, 8)
        XCTAssertEqual(nineLines, 9)
        XCTAssertFalse(UserBubbleFoldPolicy.folds(lineCount: eightLines))
        XCTAssertTrue(UserBubbleFoldPolicy.folds(lineCount: nineLines))
    }

    func testPreFilterLetsThroughTextThatCanWrapPastEightLines() {
        let message = "Deploy failed again on staging. Can you find why the migration step times out? It worked yesterday."
        let sevenWrappingLines = Array(repeating: String(repeating: "word ", count: 8), count: 7)
            .joined(separator: "\n")

        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: paragraph, font: body))
        XCTAssertFalse(UserBubbleFoldPolicy.mayFold(text: message, font: body))
        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: message, font: .systemFont(ofSize: 40)))
        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: sevenWrappingLines, font: body))
    }

    func testTextThePreFilterSkipsFitsTheNarrowestColumn() {
        for text in [paragraph, paragraph.uppercased()] {
            var skipped = ""
            for character in text {
                let next = skipped + String(character)
                if UserBubbleFoldPolicy.mayFold(text: next, font: body) { break }
                skipped = next
            }

            XCTAssertLessThanOrEqual(UserBubbleFoldPolicy.lineCount(text: skipped, width: 228, font: body), 8, skipped)
        }
    }

    func testLongParagraphWrapsPastEightLinesAndStopsAtTheLimit() {
        let lines = UserBubbleFoldPolicy.lineCount(text: paragraph, width: 300, font: body)

        XCTAssertGreaterThan(lines, 8)
        XCTAssertEqual(UserBubbleFoldPolicy.lineCount(text: paragraph, width: 300, font: body, limit: 9), 9)
    }
}
