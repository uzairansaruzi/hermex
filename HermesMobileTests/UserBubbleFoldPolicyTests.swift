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

    func testShortMessageIsNeverMeasuredAtAnyTextSize() {
        let fifty = String(repeating: "Short note. ", count: 5).prefix(50)

        XCTAssertFalse(UserBubbleFoldPolicy.mayFold(text: String(fifty), font: body))
        XCTAssertFalse(UserBubbleFoldPolicy.mayFold(text: String(fifty), font: .systemFont(ofSize: 53)))
    }

    /// The design's AX3 frame: a 168-character message is a short bubble at the
    /// default size but wraps past eight lines at 40 pt, so it must be measured.
    func testPreFilterLetsThroughTextThatCanWrapPastEightLines() {
        let message = "Deploy failed again on staging. Can you find why the migration step times out? "
            + "It worked yesterday with the same config, and the only change is the new network peering."
        let sevenWrappingLines = Array(repeating: String(repeating: "word ", count: 8), count: 7)
            .joined(separator: "\n")

        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: paragraph, font: body))
        XCTAssertFalse(UserBubbleFoldPolicy.mayFold(text: message, font: body))
        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: message, font: .systemFont(ofSize: 40)))
        XCTAssertTrue(UserBubbleFoldPolicy.mayFold(text: sevenWrappingLines, font: body))
    }

    func testLongParagraphWrapsPastEightLinesAndStopsAtTheLimit() {
        let lines = UserBubbleFoldPolicy.lineCount(text: paragraph, width: 300, font: body)

        XCTAssertGreaterThan(lines, 8)
        XCTAssertEqual(UserBubbleFoldPolicy.lineCount(text: paragraph, width: 300, font: body, limit: 9), 9)
    }

    func testWiderBubbleWrapsToFewerLines() {
        let narrow = UserBubbleFoldPolicy.lineCount(text: paragraph, width: 300, font: body)
        let wide = UserBubbleFoldPolicy.lineCount(text: paragraph, width: 700, font: body)

        XCTAssertGreaterThan(wide, 0)
        XCTAssertLessThan(wide, narrow)
    }

    func testCJKWrapsToMoreLinesThanLatinOfTheSameLength() {
        let latin = String(paragraph.prefix(200))
        let cjk = String(String(repeating: "我们在服务器上运行代理并在手机上查看结果", count: 12).prefix(200))

        let latinLines = UserBubbleFoldPolicy.lineCount(text: latin, width: 300, font: body)
        let cjkLines = UserBubbleFoldPolicy.lineCount(text: cjk, width: 300, font: body)

        XCTAssertGreaterThan(latinLines, 0)
        XCTAssertGreaterThan(cjkLines, latinLines)
    }
}
