import Foundation

struct ReviewDiffDefaultCollapse {
    static let maxChangedLines = 400

    private enum Default {
        case fold
        case measure
    }

    private var defaults: [String: Default] = [:]

    init(files: [GitFile], initialFile: GitFile?) {
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

    mutating func settle(_ fileID: String) {
        defaults[fileID] = nil
    }

    mutating func apply(_ rows: [ReviewDiffRow], to collapsedFileIDs: inout Set<String>) {
        guard !defaults.isEmpty else { return }
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
