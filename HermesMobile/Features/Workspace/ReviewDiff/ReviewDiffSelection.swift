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

    /// The selected diff lines for Comment…: prefixed with `+`, `-`, or a space so the
    /// agent sees what was added, removed, or unchanged, in a `diff` fence.
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

    /// The selected lines of a workspace file for Comment…: unprefixed, in a fence
    /// named for the file's language, or a bare fence for plain text.
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
        // One backtick longer than any run inside, so selecting a Markdown code
        // block cannot close the fence early.
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


/// Selected lines captured when Comment… opens, so the sheet names them and Add
/// quotes them even if the surface's rows change underneath.
struct ReviewCommentContext: Identifiable {
    let id = UUID()
    let path: String
    /// First and last display line numbers, in row order; nil when no line has one. Not
    /// a range: a diff can run from a higher old-side number to a lower new-side one.
    let lines: (first: Int, last: Int)?
    let fencedLines: String

    /// What lands in the draft: `path L1-L9`, then `: comment` when there is one, then
    /// the fenced lines. A blank comment gives exactly the old "Add to prompt" snippet.
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

/// The Comment… flow on a review surface. `context` drives the comment sheet; Add
/// turns it into draft Markdown once, and `addedCount` feeds the bar's "N comments
/// added" for this surface's lifetime. The draft itself is the only queue.
struct ReviewCommentComposer {
    var context: ReviewCommentContext?
    private(set) var addedCount = 0

    /// The Markdown to append, or nil when the context is gone, as after a refresh.
    mutating func add(comment: String) -> String? {
        guard let context else { return nil }
        self.context = nil
        addedCount += 1
        return context.markdown(comment: comment)
    }

    /// Closes the sheet without adding. Refreshes and content swaps call it so a
    /// late Add cannot quote lines that are no longer on screen.
    mutating func discard() {
        context = nil
    }

    /// The draft with `markdown` appended as its own paragraph, ending in a newline
    /// so the next comment or the user's typing starts on a fresh line.
    static func appending(_ markdown: String, to draft: String) -> String {
        let separator = draft.isEmpty ? "" : (draft.hasSuffix("\n") ? "\n" : "\n\n")
        return draft + separator + markdown + "\n"
    }
}
