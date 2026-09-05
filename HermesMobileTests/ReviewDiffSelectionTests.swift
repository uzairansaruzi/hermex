import XCTest
@testable import HermesMobile

final class ReviewDiffSelectionTests: XCTestCase {
    private let rows: [ReviewDiffRow] = [
        ReviewDiffRow(id: "f:header", fileID: "f", kind: .file(ReviewDiffFileHeader(path: "Sources/App.swift", previousPath: nil, changeKind: .modified, additions: 1, deletions: 1))),
        ReviewDiffRow(id: "f:hunk:0", fileID: "f", kind: .hunk("Lines 10-12")),
        ReviewDiffRow(id: "f:line:0", fileID: "f", kind: .line(ReviewDiffLine(content: "let a = 1", change: .context, oldLineNumber: 10, newLineNumber: 10))),
        ReviewDiffRow(id: "f:line:1", fileID: "f", kind: .line(ReviewDiffLine(content: "old()", change: .deletion, oldLineNumber: 11, newLineNumber: nil))),
        ReviewDiffRow(id: "f:line:2", fileID: "f", kind: .line(ReviewDiffLine(content: "new()", change: .addition, oldLineNumber: nil, newLineNumber: 11))),
        ReviewDiffRow(id: "f:line:3", fileID: "f", kind: .line(ReviewDiffLine(content: "}", change: .context, oldLineNumber: 12, newLineNumber: 12))),
        ReviewDiffRow(id: "g:header", fileID: "g", kind: .file(ReviewDiffFileHeader(path: "Other.swift", previousPath: nil, changeKind: .added, additions: 1, deletions: 0))),
        ReviewDiffRow(id: "g:line:0", fileID: "g", kind: .line(ReviewDiffLine(content: "x", change: .addition, oldLineNumber: nil, newLineNumber: 1)))
    ]

    func testTapSelectsOneLineAndTappingItAgainClears() {
        var selection = ReviewDiffSelection()
        selection.tap(rowID: "f:line:1", fileID: "f")
        XCTAssertEqual(selection.selectedRowIDs(in: rows), ["f:line:1"])
        selection.tap(rowID: "f:line:1", fileID: "f")
        XCTAssertTrue(selection.isEmpty)
    }

    func testLongPressThenTapSelectsTheRangeInEitherDirection() {
        var selection = ReviewDiffSelection()
        selection.longPress(rowID: "f:line:3", fileID: "f")
        XCTAssertTrue(selection.isAwaitingRangeEnd)
        XCTAssertEqual(selection.selectedRowIDs(in: rows), ["f:line:3"], "The anchor shows as selected while waiting.")
        selection.tap(rowID: "f:line:0", fileID: "f")
        XCTAssertFalse(selection.isAwaitingRangeEnd)
        XCTAssertEqual(selection.selectedRowIDs(in: rows), ["f:line:0", "f:line:1", "f:line:2", "f:line:3"])

        selection.tap(rowID: "f:line:2", fileID: "f")
        XCTAssertEqual(selection.selectedRowIDs(in: rows), ["f:line:2"], "A plain tap after a range starts over.")
    }

    func testTapInAnotherFileWhileAwaitingStartsFresh() {
        var selection = ReviewDiffSelection()
        selection.longPress(rowID: "f:line:0", fileID: "f")
        selection.tap(rowID: "g:line:0", fileID: "g")
        XCTAssertEqual(selection.selectedRowIDs(in: rows), ["g:line:0"])
        XCTAssertFalse(selection.isAwaitingRangeEnd)
    }

    func testSnippetIsPathLineRangeAndFencedDiff() {
        var selection = ReviewDiffSelection()
        selection.longPress(rowID: "f:line:0", fileID: "f")
        selection.tap(rowID: "f:line:3", fileID: "f")
        XCTAssertEqual(
            selection.snippet(in: rows),
            """
            Sources/App.swift L10-L12
            ```diff
             let a = 1
            -old()
            +new()
             }
            ```
            """
        )

        selection.tap(rowID: "g:line:0", fileID: "g")
        XCTAssertEqual(selection.snippet(in: rows), "Other.swift L1\n```diff\n+x\n```")
        selection.clear()
        XCTAssertNil(selection.snippet(in: rows))
    }
}
