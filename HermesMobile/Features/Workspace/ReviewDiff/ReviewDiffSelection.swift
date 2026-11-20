import Foundation

struct ReviewDiffSelection: Equatable {
    private(set) var fileID: String?
    private(set) var anchorRowID: String?
    private(set) var endRowID: String?
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

    func commentContext(in rows: [ReviewDiffRow]) -> ReviewCommentContext? {
        let path = rows.first { $0.fileID == fileID && $0.isFileHeader }?.fileHeader?.path ?? fileID
        return commentContext(in: rows, path: path, language: "diff") { line in
            switch line.change {
            case .addition: "+" + line.content
            case .deletion: "-" + line.content
            case .context: " " + line.content
            }
        }
    }

    func sourceCommentContext(in rows: [ReviewDiffRow], path: String, language: String?) -> ReviewCommentContext? {
        commentContext(in: rows, path: path, language: language ?? "") { $0.content }
    }

    private func commentContext(
        in rows: [ReviewDiffRow],
        path: String?,
        language: String,
        quote: (ReviewDiffLine) -> String
    ) -> ReviewCommentContext? {
        let lines = selectedRows(in: rows).compactMap(\.line)
        guard let path, !lines.isEmpty else { return nil }
        let numbers = lines.compactMap(\.displayLineNumber)
        let body = lines.map(quote)
        let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: body) + 1))
        return ReviewCommentContext(
            path: path,
            lines: numbers.first.flatMap { first in numbers.last.map { (first, $0) } },
            fencedLines: "\(fence)\(language)\n\(body.joined(separator: "\n"))\n\(fence)"
        )
    }

    private static func longestBacktickRun(in lines: [String]) -> Int {
        var longest = 0
        for line in lines {
            var run = 0
            for character in line {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return longest
    }
}


struct ReviewCommentContext: Identifiable {
    let id = UUID()
    let path: String
    let lines: (first: Int, last: Int)?
    let fencedLines: String

    func markdown(comment: String = "") -> String {
        var heading = path
        if let lines {
            heading += lines.first == lines.last ? " L\(lines.first)" : " L\(lines.first)-L\(lines.last)"
        }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { heading += ": " + comment }
        return heading + "\n" + fencedLines
    }
}

struct ReviewCommentComposer {
    var context: ReviewCommentContext?
    private(set) var addedCount = 0

    mutating func add(comment: String) -> String? {
        guard let context else { return nil }
        self.context = nil
        addedCount += 1
        return context.markdown(comment: comment)
    }

    mutating func discard() {
        context = nil
    }

    static func appending(_ markdown: String, to draft: String) -> String {
        let separator = draft.isEmpty ? "" : (draft.hasSuffix("\n") ? "\n" : "\n\n")
        return draft + separator + markdown + "\n"
    }
}
