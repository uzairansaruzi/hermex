import Foundation

/// Which files a multi-file review folds by default: lockfiles, generated output, and changes
/// of more than `maxChangedLines` added and deleted lines, so the real edits come first.
/// A default fold covers only a loaded diff: loading, binary, too-large and failed notices
/// read in the open. A header tap or viewed toggle settles the file, so no later load or
/// refresh folds or unfolds it again.
///
/// `ReviewDiffProgress` builds this as a review opens, settles the files the user already chose
/// for, calls `apply(_:to:)` on every publish, and `settle(_:)` on every user toggle.
struct ReviewDiffDefaultCollapse {
    static let maxChangedLines = 400

    private enum Default {
        /// Folds whenever its loaded diff is showing.
        case fold
        /// Its status counts were missing, so the first loaded diff decides.
        case measure
    }

    /// Files the user hasn't toggled whose default folds them, or hasn't been measured yet.
    private var defaults: [String: Default] = [:]

    init(files: [GitFile], initialFile: GitFile?) {
        // A single file, or the one the user tapped, is what they came to read.
        guard files.count > 1 else { return }
        for file in files where file.id != initialFile?.id {
            if Self.isGenerated(file.displayPath) {
                defaults[file.id] = .fold
            } else if let additions = file.additions, let deletions = file.deletions {
                if additions + deletions > Self.maxChangedLines { defaults[file.id] = .fold }
            } else {
                defaults[file.id] = .measure
            }
        }
    }

    /// Records the user's own collapse or viewed choice; no default touches the file again.
    mutating func settle(_ fileID: String) {
        defaults[fileID] = nil
    }

    /// Folds or unfolds each defaulted file for the latest full row list: folded while its
    /// loaded diff shows, open while it shows a notice. A file awaiting measurement is
    /// decided by its first loaded diff, counting added and deleted lines, not context.
    mutating func apply(_ rows: [ReviewDiffRow], to collapsedFileIDs: inout Set<String>) {
        guard !defaults.isEmpty else { return }
        // Rows arrive grouped by file, each group led by its header.
        var end = rows.startIndex
        while end < rows.endIndex {
            let start = end
            let fileID = rows[start].fileID
            end += 1
            while end < rows.endIndex, rows[end].fileID == fileID { end += 1 }
            guard let current = defaults[fileID] else { continue }

            let fileRows = rows[(start + 1)..<end]
            if fileRows.contains(where: { if case .notice = $0.kind { true } else { false } }) {
                collapsedFileIDs.remove(fileID)
                continue
            }
            if current == .measure {
                let changed = fileRows.reduce(0) { count, row in
                    guard let change = row.line?.change, change != .context else { return count }
                    return count + 1
                }
                guard changed > Self.maxChangedLines else {
                    defaults[fileID] = nil
                    continue
                }
                defaults[fileID] = .fold
            }
            collapsedFileIDs.insert(fileID)
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
