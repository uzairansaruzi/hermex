import Foundation

/// Loads read-only git status for a chat's repository (issue #312, Slice A; Hermes #1114).
///
/// State is per repository client: a webui session's (`WebUIGitClient`, which only ever sends
/// that session's `session_id`, so the server resolves the workspace path) or a Hermes chat's
/// folder (`HermesGitClient`). Two sessions on the same folder therefore see the same git
/// state; different folders see independent state.
@Observable
final class GitWorkspaceViewModel {
    /// Nil for a webui session without an ID.
    private let git: (any GitDataClient)?

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private var hasLoaded = false

    init(git: (any GitDataClient)?) {
        self.git = git
    }

    convenience init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.init(git: WebUIGitClient(session: session, apiClient: apiClient ?? APIClient(baseURL: server)))
    }

    /// True once a status has loaded and the workspace is not a git repository
    /// (`is_git == false`). Drives the non-blocking empty state.
    var isNonRepository: Bool {
        status?.isGit == false
    }

    /// True once a real git status has loaded (a repo with `is_git == true`).
    var hasRepository: Bool {
        status?.isGit == true
    }

    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    @MainActor
    func load() async {
        guard let git else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil

        do {
            status = try await git.status()
            hasLoaded = true
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

/// Lightweight toolbar probe for whether a chat's workspace is a git repository.
/// The toolbar stays hidden unless the server confirms `is_git == true`.
///
/// Reads, commits, pushes and branch switches go through `git` (#1114, #1115, #1116). Fetch and
/// pull go to webui's session routes and need `session`'s ID, so a Hermes chat, which has none,
/// has none.
@Observable
final class GitWorkspaceAvailabilityViewModel {
    private let session: SessionSummary
    private let apiClient: APIClient
    /// What the menu, Changes sheet and diffs read; nil when the chat has no repository to read.
    let git: (any GitDataClient)?

    private(set) var hasRepository = false
    private(set) var isLoading = false
    private(set) var isStatusLoading = false
    private(set) var lastError: Error?
    private(set) var gitInfo: GitInfo?
    private(set) var status: GitStatus?
    private(set) var statusError: Error?
    private(set) var branches: GitBranches?
    private(set) var branchesError: Error?
    private(set) var isLoadingBranches = false
    private(set) var isSwitchingBranch = false
    private(set) var runningRemoteAction: GitRemoteAction?
    private(set) var commitPhase: GitCommitPhase?
    private(set) var actionErrorMessage: String?
    private(set) var lastActionMessage: String?
    private var hasLoaded = false
    /// Set once the chat leaves this repository (`retire()`).
    private(set) var isRetired = false

    init(session: SessionSummary, server: URL, git: (any GitDataClient)?, apiClient: APIClient? = nil) {
        self.session = session
        self.apiClient = apiClient ?? APIClient(baseURL: server)
        self.git = git
    }

    /// A webui session's repository, read and written through its session routes.
    convenience init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        let client = apiClient ?? APIClient(baseURL: server)
        self.init(session: session, server: server, git: WebUIGitClient(session: session, apiClient: client), apiClient: client)
    }

    /// Called when the chat leaves this repository, as a Hermes chat does when its folder changes:
    /// an action still running finishes without a result to show (`GitQuickCommitOutcome.retired`,
    /// and no message for a remote action), so nothing from this repository appears under the next.
    func retire() {
        isRetired = true
    }

    /// Whether the menu can stage, commit and push: a repository client to write through.
    var supportsWrites: Bool { git != nil }

    /// Whether the composer's branch picker lists and switches branches.
    var supportsBranches: Bool { git != nil }

    /// Whether fetch, pull, New Branch and stash-and-switch are available: webui's routes, which
    /// take its session ID. False on a Hermes chat.
    var supportsSync: Bool { session.sessionId != nil }

    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    @MainActor
    func load() async {
        guard let git else {
            hasRepository = false
            lastError = nil
            return
        }

        isLoading = true

        do {
            let info = try await git.info()
            gitInfo = info
            hasRepository = info?.isGit == true
            lastError = nil

            if hasRepository {
                isStatusLoading = true
                do {
                    status = try await git.status()
                    statusError = nil
                    hasLoaded = true
                } catch {
                    status = nil
                    statusError = error
                }
                isStatusLoading = false
                if statusError == nil {
                    await loadBranches()
                }
            } else {
                status = nil
                statusError = nil
                branches = nil
                branchesError = nil
                hasLoaded = true
            }
        } catch {
            hasRepository = false
            gitInfo = nil
            status = nil
            statusError = nil
            lastError = error
        }

        isLoading = false
    }

    var currentBranchName: String {
        let value = branches?.current ?? gitInfo?.branch ?? status?.branch
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? String(localized: "Branch") : trimmed
    }

    @MainActor var isRunningGitAction: Bool {
        isSwitchingBranch || runningRemoteAction != nil || commitPhase != nil || isWriteLocked
    }

    /// True while a write on this repository holds its `GitWriteLock`: this menu's, a branch
    /// switch, or the commit sheet's. Always false on webui.
    @MainActor var isWriteLocked: Bool { git?.writeLock?.isHeld == true }

    /// True while a quick-commit pipeline (menu row or inline turn button) is running.
    var isCommitting: Bool { commitPhase != nil }

    /// True when there is at least one non-ignored changed file to commit.
    var hasCommittableChanges: Bool {
        !(status?.trackedFiles.isEmpty ?? true)
    }

    @MainActor
    func loadBranches() async {
        guard let git, hasRepository, !isLoadingBranches else { return }
        isLoadingBranches = true
        branchesError = nil
        do {
            branches = try await git.branches()
        } catch {
            branchesError = error
        }
        isLoadingBranches = false
    }

    /// Switches branches, then reads the status and branches again. A failed Hermes switch reads
    /// them again too; one finishing after `retire()` has nothing to show (`.retired`). Refused,
    /// quietly, while another write holds the repository's `GitWriteLock`, as the picker is
    /// disabled then.
    @MainActor
    func checkout(_ target: GitCheckoutTarget, stashingChanges: Bool = false) async -> GitCheckoutOutcome {
        guard let git, !isSwitchingBranch, git.writeLock?.acquire() ?? true else { return .failure }
        isSwitchingBranch = true
        actionErrorMessage = nil
        defer {
            isSwitchingBranch = false
            git.writeLock?.release()
        }

        do {
            let response = try await git.checkout(target, stashingChanges: stashingChanges)
            guard !isRetired else { return .retired }
            apply(response)
            await refreshGitInfo()
            // Reload the branch list so the picker + composer pill reflect the new
            // current branch (a freshly created branch isn't in the cached list yet).
            await loadBranches()
            guard !isRetired else { return .retired }
            lastActionMessage = response.message
            if response.restoreFailed == true {
                actionErrorMessage = response.restoreError ?? String(localized: "The branch changed, but the saved changes could not be restored.")
            }
            return .success
        } catch let error as APIError where error.serverCode == "dirty_worktree" && !stashingChanges {
            return isRetired ? .retired : .requiresStash
        } catch {
            guard !isRetired else { return .retired }
            actionErrorMessage = friendlyMessage(for: error)
            if git.isHermes { await refreshAfterExternalMutation() }
            return isRetired ? .retired : .failure
        }
    }

    @MainActor
    func performRemoteAction(_ action: GitRemoteAction) async -> Bool {
        guard let call = remoteCall(action), runningRemoteAction == nil, git?.writeLock?.acquire() ?? true else { return false }
        runningRemoteAction = action
        actionErrorMessage = nil
        defer {
            runningRemoteAction = nil
            git?.writeLock?.release()
        }

        do {
            let response = try await call()
            guard !isRetired else { return false }
            status = response.status ?? status
            lastActionMessage = response.message
            await loadBranches()
            await refreshGitInfo()
            return !isRetired && response.ok != false
        } catch {
            guard !isRetired else { return false }
            actionErrorMessage = friendlyMessage(for: error)
            if git?.isHermes == true { await refreshAfterExternalMutation() }
            return false
        }
    }

    /// Push through the repository client; fetch and pull through webui's session routes.
    private func remoteCall(_ action: GitRemoteAction) -> (() async throws -> GitRemoteActionResponse)? {
        switch action {
        case .push:
            guard let git else { return nil }
            return { try await git.push() }
        case .fetch, .pull:
            guard let sessionID = session.sessionId else { return nil }
            let apiClient = apiClient
            return action == .fetch ? { try await apiClient.gitFetch(sessionID: sessionID) }
                : { try await apiClient.gitPull(sessionID: sessionID) }
        }
    }

    /// One-tap commit (optionally + push) for the toolbar menu rows and the inline
    /// turn-end button. Stages every non-ignored change, asks the server to suggest a
    /// commit message from the staged diff, commits, and optionally pushes. `onPhase`
    /// lets the caller drive the stacked progress toast; `commitPhase` mirrors the same
    /// state for the inline button while it runs. Refused, quietly, while the commit sheet
    /// writes to a Hermes repository (`GitWriteLock`).
    @MainActor
    func quickCommit(push: Bool, onPhase: ((GitCommitPhase) -> Void)? = nil) async -> GitQuickCommitOutcome {
        guard let git, commitPhase == nil else { return .failure }

        let filesToStage = (status?.trackedFiles ?? []).filter {
            ($0.path ?? $0.workspacePath)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard !filesToStage.isEmpty else { return .nothingToCommit }

        // The server caps git status at 500 changed files (STATUS_FILE_LIMIT) and flags the
        // list as `truncated`. `filesToStage` would then cover only the first 500 files, so a
        // one-tap commit would silently leave files 501+ uncommitted while reporting success.
        // Block the quick-commit path entirely in that case rather than commit a partial set;
        // a >500-file commit needs a server-side "stage all" that doesn't exist yet.
        guard status?.truncated != true else {
            actionErrorMessage = String(localized: "Too many changes to quick-commit (over 500 files). Commit in smaller batches, or use git directly.")
            return .tooManyChanges
        }

        guard git.writeLock?.acquire() ?? true else { return .failure }
        actionErrorMessage = nil
        setCommitPhase(.generatingMessage, notify: onPhase)
        defer {
            commitPhase = nil
            git.writeLock?.release()
        }

        do {
            // Stage everything first so this one-tap action commits all local changes,
            // then generate the message from that staged diff.
            _ = try await git.stage(filesToStage)

            let suggestion = try await git.suggestMessage(for: nil, avoiding: nil)
            guard !isRetired else { return .retired }
            let message = (suggestion.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                actionErrorMessage = String(localized: "No commit message could be generated.")
                return .failure
            }

            setCommitPhase(.committing, notify: onPhase)
            let commit = try await git.commit(message: message, only: nil)
            guard !isRetired else { return .retired }
            status = commit.resolvedStatus ?? status

            // The commit has already landed on the server. A push failure from here must
            // not be reported as a total failure: keep the commit's success path (refresh,
            // SHA toast) and surface the push error separately.
            var didPush = false
            var pushFailureMessage: String? = nil
            if push {
                setCommitPhase(.pushing, notify: onPhase)
                do {
                    let pushResponse = try await git.push()
                    status = pushResponse.status ?? status
                    lastActionMessage = pushResponse.message
                    didPush = pushResponse.ok != false
                } catch {
                    pushFailureMessage = friendlyMessage(for: error)
                    actionErrorMessage = pushFailureMessage
                }
            }

            await loadBranches()
            await refreshGitInfo()
            guard !isRetired else { return .retired }

            return .success(GitQuickCommitResult(
                shortSHA: commit.shortSHA,
                branch: currentBranchName,
                message: message,
                truncatedMessage: suggestion.truncated == true,
                didPush: didPush,
                pushFailureMessage: pushFailureMessage
            ))
        } catch {
            guard !isRetired else { return .retired }
            actionErrorMessage = friendlyMessage(for: error)
            if git.isHermes { await refreshAfterExternalMutation() }
            return .failure
        }
    }

    private func setCommitPhase(_ phase: GitCommitPhase, notify: ((GitCommitPhase) -> Void)?) {
        commitPhase = phase
        notify?(phase)
    }

    /// Re-fetch info, status and branches after the advanced staging sheet mutates the
    /// working tree, or a Hermes write here fails partway, so the toolbar badge and Changes row
    /// stay in sync.
    @MainActor
    func refreshAfterExternalMutation() async {
        await refreshGitInfo()
        guard let git, hasRepository else { return }
        if let refreshed = try? await git.status() {
            status = refreshed
            statusError = nil
        }
        await loadBranches()
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    private func apply(_ response: GitCheckoutResponse) {
        status = response.resolvedStatus ?? status
        branches = response.branches ?? branches
    }

    @MainActor
    private func refreshGitInfo() async {
        guard let git else { return }
        do {
            let info = try await git.info()
            gitInfo = info
            hasRepository = info?.isGit == true
        } catch {
            // A failed refresh keeps the last answer: it is not a missing repository.
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        gitWriteFriendlyMessage(for: error)
    }
}

/// Maps server git errors to short, friendly copy shared by every git write surface
/// (branch switching, remote sync, and the commit flow). Unknown codes fall back to the
/// server's own message, then the generic localized description. The stale-runtime
/// 409 (commit-message generation) has no code and gets the app's restart copy.
func gitWriteFriendlyMessage(for error: Error) -> String {
    guard let apiError = error as? APIError else { return error.localizedDescription }
    if let stale = apiError.agentRuntimeStale { return stale.message }
    switch apiError.serverCode {
    case "destructive_git_disabled":
        return String(localized: "Writes disabled on server. Enable HERMES_WEBUI_WORKSPACE_GIT_DESTRUCTIVE=1 on the server to use this.")
    case "active_stream":
        return String(localized: "Wait for the active response to finish before changing this repository.")
    default:
        return apiError.serverMessage ?? apiError.localizedDescription
    }
}

enum GitRemoteAction: String, Equatable, Identifiable {
    case fetch
    case pull
    case push

    var id: String { rawValue }

    var progressTitle: String {
        switch self {
        case .fetch: String(localized: "Fetching...")
        case .pull: String(localized: "Pulling...")
        case .push: String(localized: "Pushing...")
        }
    }

    var successTitle: String {
        switch self {
        case .fetch: String(localized: "Fetch complete")
        case .pull: String(localized: "Pull complete")
        case .push: String(localized: "Push complete")
        }
    }
}

enum GitCheckoutOutcome: Equatable {
    case success
    case requiresStash
    case failure
    /// The chat left the repository while the switch ran: nothing to show.
    case retired
}

/// The visible phases of the one-tap commit pipeline (issue #315, Slice C). Staging
/// happens under `generatingMessage` so the toast shows the same sequence the spec
/// describes: "Generating commit message…" → "Committing…" → "Pushing…".
enum GitCommitPhase: Equatable {
    case generatingMessage
    case committing
    case pushing

    var progressTitle: String {
        switch self {
        case .generatingMessage: String(localized: "Generating commit message...")
        case .committing: String(localized: "Committing...")
        case .pushing: String(localized: "Pushing...")
        }
    }

    /// Short label used inside the inline turn-end button while running.
    var inlineTitle: String {
        switch self {
        case .generatingMessage, .committing: String(localized: "Committing...")
        case .pushing: String(localized: "Pushing...")
        }
    }
}

struct GitQuickCommitResult: Equatable {
    let shortSHA: String?
    let branch: String?
    let message: String?
    let truncatedMessage: Bool
    let didPush: Bool
    /// Set when the commit succeeded but a requested push failed; carries the friendly
    /// push error so the caller can report partial success instead of a clean toast.
    var pushFailureMessage: String? = nil
}

enum GitQuickCommitOutcome: Equatable {
    case success(GitQuickCommitResult)
    case nothingToCommit
    /// The server truncated the status list (>500 changed files), so the client only knows
    /// the first 500. Quick-commit refuses rather than silently committing a partial set.
    case tooManyChanges
    case failure
    /// The chat left the repository while it ran (`GitWorkspaceAvailabilityViewModel.retire()`):
    /// nothing to show.
    case retired
}

struct GitWriteAvailability: Equatable {
    let isStreaming: Bool
    let isViewingCachedData: Bool
    /// A Hermes chat's repository has no fetch or pull (#1114, #1115): those entries are
    /// hidden, not disabled.
    var hidesSync = false

    var writesDisabled: Bool { isStreaming || isViewingCachedData }
    var fetchDisabled: Bool { isViewingCachedData }
}

/// Pure presentation state for the toolbar menu, kept outside UIKit so its edge cases are testable.
struct GitToolbarPresentation: Equatable {
    let hasRepository: Bool
    let isLoading: Bool
    let info: GitInfo?
    let status: GitStatus?
    let statusFailed: Bool

    var accessibilityValue: String {
        guard hasRepository else { return String(localized: "Repository status unavailable") }
        let dirty = (info?.dirty ?? 0) > 0
        let ahead = (info?.ahead ?? 0) > 0
        let behind = (info?.behind ?? 0) > 0
        if dirty && behind { return String(localized: "Local changes exist and remote branch moved ahead") }
        if dirty { return String(localized: "Local repository has uncommitted changes") }
        if ahead && behind { return String(localized: "Local and remote branches diverged") }
        if behind { return String(localized: "Remote branch ahead of local branch") }
        if ahead { return String(localized: "Local branch ahead of remote") }
        return String(localized: "Repository up to date")
    }

    var changesAreEnabled: Bool { !isLoading && (status != nil || statusFailed) }

    /// The branch, with the Changes header's "↑ahead ↓behind" once it has moved from its
    /// upstream, for a menu without fetch or pull (a Hermes chat's). Nil without a branch.
    var branchSummary: String? {
        guard hasRepository, let branch = info?.branch ?? status?.branch, !branch.isEmpty else { return nil }
        let ahead = info?.ahead ?? status?.ahead ?? 0
        let behind = info?.behind ?? status?.behind ?? 0
        return ahead > 0 || behind > 0 ? "\(branch)  ↑\(ahead) ↓\(behind)" : branch
    }
}

/// Which mutating operation the advanced staging sheet is currently running, used to
/// disable controls and show the right inline spinner.
enum GitCommitOperation: Equatable {
    case staging
    case unstaging
    case discarding
    case committing
    case suggesting
}

/// View model for the advanced staging & commit sheet (issue #315, Slice C; Hermes #1115).
///
/// Self-contained per repository client: it loads its own status so the sheet always reflects
/// the current working tree, and owns the file selection, commit-message field, and the
/// stage / unstage / discard / suggest / commit operations. A failed Hermes write reads the
/// status again, since it can have changed part of the tree (`GitDataClient.isHermes`), and
/// none starts while the Git menu writes to the same repository (`GitWriteLock`).
@MainActor
@Observable
final class GitCommitViewModel {
    /// Nil for a webui session without an ID.
    private let git: (any GitDataClient)?

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?
    private(set) var lastError: Error?

    /// Paths the user has checked for batch stage/unstage/discard and "Commit selected".
    private(set) var selectedPaths: Set<String> = []

    /// The commit-message field (two-way bound from the sheet).
    var message: String = ""
    private(set) var messageWasTruncated = false
    private(set) var busyOperation: GitCommitOperation?
    private(set) var actionErrorMessage: String?
    private(set) var lastCommitSHA: String?
    /// Bumps after every successful commit so the host can refresh the toolbar badge.
    private(set) var committedRevision = 0
    /// The last suggested message, which Regenerate asks the client to avoid.
    private var lastSuggestion: String?

    init(git: (any GitDataClient)?) {
        self.git = git
    }

    /// A webui session's repository.
    convenience init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.init(git: WebUIGitClient(session: session, apiClient: apiClient ?? APIClient(baseURL: server)))
    }

    /// The last commit's sha, which the sheet shows for a Hermes repository.
    var shownCommitSHA: String? { git?.isHermes == true ? lastCommitSHA : nil }

    var trackedFiles: [GitFile] { status?.trackedFiles ?? [] }
    var stagedFiles: [GitFile] { trackedFiles.filter { $0.staged == true } }
    var hasChanges: Bool { !trackedFiles.isEmpty }
    var hasStagedChanges: Bool { !stagedFiles.isEmpty }
    var hasSelection: Bool { !selectedPaths.isEmpty }
    /// True while this sheet runs an operation, or the Git menu's quick commit or push or a branch
    /// switch holds the repository's `GitWriteLock`.
    var isBusy: Bool { busyOperation != nil || git?.writeLock?.isHeld == true }
    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    func isSelected(_ file: GitFile) -> Bool { selectedPaths.contains(file.id) }

    func toggleSelection(_ file: GitFile) {
        if selectedPaths.contains(file.id) {
            selectedPaths.remove(file.id)
        } else {
            selectedPaths.insert(file.id)
        }
    }

    func clearSelection() { selectedPaths.removeAll() }

    func clearActionError() { actionErrorMessage = nil }

    /// The current selection, or all changed files when nothing is selected (the "operate on
    /// everything" default for the batch buttons).
    private var targetFiles: [GitFile] {
        hasSelection ? trackedFiles.filter { selectedPaths.contains($0.id) } : trackedFiles
    }

    func load() async {
        guard let git else {
            loadErrorMessage = String(localized: "Session ID is missing.")
            return
        }
        isLoading = true
        loadErrorMessage = nil
        lastError = nil
        do {
            status = try await git.status()
            pruneSelectionToCurrentFiles()
        } catch {
            lastError = error
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func stageSelectedOrAll() async {
        await mutate(.staging, files: targetFiles) { git, files in try await git.stage(files) }
    }

    func unstageSelectedOrAll() async {
        await mutate(.unstaging, files: targetFiles) { git, files in try await git.unstage(files) }
    }

    /// Discards the selection, or every change. The client unstages staged targets first so the
    /// index is reverted too, as the destructive confirmation says.
    func discardSelectedOrAll(deleteUntracked: Bool) async {
        let targets = targetFiles
        await mutate(.discarding, files: targets) { git, files in
            try await git.discard(files, deleteUntracked: deleteUntracked)
        }
        if actionErrorMessage == nil { selectedPaths.subtract(targets.map(\.id)) }
    }

    /// Generate a message from the selection (or whole staged diff). Read-only: works
    /// even with the destructive flag off and during an active stream. Again, it asks for a
    /// different message than the last one.
    func suggestMessage() async {
        guard let git, busyOperation == nil else { return }
        busyOperation = .suggesting
        actionErrorMessage = nil
        defer { busyOperation = nil }
        do {
            let response = try await git.suggestMessage(for: hasSelection ? targetFiles : nil, avoiding: lastSuggestion)
            let suggested = (response.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if suggested.isEmpty {
                actionErrorMessage = String(localized: "No commit message could be generated.")
            } else {
                message = suggested
                lastSuggestion = suggested
                messageWasTruncated = response.truncated == true
            }
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
        }
    }

    /// Commit all staged changes with the current message. Returns `true` on success.
    func commit(push: Bool) async -> Bool {
        await runCommit(push: push) { git, message in try await git.commit(message: message, only: nil) }
    }

    /// Commit only the selected paths. Returns `true` on success.
    func commitSelected(push: Bool) async -> Bool {
        let selected = targetFiles
        guard !selected.isEmpty else { return false }
        return await runCommit(push: push) { git, message in try await git.commit(message: message, only: selected) }
    }

    private func runCommit(
        push: Bool,
        _ commitCall: @escaping (any GitDataClient, String) async throws -> GitCommitResponse
    ) async -> Bool {
        guard let git, busyOperation == nil else { return false }
        let messageToSend = trimmedMessage
        guard !messageToSend.isEmpty else {
            actionErrorMessage = String(localized: "Enter a commit message first.")
            return false
        }
        guard git.writeLock?.acquire() ?? true else { return false }
        busyOperation = .committing
        actionErrorMessage = nil
        defer {
            busyOperation = nil
            git.writeLock?.release()
        }
        do {
            let response = try await commitCall(git, messageToSend)
            status = response.resolvedStatus ?? status
            lastCommitSHA = response.shortSHA
            // A Hermes Commit Selected landed but left some other staged files unstaged.
            let restoreWarning = response.stagingNotRestored
                ? String(localized: "Committed, but some files couldn’t be staged again.") : nil
            actionErrorMessage = restoreWarning
            // The commit has already landed. If a requested push then fails, still run the
            // success cleanup (clear message/selection, bump committedRevision so the caller
            // refreshes the toolbar) and surface the push error in the sheet banner.
            if push {
                do {
                    let pushResponse = try await git.push()
                    status = pushResponse.status ?? status
                } catch {
                    // The commit already landed; only the push failed. Phrase it as a
                    // partial success so the banner doesn't read as a failed commit.
                    actionErrorMessage = [restoreWarning, String(localized: "Committed, but the push failed.")
                        + " " + gitWriteFriendlyMessage(for: error)].compactMap { $0 }.joined(separator: " ")
                }
            }
            message = ""
            messageWasTruncated = false
            lastSuggestion = nil
            clearSelection()
            committedRevision += 1
            return true
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
            if git.isHermes { await reloadAfterFailedWrite(git) }
            return false
        }
    }

    private func mutate(
        _ operation: GitCommitOperation,
        files: [GitFile],
        _ call: @escaping (any GitDataClient, [GitFile]) async throws -> GitStatus?
    ) async {
        guard let git, busyOperation == nil, !files.isEmpty, git.writeLock?.acquire() ?? true else { return }
        busyOperation = operation
        actionErrorMessage = nil
        defer {
            busyOperation = nil
            git.writeLock?.release()
        }
        do {
            status = try await call(git, files) ?? status
            pruneSelectionToCurrentFiles()
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
            if git.isHermes { await reloadAfterFailedWrite(git) }
        }
    }

    /// The status after a write that failed, which may have changed part of the tree. A failed
    /// read keeps the last one.
    private func reloadAfterFailedWrite(_ git: any GitDataClient) async {
        guard let refreshed = try? await git.status() else { return }
        status = refreshed
        pruneSelectionToCurrentFiles()
    }

    private func pruneSelectionToCurrentFiles() {
        let valid = Set(trackedFiles.map(\.id))
        selectedPaths.formIntersection(valid)
    }
}
