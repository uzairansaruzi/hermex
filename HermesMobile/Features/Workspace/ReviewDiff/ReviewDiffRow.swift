import Foundation

/// One drawn row of the review surface. The surface is a flat list, so layout is a
/// prefix sum over row heights and hit testing is a binary search over offsets.
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

    /// The text a row contributes to its file's horizontal content width.
    var columnCount: Int {
        switch kind {
        case .hunk(let text): return text.count
        case .line(let line): return line.content.count
        case .file, .notice: return 0
        }
    }
}

struct ReviewDiffFileHeader: Equatable {
    let path: String
    /// Set for renames when the old path differs from `path`.
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
    /// Display text without the unified-diff prefix character, tabs expanded so the
    /// monospaced character grid the word highlights sit on stays honest.
    let content: String
    let change: DiffLine.Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    /// Character offsets into `content` to highlight as the changed words.
    var wordDiffRanges: [Range<Int>] = []

    var displayLineNumber: Int? { newLineNumber ?? oldLineNumber }
}

/// What the host knows about one file's diff while the surface is on screen.
enum ReviewDiffFileState: Equatable {
    case loading
    case loaded(GitDiff)
    case failed(String)
}

struct ReviewDiffFileInput: Equatable {
    let file: GitFile
    let state: ReviewDiffFileState
}

/// Turns the per-file `git/diff` results into the flat row list the surface draws.
/// Row ids are stable across reloads (file id, hunk index, line index) so collapse,
/// viewed, and selection state survive a rows rebuild.
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
        // "\ No newline at end of file" markers keep their text; real lines drop the
        // +/-/space prefix.
        let raw = line.text.hasPrefix("\\") ? line.text : String(line.text.dropFirst())
        return ReviewDiffLine(
            content: raw.replacingOccurrences(of: "\t", with: "    "),
            change: line.kind,
            oldLineNumber: line.oldLineNumber,
            newLineNumber: line.newLineNumber
        )
    }
}
