import Foundation

/// Line selection on the review surface. A tap selects one line (tapping it again
/// clears), a long press anchors a range and the next tap in the same file ends it.
/// The selection is a pair of row ids so it survives a rows rebuild with stable ids.
struct ReviewDiffSelection: Equatable {
    private(set) var fileID: String?
    private(set) var anchorRowID: String?
    private(set) var endRowID: String?
    /// True between a long press and the tap that ends the range.
    private(set) var isAwaitingRangeEnd = false

    var isEmpty: Bool { anchorRowID == nil }

    mutating func longPress(rowID: String, fileID: String) {
        self.fileID = fileID
        anchorRowID = rowID
        endRowID = rowID
        isAwaitingRangeEnd = true
    }

    mutating func tap(rowID: String, fileID: String) {
        if isAwaitingRangeEnd, self.fileID == fileID {
            endRowID = rowID
            isAwaitingRangeEnd = false
            return
        }
        if anchorRowID == rowID, endRowID == rowID {
            clear()
            return
        }
        self.fileID = fileID
        anchorRowID = rowID
        endRowID = rowID
        isAwaitingRangeEnd = false
    }

    mutating func clear() {
        fileID = nil
        anchorRowID = nil
        endRowID = nil
        isAwaitingRangeEnd = false
    }

    /// The line rows between anchor and end, inclusive, in either direction.
    func selectedRows(in rows: [ReviewDiffRow]) -> [ReviewDiffRow] {
        guard let anchorRowID, let endRowID,
              let anchorIndex = rows.firstIndex(where: { $0.id == anchorRowID }),
              let endIndex = rows.firstIndex(where: { $0.id == endRowID }) else { return [] }
        let range = min(anchorIndex, endIndex)...max(anchorIndex, endIndex)
        return rows[range].filter { $0.line != nil && $0.fileID == fileID }
    }

    func selectedRowIDs(in rows: [ReviewDiffRow]) -> Set<String> {
        Set(selectedRows(in: rows).map(\.id))
    }

    /// Plain Markdown for the composer: path and line range, then the selected lines
    /// as a fenced diff so the agent sees what was added, removed, or unchanged.
    func snippet(in rows: [ReviewDiffRow]) -> String? {
        let selected = selectedRows(in: rows)
        guard let fileID, !selected.isEmpty else { return nil }
        let path = rows.first { $0.fileID == fileID && $0.isFileHeader }?.fileHeader?.path ?? fileID
        let numbers = selected.compactMap { $0.line?.displayLineNumber }
        var heading = path
        if let first = numbers.first, let last = numbers.last {
            heading += first == last ? " L\(first)" : " L\(first)-L\(last)"
        }
        let body = selected.compactMap { row -> String? in
            guard let line = row.line else { return nil }
            let prefix: String
            switch line.change {
            case .addition: prefix = "+"
            case .deletion: prefix = "-"
            case .context: prefix = " "
            }
            return prefix + line.content
        }
        return "\(heading)\n```diff\n\(body.joined(separator: "\n"))\n```"
    }
}
