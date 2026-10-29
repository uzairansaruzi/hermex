import Foundation

/// Which files a multi-file review starts folded: lockfiles, generated output, and changes
/// of more than `maxChangedLines` added and deleted lines, so the real edits come first.
/// Each file's default applies once per sheet. A header tap or viewed toggle settles it,
/// so later loads and refreshes never fold a file the user opened.
///
/// `GitDiffView` seeds its collapsed files from `initiallyCollapsedFileIDs`, calls
/// `apply(_:to:)` on every publish, and `settle(_:)` on every user toggle.
struct ReviewDiffDefaultCollapse {
    static let maxChangedLines = 400

    private enum Pending {
        /// Folded from the start by its path or status counts. A notice unfolds it until
        /// rows load.
        case fold
        /// Its status counts were missing, so the first loaded rows decide.
        case measure
    }

    let initiallyCollapsedFileIDs: Set<String>
    /// Files whose default hasn't met loaded rows or a user choice yet.
    private var pending: [String: Pending] = [:]

    init(files: [GitFile], initialFile: GitFile?) {
        var collapsed: Set<String> = []
        // A single file, or the one the user tapped, is what they came to read.
        if files.count > 1 {
            for file in files where file.id != initialFile?.id {
                let decision: Pending?
                if Self.isGenerated(file.displayPath) {
                    decision = .fold
                } else if let additions = file.additions, let deletions = file.deletions {
                    decision = additions + deletions > Self.maxChangedLines ? .fold : nil
                } else {
                    decision = .measure
                }
                pending[file.id] = decision
                if decision == .fold { collapsed.insert(file.id) }
            }
        }
        initiallyCollapsedFileIDs = collapsed
    }

    /// Records the user's own collapse or viewed choice; no default touches the file again.
    mutating func settle(_ fileID: String) {
        pending[fileID] = nil
    }

    /// Applies pending defaults to the latest full row list. Loading placeholders decide
    /// nothing. A notice (binary, too large, failed, empty) unfolds a default fold so it
    /// stays readable, and leaves the default for a later successful load. Loaded lines
    /// settle the file, measured by added and deleted lines, not context.
    mutating func apply(_ rows: [ReviewDiffRow], to collapsedFileIDs: inout Set<String>) {
        guard !pending.isEmpty else { return }
        // Rows arrive grouped by file, each group led by its header.
        var end = rows.startIndex
        while end < rows.endIndex {
            let start = end
            let fileID = rows[start].fileID
            end += 1
            while end < rows.endIndex, rows[end].fileID == fileID { end += 1 }
            guard let decision = pending[fileID], rows[start].fileHeader?.isLoading == false else { continue }

            let fileRows = rows[(start + 1)..<end]
            if fileRows.contains(where: { if case .notice = $0.kind { true } else { false } }) {
                if decision == .fold { collapsedFileIDs.remove(fileID) }
                continue
            }
            pending[fileID] = nil
            let changed = fileRows.reduce(0) { count, row in
                guard let change = row.line?.change, change != .context else { return count }
                return count + 1
            }
            if decision == .fold || changed > Self.maxChangedLines { collapsedFileIDs.insert(fileID) }
        }
    }

    private static let lockfileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved", "Podfile.lock",
        "Gemfile.lock", "Cargo.lock", "composer.lock", "poetry.lock", "uv.lock", "go.sum"
    ]
    private static let generatedSuffixes = [".snap", ".min.js", ".min.css", ".map"]
    private static let generatedDirectories: Set<String> = ["node_modules", "dist", ".next", ".cache", "__snapshots__"]

    private static func isGenerated(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        if lockfileNames.contains(name) { return true }
        let lowercased = name.lowercased()
        if generatedSuffixes.contains(where: lowercased.hasSuffix) { return true }
        return components.dropLast().contains(where: generatedDirectories.contains)
    }
}
