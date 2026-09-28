import UIKit
import XCTest
@testable import HermesMobile

final class SourceHighlighterTests: XCTestCase {
    func testLanguageResolutionPrefersTheServerThenTheExtension() {
        XCTAssertEqual(SourceHighlightLanguage.resolve(path: "a/b.swift", serverLanguage: nil), "swift")
        XCTAssertEqual(SourceHighlightLanguage.resolve(path: "Podfile", serverLanguage: "ruby"), "ruby")
        XCTAssertEqual(SourceHighlightLanguage.resolve(path: "x.tsx", serverLanguage: "typescriptreact"), "typescript",
                       "An unknown server language falls back to the extension alias.")
        XCTAssertEqual(SourceHighlightLanguage.resolve(path: "lib.h", serverLanguage: nil), "c")
        XCTAssertNil(SourceHighlightLanguage.resolve(path: "notes.txt", serverLanguage: "text"))
        XCTAssertNil(SourceHighlightLanguage.resolve(path: "LICENSE", serverLanguage: nil))
    }

    func testRunsByLineSplitsColourRunsAtNewlinesWithLineLocalOffsets() {
        let text = NSMutableAttributedString(string: "ab\ncde\n\nf")
        let red = UIColor.red
        let blue = UIColor.blue
        // "b\ncd" spans the first newline; "f" is on the last line with no newline after it.
        text.addAttribute(.foregroundColor, value: red, range: NSRange(location: 1, length: 4))
        text.addAttribute(.foregroundColor, value: blue, range: NSRange(location: 8, length: 1))

        let runs = SourceHighlighter.runsByLine(in: text, lineCount: 4)

        XCTAssertEqual(runs.count, 4)
        XCTAssertEqual(runs[0], [SourceHighlightRun(range: NSRange(location: 1, length: 1), color: red)])
        XCTAssertEqual(runs[1], [SourceHighlightRun(range: NSRange(location: 0, length: 2), color: red)])
        XCTAssertEqual(runs[2], [])
        XCTAssertEqual(runs[3], [SourceHighlightRun(range: NSRange(location: 0, length: 1), color: blue)])
    }

    func testHighlightReturnsColourForJSONAndBlanksOverLongLines() async throws {
        let long = String(repeating: "x", count: SourceHighlighter.maxLineLength + 1)
        let lines = ["{\"key\": 1,", long, "\"flag\": true}"]

        let result = await SourceHighlighter().highlight(lines: lines, language: "json", isDark: false)
        let runs = try XCTUnwrap(result)

        XCTAssertEqual(runs.count, 3)
        XCTAssertFalse(runs[0].isEmpty, "A JSON key should get at least one colour run.")
        XCTAssertTrue(runs[1].isEmpty, "Over-long lines are not tokenized.")
        XCTAssertFalse(runs[2].isEmpty)
        for run in runs.flatMap({ $0 }) {
            XCTAssertLessThanOrEqual(NSMaxRange(run.range), (lines[2] as NSString).length + 1)
        }
    }
}
