import CoreGraphics
import Foundation

/// Row heights the layout needs. The canvas derives them from the resolved fonts so
/// Dynamic Type changes rebuild the layout instead of clipping text.
struct ReviewDiffMetrics: Equatable {
    var rowHeight: CGFloat
    var fileHeaderHeight: CGFloat
    var noticeHeight: CGFloat
}

/// Vertical geometry of the row list: prefix-sum offsets, binary-search hit testing,
/// and the sticky header the next file header pushes off screen. Pure and cheap to
/// rebuild, so collapse and Dynamic Type just build a new one.
struct ReviewDiffLayout {
    struct StickyHeader: Equatable {
        let rowIndex: Int
        /// Top of the header in viewport coordinates, zero or negative while the
        /// next file header pushes it up.
        let y: CGFloat
    }

    let rows: [ReviewDiffRow]
    let collapsedFileIDs: Set<String>
    let metrics: ReviewDiffMetrics
    private(set) var rowOffsets: [CGFloat] = []
    private(set) var fileHeaderRowIndices: [Int] = []
    /// Rows with a non-zero height, in order; the accessibility element list.
    private(set) var visibleRowIndices: [Int] = []
    private(set) var contentHeight: CGFloat = 0
    /// Longest line per file, in characters; the canvas turns it into a content width.
    private(set) var maxColumnCountsByFileID: [String: Int] = [:]

    init(rows: [ReviewDiffRow], collapsedFileIDs: Set<String>, metrics: ReviewDiffMetrics) {
        self.rows = rows
        self.collapsedFileIDs = collapsedFileIDs
        self.metrics = metrics

        rowOffsets.reserveCapacity(rows.count)
        var offset: CGFloat = 0
        for (index, row) in rows.enumerated() {
            rowOffsets.append(offset)
            if row.isFileHeader { fileHeaderRowIndices.append(index) }
            let height = height(forRowAt: index)
            if height > 0 { visibleRowIndices.append(index) }
            offset += height
            let columns = row.columnCount
            if columns > 0 {
                maxColumnCountsByFileID[row.fileID] = max(maxColumnCountsByFileID[row.fileID] ?? 0, columns)
            }
        }
        contentHeight = offset
    }

    func height(forRowAt index: Int) -> CGFloat {
        let row = rows[index]
        switch row.kind {
        case .file:
            return metrics.fileHeaderHeight
        case .hunk, .line:
            return collapsedFileIDs.contains(row.fileID) ? 0 : metrics.rowHeight
        case .notice:
            return collapsedFileIDs.contains(row.fileID) ? 0 : metrics.noticeHeight
        }
    }

    /// Vertical extent of a row in content coordinates.
    func frame(forRowAt index: Int) -> (minY: CGFloat, height: CGFloat)? {
        guard rows.indices.contains(index) else { return nil }
        return (rowOffsets[index], height(forRowAt: index))
    }

    /// The row containing `absoluteY`, skipping collapsed (zero-height) rows.
    func rowIndex(at absoluteY: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count - 1
        while lower <= upper {
            let middle = (lower + upper) / 2
            let start = rowOffsets[middle]
            let end = start + height(forRowAt: middle)
            if absoluteY < start {
                upper = middle - 1
            } else if absoluteY >= end {
                lower = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    func firstRowIndex(endingAtOrAfter absoluteY: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rowOffsets[middle] + height(forRowAt: middle) < absoluteY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < rows.count ? lower : nil
    }

    func lastRowIndex(startingAtOrBefore absoluteY: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rowOffsets[middle] <= absoluteY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : nil
    }

    /// Rows that intersect `minY...maxY` in content coordinates.
    func rowRange(intersecting minY: CGFloat, _ maxY: CGFloat) -> ClosedRange<Int>? {
        guard let first = firstRowIndex(endingAtOrAfter: minY),
              let last = lastRowIndex(startingAtOrBefore: maxY),
              first <= last else { return nil }
        return first...last
    }

    func fileHeaderRowIndex(forFileID fileID: String) -> Int? {
        fileHeaderRowIndices.first { rows[$0].fileID == fileID }
    }

    func fileHeaderOffset(forFileID fileID: String) -> CGFloat? {
        fileHeaderRowIndex(forFileID: fileID).map { rowOffsets[$0] }
    }

    /// Position (in `fileHeaderRowIndices`) of the last header at or above `absoluteY`.
    private func lastHeaderPosition(atOrAbove absoluteY: CGFloat) -> Int? {
        var lower = 0
        var upper = fileHeaderRowIndices.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rowOffsets[fileHeaderRowIndices[middle]] <= absoluteY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : nil
    }

    /// The file whose header is at or above the viewport top, or the first file.
    func visibleFileID(atVerticalOffset verticalOffset: CGFloat) -> String? {
        guard let firstHeader = fileHeaderRowIndices.first else { return nil }
        let position = lastHeaderPosition(atOrAbove: verticalOffset + 0.5)
        let rowIndex = position.map { fileHeaderRowIndices[$0] } ?? firstHeader
        return rows[rowIndex].fileID
    }

    /// The header pinned at the top once its own row has scrolled past, pushed up by
    /// the next file's header until it is fully off screen.
    func stickyHeader(atVerticalOffset verticalOffset: CGFloat) -> StickyHeader? {
        guard let position = lastHeaderPosition(atOrAbove: verticalOffset) else { return nil }
        let rowIndex = fileHeaderRowIndices[position]
        guard rowOffsets[rowIndex] < verticalOffset else { return nil }

        var pushedY: CGFloat = 0
        if fileHeaderRowIndices.indices.contains(position + 1) {
            let nextTop = rowOffsets[fileHeaderRowIndices[position + 1]]
            pushedY = min(0, nextTop - verticalOffset - metrics.fileHeaderHeight)
        }
        guard pushedY > -metrics.fileHeaderHeight else { return nil }
        return StickyHeader(rowIndex: rowIndex, y: pushedY)
    }
}
