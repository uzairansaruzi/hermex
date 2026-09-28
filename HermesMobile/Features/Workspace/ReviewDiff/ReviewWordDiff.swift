import Foundation

/// Word-level highlights for paired deleted/added lines. A run of deletions followed by
/// a run of additions is paired index by index; each pair is diffed by word and the
/// changed words become highlight ranges, subject to gates that keep noisy lines plain.
enum ReviewWordDiff {
    /// Lines longer than this are never word-diffed.
    static let maxLineLength = 1000
    /// More ranges than this reads as noise, so the line stays plain.
    static let maxRangeCount = 4
    /// Highlights covering more than this share of the non-whitespace text mean the
    /// line was rewritten, not edited; the line stays plain.
    static let maxCoverage = 0.45

    struct Pair: Equatable {
        var deletion: [Range<Int>]
        var addition: [Range<Int>]
    }

    /// Adds word-diff ranges to every paired deletion/addition line in `rows`.
    /// Pairs never cross a file or hunk boundary because those rows break the run.
    static func annotate(_ rows: inout [ReviewDiffRow]) {
        var index = 0
        while index < rows.count {
            var deleted: [Int] = []
            var added: [Int] = []
            while index < rows.count, rows[index].line?.change == .deletion {
                deleted.append(index)
                index += 1
            }
            while index < rows.count, rows[index].line?.change == .addition {
                added.append(index)
                index += 1
            }
            if deleted.isEmpty, added.isEmpty {
                index += 1
                continue
            }
            for (deletedIndex, addedIndex) in zip(deleted, added) {
                guard let deletedLine = rows[deletedIndex].line, let addedLine = rows[addedIndex].line,
                      !deletedLine.content.isEmpty, !addedLine.content.isEmpty else { continue }
                let pair = ranges(deletion: deletedLine.content, addition: addedLine.content)
                if !pair.deletion.isEmpty {
                    rows[deletedIndex] = rows[deletedIndex].replacingWordDiffRanges(pair.deletion)
                }
                if !pair.addition.isEmpty {
                    rows[addedIndex] = rows[addedIndex].replacingWordDiffRanges(pair.addition)
                }
            }
        }
    }

    /// Ranges are Character offsets. Either side is empty when its gates fail.
    static func ranges(deletion: String, addition: String) -> Pair {
        guard !(deletion.isEmpty && addition.isEmpty),
              deletion.count <= maxLineLength, addition.count <= maxLineLength else {
            return Pair(deletion: [], addition: [])
        }

        let deletionTokens = tokenize(deletion)
        let additionTokens = tokenize(addition)
        let operations = diff(deletionTokens, additionTokens)

        var deletionSpans: [Span] = []
        var additionSpans: [Span] = []
        for (offset, operation) in operations.enumerated() {
            let isLast = offset == operations.count - 1
            switch operation {
            case .equal(let token):
                pushOrJoin(Span(isChanged: false, text: token), into: &deletionSpans, isLast: isLast)
                pushOrJoin(Span(isChanged: false, text: token), into: &additionSpans, isLast: isLast)
            case .removed(let token):
                pushOrJoin(Span(isChanged: true, text: token), into: &deletionSpans, isLast: isLast)
            case .added(let token):
                pushOrJoin(Span(isChanged: true, text: token), into: &additionSpans, isLast: isLast)
            }
        }

        let deletionRanges = trimmed(mergeNearby(ranges(from: deletionSpans)), in: deletion)
        let additionRanges = trimmed(mergeNearby(ranges(from: additionSpans)), in: addition)
        return Pair(
            deletion: passesGates(deletionRanges, in: deletion) ? deletionRanges : [],
            addition: passesGates(additionRanges, in: addition) ? additionRanges : []
        )
    }

    // MARK: - Spans

    private struct Span {
        var isChanged: Bool
        var text: String
    }

    /// Consecutive spans of one kind merge. A single neutral character (a dot, a
    /// bracket) between two changed words joins the change so the highlight reads as
    /// one edit instead of a stutter. The last operation never joins, so a trailing
    /// unchanged run stays unhighlighted.
    private static func pushOrJoin(_ span: Span, into spans: inout [Span], isLast: Bool) {
        guard let last = spans.last, !isLast else {
            spans.append(span)
            return
        }
        let joinsSameKind = span.isChanged == last.isChanged
        let joinsSingleNeutral = !span.isChanged && span.text.count == 1 && last.isChanged
        if joinsSameKind || joinsSingleNeutral {
            spans[spans.count - 1].text += span.text
            return
        }
        spans.append(span)
    }

    private static func ranges(from spans: [Span]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        for span in spans {
            let next = offset + span.text.count
            if span.isChanged, next > offset {
                ranges.append(offset..<next)
            }
            offset = next
        }
        return ranges
    }

    private static func mergeNearby(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges {
            if let previous = merged.last, range.lowerBound - previous.upperBound <= 1 {
                merged[merged.count - 1] = previous.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func trimmed(_ ranges: [Range<Int>], in content: String) -> [Range<Int>] {
        let characters = Array(content)
        return ranges.compactMap { range in
            var start = max(0, range.lowerBound)
            var end = min(characters.count, range.upperBound)
            while start < end, characters[start].isWhitespace { start += 1 }
            while end > start, characters[end - 1].isWhitespace { end -= 1 }
            return end > start ? start..<end : nil
        }
    }

    private static func passesGates(_ ranges: [Range<Int>], in content: String) -> Bool {
        guard !ranges.isEmpty, ranges.count <= maxRangeCount else { return false }
        let characters = Array(content)
        let meaningful = characters.filter { !$0.isWhitespace }.count
        guard meaningful > 0 else { return false }
        let highlighted = ranges.reduce(0) { total, range in
            total + characters[range].filter { !$0.isWhitespace }.count
        }
        return Double(highlighted) / Double(meaningful) <= maxCoverage
    }

    // MARK: - Token diff

    /// Runs of word characters, whitespace, and other characters, so "foo.bar" diffs as
    /// three tokens and an edit inside a word highlights just that word.
    static func tokenize(_ text: String) -> [String] {
        enum Run { case word, space, other }
        var tokens: [String] = []
        var current = ""
        var currentRun: Run?
        for character in text {
            let run: Run
            if character.isLetter || character.isNumber || character == "_" {
                run = .word
            } else if character.isWhitespace {
                run = .space
            } else {
                run = .other
            }
            if run != currentRun, !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(character)
            currentRun = run
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private enum Operation {
        case equal(String)
        case removed(String)
        case added(String)
    }

    /// Longest-common-subsequence diff over tokens. Lines are capped at
    /// `maxLineLength`, so the table stays small.
    private static func diff(_ old: [String], _ new: [String]) -> [Operation] {
        let rows = old.count
        let columns = new.count
        var table = [Int](repeating: 0, count: (rows + 1) * (columns + 1))
        let stride = columns + 1
        if rows > 0, columns > 0 {
            // Suffix table: cell (row, column) is the LCS length of the tails.
            for row in (0..<rows).reversed() {
                for column in (0..<columns).reversed() {
                    if old[row] == new[column] {
                        table[(row) * stride + column] = table[(row + 1) * stride + column + 1] + 1
                    } else {
                        table[(row) * stride + column] = max(
                            table[(row + 1) * stride + column],
                            table[(row) * stride + column + 1]
                        )
                    }
                }
            }
        }

        var operations: [Operation] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if old[row] == new[column] {
                operations.append(.equal(old[row]))
                row += 1
                column += 1
            } else if table[(row + 1) * stride + column] >= table[row * stride + column + 1] {
                operations.append(.removed(old[row]))
                row += 1
            } else {
                operations.append(.added(new[column]))
                column += 1
            }
        }
        while row < rows {
            operations.append(.removed(old[row]))
            row += 1
        }
        while column < columns {
            operations.append(.added(new[column]))
            column += 1
        }
        return operations
    }
}

private extension ReviewDiffRow {
    func replacingWordDiffRanges(_ ranges: [Range<Int>]) -> ReviewDiffRow {
        guard var line else { return self }
        line.wordDiffRanges = ranges
        return ReviewDiffRow(id: id, fileID: fileID, kind: .line(line))
    }
}
