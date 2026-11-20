import CoreGraphics
import Foundation

struct ReviewDiffMetrics: Equatable {
    var rowHeight: CGFloat
    var fileHeaderHeight: CGFloat
    var noticeHeight: CGFloat
    var wrappedLineHeight: CGFloat = 0
}

struct ReviewDiffLayout {
    struct StickyHeader: Equatable {
        let rowIndex: Int
        let y: CGFloat
    }

    let rows: [ReviewDiffRow]
    let collapsedFileIDs: Set<String>
    let metrics: ReviewDiffMetrics
    let wrapColumns: Int?
    private(set) var rowOffsets: [CGFloat] = []
    private(set) var fileHeaderRowIndices: [Int] = []
    private(set) var visibleRowIndices: [Int] = []
    private(set) var contentHeight: CGFloat = 0
    private(set) var maxColumnCountsByFileID: [String: Int] = [:]

    init(rows: [ReviewDiffRow], collapsedFileIDs: Set<String>, metrics: ReviewDiffMetrics, wrapColumns: Int? = nil) {
        self.rows = rows
        self.collapsedFileIDs = collapsedFileIDs
        self.metrics = metrics
        self.wrapColumns = wrapColumns.map { max(1, $0) }

        rowOffsets.reserveCapacity(rows.count)
        var offset: CGFloat = 0
        for (index, row) in rows.enumerated() {
            rowOffsets.append(offset)
            if row.isFileHeader { fileHeaderRowIndices.append(index) }
            let height = height(forRowAt: index)
            if height > 0 { visibleRowIndices.append(index) }
            offset += height
            let columns = min(row.columnCount, self.wrapColumns ?? Int.max)
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
        case .hunk:
            return collapsedFileIDs.contains(row.fileID) ? 0 : metrics.rowHeight
        case .line:
            guard !collapsedFileIDs.contains(row.fileID) else { return 0 }
            return metrics.rowHeight + CGFloat(visualLineCount(forRowAt: index) - 1) * metrics.wrappedLineHeight
        case .notice:
            return collapsedFileIDs.contains(row.fileID) ? 0 : metrics.noticeHeight
        }
    }

    func visualLineCount(forRowAt index: Int) -> Int {
        guard let wrapColumns else { return 1 }
        let columns = rows[index].columnCount
        return max(1, (columns + wrapColumns - 1) / wrapColumns)
    }

    func drawnCharacterRange(
        columnCount: Int,
        reachableColumns: Int,
        visibleMinY: CGFloat,
        visibleMaxY: CGFloat
    ) -> Range<Int> {
        guard let wrapColumns else { return 0..<min(columnCount, max(0, reachableColumns)) }
        let lineHeight = metrics.wrappedLineHeight
        guard lineHeight > 0, visibleMinY <= visibleMaxY else { return 0..<columnCount }
        let lineCount = max(1, (columnCount + wrapColumns - 1) / wrapColumns)
        let first = max(0, Int(floor(visibleMinY / lineHeight)) - 1)
        let last = min(lineCount - 1, Int(ceil(visibleMaxY / lineHeight)) + 1)
        guard first <= last else { return 0..<0 }
        return min(first * wrapColumns, columnCount)..<min((last + 1) * wrapColumns, columnCount)
    }

    func frame(forRowAt index: Int) -> (minY: CGFloat, height: CGFloat)? {
        guard rows.indices.contains(index) else { return nil }
        return (rowOffsets[index], height(forRowAt: index))
    }

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

    func visibleFileID(atVerticalOffset verticalOffset: CGFloat) -> String? {
        guard let firstHeader = fileHeaderRowIndices.first else { return nil }
        let position = lastHeaderPosition(atOrAbove: verticalOffset + 0.5)
        let rowIndex = position.map { fileHeaderRowIndices[$0] } ?? firstHeader
        return rows[rowIndex].fileID
    }

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
