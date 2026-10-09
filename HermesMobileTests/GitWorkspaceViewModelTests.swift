import XCTest
import SwiftUI
@testable import HermesMobile

/// View-model behaviour + diff parsing for the workspace-git feature (issue #312, Slice A).
final class GitWorkspaceViewModelTests: APIClientTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    private func session(id: String) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id": "\#(id)", "title": "T", "workspace": "/tmp/\#(id)"}"#.utf8)
        )
    }

    private static let statusWithIgnored = """
    {
      "git": {
        "is_git": true, "branch": "main",
        "totals": {"changed": 1},
        "files": [
          {"path": "a.swift", "status": "M", "unstaged": true, "additions": 3, "deletions": 1, "ignored": false},
          {"path": ".DS_Store", "status": "Ignored", "ignored": true, "additions": 0, "deletions": 0}
        ],
        "truncated": false
      }
    }
    """

    // MARK: - Loading

    @MainActor
    func testLoadExcludesIgnoredFilesFromCountsAndTotals() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(Self.statusWithIgnored, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertFalse(viewModel.isNonRepository)
        let status = try XCTUnwrap(viewModel.status)
        XCTAssertEqual(status.files?.count, 2)
        XCTAssertEqual(status.trackedFiles.count, 1)
        XCTAssertEqual(status.changedCount, 1)
        XCTAssertEqual(status.totalAdditions, 3)
        XCTAssertEqual(status.totalDeletions, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testRefreshReplacesStaleData() async throws {
        var dirty = true
        let client = makeClient { request in
            let json = dirty ? Self.statusWithIgnored : #"{"git": {"is_git": true, "branch": "main", "files": [], "totals": {"changed": 0}}}"#
            return apiTestJSONResponse(json, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()
        XCTAssertEqual(viewModel.status?.trackedFiles.count, 1)

        dirty = false
        await viewModel.load()
        XCTAssertEqual(viewModel.status?.trackedFiles.count, 0, "Refreshing replaces, not appends.")
        XCTAssertEqual(viewModel.status?.changedCount, 0)
    }

    @MainActor
    func testDifferentSessionsHaveIndependentState() async throws {
        // One handler that answers per session_id; two view models, each scoped to its session.
        let client = makeClient { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let sessionID = components?.queryItems?.first { $0.name == "session_id" }?.value
            let branch = sessionID == "s1" ? "main" : "feature/x"
            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "\#(branch)", "files": []}}"#, for: request)
        }

        let vm1 = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        let vm2 = GitWorkspaceViewModel(session: try session(id: "s2"), server: URL(string: "https://example.test")!, apiClient: client)

        await vm1.load()
        await vm2.load()

        XCTAssertEqual(vm1.status?.branch, "main")
        XCTAssertEqual(vm2.status?.branch, "feature/x")
    }

    @MainActor
    func testLoadIfNeededLoadsOnlyOnce() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testLoadIfNeededRetriesAfterTransientFailure() async throws {
        var shouldFail = true
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            if shouldFail {
                shouldFail = false
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }

            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(requestCount, 1)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.status?.branch, "main")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testNonRepositoryWorkspaceSetsEmptyState() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"git": {"is_git": false}}"#, for: request)
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.isNonRepository)
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testLoadSurfacesErrorOnHTTPFailure() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error": "boom"}"#.utf8))
        }
        let viewModel = GitWorkspaceViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertNil(viewModel.status)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    // MARK: - Toolbar availability

    @MainActor
    func testAvailabilityShowsOnlyWhenGitInfoConfirmsRepository() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/git-info" {
                return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main"}}"#, for: request)
            }
            if request.url?.path == "/api/git/status" {
                return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/git/branches")
            return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main"}}"#, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        XCTAssertFalse(viewModel.hasRepository)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertEqual(viewModel.status?.changedCount, 0)
        XCTAssertNil(viewModel.lastError)
    }

    func testToolbarPresentationEnablesChangesAfterStatusFailure() {
        let failed = GitToolbarPresentation(
            hasRepository: true,
            isLoading: false,
            info: nil,
            status: nil,
            statusFailed: true
        )
        let loading = GitToolbarPresentation(
            hasRepository: true,
            isLoading: true,
            info: nil,
            status: nil,
            statusFailed: true
        )

        XCTAssertTrue(failed.changesAreEnabled, "The status sheet provides the manual retry path.")
        XCTAssertFalse(loading.changesAreEnabled)
    }

    /// The read-only menu's branch row: the branch alone when it matches its upstream, with the
    /// Changes header's "↑ahead ↓behind" when it has moved, and none outside a repository.
    func testToolbarBranchSummaryShowsTheBranchAndItsDistanceFromUpstream() {
        func summary(_ info: GitInfo?, hasRepository: Bool = true) -> String? {
            GitToolbarPresentation(hasRepository: hasRepository, isLoading: false, info: info, status: nil,
                                   statusFailed: false).branchSummary
        }
        let info = { (ahead: Int, behind: Int) in
            GitInfo(branch: "main", dirty: 0, modified: 0, untracked: 0, ahead: ahead, behind: behind, isGit: true)
        }

        XCTAssertEqual(summary(info(0, 0)), "main")
        XCTAssertEqual(summary(info(0, 3)), "main  ↑0 ↓3")
        XCTAssertNil(summary(info(1, 0), hasRepository: false))
        XCTAssertNil(summary(nil))
    }

    @MainActor
    func testAvailabilityHidesForNonRepositoryAndNullGitInfo() async throws {
        var returnsNullGit = false
        let client = makeClient { request in
            let json = returnsNullGit ? #"{"git": null}"# : #"{"git": {"is_git": false}}"#
            return apiTestJSONResponse(json, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()
        XCTAssertFalse(viewModel.hasRepository)

        returnsNullGit = true
        await viewModel.load()
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityHidesOnHTTPFailure() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error": "boom"}"#.utf8))
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityLoadIfNeededRetriesAfterTransientFailure() async throws {
        var shouldFail = true
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            if shouldFail {
                shouldFail = false
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }

            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main"}}"#, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertFalse(viewModel.hasRepository)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(requestCount, 1)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 4, "Successful availability also loads menu status and branches.")
        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testAvailabilityLoadIfNeededRetriesAfterTransientStatusFailure() async throws {
        var statusShouldFail = true
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            if request.url?.path == "/api/git-info" {
                return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main"}}"#, for: request)
            }
            if statusShouldFail {
                statusShouldFail = false
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error": "boom"}"#.utf8))
            }
            return apiTestJSONResponse(#"{"git": {"is_git": true, "branch": "main", "files": []}}"#, for: request)
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)

        await viewModel.loadIfNeeded()
        XCTAssertTrue(viewModel.hasRepository)
        XCTAssertNil(viewModel.status)
        XCTAssertNotNil(viewModel.statusError)

        await viewModel.loadIfNeeded()

        XCTAssertEqual(requestCount, 5)
        XCTAssertEqual(viewModel.status?.changedCount, 0)
        XCTAssertNil(viewModel.statusError)
    }

    @MainActor
    func testAvailabilityLoadsBranchesAndCheckoutRefreshesSharedState() async throws {
        // Stateful mock: the server reflects the new current branch on every read after a
        // checkout, so the post-checkout branch reload sees "feature", not stale "main".
        var currentBranch = "main"
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"\#(currentBranch)"}}"#, for: request)
            case "/api/git/status":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"\#(currentBranch)","files":[]}}"#, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"\#(currentBranch)","local":[{"name":"main"},{"name":"feature"}],"remote":[]}}"#, for: request)
            case "/api/git/checkout":
                currentBranch = "feature"
                return apiTestJSONResponse(#"{"ok":true,"current_branch":"feature","status":{"is_git":true,"branch":"feature"},"branches":{"is_git":true,"current":"feature","local":[{"name":"main"},{"name":"feature"}]}}"#, for: request)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(
            session: try session(id: "s1"),
            server: URL(string: "https://example.test")!,
            apiClient: client
        )

        await viewModel.load()
        XCTAssertEqual(viewModel.branches?.local?.compactMap(\.name), ["main", "feature"])

        let outcome = await viewModel.checkout(GitCheckoutTarget(ref: "feature", mode: .local))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(viewModel.currentBranchName, "feature")
        XCTAssertEqual(viewModel.status?.branch, "feature")
    }

    @MainActor
    func testCheckoutDirtyWorktreeRequestsStashConfirmation() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main"}}"#, for: request)
            case "/api/git/status":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main"}}"#, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main"}}"#, for: request)
            case "/api/git/checkout":
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"Checkout blocked","code":"dirty_worktree"}"#.utf8))
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(
            session: try session(id: "s1"),
            server: URL(string: "https://example.test")!,
            apiClient: client
        )
        await viewModel.load()

        let outcome = await viewModel.checkout(GitCheckoutTarget(ref: "feature", mode: .local))

        XCTAssertEqual(outcome, .requiresStash)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testStashCheckoutSurfacesRestoreFailureOnSuccess() async throws {
        var currentBranch = "main"
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"\#(currentBranch)"}}"#, for: request)
            case "/api/git/status":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"\#(currentBranch)"}}"#, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"\#(currentBranch)","local":[{"name":"main"},{"name":"feature"}]}}"#, for: request)
            case "/api/git/stash-checkout":
                currentBranch = "feature"
                return apiTestJSONResponse(#"{"ok":true,"current_branch":"feature","status":{"is_git":true,"branch":"feature"},"branches":{"is_git":true,"current":"feature","local":[{"name":"main"},{"name":"feature"}]},"restore_failed":true,"restore_error":"CONFLICT: stash could not be restored"}"#, for: request)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = GitWorkspaceAvailabilityViewModel(
            session: try session(id: "s1"),
            server: URL(string: "https://example.test")!,
            apiClient: client
        )
        await viewModel.load()

        let outcome = await viewModel.checkout(
            GitCheckoutTarget(ref: "feature", mode: .local),
            stashingChanges: true
        )

        // The branch switch itself succeeded, so the outcome stays .success...
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(viewModel.currentBranchName, "feature")
        // ...but the restore failure must surface so the UI can alert the user that
        // their stashed changes were not re-applied.
        XCTAssertEqual(viewModel.actionErrorMessage, "CONFLICT: stash could not be restored")
    }

    func testWriteAvailabilityDisablesWritesDuringStreamAndCachedMode() {
        XCTAssertFalse(GitWriteAvailability(isStreaming: false, isViewingCachedData: false).writesDisabled)
        XCTAssertTrue(GitWriteAvailability(isStreaming: true, isViewingCachedData: false).writesDisabled)
        XCTAssertTrue(GitWriteAvailability(isStreaming: false, isViewingCachedData: true).writesDisabled)
        XCTAssertFalse(GitWriteAvailability(isStreaming: true, isViewingCachedData: false).fetchDisabled)
        XCTAssertTrue(GitWriteAvailability(isStreaming: false, isViewingCachedData: true).fetchDisabled)
    }

    // MARK: - Hermes repository (#1114)

    /// Changes rows come from `review/list` (counts, status letter, staged) joined by path with
    /// `status.files`' flags, which the host lists in its own order. The badge reads the branch,
    /// ahead/behind and dirty count from the status, and a Hermes chat has writes and branches
    /// but no fetch or pull.
    @MainActor
    func testHermesChangesJoinReviewRowsWithStatusFlagsByPath() async throws {
        let git = HermesGitHost.client { request in
            HermesGitHost.repositoryReply(request, branch: "feature/x", ahead: 2, behind: 1, rows: [
                ("README.md", 1, 1, "M", false), ("Sources/Both.swift", 4, 2, "M", true),
                ("Sources/New.swift", 5, 0, "A", true), ("conflict.txt", 0, 0, "U", false), ("notes.txt", 3, 0, "?", false)
            ], flags: [
                ("notes.txt", false, true, true, false), ("conflict.txt", false, false, false, true),
                ("Sources/New.swift", true, false, false, false), ("Sources/Both.swift", true, true, false, false),
                ("README.md", false, true, false, false)
            ])
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        let changes = GitWorkspaceViewModel(git: git)

        await availability.load()
        await changes.load()

        XCTAssertTrue(availability.hasRepository)
        XCTAssertTrue(availability.supportsWrites)
        XCTAssertTrue(availability.supportsBranches)
        XCTAssertFalse(availability.supportsSync)
        XCTAssertEqual(availability.currentBranchName, "feature/x")
        XCTAssertEqual(availability.gitInfo?.ahead, 2)
        XCTAssertEqual(availability.gitInfo?.behind, 1)
        XCTAssertEqual(availability.gitInfo?.dirty, 5)
        let presentation = GitToolbarPresentation(hasRepository: true, isLoading: false, info: availability.gitInfo,
                                                  status: availability.status, statusFailed: false)
        XCTAssertEqual(presentation.accessibilityValue, String(localized: "Local changes exist and remote branch moved ahead"))
        XCTAssertEqual(presentation.branchSummary, "feature/x  ↑2 ↓1")
        let files = try XCTUnwrap(changes.status?.trackedFiles)
        XCTAssertEqual(files.map(\.displayPath), ["README.md", "Sources/Both.swift", "Sources/New.swift", "conflict.txt", "notes.txt"])
        XCTAssertEqual(files.map(\.changeKind), [.modified, .modified, .added, .conflict, .untracked])
        XCTAssertEqual(files.map(\.preferredDiffKind), ["unstaged", "unstaged", "staged", "unstaged", "unstaged"])
        XCTAssertEqual(files.map { $0.additions ?? -1 }, [1, 4, 5, 0, 3])
        XCTAssertEqual(changes.status?.changedCount, 5)
        XCTAssertEqual(changes.status?.branch, "feature/x")
    }

    /// The host caps `status.files` at 200 but lists every change in `review/list`, so a change
    /// past the cap is still a row, and the list isn't marked truncated. Such a row takes untracked
    /// and conflicted from its status letter. Whether a staged one also has worktree edits is
    /// unknown, so it opens its whole change against HEAD, never only the staged half.
    @MainActor
    func testHermesRowsPastTheStatusCapStayListedWithTheirWholeChange() async throws {
        let capped = (0..<200).map { String(format: "f%03d.txt", $0) }
        let wholeChange = "diff --git a/both.swift b/both.swift\n@@ -1 +1,2 @@\n-old\n+staged\n+worktree\n"
        let git = HermesGitHost.client { request in
            if request.url?.path == "/api/git/file-diff" { return .json(200, .object(["diff": .string(wholeChange)])) }
            return HermesGitHost.repositoryReply(request,
                rows: capped.map { ($0, 1, 0, "M", false) } + [("both.swift", 2, 1, "M", true), ("conflict.txt", 4, 0, "U", false),
                                                               ("notes.txt", 2, 0, "?", false)],
                flags: capped.map { ($0, false, true, false, false) } + [("both.swift", true, true, false, false),
                                                                         ("conflict.txt", false, false, false, true),
                                                                         ("notes.txt", false, true, true, false)])
        }
        let changes = GitWorkspaceViewModel(git: git)

        await changes.load()

        let status = try XCTUnwrap(changes.status)
        XCTAssertEqual(status.trackedFiles.count, 203)
        XCTAssertEqual(status.changedCount, 203)
        XCTAssertEqual(status.truncated, false)
        let pastCap = Array(status.trackedFiles.suffix(3))
        XCTAssertEqual(pastCap.map(\.displayPath), ["both.swift", "conflict.txt", "notes.txt"])
        XCTAssertEqual(pastCap.map(\.changeKind), [.modified, .conflict, .untracked])
        XCTAssertEqual(pastCap.map(\.conflict), [false, true, false])
        XCTAssertEqual(pastCap.map(\.untracked), [false, false, true])

        let diff = try await git.diff(for: pastCap[0])

        XCTAssertEqual(HermesGitHost.requests.last.map(HermesGitHost.describe),
                       "/api/git/file-diff path=\(HermesGitHost.repository) file=both.swift")
        XCTAssertEqual(DiffHunk.parse(diff?.diff ?? "").map(\.additions), [2])
    }

    /// Before the first commit `file-diff` (`git diff HEAD`) is empty, so a staged new file past
    /// the cap shows its current content as all additions, worktree edits included, as webui shows
    /// an untracked file; a binary one reads as binary.
    @MainActor
    func testAHermesStagedFileBeforeTheFirstCommitShowsItsCurrentContent() async throws {
        let capped = (0..<200).map { String(format: "f%03d.txt", $0) }
        let git = HermesGitHost.client { request in
            switch request.url?.path {
            case "/api/git/file-diff":
                return .json(200, .object(["diff": .string("")]))
            case "/api/fs/read-text":
                let binary = HermesGitHost.query(request, "path")?.hasSuffix(".png") == true
                return .json(200, .object(["binary": .bool(binary), "byteSize": .number(16), "truncated": .bool(false),
                                           "text": .string(binary ? "\u{FFFD}PNG" : "staged\nworktree\n")]))
            default:
                return HermesGitHost.repositoryReply(request,
                    rows: capped.map { ($0, 1, 0, "A", true) } + [("New.swift", 2, 0, "A", true), ("logo.png", 0, 0, "A", true)],
                    flags: capped.map { ($0, true, false, false, false) } + [("New.swift", true, true, false, false),
                                                                            ("logo.png", true, false, false, false)])
            }
        }
        let changes = GitWorkspaceViewModel(git: git)
        await changes.load()
        let pastCap = Array(try XCTUnwrap(changes.status).trackedFiles.suffix(2))

        let diff = try await git.diff(for: pastCap[0])

        XCTAssertEqual(HermesHostFixture.requests.suffix(2).map(HermesGitHost.describe), [
            "/api/git/file-diff path=\(HermesGitHost.repository) file=New.swift",
            "/api/fs/read-text path=\(HermesGitHost.repository)/New.swift"
        ])
        XCTAssertEqual(DiffHunk.parse(diff?.diff ?? "").map(\.additions), [2])
        XCTAssertTrue(diff?.diff?.contains("+worktree\n") == true)
        XCTAssertEqual(diff?.binary, false)

        let image = try await git.diff(for: pastCap[1])

        XCTAssertEqual(image?.binary, true)
    }

    /// Hermes tools name files relative to the chat's folder or absolutely, while rows are relative
    /// to the repository root. From `Sources`, the turn's `App.swift` is `Sources/App.swift`, not
    /// the root's `App.swift`, and an absolute path picks its own row, so the card opens that diff.
    @MainActor
    func testAHermesTurnCardFindsSubfolderFilesByTheirRepositoryPath() async throws {
        let git = HermesGitHost.client(cwd: HermesGitHost.repository + "/Sources") { request in
            HermesGitHost.repositoryReply(request, rows: [("App.swift", 9, 9, "M", false), ("Sources/App.swift", 3, 1, "M", false),
                                                          ("Sources/Model.swift", 2, 0, "M", false)],
                                          flags: [("App.swift", false, true, false, false),
                                                  ("Sources/App.swift", false, true, false, false),
                                                  ("Sources/Model.swift", false, true, false, false)])
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()

        let summary = TurnFileChangeAggregator.summarize(toolCalls: [
            ToolCall(name: "write_file", preview: nil, args: ["path": .string("App.swift")]),
            ToolCall(name: "patch", preview: nil, args: ["path": .string("./App.swift")]),
            ToolCall(name: "patch", preview: nil, args: ["path": .string(HermesGitHost.repository + "/Sources/Model.swift")])
        ], status: availability.status, rowPath: git.rowPath(forToolPath:))
        let diff = try await git.diff(for: try XCTUnwrap(summary.diffFiles.first))

        XCTAssertEqual(summary.changes.map(\.path), ["Sources/App.swift", "Sources/Model.swift"])
        XCTAssertEqual(summary.changes.map(\.additions), [3, 2])
        XCTAssertEqual(summary.diffFiles.map(\.displayPath), ["Sources/App.swift", "Sources/Model.swift"])
        XCTAssertEqual(HermesGitHost.requests.last.map { HermesGitHost.query($0, "file") }, "Sources/App.swift")
        XCTAssertEqual(diff?.diff, HermesGitHost.diffText(for: "Sources/App.swift"))
    }

    /// A tool path is anchored to the chat's folder and its dot segments collapsed, as the host
    /// resolves it, so `../README.md` from `Sources` is the root's README, not `Sources/README.md`.
    @MainActor
    func testAHermesTurnCardFollowsDotSegmentsFromTheChatsFolder() async throws {
        let git = HermesGitHost.client(cwd: HermesGitHost.repository + "/Sources") { request in
            HermesGitHost.repositoryReply(request, rows: [("README.md", 4, 0, "M", false), ("Sources/Model.swift", 2, 0, "M", false),
                                                          ("Sources/README.md", 1, 0, "M", false)],
                                          flags: [("README.md", false, true, false, false),
                                                  ("Sources/Model.swift", false, true, false, false),
                                                  ("Sources/README.md", false, true, false, false)])
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()

        let summary = TurnFileChangeAggregator.summarize(toolCalls: [
            ToolCall(name: "write_file", preview: nil, args: ["path": .string("../README.md")]),
            ToolCall(name: "patch", preview: nil, args: ["path": .string("Nested/../Model.swift")])
        ], status: availability.status, rowPath: git.rowPath(forToolPath:))
        _ = try await git.diff(for: try XCTUnwrap(summary.diffFiles.first))

        XCTAssertEqual(summary.changes.map(\.path), ["README.md", "Sources/Model.swift"])
        XCTAssertEqual(summary.changes.map(\.additions), [4, 2])
        XCTAssertEqual(HermesGitHost.requests.last.map { HermesGitHost.query($0, "file") }, "README.md")
    }

    /// The host resolves symlinks in the root it returns (`/private/tmp/app` on a Mac) but keeps
    /// the folder as configured (`/tmp/app/Sources`). The folder still maps into the root, so the
    /// turn's `App.swift` is `Sources/App.swift`, not the root's `App.swift`.
    @MainActor
    func testAHermesTurnCardMapsAFolderSpelledThroughASymlink() async throws {
        let root = "/private/tmp/app"
        let git = HermesGitHost.client(cwd: "/tmp/app/Sources") { request in
            HermesGitHost.repositoryReply(request, root: root,
                                          rows: [("App.swift", 9, 9, "M", false), ("Sources/App.swift", 3, 1, "M", false),
                                                 ("Sources/Model.swift", 2, 0, "M", false)],
                                          flags: [("App.swift", false, true, false, false),
                                                  ("Sources/App.swift", false, true, false, false),
                                                  ("Sources/Model.swift", false, true, false, false)])
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()

        let summary = TurnFileChangeAggregator.summarize(toolCalls: [
            ToolCall(name: "write_file", preview: nil, args: ["path": .string("App.swift")]),
            ToolCall(name: "patch", preview: nil, args: ["path": .string("/tmp/app/Sources/Model.swift")])
        ], status: availability.status, rowPath: git.rowPath(forToolPath:))
        _ = try await git.diff(for: try XCTUnwrap(summary.diffFiles.first))

        XCTAssertEqual(summary.changes.map(\.path), ["Sources/App.swift", "Sources/Model.swift"])
        XCTAssertEqual(summary.changes.map(\.additions), [3, 2])
        XCTAssertEqual(HermesGitHost.requests.last.map(HermesGitHost.describe),
                       "/api/git/review/diff path=\(root) file=Sources/App.swift scope=uncommitted staged=false")
    }

    /// A folder outside a repository hides Git without asking for its status, and the Changes
    /// sheet shows its non-repository state. A repository the agent then creates shows at turn end.
    @MainActor
    func testAHermesFolderOutsideARepositoryHidesGitUntilOneAppears() async throws {
        var root: String?
        let git = HermesGitHost.client { request in
            HermesGitHost.repositoryReply(request, root: root, rows: [("a.txt", 1, 0, "?", false)],
                                          flags: [("a.txt", false, true, true, false)])
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        let changes = GitWorkspaceViewModel(git: git)

        await availability.load()
        await changes.load()

        XCTAssertFalse(availability.hasRepository)
        XCTAssertTrue(changes.isNonRepository)
        XCTAssertEqual(HermesGitHost.requests.filter { $0.url?.path.hasPrefix("/api/git/") == true }.count, 0)

        HermesHostFixture.script { root = HermesGitHost.repository }
        await availability.refreshAfterExternalMutation()

        XCTAssertTrue(availability.hasRepository)
        XCTAssertEqual(availability.status?.trackedFiles.map(\.displayPath), ["a.txt"])
    }

    /// Each folder's client resolves its own root, once: a refresh reuses it, and a chat moved to
    /// another folder (which gets a new client) asks again and reads the new repository.
    @MainActor
    func testEachHermesFolderResolvesItsOwnRootOnce() async throws {
        let other = "/Users/agent/projects/other"
        let script: (URLRequest) -> HermesHostFixture.Reply? = { request in
            let path = HermesGitHost.query(request, "path") ?? ""
            let inOther = path.hasPrefix(other)
            return HermesGitHost.repositoryReply(request, root: inOther ? other : HermesGitHost.repository,
                                                 branch: inOther ? "other-main" : "main")
        }
        let first = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!,
            git: HermesGitHost.client(cwd: HermesGitHost.repository + "/Sources", script)
        )
        await first.load()
        await first.refreshAfterExternalMutation()
        let moved = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!,
            git: HermesGitHost.client(cwd: other, script)
        )
        await moved.load()

        let roots = HermesGitHost.requests.filter { $0.url?.path == "/api/fs/git-root" }
        XCTAssertEqual(roots.map { HermesGitHost.query($0, "path") }, [HermesGitHost.repository + "/Sources", other])
        let statusPaths = Set(HermesGitHost.requests.filter { $0.url?.path == "/api/git/status" }.map { HermesGitHost.query($0, "path") })
        XCTAssertEqual(statusPaths, [HermesGitHost.repository, other])
        XCTAssertEqual(first.currentBranchName, "main")
        XCTAssertEqual(moved.currentBranchName, "other-main")
    }

    // MARK: - Diff parsing

    func testDiffParserDropsPreambleAndClassifiesLines() {
        let raw = """
        diff --git a/App.swift b/App.swift
        index 1234567..89abcde 100644
        --- a/App.swift
        +++ b/App.swift
        @@ -1,3 +1,3 @@
         context line
        -removed line
        +added line
        """
        let hunks = DiffHunk.parse(raw)

        XCTAssertEqual(hunks.count, 1)
        let hunk = try! XCTUnwrap(hunks.first)
        XCTAssertEqual(hunk.header, "@@ -1,3 +1,3 @@")
        XCTAssertEqual(hunk.lines.count, 3)
        XCTAssertEqual(hunk.lines[0].kind, .context)
        XCTAssertEqual(hunk.lines[1].kind, .deletion)
        XCTAssertEqual(hunk.lines[2].kind, .addition)
        XCTAssertEqual(hunk.lines[2].text, "+added line")
    }

    func testDiffParserHandlesMultipleHunks() {
        let raw = """
        @@ -1,1 +1,1 @@
        -a
        +b
        @@ -10,2 +10,3 @@
         keep
        +new
        """
        let hunks = DiffHunk.parse(raw)

        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].id, 0)
        XCTAssertEqual(hunks[1].id, 1)
        XCTAssertEqual(hunks[1].header, "@@ -10,2 +10,3 @@")
        XCTAssertEqual(hunks[1].lines.map(\.kind), [.context, .addition])
        XCTAssertEqual(hunks[1].displayLabel, "Lines 10-12")
        XCTAssertEqual(hunks[1].lines[0].newLineNumber, 10)
        XCTAssertEqual(hunks[1].lines[1].newLineNumber, 11)
    }

    func testDiffParserCreatesSyntheticPatchWithoutHunkHeader() {
        let hunks = DiffHunk.parse("--- a/a.txt\n+++ b/a.txt\n-old\n+new")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertTrue(hunks[0].isSynthetic)
        XCTAssertEqual(hunks[0].displayLabel, "Patch 1 of 1")
        XCTAssertEqual(hunks[0].additions, 1)
        XCTAssertEqual(hunks[0].deletions, 1)
    }

    func testSyntheticDiffParserKeepsChangedLinesBeginningWithHeaderLikePrefixes() {
        let hunks = DiffHunk.parse("--- a/a.txt\n+++ b/a.txt\n---actual content\n+++actual content")

        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].lines.map(\.text), ["---actual content", "+++actual content"])
        XCTAssertEqual(hunks[0].lines.map(\.kind), [.deletion, .addition])
    }

    func testDiffParserNumbersMultipleSyntheticPatches() {
        let hunks = DiffHunk.parse("diff --git a/a b/a\n-a\n+b\ndiff --git a/b b/b\n-c\n+d")

        XCTAssertEqual(hunks.map(\.displayLabel), ["Patch 1 of 2", "Patch 2 of 2"])
    }

    func testDiffParserEmptyInputReturnsNoHunks() {
        XCTAssertTrue(DiffHunk.parse("").isEmpty)
        XCTAssertTrue(DiffHunk.parse("diff --git a/x b/x\nindex 1..2\n").isEmpty, "No hunk header → nothing to show.")
    }

    @MainActor
    func testToastProgressSuccessAndAutoDismiss() async {
        let state = GitActionToastState()
        state.showProgress(GitActionProgress(title: "Working", detailLines: ["• Fetching"]))
        XCTAssertNotNil(state.progress)
        XCTAssertNil(state.success)

        state.showSuccess(GitActionSuccess(title: "Done"), autoDismissAfter: .milliseconds(10))
        XCTAssertNil(state.progress)
        XCTAssertNotNil(state.success)

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(state.success)
    }

    @MainActor
    func testToastRapidReplacementDoesNotDismissLatestSuccess() async {
        let state = GitActionToastState()
        state.showSuccess(GitActionSuccess(title: "First"), autoDismissAfter: .milliseconds(5))
        state.showSuccess(GitActionSuccess(title: "Second"), autoDismissAfter: .seconds(1))

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.success?.title, "Second")
        state.dismissSuccess()
    }

    @MainActor
    func testToastAnimationSnapsUnderReduceMotion() {
        XCTAssertNil(GitActionToastState.toastAnimation(reduceMotion: true))
        XCTAssertEqual(
            GitActionToastState.toastAnimation(reduceMotion: false),
            .easeInOut(duration: 0.18)
        )
    }

    // MARK: - Quick commit pipeline (issue #315, Slice C)

    /// Status with a single committable file, used to seed the availability/commit VMs.
    private static let statusWithOneFile = """
    {"git":{"is_git":true,"branch":"main","totals":{"changed":1},"files":[
      {"path":"a.swift","status":"M","unstaged":true,"additions":3,"deletions":1}
    ]}}
    """

    /// Status flagged `truncated` (server capped the list at 500 changed files). Reports a
    /// non-empty list so `hasCommittableChanges` is true and only the truncation blocks the commit.
    private static let truncatedStatus = """
    {"git":{"is_git":true,"branch":"main","totals":{"changed":501},"truncated":true,"files":[
      {"path":"a.swift","status":"M","unstaged":true,"additions":3,"deletions":1}
    ]}}
    """

    private func commitPipelineClient(
        stageStatus: Int = 200,
        pushStatus: Int = 200,
        truncated: Bool = false,
        record: ((String) -> Void)? = nil
    ) -> APIClient {
        makeClient { request in
            let path = request.url?.path ?? ""
            record?(path)
            switch path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main","dirty":1}}"#, for: request)
            case "/api/git/status":
                return apiTestJSONResponse(truncated ? Self.truncatedStatus : Self.statusWithOneFile, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main","local":[],"remote":[]}}"#, for: request)
            case "/api/git/stage":
                if stageStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: stageStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main","totals":{"staged":1}}}"#, for: request)
            case "/api/git/commit-message":
                return apiTestJSONResponse(#"{"ok":true,"message":"Generated message","truncated":false}"#, for: request)
            case "/api/git/commit":
                return apiTestJSONResponse(#"{"ok":true,"commit":"abc1234","status":{"is_git":true,"branch":"main","totals":{"changed":0},"files":[]}}"#, for: request)
            case "/api/git/push":
                if pushStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: pushStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Remote rejected the push","code":"push_failed"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"message":"pushed","status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
    }

    @MainActor
    func testQuickCommitWithPushRunsFullPipelineAndReportsPhases() async throws {
        var phases: [GitCommitPhase] = []
        var paths: [String] = []
        let client = commitPipelineClient { paths.append($0) }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertTrue(vm.hasCommittableChanges)

        let outcome = await vm.quickCommit(push: true) { phases.append($0) }

        guard case .success(let result) = outcome else { return XCTFail("Expected success, got \(outcome)") }
        XCTAssertEqual(result.shortSHA, "abc1234")
        XCTAssertTrue(result.didPush)
        XCTAssertFalse(result.truncatedMessage)
        XCTAssertEqual(phases, [.generatingMessage, .committing, .pushing])
        XCTAssertNil(vm.commitPhase, "Phase resets after the pipeline finishes.")
        XCTAssertTrue(paths.contains("/api/git/stage"))
        XCTAssertTrue(paths.contains("/api/git/push"))
        XCTAssertEqual(vm.status?.changedCount, 0, "Status refreshes to the post-commit state.")
    }

    @MainActor
    func testQuickCommitWithoutPushSkipsPushCall() async throws {
        var paths: [String] = []
        let client = commitPipelineClient { paths.append($0) }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        let outcome = await vm.quickCommit(push: false)

        guard case .success(let result) = outcome else { return XCTFail("Expected success, got \(outcome)") }
        XCTAssertFalse(result.didPush)
        XCTAssertFalse(paths.contains("/api/git/push"), "push must not run for a plain Commit.")
    }

    @MainActor
    func testQuickCommitReportsSuccessWhenCommitSucceedsButPushFails() async throws {
        var paths: [String] = []
        let client = commitPipelineClient(pushStatus: 500) { paths.append($0) }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        let outcome = await vm.quickCommit(push: true)

        // The commit already landed, so a push failure must NOT collapse to .failure:
        // the SHA is reported, the push error is surfaced, and the badge/status refresh runs.
        guard case .success(let result) = outcome else { return XCTFail("Expected success, got \(outcome)") }
        XCTAssertEqual(result.shortSHA, "abc1234")
        XCTAssertFalse(result.didPush, "Push failed, so didPush stays false.")
        XCTAssertNotNil(result.pushFailureMessage, "The push failure is surfaced to the caller.")
        XCTAssertNotNil(vm.actionErrorMessage)
        XCTAssertNil(vm.commitPhase, "Phase resets even when push fails.")
        XCTAssertTrue(paths.contains("/api/git/push"), "push was attempted.")
        XCTAssertTrue(paths.filter { $0 == "/api/git-info" }.count >= 2, "refreshGitInfo runs after a push failure (load + post-commit).")
        XCTAssertEqual(vm.status?.changedCount, 0, "Status reflects the post-commit state.")
    }

    @MainActor
    func testQuickCommitReturnsNothingToCommitWhenClean() async throws {
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            if path == "/api/git-info" { return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main"}}"#, for: request) }
            if path == "/api/git/branches" { return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main"}}"#, for: request) }
            return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main","files":[],"totals":{"changed":0}}}"#, for: request)
        }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        let outcome = await vm.quickCommit(push: true)
        XCTAssertEqual(outcome, .nothingToCommit)
        XCTAssertNil(vm.commitPhase)
    }

    @MainActor
    func testQuickCommitBlocksWhenStatusTruncated() async throws {
        // >500 changed files → server truncates the status list, so the client only knows the
        // first 500. Quick-commit must refuse (no stage/commit/push) instead of silently
        // committing a partial set. Both the plain Commit and Commit & Push rows are blocked.
        for push in [true, false] {
            var paths: [String] = []
            let client = commitPipelineClient(truncated: true) { paths.append($0) }
            let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
            await vm.load()
            XCTAssertEqual(vm.status?.truncated, true)
            XCTAssertTrue(vm.hasCommittableChanges)

            paths.removeAll()
            let outcome = await vm.quickCommit(push: push)

            XCTAssertEqual(outcome, .tooManyChanges, "push=\(push)")
            XCTAssertNil(vm.commitPhase, "Phase resets after the blocked commit (push=\(push)).")
            XCTAssertNotNil(vm.actionErrorMessage, "A blocked message is surfaced (push=\(push)).")
            XCTAssertFalse(paths.contains("/api/git/stage"), "No staging when truncated (push=\(push)).")
            XCTAssertFalse(paths.contains("/api/git/commit"), "No commit when truncated (push=\(push)).")
            XCTAssertFalse(paths.contains("/api/git/push"), "No push when truncated (push=\(push)).")
        }
    }

    @MainActor
    func testQuickCommitFailsWithFriendlyMessageWhenWritesDisabled() async throws {
        let client = commitPipelineClient(stageStatus: 403)
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        let outcome = await vm.quickCommit(push: true)
        XCTAssertEqual(outcome, .failure)
        XCTAssertNil(vm.commitPhase)
        XCTAssertEqual(vm.actionErrorMessage?.contains("Writes disabled"), true)
    }

    @MainActor
    func testRefreshAfterExternalMutationPicksUpNewStatus() async throws {
        var changed = true
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git-info":
                return apiTestJSONResponse(#"{"git":{"is_git":true,"branch":"main"}}"#, for: request)
            case "/api/git/branches":
                return apiTestJSONResponse(#"{"branches":{"is_git":true,"current":"main"}}"#, for: request)
            default:
                let json = changed ? Self.statusWithOneFile : #"{"git":{"is_git":true,"branch":"main","files":[],"totals":{"changed":0}}}"#
                return apiTestJSONResponse(json, for: request)
            }
        }
        let vm = GitWorkspaceAvailabilityViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.status?.changedCount, 1)

        changed = false
        await vm.refreshAfterExternalMutation()

        XCTAssertEqual(vm.status?.changedCount, 0, "Refreshing after an agent turn surfaces the new working-tree state.")
    }

    // MARK: - Advanced staging sheet view model (GitCommitViewModel)

    private func commitSheetClient(
        suggestSelectedMessage: String = "selected msg",
        discardStatus: Int = 200,
        pushStatus: Int = 200
    ) -> APIClient {
        makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/git/push":
                if pushStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: pushStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Remote rejected the push","code":"push_failed"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"message":"pushed","status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/commit-message":
                return apiTestJSONResponse(#"{"ok":true,"message":"Generated message","truncated":true}"#, for: request)
            case "/api/git/commit-message-selected":
                return apiTestJSONResponse(#"{"ok":true,"message":"\#(suggestSelectedMessage)","truncated":false}"#, for: request)
            case "/api/git/commit":
                return apiTestJSONResponse(#"{"ok":true,"commit":"abc1234","status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            case "/api/git/commit-selected":
                return apiTestJSONResponse(#"{"ok":true,"commit":"deadbee","paths":["a.swift"],"status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            case "/api/git/stage":
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main"}}"#, for: request)
            case "/api/git/discard":
                if discardStatus != 200 {
                    let response = HTTPURLResponse(url: request.url!, statusCode: discardStatus, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (response, Data(#"{"error":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#.utf8))
                }
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
    }

    @MainActor
    func testCommitSheetSuggestMessagePopulatesFieldWithoutSelection() async throws {
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: commitSheetClient())
        await vm.load()
        XCTAssertTrue(vm.message.isEmpty)

        await vm.suggestMessage()

        XCTAssertEqual(vm.message, "Generated message")
        XCTAssertTrue(vm.messageWasTruncated, "The large-diff flag is surfaced.")
    }

    @MainActor
    func testCommitSheetSuggestUsesSelectedEndpointWhenFilesSelected() async throws {
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: commitSheetClient())
        await vm.load()
        let file = try XCTUnwrap(vm.trackedFiles.first)
        vm.toggleSelection(file)
        XCTAssertTrue(vm.hasSelection)

        await vm.suggestMessage()

        XCTAssertEqual(vm.message, "selected msg")
        XCTAssertFalse(vm.messageWasTruncated)
    }

    /// Commit-message generation runs the Agent, so it hits the stale-runtime 409 (#955).
    @MainActor
    func testCommitSheetSuggestShowsRestartCopyForStaleAgentRuntime() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/commit-message":
                return apiTestJSONResponse(
                    #"{"error": "Hermes Agent was updated while Hermes WebUI was running. Restart Hermes WebUI manually before retrying this action.", "type": "agent_runtime_stale", "retryable": true, "restart_scheduled": false}"#,
                    for: request,
                    status: 409
                )
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()

        await vm.suggestMessage()

        XCTAssertEqual(vm.actionErrorMessage, "Hermes was updated on your server. Restart Hermes WebUI there, then try again.")
        XCTAssertTrue(vm.message.isEmpty)
    }

    @MainActor
    func testCommitSheetCommitClearsMessageAndBumpsRevision() async throws {
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: commitSheetClient())
        await vm.load()
        vm.message = "Real commit"

        let ok = await vm.commit(push: false)

        XCTAssertTrue(ok)
        XCTAssertEqual(vm.lastCommitSHA, "abc1234")
        XCTAssertEqual(vm.committedRevision, 1)
        XCTAssertTrue(vm.message.isEmpty, "The message field clears after a successful commit.")
    }

    @MainActor
    func testCommitSheetCommitSucceedsAndClearsStateEvenWhenPushFails() async throws {
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: commitSheetClient(pushStatus: 500))
        await vm.load()
        vm.message = "Real commit"

        let ok = await vm.commit(push: true)

        // Commit landed; a push failure must still run the success cleanup so the caller
        // (GitCommitView) calls onCommitted() and the toolbar refreshes — while the sheet
        // banner reports that only the push failed.
        XCTAssertTrue(ok, "A push failure after a successful commit still returns true.")
        XCTAssertEqual(vm.lastCommitSHA, "abc1234")
        XCTAssertEqual(vm.committedRevision, 1, "committedRevision still bumps so the toolbar refreshes.")
        XCTAssertTrue(vm.message.isEmpty, "The message field clears after the commit lands.")
        let banner = try XCTUnwrap(vm.actionErrorMessage, "The push failure is surfaced in the sheet banner.")
        XCTAssertTrue(banner.contains("push failed"), "The banner reads as a partial success, not a failed commit.")
        XCTAssertTrue(banner.contains("Remote rejected the push"), "The server's push error detail is preserved.")
    }

    @MainActor
    func testCommitSheetCommitRequiresNonEmptyMessage() async throws {
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: commitSheetClient())
        await vm.load()

        let ok = await vm.commit(push: false)

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.committedRevision, 0)
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    @MainActor
    func testCommitSheetCommitSelectedCommitsChosenPaths() async throws {
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: commitSheetClient())
        await vm.load()
        let file = try XCTUnwrap(vm.trackedFiles.first)
        vm.toggleSelection(file)
        vm.message = "Partial"

        let ok = await vm.commitSelected(push: false)

        XCTAssertTrue(ok)
        XCTAssertEqual(vm.lastCommitSHA, "deadbee")
        XCTAssertFalse(vm.hasSelection, "Selection clears after committing it.")
    }

    @MainActor
    func testCommitSheetDiscardSurfacesFriendlyErrorWhenDisabled() async throws {
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: commitSheetClient(discardStatus: 403))
        await vm.load()

        await vm.discardSelectedOrAll(deleteUntracked: false)

        XCTAssertEqual(vm.actionErrorMessage?.contains("Writes disabled"), true)
    }

    @MainActor
    func testCommitSheetDiscardUnstagesStagedFilesFirst() async throws {
        // The server's discard only restores the worktree, leaving the index intact, so a
        // staged change would survive. The sheet must unstage staged targets before
        // discarding (and in that order) for the discard to actually take effect.
        var calls: [String] = []
        let stagedStatus = """
        {"git":{"is_git":true,"branch":"main","totals":{"changed":1},"files":[
          {"path":"a.swift","status":"M","staged":true,"additions":3,"deletions":1}
        ]}}
        """
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/git/status":
                return apiTestJSONResponse(stagedStatus, for: request)
            case "/api/git/unstage", "/api/git/discard":
                calls.append(path)
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.trackedFiles.first?.staged, true)

        await vm.discardSelectedOrAll(deleteUntracked: false)

        XCTAssertNil(vm.actionErrorMessage)
        XCTAssertEqual(calls, ["/api/git/unstage", "/api/git/discard"],
                       "Staged targets are unstaged before discard so the index is reverted too.")
    }

    @MainActor
    func testCommitSheetDiscardSkipsUnstageWhenNoStagedTargets() async throws {
        // A purely unstaged change needs no unstage step — discard alone reverts the worktree.
        var calls: [String] = []
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/git/status":
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/unstage", "/api/git/discard":
                calls.append(path)
                return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let vm = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await vm.load()
        XCTAssertEqual(vm.trackedFiles.first?.unstaged, true)

        await vm.discardSelectedOrAll(deleteUntracked: false)

        XCTAssertEqual(calls, ["/api/git/discard"], "No staged targets means no unstage call.")
    }
}

// MARK: - Hermes writes (#1115)

extension GitWorkspaceViewModelTests {
    /// Push names the repository root. The host would skip a detached HEAD without a word, so
    /// one is refused with webui's copy and never sent; the status is read again either way.
    @MainActor
    func testAHermesPushSendsTheRootAndRefusesADetachedHead() async throws {
        nonisolated(unsafe) var detached = false
        let git = HermesGitHost.client { request in
            HermesGitHost.repositoryReply(request, detached: detached, ahead: 1, rows: [("a.swift", 1, 0, "M", false)],
                                          flags: [("a.swift", false, true, false, false)])
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()

        let pushed = await availability.performRemoteAction(.push)
        HermesHostFixture.script { detached = true }
        let statusReads = HermesGitHost.requests.filter { $0.url?.path == "/api/git/status" }.count
        let refused = await availability.performRemoteAction(.push)

        XCTAssertTrue(availability.supportsWrites)
        XCTAssertTrue(pushed)
        XCTAssertFalse(refused)
        XCTAssertEqual(availability.actionErrorMessage, String(localized: "Cannot push from a detached HEAD"))
        let pushes = HermesGitHost.requests.filter { $0.url?.path == "/api/git/review/push" }
        XCTAssertEqual(pushes.map(HermesCronFixture.body), [.object(["path": .string(HermesGitHost.repository)])])
        XCTAssertGreaterThan(HermesGitHost.requests.filter { $0.url?.path == "/api/git/status" }.count, statusReads + 1,
                             "The refusal reads the head, then the status again")
    }

    /// A Hermes repository's commit sheet on the host `script` answers, its messages written by
    /// `writeMessage`.
    @MainActor
    private func hermesCommitSheet(
        writeMessage: HermesGitClient.MessageWriter? = nil,
        _ script: @escaping (URLRequest) -> HermesHostFixture.Reply?
    ) async -> GitCommitViewModel {
        let sheet = GitCommitViewModel(git: HermesGitHost.client(writeMessage: writeMessage, script))
        await sheet.load()
        return sheet
    }

    /// One edited, one staged and one untracked file, as the host lists them.
    private static func threeChanges(_ request: URLRequest, conflicted: Bool = false) -> HermesHostFixture.Reply? {
        HermesGitHost.repositoryReply(request, rows: [
            ("a.swift", 1, 0, "M", false), ("b.swift", 2, 1, "M", true), ("c.txt", 1, 0, conflicted ? "U" : "?", false)
        ], flags: [
            ("a.swift", false, true, false, false), ("b.swift", true, false, false, false),
            ("c.txt", false, !conflicted, !conflicted, conflicted)
        ])
    }

    /// Stage, unstage and discard act on the selection, or everything, one file per request,
    /// and the list is read at each write, for the rows it acts on, and again after it.
    @MainActor
    func testTheHermesSheetStagesUnstagesAndDiscardsTheSelectionAndRefreshes() async throws {
        let sheet = await hermesCommitSheet { Self.threeChanges($0) }
        let files = sheet.trackedFiles

        sheet.toggleSelection(files[0])
        await sheet.stageSelectedOrAll()
        let listReads = HermesGitHost.requests.filter { $0.url?.path == "/api/git/review/list" }.count
        sheet.clearSelection()
        await sheet.unstageSelectedOrAll()
        sheet.toggleSelection(files[2])
        await sheet.discardSelectedOrAll(deleteUntracked: true)

        XCTAssertNil(sheet.actionErrorMessage)
        XCTAssertEqual(HermesGitHost.writes, ["stage a.swift", "unstage b.swift", "revert c.txt"])
        XCTAssertEqual(listReads, 3, "The load, then the reads at staging and after it")
        XCTAssertEqual(HermesGitHost.requests.filter { $0.url?.path == "/api/git/review/list" }.count, 7)
        XCTAssertFalse(sheet.hasSelection, "A discarded file leaves the selection")
    }

    /// Staging a conflicted file would mark it resolved, and webui refuses to discard or commit
    /// one, so none of them is sent.
    @MainActor
    func testAHermesConflictRefusesStageDiscardAndCommit() async throws {
        let sheet = await hermesCommitSheet { Self.threeChanges($0, conflicted: true) }
        var refusals: [String?] = []

        await sheet.stageSelectedOrAll()
        refusals.append(sheet.actionErrorMessage)
        await sheet.discardSelectedOrAll(deleteUntracked: true)
        refusals.append(sheet.actionErrorMessage)
        sheet.message = "fix: keep it"
        let committed = await sheet.commit(push: false)
        refusals.append(sheet.actionErrorMessage)

        XCTAssertFalse(committed)
        XCTAssertEqual(refusals, [String(localized: "Conflicted files cannot be staged from this panel"),
                                  String(localized: "Conflicted files cannot be discarded from this panel"),
                                  String(localized: "Resolve conflicts before committing")])
        XCTAssertEqual(HermesGitHost.writes, [])
    }

    /// The host stages everything for a commit with nothing staged, so one is refused; with
    /// something staged it commits, never pushing in the same call, and shows HEAD's short sha.
    @MainActor
    func testAHermesCommitNeedsSomethingStagedAndShowsItsSha() async throws {
        nonisolated(unsafe) var staged = false
        let sheet = await hermesCommitSheet { request in
            HermesGitHost.repositoryReply(request, rows: [("a.swift", 1, 0, "M", staged)],
                                          flags: [("a.swift", staged, !staged, false, false)])
        }
        sheet.message = "fix(app): keep the row"

        let refused = await sheet.commit(push: false)
        let refusal = sheet.actionErrorMessage
        HermesHostFixture.script { staged = true }
        let committed = await sheet.commit(push: false)

        XCTAssertFalse(refused)
        XCTAssertEqual(refusal, String(localized: "Stage changes before committing"))
        XCTAssertTrue(committed)
        XCTAssertEqual(sheet.lastCommitSHA, "abc1234")
        XCTAssertEqual(sheet.shownCommitSHA, "abc1234")
        XCTAssertEqual(HermesGitHost.writes, [#"commit "fix(app): keep the row""#])
    }

    /// The host commits the whole index, so Commit Selected unstages everything, stages the
    /// selection, checks something is staged, commits, then stages the other staged files again.
    @MainActor
    func testAHermesCommitSelectedKeepsTheOtherStagedFilesStaged() async throws {
        let sheet = await hermesCommitSheet { Self.threeChanges($0) }
        sheet.toggleSelection(sheet.trackedFiles[0])
        sheet.message = "feat(app): add a"

        let committed = await sheet.commitSelected(push: false)

        XCTAssertTrue(committed)
        XCTAssertEqual(HermesGitHost.writes, ["unstage (all)", "stage a.swift", #"commit "feat(app): add a""#, "stage b.swift"])
        XCTAssertEqual(sheet.lastCommitSHA, "abc1234")
        XCTAssertFalse(sheet.hasSelection)
    }

    /// A commit that fails partway puts the staged files back as they were, says so without
    /// git's output, and reads the status again.
    @MainActor
    func testAHermesCommitSelectedRestoresTheStagedFilesWhenTheCommitFails() async throws {
        let sheet = await hermesCommitSheet { request in
            request.url?.path == "/api/git/review/commit"
                ? .json(400, .object(["detail": .string("hook failed")])) : Self.threeChanges(request)
        }
        sheet.toggleSelection(sheet.trackedFiles[0])
        sheet.message = "feat(app): add a"
        let statusReads = HermesGitHost.requests.filter { $0.url?.path == "/api/git/review/list" }.count

        let committed = await sheet.commitSelected(push: false)

        XCTAssertFalse(committed)
        XCTAssertEqual(HermesGitHost.writes, ["unstage (all)", "stage a.swift", #"commit "feat(app): add a""#,
                                              "unstage (all)", "stage b.swift"])
        XCTAssertEqual(sheet.actionErrorMessage, String(localized: "Git couldn’t finish this change on your Hermes host."))
        XCTAssertEqual(sheet.message, "feat(app): add a", "The message stays for a retry")
        XCTAssertEqual(HermesGitHost.requests.filter { $0.url?.path == "/api/git/review/list" }.count, statusReads + 2,
                       "The remembered staged files, then the status after the failure")
    }

    /// Suggest sends `commit-context`'s diff and recent subjects, or the selected files' whole
    /// changes; Regenerate also sends the last suggestion to avoid.
    @MainActor
    func testAHermesSuggestionSendsWhatWouldCommitAndAvoidsTheLastOne() async throws {
        nonisolated(unsafe) var asked: [(diff: String, recent: String, avoid: String?)] = []
        let sheet = await hermesCommitSheet(writeMessage: { diff, recent, avoid in
            asked.append((diff, recent, avoid))
            return "  feat(app): message \(asked.count)\n"
        }) { Self.threeChanges($0) }

        await sheet.suggestMessage()
        let first = sheet.message
        await sheet.suggestMessage()
        sheet.toggleSelection(sheet.trackedFiles[0])
        sheet.toggleSelection(sheet.trackedFiles[2])
        await sheet.suggestMessage()

        XCTAssertEqual(first, "feat(app): message 1")
        XCTAssertEqual(sheet.message, "feat(app): message 3")
        XCTAssertEqual(asked.map(\.diff), [HermesGitHost.contextDiff, HermesGitHost.contextDiff,
                                           HermesGitHost.diffText(for: "a.swift") + HermesGitHost.diffText(for: "c.txt")])
        XCTAssertEqual(asked.map(\.recent), Array(repeating: HermesGitHost.recentSubjects, count: 3))
        XCTAssertEqual(asked.map(\.avoid), [nil, "feat(app): message 1", "feat(app): message 2"])
        XCTAssertFalse(sheet.messageWasTruncated)
    }

    /// One tap on a Hermes repository stages every change a file at a time, writes a message for
    /// it, commits and reports the sha.
    @MainActor
    func testAHermesQuickCommitStagesEachFileThenCommits() async throws {
        let git = HermesGitHost.client(writeMessage: { _, _, _ in "chore: tidy" }) { Self.threeChanges($0) }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()

        let outcome = await availability.quickCommit(push: false)

        guard case .success(let result) = outcome else { return XCTFail("Expected success, got \(outcome)") }
        XCTAssertEqual(result.shortSHA, "abc1234")
        XCTAssertEqual(result.message, "chore: tidy")
        XCTAssertEqual(HermesGitHost.writes, ["stage a.swift", "stage c.txt", #"commit "chore: tidy""#])
    }

    // MARK: Review fixes

    /// One edited file and one staged file that `stagedAlso` describes: also edited in the
    /// worktree (`true`), or past the status cap, where that is unknown (`nil`).
    private static func partlyStaged(_ request: URLRequest, stagedAlso unstaged: Bool?) -> HermesHostFixture.Reply? {
        HermesGitHost.repositoryReply(request, rows: [("a.swift", 1, 0, "M", false), ("b.swift", 2, 1, "M", true)],
                                      flags: [("a.swift", false, true, false, false)]
                                          + (unstaged.map { [("b.swift", true, $0, false, false)] } ?? []))
    }

    /// `git add` can put back only a whole file, so Commit Selected is refused before it changes
    /// the index while a staged file outside the selection also has worktree edits, or may have
    /// (past the status cap): restoring it would stage those too.
    @MainActor
    func testAHermesCommitSelectedRefusesAPartlyStagedFileBeforeAnythingIsSent() async throws {
        for unstaged in [true, nil] as [Bool?] {
            HermesHostFixture.reset()
            let sheet = await hermesCommitSheet { Self.partlyStaged($0, stagedAlso: unstaged) }
            sheet.toggleSelection(sheet.trackedFiles[0])
            sheet.message = "feat(app): add a"

            let committed = await sheet.commitSelected(push: false)

            XCTAssertFalse(committed)
            XCTAssertEqual(sheet.actionErrorMessage, String(localized:
                "Fully stage or fully unstage partly staged or renamed files before committing selected files"), "\(String(describing: unstaged))")
            XCTAssertEqual(HermesGitHost.writes, [], "\(String(describing: unstaged))")
        }
    }

    /// Before the first commit the host can't unstage everything, so Commit Selected is refused
    /// up front, and the index stays as it was.
    @MainActor
    func testAHermesCommitSelectedBeforeTheFirstCommitIsRefusedUpFront() async throws {
        let sheet = await hermesCommitSheet { request in
            HermesGitHost.repositoryReply(request, unborn: true, rows: [("a.swift", 1, 0, "A", true), ("b.swift", 1, 0, "A", true)],
                                          flags: [("a.swift", true, false, false, false), ("b.swift", true, false, false, false)])
        }
        sheet.toggleSelection(sheet.trackedFiles[0])
        sheet.message = "feat(app): start"

        let committed = await sheet.commitSelected(push: false)

        XCTAssertFalse(committed)
        XCTAssertEqual(sheet.actionErrorMessage, String(localized: "Make the first commit with Commit, then commit selected files"))
        XCTAssertEqual(HermesGitHost.writes, [])
    }

    /// The three changes' reply, except a 400 for `route`, or only for its requests naming `file`.
    private static func failing(_ request: URLRequest, route: String, file: String? = nil) -> HermesHostFixture.Reply? {
        let body = apiTestBodyData(from: request).flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) }
        let fails = request.url?.path == route && (file == nil || body?["file"].text == ":(literal)" + (file ?? ""))
        return fails ? .json(400, .object(["detail": .string("index.lock exists")])) : threeChanges(request)
    }

    /// A Commit Selected whose commit lands but which can't stage the other staged files again
    /// keeps the commit and its sha, and says the staging wasn't put back.
    @MainActor
    func testAHermesCommitSelectedSaysWhenItCouldNotStageTheOtherFilesAgain() async throws {
        let sheet = await hermesCommitSheet { request in
            Self.failing(request, route: "/api/git/review/stage", file: "b.swift")
        }
        sheet.toggleSelection(sheet.trackedFiles[0])
        sheet.message = "feat(app): add a"

        let committed = await sheet.commitSelected(push: false)

        XCTAssertTrue(committed)
        XCTAssertEqual(sheet.lastCommitSHA, "abc1234")
        XCTAssertEqual(sheet.actionErrorMessage, String(localized: "Committed, but some files couldn’t be staged again."))
        XCTAssertEqual(HermesGitHost.writes, ["unstage (all)", "stage a.swift", #"commit "feat(app): add a""#, "stage b.swift"])
    }

    /// A Commit Selected that fails before its commit, and then can't stage the files again
    /// either, says both, not only that the commit failed.
    @MainActor
    func testAHermesCommitSelectedSaysWhenItCouldNotPutTheStagedFilesBack() async throws {
        let sheet = await hermesCommitSheet { request in
            request.url?.path == "/api/git/review/commit"
                ? .json(400, .object(["detail": .string("hook failed")]))
                : Self.failing(request, route: "/api/git/review/stage", file: "b.swift")
        }
        sheet.toggleSelection(sheet.trackedFiles[0])
        sheet.message = "feat(app): add a"

        let committed = await sheet.commitSelected(push: false)

        XCTAssertFalse(committed)
        XCTAssertEqual(sheet.actionErrorMessage,
                       String(localized: "Git couldn’t finish this change, and the staged files couldn’t be restored."))
        XCTAssertEqual(HermesGitHost.writes, ["unstage (all)", "stage a.swift", #"commit "feat(app): add a""#,
                                              "unstage (all)", "stage b.swift"])
    }

    /// A quick commit whose turn starts while its message is being written stops before the
    /// commit: the chat's turn owns the repository now.
    @MainActor
    func testAHermesQuickCommitStopsWhenATurnStartsDuringItsMessage() async throws {
        let chat = HermesGitChatStub()
        let git = HermesGitHost.client(writeMessage: { _, _, _ in
            chat.turnRunning = true
            return "chore: tidy"
        }, writeOwner: chat.owner) { Self.threeChanges($0) }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()

        let outcome = await availability.quickCommit(push: true)

        XCTAssertEqual(outcome, .failure)
        XCTAssertEqual(availability.actionErrorMessage,
                       String(localized: "Wait for the active response to finish before changing this repository."))
        XCTAssertEqual(HermesGitHost.writes, ["stage a.swift", "stage c.txt"])
    }

    // MARK: Review fixes, round 2

    /// Commit Selected clears the whole index and promises to put back every staged file, so each
    /// one it remembers must name one file. The host trims a tracked file's name, so ` a.txt` and
    /// `a.txt` both list as `a.txt`: staging that path again couldn't reach both, and the
    /// sequence is refused before it changes anything.
    @MainActor
    func testAHermesCommitSelectedRefusesStagedFilesItCouldNotPutBack() async throws {
        let sheet = await hermesCommitSheet { request in
            HermesGitHost.repositoryReply(request, rows: [
                ("a.txt", 1, 0, "M", true), ("a.txt", 1, 0, "M", true), ("c.txt", 1, 0, "M", false)
            ], flags: [("a.txt", true, false, false, false), ("c.txt", false, true, false, false)])
        }
        sheet.toggleSelection(try XCTUnwrap(sheet.trackedFiles.first { $0.path == "c.txt" }))
        sheet.message = "feat(app): add c"

        let committed = await sheet.commitSelected(push: false)

        XCTAssertFalse(committed)
        XCTAssertEqual(sheet.actionErrorMessage, String(localized: "Git couldn’t finish this change on your Hermes host."))
        XCTAssertEqual(HermesGitHost.writes, [])
    }

    /// A Commit Selected whose first reset reaches the host but whose reply is lost may have
    /// cleared the index: it puts the staged files back before it reports the failure.
    @MainActor
    func testAHermesCommitSelectedPutsTheStagedFilesBackWhenTheResetsReplyIsLost() async throws {
        nonisolated(unsafe) var bStaged = true
        nonisolated(unsafe) var resets = 0
        let sheet = await hermesCommitSheet { request in
            let body = HermesCronFixture.body(request)
            switch (request.url?.path, body["file"].text) {
            case ("/api/git/review/unstage", nil):
                resets += 1
                bStaged = false
                return resets == 1 ? .fail(URLError(.networkConnectionLost)) : .json(200, .object(["ok": .bool(true)]))
            case ("/api/git/review/stage", ":(literal)b.swift"):
                bStaged = true
                return .json(200, .object(["ok": .bool(true)]))
            default:
                return HermesGitHost.repositoryReply(request, rows: [("a.swift", 1, 0, "M", false), ("b.swift", 2, 1, "M", bStaged)],
                                                     flags: [("a.swift", false, true, false, false), ("b.swift", bStaged, !bStaged, false, false)])
            }
        }
        sheet.toggleSelection(sheet.trackedFiles[0])
        sheet.message = "feat(app): add a"

        let committed = await sheet.commitSelected(push: false)

        XCTAssertFalse(committed)
        XCTAssertEqual(HermesGitHost.writes, ["unstage (all)", "unstage (all)", "stage b.swift"])
        XCTAssertTrue(bStaged, "The staged file is staged again")
        XCTAssertNotEqual(sheet.actionErrorMessage,
                          String(localized: "Git couldn’t finish this change, and the staged files couldn’t be restored."))
        XCTAssertNotNil(sheet.actionErrorMessage)
    }

    /// A quick commit still running when the chat leaves the folder (`retire()`) finishes without
    /// a result to show: no later phase, no push, and nothing for the toast.
    @MainActor
    func testAHermesQuickCommitFinishingAfterAFolderChangeShowsNothing() async throws {
        let git = HermesGitHost.client(writeMessage: { _, _, _ in "chore: tidy" }) { request in
            request.url?.path == "/api/git/review/commit" ? .park : Self.threeChanges(request)
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        HermesHostFixture.onPark = { Task { @MainActor in
            availability.retire()
            HermesHostFixture.releaseParked()
        } }
        var phases: [GitCommitPhase] = []

        let outcome = await availability.quickCommit(push: true) { phases.append($0) }

        XCTAssertEqual(outcome, .retired)
        XCTAssertEqual(phases, [.generatingMessage, .committing])
        XCTAssertNil(availability.actionErrorMessage)
        XCTAssertEqual(HermesGitHost.writes, ["stage a.swift", "stage c.txt", #"commit "chore: tidy""#])
    }

    /// A push still running when the chat leaves the folder finishes without a result to show.
    @MainActor
    func testAHermesPushFinishingAfterAFolderChangeShowsNothing() async throws {
        let git = HermesGitHost.client { request in
            request.url?.path == "/api/git/review/push" ? .park : Self.threeChanges(request)
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        HermesHostFixture.onPark = { Task { @MainActor in
            availability.retire()
            HermesHostFixture.releaseParked(.json(400, .object(["detail": .string("rejected")])))
        } }

        let pushed = await availability.performRemoteAction(.push)

        XCTAssertFalse(pushed)
        XCTAssertTrue(availability.isRetired)
        XCTAssertNil(availability.actionErrorMessage)
        XCTAssertNil(availability.lastActionMessage)
    }

    /// While a quick commit waits for its message, the commit sheet on the same repository is busy
    /// and sends nothing, so the quick commit commits what it staged.
    @MainActor
    func testTheHermesSheetWritesNothingWhileAQuickCommitWaitsForItsMessage() async throws {
        let reference = SheetReference()
        nonisolated(unsafe) var duringMessage: (busy: Bool, committed: Bool, writes: [String])?
        let git = HermesGitHost.client(writeMessage: { _, _, _ in
            if let sheet = reference.sheet {
                sheet.toggleSelection(sheet.trackedFiles[1])
                sheet.message = "feat(app): only b"
                await sheet.unstageSelectedOrAll()
                await sheet.discardSelectedOrAll(deleteUntracked: true)
                let committed = await sheet.commitSelected(push: false)
                duringMessage = (sheet.isBusy, committed, HermesGitHost.writes)
            }
            return "chore: tidy"
        }) { Self.threeChanges($0) }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        let commitSheet = GitCommitViewModel(git: git)
        await commitSheet.load()
        reference.sheet = commitSheet

        let outcome = await availability.quickCommit(push: false)

        XCTAssertEqual(duringMessage?.busy, true)
        XCTAssertEqual(duringMessage?.committed, false)
        XCTAssertEqual(duringMessage?.writes, ["stage a.swift", "stage c.txt"])
        guard case .success = outcome else { return XCTFail("Expected success, got \(outcome)") }
        XCTAssertEqual(HermesGitHost.writes, ["stage a.swift", "stage c.txt", #"commit "chore: tidy""#])
        XCTAssertFalse(commitSheet.isBusy)
    }

    /// While the commit sheet commits, the Git menu's quick commit and push are disabled and send
    /// nothing.
    @MainActor
    func testAHermesQuickCommitAndPushWaitForTheSheetsCommit() async throws {
        let git = HermesGitHost.client(writeMessage: { _, _, _ in "chore: tidy" }) { request in
            request.url?.path == "/api/git/review/commit" ? .park : Self.threeChanges(request)
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        let sheet = GitCommitViewModel(git: git)
        await sheet.load()
        sheet.message = "feat(app): b"
        nonisolated(unsafe) var duringCommit: (running: Bool, outcome: GitQuickCommitOutcome, pushed: Bool)?
        HermesHostFixture.onPark = { Task { @MainActor in
            let running = availability.isRunningGitAction
            let outcome = await availability.quickCommit(push: true)
            let pushed = await availability.performRemoteAction(.push)
            duringCommit = (running, outcome, pushed)
            HermesHostFixture.releaseParked()
        } }

        let committed = await sheet.commit(push: false)

        XCTAssertTrue(committed)
        XCTAssertEqual(duringCommit?.running, true)
        XCTAssertEqual(duringCommit?.outcome, .failure)
        XCTAssertEqual(duringCommit?.pushed, false)
        XCTAssertEqual(HermesGitHost.writes, [#"commit "feat(app): b""#])
        XCTAssertFalse(availability.isRunningGitAction)
    }

    /// Before the first commit `file-diff` is empty, so a selected new file's message is written
    /// from its current content, as its diff shows it.
    @MainActor
    func testAHermesSuggestionBeforeTheFirstCommitSendsANewFilesContent() async throws {
        nonisolated(unsafe) var asked: [String] = []
        let sheet = await hermesCommitSheet(writeMessage: { diff, _, _ in
            asked.append(diff)
            return "feat(app): add notes"
        }) { request in
            switch request.url?.path {
            case "/api/git/file-diff":
                return .json(200, .object(["diff": .string("")]))
            case "/api/fs/read-text":
                return .json(200, .object(["binary": .bool(false), "byteSize": .number(13), "truncated": .bool(false),
                                           "text": .string("first\nsecond\n")]))
            default:
                return HermesGitHost.repositoryReply(request, unborn: true, rows: [("notes.txt", 2, 0, "A", true)],
                                                     flags: [("notes.txt", true, false, false, false)])
            }
        }
        sheet.toggleSelection(sheet.trackedFiles[0])

        await sheet.suggestMessage()

        XCTAssertNil(sheet.actionErrorMessage)
        XCTAssertEqual(sheet.message, "feat(app): add notes")
        XCTAssertEqual(asked, ["diff --git a/notes.txt b/notes.txt\n--- /dev/null\n+++ b/notes.txt\n@@ -0,0 +1,2 @@\n+first\n+second\n"])
        XCTAssertEqual(HermesHostFixture.requests.last.map(HermesGitHost.describe),
                       "/api/fs/read-text path=\(HermesGitHost.repository)/notes.txt")
    }

    /// webui's writes keep their presentation (#1115): a failed one doesn't read the status
    /// again, and the sheet shows no commit sha.
    @MainActor
    func testAWebUICommitSheetKeepsItsPresentation() async throws {
        nonisolated(unsafe) var statusReads = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/git/status":
                statusReads += 1
                return apiTestJSONResponse(Self.statusWithOneFile, for: request)
            case "/api/git/stage":
                let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                return (response, Data(#"{"error":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#.utf8))
            case "/api/git/commit":
                return apiTestJSONResponse(#"{"ok":true,"commit":"abc1234","status":{"is_git":true,"branch":"main","files":[]}}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let sheet = GitCommitViewModel(session: try session(id: "s1"), server: URL(string: "https://example.test")!, apiClient: client)
        await sheet.load()

        await sheet.stageSelectedOrAll()
        let failure = sheet.actionErrorMessage
        let readsAfterTheFailure = statusReads
        sheet.message = "fix: a"
        let committed = await sheet.commit(push: false)

        XCTAssertEqual(failure?.contains("Writes disabled"), true)
        XCTAssertEqual(readsAfterTheFailure, 1, "Only the load")
        XCTAssertTrue(committed)
        XCTAssertEqual(sheet.lastCommitSHA, "abc1234")
        XCTAssertNil(sheet.shownCommitSHA)
    }
}

/// The commit sheet a test's message writer reaches, set once both exist.
@MainActor private final class SheetReference {
    var sheet: GitCommitViewModel?
}

// MARK: - Hermes branches (#1116)

extension GitWorkspaceViewModelTests {
    /// A Hermes chat on `branch` whose host lists local `main` and `dev` and the remote-only
    /// `origin/feature/x`, with no uncommitted change unless `dirty`.
    private static func branchHost(_ request: URLRequest, branch: String, dirty: Bool = false) -> HermesHostFixture.Reply? {
        HermesGitHost.repositoryReply(request, branch: branch,
                                      rows: dirty ? [("notes.txt", 1, 0, "?", false)] : [],
                                      flags: dirty ? [("notes.txt", false, true, true, false)] : [],
                                      branches: [("main", false), ("dev", false), ("origin/feature/x", true)])
    }

    /// `branchHost` with `b.swift` staged, so the commit sheet has something to commit.
    private static func stagedBranchHost(_ request: URLRequest) -> HermesHostFixture.Reply? {
        HermesGitHost.repositoryReply(request, branch: "main",
                                      rows: [("b.swift", 2, 1, "M", true)],
                                      flags: [("b.swift", true, false, false, false)],
                                      branches: [("main", false), ("dev", false)])
    }

    /// The picker lists the host's local branches, then its remote-only ones, and switches to
    /// either. A remote row goes out by its short name, which `git switch` makes a tracking
    /// branch of, once a fresh branch list shows the name is only its; the status and branches
    /// are read again after each switch.
    @MainActor
    func testAHermesSwitchSendsARemoteBranchByItsShortNameAndRefreshes() async throws {
        nonisolated(unsafe) var current = "main"
        let git = HermesGitHost.client { request in
            if request.url?.path == "/api/git/branch/switch" {
                current = HermesCronFixture.body(request)["branch"].text ?? current
                return .json(200, .object(["branch": .string(current)]))
            }
            return Self.branchHost(request, branch: current)
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        let local = availability.branches?.local?.compactMap(\.name)
        let remote = availability.branches?.remote?.compactMap(\.name)
        let branchReads = HermesGitHost.requests.filter { $0.url?.path == "/api/git/branches" }.count

        let toRemote = await availability.checkout(GitCheckoutTarget(ref: "origin/feature/x", mode: .remote, track: true))
        let remoteLabel = availability.currentBranchName
        let toLocal = await availability.checkout(GitCheckoutTarget(ref: "dev", mode: .local))

        XCTAssertTrue(availability.supportsBranches)
        XCTAssertEqual(local, ["main", "dev"])
        XCTAssertEqual(remote, ["origin/feature/x"])
        XCTAssertEqual(toRemote, .success)
        XCTAssertEqual(toLocal, .success)
        XCTAssertEqual(remoteLabel, "feature/x")
        XCTAssertEqual(availability.currentBranchName, "dev")
        XCTAssertEqual(availability.status?.branch, "dev")
        XCTAssertEqual(HermesGitHost.writes, ["switch feature/x", "switch dev"])
        XCTAssertEqual(HermesGitHost.requests.filter { $0.url?.path == "/api/git/branches" }.count, branchReads + 3)
        XCTAssertNil(availability.actionErrorMessage)
    }

    /// Any uncommitted change, an untracked file included, blocks the switch rather than let
    /// `git switch` carry it across (Decision, 2026-10-08): nothing is sent and the picker says why.
    @MainActor
    func testAHermesSwitchWithUncommittedChangesIsRefused() async throws {
        let git = HermesGitHost.client { Self.branchHost($0, branch: "main", dirty: true) }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()

        let outcome = await availability.checkout(GitCheckoutTarget(ref: "dev", mode: .local))

        XCTAssertEqual(outcome, .failure)
        XCTAssertEqual(availability.actionErrorMessage, String(localized: "Commit or discard first."))
        XCTAssertEqual(HermesGitHost.writes, [])
        XCTAssertEqual(availability.currentBranchName, "main")
    }

    /// A switch is a write the chat owns, as #1115's are: refused while its turn runs.
    @MainActor
    func testAHermesSwitchWaitsForTheRunningTurn() async throws {
        let chat = HermesGitChatStub()
        let git = HermesGitHost.client(writeOwner: chat.owner) { Self.branchHost($0, branch: "main") }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        chat.turnRunning = true

        let outcome = await availability.checkout(GitCheckoutTarget(ref: "dev", mode: .local))

        XCTAssertEqual(outcome, .failure)
        XCTAssertEqual(availability.actionErrorMessage,
                       String(localized: "Wait for the active response to finish before changing this repository."))
        XCTAssertEqual(HermesGitHost.writes, [])
    }

    /// A switch shares the repository's write lock (#1115): while the commit sheet commits, the
    /// picker is disabled and a switch sends nothing.
    @MainActor
    func testAHermesSwitchWaitsForTheSheetsCommit() async throws {
        let git = HermesGitHost.client(writeMessage: { _, _, _ in "chore: tidy" }) { request in
            request.url?.path == "/api/git/review/commit" ? .park : Self.stagedBranchHost(request)
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        let sheet = GitCommitViewModel(git: git)
        await sheet.load()
        sheet.message = "feat(app): b"
        nonisolated(unsafe) var duringCommit: (locked: Bool, outcome: GitCheckoutOutcome)?
        HermesHostFixture.onPark = { Task { @MainActor in
            let locked = availability.isWriteLocked
            let outcome = await availability.checkout(GitCheckoutTarget(ref: "dev", mode: .local))
            duringCommit = (locked, outcome)
            HermesHostFixture.releaseParked()
        } }

        let committed = await sheet.commit(push: false)

        XCTAssertTrue(committed)
        XCTAssertEqual(duringCommit?.locked, true)
        XCTAssertEqual(duringCommit?.outcome, .failure)
        XCTAssertNil(availability.actionErrorMessage)
        XCTAssertEqual(HermesGitHost.writes, [#"commit "feat(app): b""#])
        XCTAssertEqual(availability.currentBranchName, "main")
    }

    /// While a switch runs, the commit sheet is busy and the Git menu's push is refused: neither
    /// writes under it.
    @MainActor
    func testTheHermesSheetAndPushWaitForASwitch() async throws {
        // The sheet loads a staged file; the switch's own status read finds the tree clean.
        nonisolated(unsafe) var staged = true
        let git = HermesGitHost.client { request in
            if request.url?.path == "/api/git/branch/switch" { return .park }
            return staged ? Self.stagedBranchHost(request) : Self.branchHost(request, branch: "main")
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        let sheet = GitCommitViewModel(git: git)
        await sheet.load()
        sheet.message = "feat(app): b"
        HermesHostFixture.script { staged = false }
        nonisolated(unsafe) var duringSwitch: (busy: Bool, committed: Bool, pushed: Bool)?
        HermesHostFixture.onPark = { Task { @MainActor in
            let busy = sheet.isBusy
            let committed = await sheet.commit(push: false)
            let pushed = await availability.performRemoteAction(.push)
            duringSwitch = (busy, committed, pushed)
            HermesHostFixture.releaseParked(.json(200, .object(["branch": .string("dev")])))
        } }

        let outcome = await availability.checkout(GitCheckoutTarget(ref: "dev", mode: .local))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(duringSwitch?.busy, true)
        XCTAssertEqual(duringSwitch?.committed, false)
        XCTAssertEqual(duringSwitch?.pushed, false)
        XCTAssertEqual(HermesGitHost.writes, ["switch dev"])
        XCTAssertFalse(availability.isWriteLocked)
        XCTAssertFalse(sheet.isBusy)
    }

    /// A failed switch reads the repository again; if the chat leaves the folder during that
    /// read, the failure belongs to the old repository and has nothing to show (`.retired`).
    @MainActor
    func testAFailedHermesSwitchRetiredDuringItsRefreshShowsNothing() async throws {
        nonisolated(unsafe) var branchReads = 0
        let git = HermesGitHost.client { request in
            switch request.url?.path {
            case "/api/git/branch/switch":
                return .json(400, .object(["detail": .string("rejected")]))
            case "/api/git/branches":
                branchReads += 1
                return branchReads > 1 ? .park : Self.branchHost(request, branch: "main")
            default:
                return Self.branchHost(request, branch: "main")
            }
        }
        let availability = GitWorkspaceAvailabilityViewModel(
            session: SessionSummary(), server: URL(string: "https://webui.example")!, git: git
        )
        await availability.load()
        HermesHostFixture.onPark = { Task { @MainActor in
            availability.retire()
            HermesHostFixture.releaseParked()
        } }

        let outcome = await availability.checkout(GitCheckoutTarget(ref: "dev", mode: .local))

        XCTAssertEqual(branchReads, 2)
        XCTAssertEqual(outcome, .retired)
        XCTAssertEqual(HermesGitHost.writes, ["switch dev"])
    }
}
