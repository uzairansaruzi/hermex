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
