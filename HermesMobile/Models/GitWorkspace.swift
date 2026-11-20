import Foundation

struct GitInfoResponse: Decodable, Equatable {
    let git: GitInfo?
}

struct GitInfo: Decodable, Equatable {
    let branch: String?
    let dirty: Int?
    let modified: Int?
    let untracked: Int?
    let ahead: Int?
    let behind: Int?
    let isGit: Bool?
}

struct GitStatusResponse: Decodable, Equatable {
    let git: GitStatus?
}

struct GitStatus: Decodable, Equatable {
    let isGit: Bool?
    let branch: String?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
    let totals: GitTotals?
    let files: [GitFile]?
    let truncated: Bool?

    var trackedFiles: [GitFile] {
        (files ?? []).filter { !$0.isIgnoredFile }
    }

    var changedCount: Int {
        totals?.changed ?? trackedFiles.count
    }

    var totalAdditions: Int { trackedFiles.reduce(0) { $0 + ($1.additions ?? 0) } }
    var totalDeletions: Int { trackedFiles.reduce(0) { $0 + ($1.deletions ?? 0) } }
}

struct GitTotals: Decodable, Equatable {
    let changed: Int?
    let staged: Int?
    let unstaged: Int?
    let untracked: Int?
    let conflicts: Int?
}

struct GitFile: Decodable, Equatable, Identifiable {
    let id: String
    let path: String?
    let oldPath: String?
    let workspacePath: String?
    let status: String?
    let staged: Bool?
    let unstaged: Bool?
    let untracked: Bool?
    let ignored: Bool?
    let conflict: Bool?
    let additions: Int?
    let deletions: Int?
    let binary: Bool?

    enum CodingKeys: String, CodingKey {
        case path
        case oldPath
        case workspacePath
        case status
        case staged
        case unstaged
        case untracked
        case ignored
        case conflict
        case additions
        case deletions
        case binary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = container.decodeLossyStringIfPresent(forKey: .path)
        oldPath = container.decodeLossyStringIfPresent(forKey: .oldPath)
        workspacePath = container.decodeLossyStringIfPresent(forKey: .workspacePath)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        staged = container.decodeLossyBoolIfPresent(forKey: .staged)
        unstaged = container.decodeLossyBoolIfPresent(forKey: .unstaged)
        untracked = container.decodeLossyBoolIfPresent(forKey: .untracked)
        ignored = container.decodeLossyBoolIfPresent(forKey: .ignored)
        conflict = container.decodeLossyBoolIfPresent(forKey: .conflict)
        additions = container.decodeLossyIntIfPresent(forKey: .additions)
        deletions = container.decodeLossyIntIfPresent(forKey: .deletions)
        binary = container.decodeLossyBoolIfPresent(forKey: .binary)

        if let stablePath = Self.stablePath(path: path, workspacePath: workspacePath, oldPath: oldPath) {
            id = stablePath
        } else {
            id = UUID().uuidString
        }
    }

    private static func stablePath(path: String?, workspacePath: String?, oldPath: String?) -> String? {
        let candidate = [path, workspacePath, oldPath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return candidate
    }
}

extension GitFile {
    init(path: String, status: String?, staged: Bool?, unstaged: Bool?, untracked: Bool?, conflict: Bool?,
         additions: Int?, deletions: Int?) {
        id = path.isEmpty ? UUID().uuidString : path
        self.path = path
        oldPath = nil
        workspacePath = nil
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        ignored = nil
        self.conflict = conflict
        self.additions = additions
        self.deletions = deletions
        binary = nil
    }

    enum ChangeKind: Equatable {
        case conflict
        case untracked
        case added
        case deleted
        case renamed
        case modified
        case ignored
        case unknown
    }

    var changeKind: ChangeKind {
        if conflict == true { return .conflict }
        if isIgnoredFile { return .ignored }
        if untracked == true { return .untracked }

        switch (status ?? "").uppercased().first {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "M", "T": return .modified
        default:
            return (staged == true || unstaged == true) ? .modified : .unknown
        }
    }

    var fileName: String {
        let value = displayPath
        return value.split(separator: "/").last.map(String.init) ?? value
    }

    var parentDirectory: String? {
        let parts = displayPath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    var preferredDiffKind: String {
        (staged == true && unstaged != true) ? "staged" : "unstaged"
    }

    var displayPath: String {
        let trimmed = (path ?? workspacePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (oldPath ?? "") : trimmed
    }

    var isIgnoredFile: Bool {
        ignored == true || (status ?? "").caseInsensitiveCompare("Ignored") == .orderedSame
    }
}

enum GitReviewScope: Hashable {
    case uncommitted
    case branch
    case since(base: String)
}

struct GitTurnBase: Hashable {
    let sha: String
    let workspace: HermesWorkspaceContext
    let turn: Int
}

enum GitTurnReview: Equatable {
    case reading
    case read([GitFile])
    case failed
}

struct GitBranchReview: Equatable {
    let files: [GitFile]
    let base: String?
    let branch: String?
    let detached: Bool

    var totalAdditions: Int { files.reduce(0) { $0 + ($1.additions ?? 0) } }
    var totalDeletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }
}

struct GitBranchesResponse: Decodable, Equatable {
    let branches: GitBranches?
}

struct GitBranches: Decodable, Equatable {
    let isGit: Bool?
    let current: String?
    let detached: Bool?
    let head: String?
    let local: [GitBranchRef]?
    let remote: [GitBranchRef]?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
}

struct GitBranchRef: Decodable, Equatable {
    let name: String?
    let sha: String?
    let updated: Int?
    let updatedRelative: String?
    let author: String?
    let subject: String?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
}

enum GitBranchMode: String, Equatable {
    case local
    case remote
}

struct GitCheckoutTarget: Equatable, Identifiable {
    let ref: String
    let mode: GitBranchMode
    var newBranch: String? = nil
    var track = false

    var id: String { "\(mode.rawValue):\(ref):\(newBranch ?? "")" }
    var displayName: String { newBranch ?? ref }
}

struct GitRemoteActionResponse: Decodable, Equatable {
    let ok: Bool?
    let message: String?
    let status: GitStatus?
}

struct GitCheckoutResponse: Decodable, Equatable {
    let ok: Bool?
    let message: String?
    let status: GitStatus?
    let git: GitStatus?
    let branches: GitBranches?
    let currentBranch: String?
    let stashName: String?
    let stashed: Bool?
    let restoredStash: GitRestoredStash?
    let restoreFailed: Bool?
    let restoreError: String?
    let restoreStash: GitRestoredStash?

    var resolvedStatus: GitStatus? { status ?? git }
}

struct GitRestoredStash: Decodable, Equatable {
    let ref: String?
    let branch: String?
    let message: String?
}

struct GitMutationResponse: Decodable, Equatable {
    let ok: Bool?
    let git: GitStatus?

    var resolvedStatus: GitStatus? { git }
}

struct GitCommitResponse: Decodable, Equatable {
    let ok: Bool?
    let commit: String?
    let paths: [String]?
    let status: GitStatus?
    let git: GitStatus?
    var stagingNotRestored = false

    enum CodingKeys: String, CodingKey {
        case ok, commit, paths, status, git
    }

    var resolvedStatus: GitStatus? { status ?? git }
    var shortSHA: String? {
        let trimmed = commit?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

struct GitCommitMessageResponse: Decodable, Equatable {
    let ok: Bool?
    let message: String?
    let truncated: Bool?
}

struct GitDiffResponse: Decodable, Equatable {
    let diff: GitDiff?
}

struct GitDiff: Decodable, Equatable {
    let path: String?
    let kind: String?
    let binary: Bool?
    let tooLarge: Bool?
    let additions: Int?
    let deletions: Int?
    let diff: String?
}

struct GitPullRequest: Equatable, Sendable {
    enum State: String, Sendable {
        case open = "OPEN"
        case merged = "MERGED"
        case closed = "CLOSED"
    }

    let number: Int
    let url: URL
    let state: State?
}
