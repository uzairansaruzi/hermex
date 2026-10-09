import Foundation
import Observation

/// The repository one chat's Git menu, Changes sheet, commit sheet, diffs and turn-changes card
/// read (#1114) and change (#1115): webui's session routes (`WebUIGitClient`) or a Hermes host's
/// repository routes (`HermesGitClient`). Branches, fetch and pull are webui-only and stay on
/// `APIClient`. File paths are repository-relative, as `GitFile.path` carries them.
protocol GitDataClient: Sendable {
    /// The toolbar's badge data; nil, or `isGit == false`, outside a repository.
    func info() async throws -> GitInfo?
    /// Every changed file; `isGit == false` outside a repository.
    func status() async throws -> GitStatus?
    /// One changed file's diff, of the kind `GitFile.preferredDiffKind` names where it is known.
    func diff(for file: GitFile) async throws -> GitDiff?
    /// The row path a turn's tool names a file by, for the turn-changes card's join.
    @MainActor func rowPath(forToolPath path: String) -> String
    /// A Hermes host's repository (#1115), whose writes answer only `{ok}`: a failed write reads
    /// the status again and the commit sheet shows a commit's sha. webui's answers carry the
    /// status, and its sheet keeps its presentation.
    var isHermes: Bool { get }
    /// Held while one of this repository's writes runs, so the chat's Git menu and commit sheet
    /// never write under each other (#1115). Nil on webui, whose writes are unchanged.
    @MainActor var writeLock: GitWriteLock? { get }

    // Writes. Each answers the status after it when it has one.
    func stage(_ files: [GitFile]) async throws -> GitStatus?
    func unstage(_ files: [GitFile]) async throws -> GitStatus?
    /// Returns the files to HEAD, deleting untracked and newly added ones when `deleteUntracked`.
    func discard(_ files: [GitFile], deleteUntracked: Bool) async throws -> GitStatus?
    /// Commits what is staged, or only `files` when they are named.
    func commit(message: String, only files: [GitFile]?) async throws -> GitCommitResponse
    func push() async throws -> GitRemoteActionResponse
    /// A suggested message for what is staged, or for `files`. `previous` is the last suggestion,
    /// which a client that can ask for a different one avoids.
    func suggestMessage(for files: [GitFile]?, avoiding previous: String?) async throws -> GitCommitMessageResponse
}

extension GitDataClient {
    /// webui's rows are relative to the chat's workspace, as its tools name files.
    @MainActor func rowPath(forToolPath path: String) -> String { path }

    var isHermes: Bool { false }

    @MainActor var writeLock: GitWriteLock? { nil }
}

/// One Hermes repository's write in flight (#1115). The Git menu's quick commit and push and the
/// commit sheet's stage, unstage, discard and commit each hold it from start to finish, a quick
/// commit's message wait included, and the other surface's write controls are disabled meanwhile.
@MainActor @Observable final class GitWriteLock {
    private(set) var isHeld = false

    /// Takes the lock; false, with nothing taken, while another write holds it.
    func acquire() -> Bool {
        guard !isHeld else { return false }
        isHeld = true
        return true
    }

    func release() {
        isHeld = false
    }
}

/// `GitDataClient` over webui's session-scoped Git routes.
struct WebUIGitClient: GitDataClient {
    let apiClient: APIClient
    let sessionID: String

    /// Nil without a session ID, which every route needs.
    init?(session: SessionSummary, apiClient: APIClient) {
        guard let sessionID = session.sessionId else { return nil }
        self.apiClient = apiClient
        self.sessionID = sessionID
    }

    func info() async throws -> GitInfo? {
        try await apiClient.gitInfo(sessionID: sessionID).git
    }

    func status() async throws -> GitStatus? {
        try await apiClient.gitStatus(sessionID: sessionID).git
    }

    func diff(for file: GitFile) async throws -> GitDiff? {
        try await apiClient.gitDiff(sessionID: sessionID, path: file.displayPath, kind: file.preferredDiffKind).diff
    }

    func stage(_ files: [GitFile]) async throws -> GitStatus? {
        try await apiClient.gitStage(sessionID: sessionID, paths: Self.paths(files)).resolvedStatus
    }

    func unstage(_ files: [GitFile]) async throws -> GitStatus? {
        try await apiClient.gitUnstage(sessionID: sessionID, paths: Self.paths(files)).resolvedStatus
    }

    /// webui's discard only runs `git restore --worktree`, which leaves the index untouched, so
    /// staged targets are unstaged first for the discard to revert them. A staged-new file then
    /// becomes untracked and goes with `deleteUntracked`, which the confirmation accounts for.
    func discard(_ files: [GitFile], deleteUntracked: Bool) async throws -> GitStatus? {
        let staged = Self.paths(files.filter { $0.staged == true })
        if !staged.isEmpty { _ = try await apiClient.gitUnstage(sessionID: sessionID, paths: staged) }
        return try await apiClient.gitDiscard(sessionID: sessionID, paths: Self.paths(files), deleteUntracked: deleteUntracked)
            .resolvedStatus
    }

    func commit(message: String, only files: [GitFile]?) async throws -> GitCommitResponse {
        guard let files else { return try await apiClient.gitCommit(sessionID: sessionID, message: message) }
        return try await apiClient.gitCommitSelected(sessionID: sessionID, message: message, paths: Self.paths(files))
    }

    func push() async throws -> GitRemoteActionResponse {
        try await apiClient.gitPush(sessionID: sessionID)
    }

    /// webui has no way to ask for a different message, so `previous` goes unused.
    func suggestMessage(for files: [GitFile]?, avoiding previous: String?) async throws -> GitCommitMessageResponse {
        guard let files else { return try await apiClient.gitCommitMessage(sessionID: sessionID) }
        return try await apiClient.gitCommitMessageSelected(sessionID: sessionID, paths: Self.paths(files))
    }

    /// The server paths for `files`, skipping any without one.
    private static func paths(_ files: [GitFile]) -> [String] {
        files.compactMap { file in
            let trimmed = (file.path ?? file.workspacePath)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }
}

// Workspace Git calls. Every call is scoped to a chat session via `session_id`; the
// server resolves the workspace path itself, mirroring `APIClient+Workspace.swift`.
extension APIClient {
    func gitInfo(sessionID: String) async throws -> GitInfoResponse {
        try await send(endpoint: .gitInfo(sessionID: sessionID), method: "GET")
    }

    func gitStatus(sessionID: String) async throws -> GitStatusResponse {
        try await send(endpoint: .gitStatus(sessionID: sessionID), method: "GET")
    }

    func gitBranches(sessionID: String) async throws -> GitBranchesResponse {
        try await send(endpoint: .gitBranches(sessionID: sessionID), method: "GET")
    }

    func gitDiff(sessionID: String, path: String, kind: String = "unstaged") async throws -> GitDiffResponse {
        try await send(
            endpoint: .gitDiff(sessionID: sessionID, path: path, kind: kind),
            method: "GET"
        )
    }

    func gitFetch(sessionID: String) async throws -> GitRemoteActionResponse {
        try await send(endpoint: .gitFetch, method: "POST", body: GitSessionRequest(sessionID: sessionID))
    }

    func gitPull(sessionID: String) async throws -> GitRemoteActionResponse {
        try await send(endpoint: .gitPull, method: "POST", body: GitSessionRequest(sessionID: sessionID))
    }

    func gitPush(sessionID: String) async throws -> GitRemoteActionResponse {
        try await send(endpoint: .gitPush, method: "POST", body: GitSessionRequest(sessionID: sessionID))
    }

    func gitCheckout(sessionID: String, target: GitCheckoutTarget) async throws -> GitCheckoutResponse {
        try await send(
            endpoint: .gitCheckout,
            method: "POST",
            body: GitCheckoutRequest(sessionID: sessionID, target: target, includesDirtyMode: true)
        )
    }

    func gitStashCheckout(sessionID: String, target: GitCheckoutTarget) async throws -> GitCheckoutResponse {
        try await send(
            endpoint: .gitStashCheckout,
            method: "POST",
            body: GitCheckoutRequest(sessionID: sessionID, target: target, includesDirtyMode: false)
        )
    }

    // MARK: - Commit flow (issue #315, Slice C)

    func gitStage(sessionID: String, paths: [String]) async throws -> GitMutationResponse {
        try await send(endpoint: .gitStage, method: "POST", body: GitPathsRequest(sessionID: sessionID, paths: paths))
    }

    func gitUnstage(sessionID: String, paths: [String]) async throws -> GitMutationResponse {
        try await send(endpoint: .gitUnstage, method: "POST", body: GitPathsRequest(sessionID: sessionID, paths: paths))
    }

    func gitDiscard(sessionID: String, paths: [String], deleteUntracked: Bool = false) async throws -> GitMutationResponse {
        try await send(
            endpoint: .gitDiscard,
            method: "POST",
            body: GitDiscardRequest(sessionID: sessionID, paths: paths, deleteUntracked: deleteUntracked)
        )
    }

    func gitCommit(sessionID: String, message: String) async throws -> GitCommitResponse {
        try await send(endpoint: .gitCommit, method: "POST", body: GitCommitRequest(sessionID: sessionID, message: message))
    }

    func gitCommitSelected(sessionID: String, message: String, paths: [String]) async throws -> GitCommitResponse {
        try await send(
            endpoint: .gitCommitSelected,
            method: "POST",
            body: GitCommitSelectedRequest(sessionID: sessionID, message: message, paths: paths)
        )
    }

    /// Generate a commit message from the staged diff. Not gated by the destructive flag.
    /// Generation runs an LLM server-side, so it gets a wider timeout than other calls.
    func gitCommitMessage(sessionID: String) async throws -> GitCommitMessageResponse {
        try await send(
            endpoint: .gitCommitMessage,
            method: "POST",
            body: GitSessionRequest(sessionID: sessionID),
            timeout: Self.commitMessageTimeout
        )
    }

    /// Generate a commit message from the selected paths' diff. Not gated by the destructive flag.
    func gitCommitMessageSelected(sessionID: String, paths: [String]) async throws -> GitCommitMessageResponse {
        try await send(
            endpoint: .gitCommitMessageSelected,
            method: "POST",
            body: GitPathsRequest(sessionID: sessionID, paths: paths),
            timeout: Self.commitMessageTimeout
        )
    }

    /// LLM commit-message generation can take far longer than the 60s session default,
    /// especially over a cold tunnel; allow up to two minutes before timing out.
    private static let commitMessageTimeout: TimeInterval = 120
}

private struct GitSessionRequest: Encodable {
    let sessionID: String
}

private struct GitPathsRequest: Encodable {
    let sessionID: String
    let paths: [String]
}

private struct GitDiscardRequest: Encodable {
    let sessionID: String
    let paths: [String]
    let deleteUntracked: Bool
}

private struct GitCommitRequest: Encodable {
    let sessionID: String
    let message: String
}

private struct GitCommitSelectedRequest: Encodable {
    let sessionID: String
    let message: String
    let paths: [String]
}

private struct GitCheckoutRequest: Encodable {
    let sessionID: String
    let ref: String
    let mode: String
    let newBranch: String?
    let track: Bool?
    let dirtyMode: String?

    init(sessionID: String, target: GitCheckoutTarget, includesDirtyMode: Bool) {
        self.sessionID = sessionID
        ref = target.ref
        // Creating a brand-new local branch must use the server's "new" mode. The
        // "local" mode only switches to an existing branch and ignores `new_branch`
        // entirely, so sending it for a create silently switches to `ref` instead
        // (a no-op when already on it). Remote checkouts keep "remote" — that mode
        // creates a tracking branch itself.
        mode = (target.mode == .local && target.newBranch != nil) ? "new" : target.mode.rawValue
        newBranch = target.newBranch
        track = target.track ? true : nil
        dirtyMode = includesDirtyMode ? "block" : nil
    }
}
