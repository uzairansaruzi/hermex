import Foundation

// Tolerant, read-only models for the server "workspace git" API (issue #312, Slice A).
//
// Every field is optional and unknown keys are ignored so the app never crashes on a
// field the server adds or renames (hard rule #3). The shared `APIClient` decoder uses
// `.convertFromSnakeCase`, so snake_case JSON keys (`is_git`, `old_path`, `too_large`, …)
// map onto these camelCase properties automatically.
//
// A Hermes chat's repository maps into the same models in `HermesGitClient` (#1114).
//
// Endpoint contract (verified against `.codex-tmp/hermes-webui/api/workspace_git.py`):
// - GET /api/git-info  → { "git": {...} | null }
// - GET /api/git/status → { "git": {...} }   (non-repo: is_git=false, HTTP 200)
// - GET /api/git/branches → { "branches": {...} } (non-repo: HTTP 400 error envelope)
// - GET /api/git/diff → { "diff": {...} }    (non-repo / missing path: HTTP 400)

// MARK: - git-info (lightweight badge data)

struct GitInfoResponse: Decodable, Equatable {
    /// `null` when the session workspace is not a git repository.
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

// MARK: - git/status (the status sheet's source of truth)

struct GitStatusResponse: Decodable, Equatable {
    let git: GitStatus?
}

struct GitStatus: Decodable, Equatable {
    /// `false` for a non-repo workspace (still an HTTP 200 response).
    let isGit: Bool?
    let branch: String?
    let upstream: String?
    let ahead: Int?
    let behind: Int?
    let totals: GitTotals?
    let files: [GitFile]?
    /// `true` when the file list was capped (server limit is 500 changed files).
    let truncated: Bool?

    /// Changed files excluding ignored entries (e.g. `.DS_Store`), which the server
    /// includes in `files[]` but excludes from `totals.changed`.
    var trackedFiles: [GitFile] {
        (files ?? []).filter { !$0.isIgnoredFile }
    }

    /// Changed-file count, preferring the server's `totals.changed` and falling back to
    /// the non-ignored file count so the header never disagrees with the list.
    var changedCount: Int {
        totals?.changed ?? trackedFiles.count
    }

    /// Total additions/deletions across non-ignored files.
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
    /// Raw git status code (`M/A/D/R/C/T/U`, `"??"`, two-char conflicts, or `"Ignored"`).
    /// Prefer the booleans below for display; treat this as a fallback label.
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
    /// A changed file a client assembles itself, as `HermesGitClient` does from a Hermes host's
    /// rows (#1114), keyed by its path.
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

    /// A normalized change kind derived from the booleans first (the reliable signal),
    /// falling back to the raw `status` code. UI maps this to a localized chip + colour.
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
            // A tracked change with an unrecognized code is still a modification.
            return (staged == true || unstaged == true) ? .modified : .unknown
        }
    }

    /// Last path component, e.g. `ContentView.swift`.
    var fileName: String {
        let value = displayPath
        return value.split(separator: "/").last.map(String.init) ?? value
    }

    /// Parent directory shown as secondary text, or `nil` at the repo root.
    var parentDirectory: String? {
        let parts = displayPath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    /// The diff query uses staged content for staged-only changes, unstaged otherwise.
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

// MARK: - git/branches (decoded + tested now; interactive picker is Slice B)

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

/// Both checkout endpoints currently return `status`; `git` is retained as a tolerant
/// alias for servers that shipped the earlier documented response name.
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

// MARK: - git stage/unstage/discard/commit (issue #315, Slice C)

/// Response for `stage` / `unstage` / `discard`, which return the refreshed status under
/// the `git` key (the commit endpoints return it under `status` instead — see below).
struct GitMutationResponse: Decodable, Equatable {
    let ok: Bool?
    let git: GitStatus?

    var resolvedStatus: GitStatus? { git }
}

/// Response for `commit` (`{ok,commit,status}`) and `commit-selected`
/// (`{ok,commit,paths,status}`). Tolerant: `status` is decoded from either key.
struct GitCommitResponse: Decodable, Equatable {
    let ok: Bool?
    let commit: String?
    let paths: [String]?
    let status: GitStatus?
    let git: GitStatus?
    /// Set by a Hermes Commit Selected (#1115) whose commit landed but which couldn't stage the
    /// other staged files again. Never decoded.
    var stagingNotRestored = false

    enum CodingKeys: String, CodingKey {
        case ok, commit, paths, status, git
    }

    var resolvedStatus: GitStatus? { status ?? git }
    /// Short SHA produced by the commit, trimmed for display.
    var shortSHA: String? {
        let trimmed = commit?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// Response for the (ungated) `commit-message` / `commit-message-selected` endpoints.
struct GitCommitMessageResponse: Decodable, Equatable {
    let ok: Bool?
    let message: String?
    /// `true` when the diff exceeded the server's 64 KiB prompt limit, so the
    /// generated message may be partial.
    let truncated: Bool?
}

// MARK: - git/diff (per-file unified diff)

struct GitDiffResponse: Decodable, Equatable {
    let diff: GitDiff?
}

struct GitDiff: Decodable, Equatable {
    let path: String?
    let kind: String?
    let binary: Bool?
    /// `true` when the diff exceeded the server's 512 KiB cap; `diff` text is then empty.
    let tooLarge: Bool?
    let additions: Int?
    let deletions: Int?
    /// Unified diff text. Empty for binary or too-large diffs.
    let diff: String?
}
