import XCTest
@testable import HermesMobile

final class SourceFileRowsTests: XCTestCase {
    func testLinesDropTheTrailingNewlineStripCarriageReturnsAndExpandTabs() {
        XCTAssertEqual(SourceFileRows.lines(in: "a\n\tb\r\nc\n"), ["a", "    b", "c"])
        XCTAssertEqual(SourceFileRows.lines(in: ""), [""], "An empty file is one blank line, not none.")
        XCTAssertEqual(SourceFileRows.lines(in: "\n"), [""], "A lone newline is one blank line.")
        XCTAssertEqual(SourceFileRows.lines(in: "a\n\n"), ["a", ""], "Only the final newline is dropped.")
    }

    func testRowsAreContextLinesNumberedFromOneWithStableIDs() throws {
        let rows = SourceFileRows.rows(for: ["let x = 1", ""])
        XCTAssertEqual(rows.map(\.id), ["source:line:0", "source:line:1"])
        XCTAssertEqual(Set(rows.map(\.fileID)), [SourceFileRows.fileID])
        let first = try XCTUnwrap(rows[0].line)
        XCTAssertEqual(first.content, "let x = 1")
        XCTAssertEqual(first.change, .context)
        XCTAssertEqual(first.displayLineNumber, 1)
        XCTAssertEqual(rows[1].line?.displayLineNumber, 2)
        XCTAssertTrue(first.wordDiffRanges.isEmpty)
    }
}
