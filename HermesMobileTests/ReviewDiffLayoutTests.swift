import XCTest
@testable import HermesMobile

final class ReviewDiffLayoutTests: XCTestCase {
    private let metrics = ReviewDiffMetrics(rowHeight: 20, fileHeaderHeight: 50, noticeHeight: 44)

    private func header(_ fileID: String) -> ReviewDiffRow {
        ReviewDiffRow(
            id: "\(fileID):header",
            fileID: fileID,
            kind: .file(ReviewDiffFileHeader(path: fileID, previousPath: nil, changeKind: .modified, additions: 0, deletions: 0))
        )
    }

    private func line(_ fileID: String, _ index: Int, _ content: String = "x") -> ReviewDiffRow {
        ReviewDiffRow(
            id: "\(fileID):line:\(index)",
            fileID: fileID,
            kind: .line(ReviewDiffLine(content: content, change: .context, oldLineNumber: index, newLineNumber: index))
        )
    }

    /// Two files: a header and three lines each.
    private var rows: [ReviewDiffRow] {
        [header("a"), line("a", 0, "short"), line("a", 1, "a much longer line"), line("a", 2),
         header("b"), line("b", 0), line("b", 1), line("b", 2)]
    }

    func testOffsetsArePrefixSumsAndCollapsedRowsHaveNoHeight() {
        let open = ReviewDiffLayout(rows: rows, collapsedFileIDs: [], metrics: metrics)
        XCTAssertEqual(open.rowOffsets, [0, 50, 70, 90, 110, 160, 180, 200])
        XCTAssertEqual(open.contentHeight, 220)
        XCTAssertEqual(open.fileHeaderRowIndices, [0, 4])
        XCTAssertEqual(open.visibleRowIndices, Array(0..<8))
        XCTAssertEqual(open.maxColumnCountsByFileID, ["a": 18, "b": 1])

        let collapsed = ReviewDiffLayout(rows: rows, collapsedFileIDs: ["a"], metrics: metrics)
        XCTAssertEqual(collapsed.rowOffsets, [0, 50, 50, 50, 50, 100, 120, 140])
        XCTAssertEqual(collapsed.contentHeight, 160)
        XCTAssertEqual(collapsed.visibleRowIndices, [0, 4, 5, 6, 7])
        XCTAssertEqual(collapsed.fileHeaderOffset(forFileID: "b"), 50)
    }

    func testHitTestingFindsRowsAndSkipsCollapsedOnes() {
        let open = ReviewDiffLayout(rows: rows, collapsedFileIDs: [], metrics: metrics)
        XCTAssertEqual(open.rowIndex(at: 0), 0)
        XCTAssertEqual(open.rowIndex(at: 49.9), 0)
        XCTAssertEqual(open.rowIndex(at: 50), 1)
        XCTAssertEqual(open.rowIndex(at: 219), 7)
        XCTAssertNil(open.rowIndex(at: 220))
        XCTAssertNil(open.rowIndex(at: -1))

        let collapsed = ReviewDiffLayout(rows: rows, collapsedFileIDs: ["a"], metrics: metrics)
        XCTAssertEqual(collapsed.rowIndex(at: 50), 4, "Collapsed rows are invisible to hit testing.")
    }

    func testRowRangeCoversIntersectingRowsOnly() {
        let layout = ReviewDiffLayout(rows: rows, collapsedFileIDs: [], metrics: metrics)
        XCTAssertEqual(layout.rowRange(intersecting: 60, 165), 1...5)
        XCTAssertEqual(layout.rowRange(intersecting: 0, 10), 0...0)
        XCTAssertEqual(layout.rowRange(intersecting: 300, 400), nil)
    }

    func testStickyHeaderPinsThenIsPushedOffByTheNextHeader() {
        let layout = ReviewDiffLayout(rows: rows, collapsedFileIDs: [], metrics: metrics)
        XCTAssertNil(layout.stickyHeader(atVerticalOffset: 0), "The header is in place, nothing to pin.")
        XCTAssertEqual(layout.stickyHeader(atVerticalOffset: 30), .init(rowIndex: 0, y: 0))
        // File b's header starts at 110; with 50 pt of header it starts pushing at offset 60.
        XCTAssertEqual(layout.stickyHeader(atVerticalOffset: 60), .init(rowIndex: 0, y: 0))
        XCTAssertEqual(layout.stickyHeader(atVerticalOffset: 80), .init(rowIndex: 0, y: -20))
        XCTAssertNil(layout.stickyHeader(atVerticalOffset: 110), "Fully pushed off, and b is in place.")
        XCTAssertEqual(layout.stickyHeader(atVerticalOffset: 150), .init(rowIndex: 4, y: 0), "The last file never gets pushed.")
    }

    func testVisibleFileFollowsTheScrollOffset() {
        let layout = ReviewDiffLayout(rows: rows, collapsedFileIDs: [], metrics: metrics)
        XCTAssertEqual(layout.visibleFileID(atVerticalOffset: 0), "a")
        XCTAssertEqual(layout.visibleFileID(atVerticalOffset: 109), "a")
        XCTAssertEqual(layout.visibleFileID(atVerticalOffset: 110), "b")
        XCTAssertNil(ReviewDiffLayout(rows: [], collapsedFileIDs: [], metrics: metrics).visibleFileID(atVerticalOffset: 0))
    }
}

extension ReviewDiffLayoutTests {
    func testWrappedRowsGrowByVisualLineAndCapTheContentWidth() {
        let metrics = ReviewDiffMetrics(rowHeight: 20, fileHeaderHeight: 50, noticeHeight: 44, wrappedLineHeight: 14)
        let rows = [
            ReviewDiffRow(id: "s:0", fileID: "s", kind: .line(ReviewDiffLine(content: String(repeating: "x", count: 25), change: .context, oldLineNumber: nil, newLineNumber: 1))),
            ReviewDiffRow(id: "s:1", fileID: "s", kind: .line(ReviewDiffLine(content: "short", change: .context, oldLineNumber: nil, newLineNumber: 2))),
            ReviewDiffRow(id: "s:2", fileID: "s", kind: .line(ReviewDiffLine(content: String(repeating: "y", count: 20), change: .context, oldLineNumber: nil, newLineNumber: 3)))
        ]

        let wrapped = ReviewDiffLayout(rows: rows, collapsedFileIDs: [], metrics: metrics, wrapColumns: 10)
        XCTAssertEqual(wrapped.visualLineCount(forRowAt: 0), 3)
        XCTAssertEqual(wrapped.visualLineCount(forRowAt: 1), 1)
        XCTAssertEqual(wrapped.visualLineCount(forRowAt: 2), 2, "An exact multiple does not add an empty visual line.")
        XCTAssertEqual(wrapped.rowOffsets, [0, 48, 68])
        XCTAssertEqual(wrapped.contentHeight, 102)
        XCTAssertEqual(wrapped.maxColumnCountsByFileID, ["s": 10], "Wrapped files never pan wider than one visual line.")
        XCTAssertEqual(wrapped.rowIndex(at: 47), 0)
        XCTAssertEqual(wrapped.rowIndex(at: 48), 1)

        let unwrapped = ReviewDiffLayout(rows: rows, collapsedFileIDs: [], metrics: metrics)
        XCTAssertEqual(unwrapped.rowOffsets, [0, 20, 40])
        XCTAssertEqual(unwrapped.maxColumnCountsByFileID, ["s": 25])
    }
}
