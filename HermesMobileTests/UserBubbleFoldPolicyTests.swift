import UIKit
import XCTest
@testable import HermesMobile

final class UserBubbleFoldPolicyTests: XCTestCase {
    private let body = UIFont.systemFont(ofSize: 17)

    /// About 1,200 characters of ordinary prose with no hard line breaks.
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

    /// A 99-character message is a short bubble at the default size but can
    /// wrap past eight lines at AX3's 40 pt, so there it must be measured.
    func testPreFilterLetsThroughTextThatCanWrapPastEightLines() {
        let message = "Deploy failed again on staging. Can you find why the migration step times out? It worked yesterday."
        let sevenWrappingLines = Array(repeating: String(repeating: "word ", count: 8), count: 7)
            .joined(separator: "\n")

        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: paragraph, font: body))
        XCTAssertFalse(UserBubbleFoldPolicy.mayFold(text: message, font: body))
        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: message, font: .systemFont(ofSize: 40)))
        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: sevenWrappingLines, font: body))
    }

    /// The narrowest text column is 228 pt: a 320 pt window (Slide Over,
    /// Display Zoom) less the row padding, the gutter and the bubble padding.
    /// The longest text the pre-filter skips must fit there, capitals included.
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
