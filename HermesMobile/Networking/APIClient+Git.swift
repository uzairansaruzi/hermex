import Foundation
import Observation

protocol GitDataClient: Sendable {
    func info() async throws -> GitInfo?
    func status() async throws -> GitStatus?
    func diff(for file: GitFile) async throws -> GitDiff?
    func branchReview() async throws -> GitBranchReview?
    func changes(since base: String) async throws -> [GitFile]?
    func diff(for file: GitFile, in scope: GitReviewScope) async throws -> GitDiff?
    var reviewScope: String { get }
    @MainActor func rowPath(forToolPath path: String) -> String
    var isHermes: Bool { get }
    @MainActor var writeLock: GitWriteLock? { get }

    func stage(_ files: [GitFile]) async throws -> GitStatus?
    func unstage(_ files: [GitFile]) async throws -> GitStatus?
    func discard(_ files: [GitFile], deleteUntracked: Bool) async throws -> GitStatus?
    func commit(message: String, only files: [GitFile]?) async throws -> GitCommitResponse
    func push() async throws -> GitRemoteActionResponse
    func supportsSync() async -> Bool
    func fetch() async throws -> GitRemoteActionResponse
    func pull() async throws -> GitRemoteActionResponse
    func suggestMessage(for files: [GitFile]?, avoiding previous: String?) async throws -> GitCommitMessageResponse

    func branches() async throws -> GitBranches?
    func checkout(_ target: GitCheckoutTarget, stashingChanges: Bool) async throws -> GitCheckoutResponse

    func pullRequest() async throws -> GitPullRequest?
}

extension GitDataClient {
    @MainActor func rowPath(forToolPath path: String) -> String { path }

    var isHermes: Bool { false }

    @MainActor var writeLock: GitWriteLock? { nil }

    func branchReview() async throws -> GitBranchReview? { throw GitReviewScopeUnsupported() }

    func changes(since base: String) async throws -> [GitFile]? { throw GitReviewScopeUnsupported() }

    func diff(for file: GitFile, in scope: GitReviewScope) async throws -> GitDiff? {
        guard scope == .uncommitted else { throw GitReviewScopeUnsupported() }
        return try await diff(for: file)
    }

    func progressScope(_ scope: GitReviewScope, base: String?) -> String {
        switch scope {
        case .uncommitted: reviewScope
        case .branch: "\(reviewScope)|branch|\(base ?? "")"
        case .since(let base): "\(reviewScope)|since|\(base)"
        }
    }

    func pullRequest() async throws -> GitPullRequest? { nil }
}

struct GitReviewScopeUnsupported: Error {}

@MainActor @Observable final class GitWriteLock {
    private(set) var isHeld = false

    func acquire() -> Bool {
        guard !isHeld else { return false }
        isHeld = true
        return true
    }

    func release() {
        isHeld = false
    }
}

struct WebUIGitClient: GitDataClient {
    let apiClient: APIClient
    let sessionID: String

    init?(session: SessionSummary, apiClient: APIClient) {
        guard let sessionID = session.sessionId else { return nil }
        self.apiClient = apiClient
        self.sessionID = sessionID
    }

    var reviewScope: String { "webui|\(sessionID)" }

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

    func supportsSync() async -> Bool { true }

    func fetch() async throws -> GitRemoteActionResponse {
        try await apiClient.gitFetch(sessionID: sessionID)
    }

    func pull() async throws -> GitRemoteActionResponse {
        try await apiClient.gitPull(sessionID: sessionID)
    }

    func suggestMessage(for files: [GitFile]?, avoiding previous: String?) async throws -> GitCommitMessageResponse {
        guard let files else { return try await apiClient.gitCommitMessage(sessionID: sessionID) }
        return try await apiClient.gitCommitMessageSelected(sessionID: sessionID, paths: Self.paths(files))
    }

    func branches() async throws -> GitBranches? {
        try await apiClient.gitBranches(sessionID: sessionID).branches
    }

    func checkout(_ target: GitCheckoutTarget, stashingChanges: Bool) async throws -> GitCheckoutResponse {
        stashingChanges ? try await apiClient.gitStashCheckout(sessionID: sessionID, target: target)
            : try await apiClient.gitCheckout(sessionID: sessionID, target: target)
    }

    private static func paths(_ files: [GitFile]) -> [String] {
        files.compactMap { file in
            let trimmed = (file.path ?? file.workspacePath)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }
}

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

    func gitCommitMessage(sessionID: String) async throws -> GitCommitMessageResponse {
        try await send(
            endpoint: .gitCommitMessage,
            method: "POST",
            body: GitSessionRequest(sessionID: sessionID),
            timeout: Self.commitMessageTimeout
        )
    }

    func gitCommitMessageSelected(sessionID: String, paths: [String]) async throws -> GitCommitMessageResponse {
        try await send(
            endpoint: .gitCommitMessageSelected,
            method: "POST",
            body: GitPathsRequest(sessionID: sessionID, paths: paths),
            timeout: Self.commitMessageTimeout
        )
    }

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
        mode = (target.mode == .local && target.newBranch != nil) ? "new" : target.mode.rawValue
        newBranch = target.newBranch
        track = target.track ? true : nil
        dirtyMode = includesDirtyMode ? "block" : nil
    }
}
