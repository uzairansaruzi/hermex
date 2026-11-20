import Foundation

struct ReviewDiffRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case file(ReviewDiffFileHeader)
        case hunk(String)
        case line(ReviewDiffLine)
        case notice(String)
    }

    let id: String
    let fileID: String
    let kind: Kind

    var fileHeader: ReviewDiffFileHeader? {
        if case .file(let header) = kind { return header }
        return nil
    }

    var line: ReviewDiffLine? {
        if case .line(let line) = kind { return line }
        return nil
    }

    var isFileHeader: Bool { fileHeader != nil }

    var columnCount: Int {
        switch kind {
        case .hunk(let text): return text.count
        case .line(let line): return line.columnCount
        case .file, .notice: return 0
        }
    }
}

struct ReviewDiffFileHeader: Equatable {
    let path: String
    let previousPath: String?
    let changeKind: GitFile.ChangeKind
    let additions: Int
    let deletions: Int

    var displayPath: String {
        guard let previousPath else { return path }
        return "\(previousPath) → \(path)"
    }
}

struct ReviewDiffLine: Equatable {
    let content: String
    let change: DiffLine.Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    var wordDiffRanges: [Range<Int>] = []
    let isNoNewlineMarker: Bool
    let columnCount: Int

    init(
        content: String,
        change: DiffLine.Kind,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        wordDiffRanges: [Range<Int>] = [],
        isNoNewlineMarker: Bool = false
    ) {
        self.content = content
        self.change = change
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.wordDiffRanges = wordDiffRanges
        self.isNoNewlineMarker = isNoNewlineMarker
        columnCount = content.count
    }

    var displayLineNumber: Int? { newLineNumber ?? oldLineNumber }

    func visualLines(in characters: Range<Int>, wrapColumns: Int?) -> [Substring] {
        let lower = min(max(0, characters.lowerBound), columnCount)
        let upper = min(max(lower, characters.upperBound), columnCount)
        guard lower < upper else { return [] }
        let start = content.index(content.startIndex, offsetBy: lower)
        let end = upper == columnCount ? content.endIndex : content.index(start, offsetBy: upper - lower)
        guard let wrapColumns else { return [content[start..<end]] }

        var lines: [Substring] = []
        var lineStart = start
        while lineStart < end {
            let lineEnd = content.index(lineStart, offsetBy: wrapColumns, limitedBy: end) ?? end
            lines.append(content[lineStart..<lineEnd])
            lineStart = lineEnd
        }
        return lines
    }
}

enum ReviewDiffFileState: Equatable {
    case loading
    case loaded(GitDiff)
    case failed(String)
}

struct ReviewDiffFileInput: Equatable {
    let file: GitFile
    let state: ReviewDiffFileState
}

enum ReviewDiffRowBuilder {
    static func rows(for inputs: [ReviewDiffFileInput]) -> [ReviewDiffRow] {
        inputs.flatMap(rows(for:))
    }

    static func rows(for input: ReviewDiffFileInput) -> [ReviewDiffRow] {
        let file = input.file
        let fileID = file.id
        let hunks: [DiffHunk]
        let notice: String?
        switch input.state {
        case .loading:
            hunks = []
            notice = String(localized: "Loading…")
        case .failed(let message):
            hunks = []
            notice = message
        case .loaded(let diff):
            if diff.binary == true {
                hunks = []
                notice = String(localized: "Binary file changed")
            } else if diff.tooLarge == true {
                hunks = []
                notice = String(localized: "Diff too large to show.")
            } else {
                hunks = DiffHunk.parse(diff.diff ?? "")
                notice = hunks.isEmpty ? String(localized: "No Changes") : nil
            }
        }

        let header = ReviewDiffFileHeader(
            path: file.displayPath,
            previousPath: previousPath(for: file),
            changeKind: file.changeKind,
            additions: file.additions ?? hunks.reduce(0) { $0 + $1.additions },
            deletions: file.deletions ?? hunks.reduce(0) { $0 + $1.deletions }
        )

        var rows: [ReviewDiffRow] = [ReviewDiffRow(id: "\(fileID):header", fileID: fileID, kind: .file(header))]
        if let notice {
            rows.append(ReviewDiffRow(id: "\(fileID):notice", fileID: fileID, kind: .notice(notice)))
            return rows
        }

        for (hunkIndex, hunk) in hunks.enumerated() {
            rows.append(ReviewDiffRow(id: "\(fileID):hunk:\(hunkIndex)", fileID: fileID, kind: .hunk(hunk.displayLabel)))
            for (lineIndex, line) in hunk.lines.enumerated() {
                rows.append(
                    ReviewDiffRow(
                        id: "\(fileID):line:\(hunkIndex):\(lineIndex)",
                        fileID: fileID,
                        kind: .line(reviewLine(for: line))
                    )
                )
            }
        }
        ReviewWordDiff.annotate(&rows)
        return rows
    }

    private static func previousPath(for file: GitFile) -> String? {
        guard let oldPath = file.oldPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !oldPath.isEmpty, oldPath != file.displayPath else { return nil }
        return oldPath
    }

    private static func reviewLine(for line: DiffLine) -> ReviewDiffLine {
        let isMarker = line.text.hasPrefix("\\")
        let raw = isMarker ? line.text : String(line.text.dropFirst())
        return ReviewDiffLine(
            content: raw.replacingOccurrences(of: "\t", with: "    "),
            change: line.kind,
            oldLineNumber: line.oldLineNumber,
            newLineNumber: line.newLineNumber,
            isNoNewlineMarker: isMarker
        )
    }
}
