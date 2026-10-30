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

    /// A comment left empty lands exactly as the old "Add to prompt" snippet did (#399).
    func testUncommentedSnippetIsPathLineRangeAndFencedDiff() {
        var selection = ReviewDiffSelection()
        selection.longPress(rowID: "f:line:0", fileID: "f")
        selection.tap(rowID: "f:line:3", fileID: "f")
        XCTAssertEqual(
            selection.commentContext(in: rows)?.markdown(comment: " \n"),
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
        XCTAssertEqual(selection.commentContext(in: rows)?.markdown(), "Other.swift L1\n```diff\n+x\n```")
        selection.clear()
        XCTAssertNil(selection.commentContext(in: rows))
    }

    func testFenceOutgrowsBackticksInsideTheSelection() {
        let markdown = [
            ReviewDiffRow(id: "m:header", fileID: "m", kind: .file(ReviewDiffFileHeader(path: "README.md", previousPath: nil, changeKind: .modified, additions: 1, deletions: 0))),
            ReviewDiffRow(id: "m:line:0", fileID: "m", kind: .line(ReviewDiffLine(content: "```swift", change: .addition, oldLineNumber: nil, newLineNumber: 4))),
            ReviewDiffRow(id: "m:line:1", fileID: "m", kind: .line(ReviewDiffLine(content: "let x = `y`", change: .addition, oldLineNumber: nil, newLineNumber: 5)))
        ]
        var selection = ReviewDiffSelection()
        selection.longPress(rowID: "m:line:0", fileID: "m")
        selection.tap(rowID: "m:line:1", fileID: "m")
        XCTAssertEqual(selection.commentContext(in: markdown)?.markdown(), "README.md L4-L5\n````diff\n+```swift\n+let x = `y`\n````")
    }

    func testSourceSelectionQuotesUnprefixedLinesInALanguageFence() {
        let source = SourceFileRows.rows(for: ["/// Use `x`:", "/// ```", "let x = 1"])
        var selection = ReviewDiffSelection()
        selection.longPress(rowID: SourceFileRows.rowID(forLineIndex: 0), fileID: SourceFileRows.fileID)
        selection.tap(rowID: SourceFileRows.rowID(forLineIndex: 2), fileID: SourceFileRows.fileID)
        XCTAssertEqual(
            selection.sourceCommentContext(in: source, path: "Sources/X.swift", language: "swift")?.markdown(comment: "rename x"),
            "Sources/X.swift L1-L3: rename x\n````swift\n/// Use `x`:\n/// ```\nlet x = 1\n````"
        )
    }

    /// Comments from two files land after what the user typed, in the order added,
    /// each a paragraph of its own, and the bar counts them.
    func testCommentsAppendToTheDraftInOrder() throws {
        var composer = ReviewCommentComposer()
        var draft = "Can you tighten these up?"
        var selection = ReviewDiffSelection()
        for (rowID, fileID, comment) in [("f:line:1", "f", "why remove this?"), ("g:line:0", "g", ""), ("f:line:2", "f", "and this")] {
            selection.tap(rowID: rowID, fileID: fileID)
            composer.context = selection.commentContext(in: rows)
            draft = ReviewCommentComposer.appending(try XCTUnwrap(composer.add(comment: comment)), to: draft)
        }
        XCTAssertEqual(draft, """
            Can you tighten these up?

            Sources/App.swift L11: why remove this?
            ```diff
            -old()
            ```

            Other.swift L1
            ```diff
            +x
            ```

            Sources/App.swift L11: and this
            ```diff
            +new()
            ```

            """)
        XCTAssertEqual(composer.addedCount, 3)
        XCTAssertNil(composer.context, "Add closes the comment sheet.")
    }
}
