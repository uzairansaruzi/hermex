import XCTest
@testable import HermesMobile

final class ReviewWordDiffTests: XCTestCase {
    func testHighlightsOnlyTheChangedWord() {
        let pair = ReviewWordDiff.ranges(deletion: "let total = price * count", addition: "let total = price * quantity")
        XCTAssertEqual(pair.deletion, [20..<25])
        XCTAssertEqual(pair.addition, [20..<28])
    }

    func testAdjacentChangesMergeAcrossASingleNeutralCharacter() {
        let pair = ReviewWordDiff.ranges(
            deletion: "let value = foo.bar ?? fallback",
            addition: "let value = baz.qux ?? fallback"
        )
        XCTAssertEqual(pair.deletion, [12..<19], "foo, the dot, and bar read as one edit.")
        XCTAssertEqual(pair.addition, [12..<19])
    }

    func testWhitespaceIsTrimmedFromRangeEdges() {
        let pair = ReviewWordDiff.ranges(deletion: "a  b c", addition: "a  x c")
        XCTAssertEqual(pair.deletion, [3..<4])
        XCTAssertEqual(pair.addition, [3..<4])
    }

    func testRewrittenLinesStayPlainAboveTheCoverageGate() {
        let pair = ReviewWordDiff.ranges(deletion: "alpha beta gamma delta", addition: "one two three four")
        XCTAssertEqual(pair.deletion, [])
        XCTAssertEqual(pair.addition, [])
    }

    func testTooManyRangesStayPlain() {
        let pair = ReviewWordDiff.ranges(
            deletion: "a1 keep b1 keep c1 keep d1 keep e1 keep keep keep keep keep keep keep keep",
            addition: "a2 keep b2 keep c2 keep d2 keep e2 keep keep keep keep keep keep keep keep"
        )
        XCTAssertEqual(pair.deletion, [], "Five separate edits are noise, not a word diff.")
        XCTAssertEqual(pair.addition, [])
    }

    func testLongLinesAreSkipped() {
        let long = String(repeating: "x", count: ReviewWordDiff.maxLineLength + 1)
        let pair = ReviewWordDiff.ranges(deletion: long, addition: long + "y")
        XCTAssertEqual(pair.deletion, [])
        XCTAssertEqual(pair.addition, [])
    }

    func testAnnotatePairsRunsIndexByIndexAndStopsAtHunkRows() {
        func line(_ id: String, _ change: DiffLine.Kind, _ content: String) -> ReviewDiffRow {
            ReviewDiffRow(id: id, fileID: "f", kind: .line(ReviewDiffLine(content: content, change: change, oldLineNumber: nil, newLineNumber: nil)))
        }
        var rows = [
            line("d1", .deletion, "let a = one"),
            line("d2", .deletion, "let b = two"),
            line("a1", .addition, "let a = uno"),
            ReviewDiffRow(id: "h", fileID: "f", kind: .hunk("Line 9")),
            line("a2", .addition, "let b = dos")
        ]
        ReviewWordDiff.annotate(&rows)

        XCTAssertEqual(rows[0].line?.wordDiffRanges, [8..<11])
        XCTAssertEqual(rows[2].line?.wordDiffRanges, [8..<11])
        XCTAssertEqual(rows[1].line?.wordDiffRanges, [], "The second deletion has no partner before the hunk row.")
        XCTAssertEqual(rows[4].line?.wordDiffRanges, [])
    }
}
