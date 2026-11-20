import Foundation

@Observable
final class GitWorkspaceViewModel {
    private let git: (any GitDataClient)?
    private let progress: ReviewProgressStore?

    var scope: GitReviewScope = .uncommitted

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private var hasLoaded = false

    private(set) var branchReview: GitBranchReview?
    private(set) var isLoadingBranch = false
    private(set) var branchErrorMessage: String?
    private(set) var hasLoadedBranch = false

    private var statusRead = 0
    private var branchRead = 0

    init(git: (any GitDataClient)?, progress: ReviewProgressStore? = nil) {
        self.git = git
        self.progress = progress
    }

    convenience init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.init(git: WebUIGitClient(session: session, apiClient: apiClient ?? APIClient(baseURL: server)))
    }

    var isNonRepository: Bool {
        status?.isGit == false
    }

    var hasRepository: Bool {
        status?.isGit == true
    }

    var showsStatusFailure: Bool {
        status == nil && (errorMessage != nil || hasLoaded && !isLoading)
    }

    var showsScopePicker: Bool {
        git?.isHermes == true && hasRepository
    }

    @MainActor
    func loadIfNeeded() async {
        lastError = nil
        switch scope {
        case .uncommitted, .since: guard !hasLoaded else { return }
        case .branch: guard !hasLoadedBranch else { return }
        }
        await load()
    }

    @MainActor
    func load() async {
        switch scope {
        case .uncommitted, .since: await loadStatus()
        case .branch: await loadBranch()
        }
    }

    @MainActor
    private func loadStatus() async {
        guard let git else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }
        statusRead += 1
        let read = statusRead
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { if read == statusRead { isLoading = false } }

        do {
            let loaded = try await git.status()
            guard read == statusRead, !Task.isCancelled else { return }
            status = loaded
            hasLoaded = true
            progress?.prune(to: loaded, in: git.reviewScope)
        } catch {
            guard read == statusRead, !Task.isCancelled else { return }
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadBranch() async {
        guard let git else { return }
        branchRead += 1
        let read = branchRead
        isLoadingBranch = true
        branchErrorMessage = nil
        lastError = nil
        defer { if read == branchRead { isLoadingBranch = false } }

        do {
            let review = try await git.branchReview()
            guard read == branchRead, !Task.isCancelled else { return }
            branchReview = review
            hasLoadedBranch = true
            if let review { progress?.prune(toListed: review.files, in: git.progressScope(.branch, base: review.base)) }
        } catch {
            guard read == branchRead, !Task.isCancelled else { return }
            lastError = error
            branchReview = nil
            branchErrorMessage = error.localizedDescription
        }
    }
}

@Observable
final class GitWorkspaceAvailabilityViewModel {
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
    private(set) var supportsSync = false
    private var hasLoaded = false
    private(set) var isRetired = false
    private var turnReview: (base: GitTurnBase, review: GitTurnReview)?
    private var turnReviewRead = 0

    init(git: (any GitDataClient)?) {
        self.git = git
    }

    convenience init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.init(git: WebUIGitClient(session: session, apiClient: apiClient ?? APIClient(baseURL: server)))
    }

    @MainActor func retire() {
        isRetired = true
        suspendPullRequestReads()
    }

    @MainActor
    func loadTurnReview(since base: GitTurnBase?) async {
        turnReviewRead += 1
        let read = turnReviewRead
        guard let base, let git else {
            turnReview = nil
            return
        }
        turnReview = (base, .reading)
        let review: GitTurnReview
        do {
            review = try await git.changes(since: base.sha).map(GitTurnReview.read) ?? .failed
        } catch {
            review = .failed
        }
        guard read == turnReviewRead, !isRetired else { return }
        turnReview = (base, review)
    }

    @MainActor
    private func reloadTurnReview() async {
        guard let base = turnReview?.base else { return }
        await loadTurnReview(since: base)
    }

    @MainActor
    func turnChangeRows(since base: GitTurnBase?) -> (files: [GitFile], scope: GitReviewScope)? {
        let uncommitted = (files: status?.files ?? [], scope: GitReviewScope.uncommitted)
        guard let base else { return uncommitted }
        guard let turnReview, turnReview.base == base else { return nil }
        switch turnReview.review {
        case .reading: return nil
        case .read(let files): return (files, .since(base: base.sha))
        case .failed: return uncommitted
        }
    }

    var supportsWrites: Bool { git != nil }

    var supportsBranches: Bool { git != nil }

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
        async let sync = git.supportsSync()

        do {
            let info = try await git.info()
            gitInfo = info
            hasRepository = info?.isGit == true
            supportsSync = await sync
            lastError = nil

            if hasRepository {
                refreshPullRequest()
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

    @MainActor var isWriteLocked: Bool { git?.writeLock?.isHeld == true }

    var isCommitting: Bool { commitPhase != nil }

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
            pullRequestRead = nil
            refreshPullRequest(force: true, on: response.currentBranch)
            async let turnRange: Void = reloadTurnReview()
            await refreshGitInfo()
            await loadBranches()
            await turnRange
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
            async let turnRange: Void = action == .pull ? reloadTurnReview() : ()
            await loadBranches()
            await refreshGitInfo()
            await turnRange
            if action == .push { refreshPullRequest(force: true) }
            return !isRetired && response.ok != false
        } catch {
            guard !isRetired else { return false }
            actionErrorMessage = friendlyMessage(for: error)
            if git?.isHermes == true { await refreshAfterExternalMutation() }
            return false
        }
    }

    private func remoteCall(_ action: GitRemoteAction) -> (() async throws -> GitRemoteActionResponse)? {
        guard let git else { return nil }
        switch action {
        case .push: return { try await git.push() }
        case .fetch: return supportsSync ? { try await git.fetch() } : nil
        case .pull: return supportsSync ? { try await git.pull() } : nil
        }
    }

    @MainActor
    func quickCommit(push: Bool, onPhase: ((GitCommitPhase) -> Void)? = nil) async -> GitQuickCommitOutcome {
        guard let git, commitPhase == nil else { return .failure }

        let filesToStage = (status?.trackedFiles ?? []).filter {
            ($0.path ?? $0.workspacePath)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard !filesToStage.isEmpty else { return .nothingToCommit }

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
            if didPush { refreshPullRequest(force: true) }

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

    @MainActor
    func refreshAfterExternalMutation() async {
        let gate = supportsSync ? nil : git
        async let sync = gate?.supportsSync()
        await refreshGitInfo()
        if let open = await sync { supportsSync = open }
        guard let git, hasRepository else { return }
        refreshPullRequest(force: true)
        if let refreshed = try? await git.status() {
            status = refreshed
            statusError = nil
        }
        await loadBranches()
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    static let pullRequestFreshness: TimeInterval = 60

    private var pullRequestRead: (branch: String, pullRequest: GitPullRequest?)?
    private var pullRequestFreshUntil: Date?
    private var pullRequestTask: Task<Void, Never>?
    private var pullRequestGeneration = 0
    private var arePullRequestReadsSuspended = false

    var pullRequest: GitPullRequest? {
        guard let pullRequestRead, pullRequestRead.branch == currentBranchName else { return nil }
        return pullRequestRead.pullRequest
    }

    @MainActor @discardableResult
    func refreshPullRequest(force: Bool = false, on branch: String? = nil) -> Task<Void, Never>? {
        guard let git, hasRepository, !isRetired, !arePullRequestReadsSuspended else { return nil }
        if !force {
            if let pullRequestTask { return pullRequestTask }
            if let pullRequestFreshUntil, Date() < pullRequestFreshUntil { return nil }
        }
        pullRequestTask?.cancel()
        pullRequestGeneration += 1
        let generation = pullRequestGeneration
        let branch = branch ?? currentBranchName
        let task = Task { @MainActor [weak self] in
            let pullRequest = try? await git.pullRequest()
            guard let self, generation == pullRequestGeneration else { return }
            pullRequestTask = nil
            pullRequestRead = (branch, pullRequest)
            pullRequestFreshUntil = Date().addingTimeInterval(Self.pullRequestFreshness)
        }
        pullRequestTask = task
        return task
    }

    @MainActor func suspendPullRequestReads() {
        arePullRequestReadsSuspended = true
        pullRequestFreshUntil = nil
        guard let pullRequestTask else { return }
        pullRequestTask.cancel()
        self.pullRequestTask = nil
        pullRequestGeneration += 1
    }

    @MainActor func resumePullRequestReads() {
        arePullRequestReadsSuspended = false
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
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        gitWriteFriendlyMessage(for: error)
    }
}

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

    var systemImage: String {
        switch self {
        case .fetch: "arrow.triangle.2.circlepath.circle"
        case .pull: "arrow.down.circle"
        case .push: "arrow.up.circle"
        }
    }
}

enum GitCheckoutOutcome: Equatable {
    case success
    case requiresStash
    case failure
    case retired
}

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

    var systemImage: String {
        switch self {
        case .generatingMessage, .committing: "smallcircle.filled.circle"
        case .pushing: "arrow.up.circle"
        }
    }

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
    var pushFailureMessage: String? = nil
}

enum GitQuickCommitOutcome: Equatable {
    case success(GitQuickCommitResult)
    case nothingToCommit
    case tooManyChanges
    case failure
    case retired
}

struct GitWriteAvailability: Equatable {
    let isStreaming: Bool
    let isViewingCachedData: Bool
    var hidesSync = false

    var writesDisabled: Bool { isStreaming || isViewingCachedData }
    var fetchDisabled: Bool { isViewingCachedData }
}

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

    var branchSummary: String? {
        guard hasRepository, let branch = info?.branch ?? status?.branch, !branch.isEmpty else { return nil }
        let ahead = info?.ahead ?? status?.ahead ?? 0
        let behind = info?.behind ?? status?.behind ?? 0
        return ahead > 0 || behind > 0 ? "\(branch)  ↑\(ahead) ↓\(behind)" : branch
    }
}

enum GitCommitOperation: Equatable {
    case staging
    case unstaging
    case discarding
    case committing
    case suggesting
}

@MainActor
@Observable
final class GitCommitViewModel {
    private let git: (any GitDataClient)?

    private(set) var status: GitStatus?
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?
    private(set) var lastError: Error?

    private(set) var selectedPaths: Set<String> = []

    var message: String = ""
    private(set) var messageWasTruncated = false
    private(set) var busyOperation: GitCommitOperation?
    private(set) var actionErrorMessage: String?
    private(set) var lastCommitSHA: String?
    private(set) var committedRevision = 0
    private var lastSuggestion: String?

    init(git: (any GitDataClient)?) {
        self.git = git
    }

    convenience init(session: SessionSummary, server: URL, apiClient: APIClient? = nil) {
        self.init(git: WebUIGitClient(session: session, apiClient: apiClient ?? APIClient(baseURL: server)))
    }

    var shownCommitSHA: String? { git?.isHermes == true ? lastCommitSHA : nil }

    var trackedFiles: [GitFile] { status?.trackedFiles ?? [] }
    var stagedFiles: [GitFile] { trackedFiles.filter { $0.staged == true } }
    var hasChanges: Bool { !trackedFiles.isEmpty }
    var hasStagedChanges: Bool { !stagedFiles.isEmpty }
    var hasSelection: Bool { !selectedPaths.isEmpty }
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

    func discardSelectedOrAll(deleteUntracked: Bool) async {
        let targets = targetFiles
        await mutate(.discarding, files: targets) { git, files in
            try await git.discard(files, deleteUntracked: deleteUntracked)
        }
        if actionErrorMessage == nil { selectedPaths.subtract(targets.map(\.id)) }
    }

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

    func commit(push: Bool) async -> Bool {
        await runCommit(push: push) { git, message in try await git.commit(message: message, only: nil) }
    }

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
            let restoreWarning = response.stagingNotRestored
                ? String(localized: "Committed, but some files couldn’t be staged again.") : nil
            actionErrorMessage = restoreWarning
            if push {
                do {
                    let pushResponse = try await git.push()
                    status = pushResponse.status ?? status
                } catch {
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
