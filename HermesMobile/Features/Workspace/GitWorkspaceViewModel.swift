import Foundation

/// Loads read-only git status for a chat session's workspace (issue #312, Slice A).
///
/// State is per session: each view model owns one `SessionSummary` and only ever sends that
/// session's `session_id` to the server, which resolves the workspace path (same rule as
/// `FileBrowserViewModel`). Two sessions on the same folder therefore see the same git state;
/// different folders see independent state.
@Observable
final class GitWorkspaceViewModel {
    private let session: SessionSummary
    private let apiClient: APIClient

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private var hasLoaded = false

    init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.session = session
        self.apiClient = apiClient ?? APIClient(baseURL: server)
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
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil

        do {
            let response = try await apiClient.gitStatus(sessionID: sessionID)
            status = response.git
            hasLoaded = true
        } catch {
            if !error.isCancellation {
                lastError = error
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }
}

/// Lightweight toolbar probe for whether a chat session's workspace is a git repository.
/// The toolbar stays hidden unless the server confirms `is_git == true`.
@Observable
final class GitWorkspaceAvailabilityViewModel {
    private let session: SessionSummary
    private let apiClient: APIClient

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

    init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.session = session
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    @MainActor
    func load() async {
        guard let sessionID = session.sessionId else {
            hasRepository = false
            lastError = nil
            return
        }

        isLoading = true

        do {
            let response = try await apiClient.gitInfo(sessionID: sessionID)
            gitInfo = response.git
            hasRepository = response.git?.isGit == true
            lastError = nil

            if hasRepository {
                isStatusLoading = true
                do {
                    status = try await apiClient.gitStatus(sessionID: sessionID).git
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

    var isRunningGitAction: Bool {
        isSwitchingBranch || runningRemoteAction != nil || commitPhase != nil
    }

    /// True while a quick-commit pipeline (menu row or inline turn button) is running.
    var isCommitting: Bool { commitPhase != nil }

    /// True when there is at least one non-ignored changed file to commit.
    var hasCommittableChanges: Bool {
        !(status?.trackedFiles.isEmpty ?? true)
    }

    @MainActor
    func loadBranches() async {
        guard let sessionID = session.sessionId, hasRepository, !isLoadingBranches else { return }
        isLoadingBranches = true
        branchesError = nil
        do {
            branches = try await apiClient.gitBranches(sessionID: sessionID).branches
        } catch {
            branchesError = error
        }
        isLoadingBranches = false
    }

    @MainActor
    func checkout(_ target: GitCheckoutTarget, stashingChanges: Bool = false) async -> GitCheckoutOutcome {
        guard let sessionID = session.sessionId, !isSwitchingBranch else { return .failure }
        isSwitchingBranch = true
        actionErrorMessage = nil
        defer { isSwitchingBranch = false }

        do {
            let response = if stashingChanges {
                try await apiClient.gitStashCheckout(sessionID: sessionID, target: target)
            } else {
                try await apiClient.gitCheckout(sessionID: sessionID, target: target)
            }
            apply(response)
            await refreshGitInfo()
            // Reload the branch list so the picker + composer pill reflect the new
            // current branch (a freshly created branch isn't in the cached list yet).
            await loadBranches()
            lastActionMessage = response.message
            if response.restoreFailed == true {
                actionErrorMessage = response.restoreError ?? String(localized: "The branch changed, but the saved changes could not be restored.")
            }
            return .success
        } catch let error as APIError where error.serverCode == "dirty_worktree" && !stashingChanges {
            return .requiresStash
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            return .failure
        }
    }

    @MainActor
    func performRemoteAction(_ action: GitRemoteAction) async -> Bool {
        guard let sessionID = session.sessionId, runningRemoteAction == nil else { return false }
        runningRemoteAction = action
        actionErrorMessage = nil
        defer { runningRemoteAction = nil }

        do {
            let response: GitRemoteActionResponse = switch action {
            case .fetch: try await apiClient.gitFetch(sessionID: sessionID)
            case .pull: try await apiClient.gitPull(sessionID: sessionID)
            case .push: try await apiClient.gitPush(sessionID: sessionID)
            }
            status = response.status ?? status
            lastActionMessage = response.message
            await loadBranches()
            await refreshGitInfo()
            return response.ok != false
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            return false
        }
    }

    /// One-tap commit (optionally + push) for the toolbar menu rows and the inline
    /// turn-end button. Stages every non-ignored change, asks the server to suggest a
    /// commit message from the staged diff, commits, and optionally pushes. `onPhase`
    /// lets the caller drive the stacked progress toast; `commitPhase` mirrors the same
    /// state for the inline button while it runs.
    @MainActor
    func quickCommit(push: Bool, onPhase: ((GitCommitPhase) -> Void)? = nil) async -> GitQuickCommitOutcome {
        guard let sessionID = session.sessionId, commitPhase == nil else { return .failure }

        let pathsToStage = (status?.trackedFiles ?? []).compactMap { file -> String? in
            let path = file.path ?? file.workspacePath
            let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        guard !pathsToStage.isEmpty else { return .nothingToCommit }

        // The server caps git status at 500 changed files (STATUS_FILE_LIMIT) and flags the
        // list as `truncated`. `pathsToStage` would then cover only the first 500 files, so a
        // one-tap commit would silently leave files 501+ uncommitted while reporting success.
        // Block the quick-commit path entirely in that case rather than commit a partial set;
        // a >500-file commit needs a server-side "stage all" that doesn't exist yet.
        guard status?.truncated != true else {
            actionErrorMessage = String(localized: "Too many changes to quick-commit (over 500 files). Commit in smaller batches, or use git directly.")
            return .tooManyChanges
        }

        actionErrorMessage = nil
        setCommitPhase(.generatingMessage, notify: onPhase)
        defer { commitPhase = nil }

        do {
            // Stage everything first so this one-tap action commits all local changes,
            // then generate the message from that staged diff.
            _ = try await apiClient.gitStage(sessionID: sessionID, paths: pathsToStage)

            let suggestion = try await apiClient.gitCommitMessage(sessionID: sessionID)
            let message = (suggestion.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                actionErrorMessage = String(localized: "No commit message could be generated.")
                return .failure
            }

            setCommitPhase(.committing, notify: onPhase)
            let commit = try await apiClient.gitCommit(sessionID: sessionID, message: message)
            status = commit.resolvedStatus ?? status

            // The commit has already landed on the server. A push failure from here must
            // not be reported as a total failure: keep the commit's success path (refresh,
            // SHA toast) and surface the push error separately.
            var didPush = false
            var pushFailureMessage: String? = nil
            if push {
                setCommitPhase(.pushing, notify: onPhase)
                do {
                    let pushResponse = try await apiClient.gitPush(sessionID: sessionID)
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

            return .success(GitQuickCommitResult(
                shortSHA: commit.shortSHA,
                branch: currentBranchName,
                message: message,
                truncatedMessage: suggestion.truncated == true,
                didPush: didPush,
                pushFailureMessage: pushFailureMessage
            ))
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            return .failure
        }
    }

    private func setCommitPhase(_ phase: GitCommitPhase, notify: ((GitCommitPhase) -> Void)?) {
        commitPhase = phase
        notify?(phase)
    }

    /// Re-fetch info, status and branches after the advanced staging sheet mutates the
    /// working tree, so the toolbar badge and Changes row stay in sync.
    @MainActor
    func refreshAfterExternalMutation() async {
        await refreshGitInfo()
        guard let sessionID = session.sessionId, hasRepository else { return }
        if let refreshed = try? await apiClient.gitStatus(sessionID: sessionID).git {
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
        guard let sessionID = session.sessionId else { return }
        if let response = try? await apiClient.gitInfo(sessionID: sessionID) {
            gitInfo = response.git
            hasRepository = response.git?.isGit == true
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        gitWriteFriendlyMessage(for: error)
    }
}

/// Maps server git errors to short, friendly copy shared by every git write surface
/// (branch switching, remote sync, and the commit flow). Unknown codes fall back to the
/// server's own message, then the generic localized description.
func gitWriteFriendlyMessage(for error: Error) -> String {
    guard let apiError = error as? APIError else { return error.localizedDescription }
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
}

struct GitWriteAvailability: Equatable {
    let isStreaming: Bool
    let isViewingCachedData: Bool

    var writesDisabled: Bool { isStreaming || isViewingCachedData }
    var fetchDisabled: Bool { isViewingCachedData }
}

enum GitToolbarStatusDot: Equatable {
    case gray
}

/// Pure presentation state for the toolbar menu, kept outside UIKit so its edge cases are testable.
struct GitToolbarPresentation: Equatable {
    let hasRepository: Bool
    let isLoading: Bool
    let info: GitInfo?
    let status: GitStatus?
    let statusFailed: Bool

    var statusDot: GitToolbarStatusDot? {
        guard hasRepository else { return nil }
        if (info?.dirty ?? 0) > 0 || (info?.behind ?? 0) > 0 { return .gray }
        return nil
    }

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

    var changesTitle: String {
        if statusFailed { return String(localized: "Changes unavailable") }
        guard let status else { return String(localized: "No changes") }
        guard status.changedCount > 0 else { return String(localized: "No changes") }
        return "+\(status.totalAdditions) −\(status.totalDeletions)  \(status.changedCount)"
    }

    var changesAreEnabled: Bool { !isLoading && (status != nil || statusFailed) }
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

/// View model for the advanced staging & commit sheet (issue #315, Slice C).
///
/// Self-contained per session: it loads its own status so the sheet always reflects the
/// current working tree, and owns the file selection, commit-message field, and the
/// stage / unstage / discard / suggest / commit operations.
@MainActor
@Observable
final class GitCommitViewModel {
    private let session: SessionSummary
    private let apiClient: APIClient

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

    init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.session = session
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var trackedFiles: [GitFile] { status?.trackedFiles ?? [] }
    var stagedFiles: [GitFile] { trackedFiles.filter { $0.staged == true } }
    var hasChanges: Bool { !trackedFiles.isEmpty }
    var hasStagedChanges: Bool { !stagedFiles.isEmpty }
    var hasSelection: Bool { !selectedPaths.isEmpty }
    var isBusy: Bool { busyOperation != nil }
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

    /// Server paths for the current selection, or all changed files when nothing is
    /// selected (the "operate on everything" default for the batch buttons).
    private var targetPaths: [String] {
        let files = hasSelection ? trackedFiles.filter { selectedPaths.contains($0.id) } : trackedFiles
        return files.compactMap(serverPath)
    }

    private func serverPath(_ file: GitFile) -> String? {
        let path = file.path ?? file.workspacePath
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    func load() async {
        guard let sessionID = session.sessionId else {
            loadErrorMessage = String(localized: "Session ID is missing.")
            return
        }
        isLoading = true
        loadErrorMessage = nil
        lastError = nil
        do {
            status = try await apiClient.gitStatus(sessionID: sessionID).git
            pruneSelectionToCurrentFiles()
        } catch {
            lastError = error
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func stageSelectedOrAll() async {
        await mutate(.staging, paths: targetPaths) { sessionID, paths in
            try await self.apiClient.gitStage(sessionID: sessionID, paths: paths)
        }
    }

    func unstageSelectedOrAll() async {
        await mutate(.unstaging, paths: targetPaths) { sessionID, paths in
            try await self.apiClient.gitUnstage(sessionID: sessionID, paths: paths)
        }
    }

    func discardSelectedOrAll(deleteUntracked: Bool) async {
        let targets = hasSelection ? trackedFiles.filter { selectedPaths.contains($0.id) } : trackedFiles
        let targetIDs = Set(targets.map(\.id))
        let allPaths = targets.compactMap(serverPath)
        let stagedPaths = targets.filter { $0.staged == true }.compactMap(serverPath)

        await mutate(.discarding, paths: allPaths) { sessionID, paths in
            // The server's discard only runs `git restore --worktree`, which leaves the
            // index untouched — so staged changes would survive a "discard". Unstage the
            // staged targets first so discarding actually reverts them, matching the
            // destructive confirmation copy. (A staged-new file then becomes untracked and
            // is removed via deleteUntracked, which the sheet's confirmation accounts for.)
            if !stagedPaths.isEmpty {
                _ = try await self.apiClient.gitUnstage(sessionID: sessionID, paths: stagedPaths)
            }
            return try await self.apiClient.gitDiscard(sessionID: sessionID, paths: paths, deleteUntracked: deleteUntracked)
        }
        if actionErrorMessage == nil { selectedPaths.subtract(targetIDs) }
    }

    /// Generate a message from the selection (or whole staged diff). Read-only: works
    /// even with the destructive flag off and during an active stream.
    func suggestMessage() async {
        guard let sessionID = session.sessionId, busyOperation == nil else { return }
        busyOperation = .suggesting
        actionErrorMessage = nil
        defer { busyOperation = nil }
        do {
            let response: GitCommitMessageResponse
            if hasSelection {
                response = try await apiClient.gitCommitMessageSelected(sessionID: sessionID, paths: targetPaths)
            } else {
                response = try await apiClient.gitCommitMessage(sessionID: sessionID)
            }
            let suggested = (response.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if suggested.isEmpty {
                actionErrorMessage = String(localized: "No commit message could be generated.")
            } else {
                message = suggested
                messageWasTruncated = response.truncated == true
            }
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
        }
    }

    /// Commit all staged changes with the current message. Returns `true` on success.
    func commit(push: Bool) async -> Bool {
        await runCommit(push: push) { sessionID, message in
            try await self.apiClient.gitCommit(sessionID: sessionID, message: message)
        }
    }

    /// Commit only the selected paths via `commit-selected`. Returns `true` on success.
    func commitSelected(push: Bool) async -> Bool {
        let selected = targetPaths
        guard !selected.isEmpty else { return false }
        return await runCommit(push: push) { sessionID, message in
            try await self.apiClient.gitCommitSelected(sessionID: sessionID, message: message, paths: selected)
        }
    }

    private func runCommit(
        push: Bool,
        _ commitCall: @escaping (String, String) async throws -> GitCommitResponse
    ) async -> Bool {
        guard let sessionID = session.sessionId, busyOperation == nil else { return false }
        let messageToSend = trimmedMessage
        guard !messageToSend.isEmpty else {
            actionErrorMessage = String(localized: "Enter a commit message first.")
            return false
        }
        busyOperation = .committing
        actionErrorMessage = nil
        defer { busyOperation = nil }
        do {
            let response = try await commitCall(sessionID, messageToSend)
            status = response.resolvedStatus ?? status
            lastCommitSHA = response.shortSHA
            // The commit has already landed. If a requested push then fails, still run the
            // success cleanup (clear message/selection, bump committedRevision so the caller
            // refreshes the toolbar) and surface the push error in the sheet banner.
            if push {
                do {
                    let pushResponse = try await apiClient.gitPush(sessionID: sessionID)
                    status = pushResponse.status ?? status
                } catch {
                    // The commit already landed; only the push failed. Phrase it as a
                    // partial success so the banner doesn't read as a failed commit.
                    actionErrorMessage = String(localized: "Committed, but the push failed.")
                        + " " + gitWriteFriendlyMessage(for: error)
                }
            }
            message = ""
            messageWasTruncated = false
            clearSelection()
            committedRevision += 1
            return true
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
            return false
        }
    }

    private func mutate(
        _ operation: GitCommitOperation,
        paths: [String],
        _ call: @escaping (String, [String]) async throws -> GitMutationResponse
    ) async {
        guard let sessionID = session.sessionId, busyOperation == nil, !paths.isEmpty else { return }
        busyOperation = operation
        actionErrorMessage = nil
        defer { busyOperation = nil }
        do {
            let response = try await call(sessionID, paths)
            status = response.resolvedStatus ?? status
            pruneSelectionToCurrentFiles()
        } catch {
            actionErrorMessage = gitWriteFriendlyMessage(for: error)
        }
    }

    private func pruneSelectionToCurrentFiles() {
        let valid = Set(trackedFiles.map(\.id))
        selectedPaths.formIntersection(valid)
    }
}
