import XCTest
@testable import HermesMobile

/// Request construction + tolerant decoding for the read-only workspace-git endpoints
/// (issue #312, Slice A). Mirrors `APIClientWorkspaceFileTests`.
final class APIClientGitTests: APIClientTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    private func query(_ request: URLRequest) throws -> [String: String?] {
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
    }

    private func errorResponse(_ json: String, status: Int, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(apiTestBodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - git-info

    func testGitInfoBuildsExpectedQueryAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git-info")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(try self.query(request)["session_id"], "abc123")

            return apiTestJSONResponse("""
            {
              "git": {
                "branch": "main",
                "dirty": 3,
                "modified": 2,
                "untracked": 1,
                "ahead": 2,
                "behind": 0,
                "is_git": true
              }
            }
            """, for: request)
        }

        let response = try await client.gitInfo(sessionID: "abc123")
        let info = try XCTUnwrap(response.git)

        XCTAssertEqual(info.branch, "main")
        XCTAssertEqual(info.dirty, 3)
        XCTAssertEqual(info.modified, 2)
        XCTAssertEqual(info.untracked, 1)
        XCTAssertEqual(info.ahead, 2)
        XCTAssertEqual(info.behind, 0)
        XCTAssertEqual(info.isGit, true)
    }

    func testGitInfoDecodesNullGitForNonRepository() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git-info")
            return apiTestJSONResponse(#"{"git": null}"#, for: request)
        }

        let response = try await client.gitInfo(sessionID: "abc123")
        XCTAssertNil(response.git)
    }

    // MARK: - git/status

    func testGitStatusBuildsExpectedQueryAndDecodesFilesAndTotals() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/status")
            XCTAssertEqual(try self.query(request)["session_id"], "abc123")

            return apiTestJSONResponse("""
            {
              "git": {
                "is_git": true,
                "branch": "feature/foo",
                "upstream": "origin/feature/foo",
                "ahead": 1,
                "behind": 2,
                "totals": {"changed": 2, "staged": 1, "unstaged": 1, "untracked": 1, "conflicts": 0},
                "files": [
                  {
                    "path": "Sources/App.swift", "old_path": null, "workspace_path": "Sources/App.swift",
                    "status": "M", "staged": false, "unstaged": true, "untracked": false,
                    "ignored": false, "conflict": false, "additions": 10, "deletions": 4, "binary": false
                  },
                  {
                    "path": "New.swift", "old_path": null, "workspace_path": "New.swift",
                    "status": "??", "staged": false, "unstaged": false, "untracked": true,
                    "ignored": false, "conflict": false, "additions": 0, "deletions": 0, "binary": false
                  },
                  {
                    "path": ".DS_Store", "old_path": null, "workspace_path": ".DS_Store",
                    "status": "Ignored", "staged": false, "unstaged": false, "untracked": false,
                    "ignored": true, "conflict": false, "additions": 0, "deletions": 0, "binary": false
                  }
                ],
                "truncated": false,
                "noise_filtering": {"enabled": true}
              }
            }
            """, for: request)
        }

        let statusResponse = try await client.gitStatus(sessionID: "abc123")
        let status = try XCTUnwrap(statusResponse.git)

        XCTAssertEqual(status.isGit, true)
        XCTAssertEqual(status.branch, "feature/foo")
        XCTAssertEqual(status.upstream, "origin/feature/foo")
        XCTAssertEqual(status.ahead, 1)
        XCTAssertEqual(status.behind, 2)
        XCTAssertEqual(status.totals?.changed, 2)
        XCTAssertEqual(status.files?.count, 3, "Raw files include the ignored entry.")

        // Ignored files are filtered from the tracked list and counts/totals.
        XCTAssertEqual(status.trackedFiles.count, 2)
        XCTAssertEqual(status.changedCount, 2)
        XCTAssertEqual(status.totalAdditions, 10)
        XCTAssertEqual(status.totalDeletions, 4)
        XCTAssertFalse(status.trackedFiles.contains { $0.ignored == true })

        // Change kind is derived from the booleans.
        XCTAssertEqual(status.trackedFiles[0].changeKind, .modified)
        XCTAssertEqual(status.trackedFiles[1].changeKind, .untracked)
        XCTAssertEqual(status.trackedFiles[0].fileName, "App.swift")
        XCTAssertEqual(status.trackedFiles[0].parentDirectory, "Sources")
    }

    func testGitStatusDecodesNonRepository() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"git": {"is_git": false}}"#, for: request)
        }

        let statusResponse = try await client.gitStatus(sessionID: "abc123")
        let status = try XCTUnwrap(statusResponse.git)
        XCTAssertEqual(status.isGit, false)
        XCTAssertTrue(status.trackedFiles.isEmpty)
        XCTAssertEqual(status.changedCount, 0)
    }

    func testGitStatusToleratesMissingFieldsAndUnknownKeys() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "git": {
                "is_git": true,
                "branch": "main",
                "files": [
                  {"path": "a.txt", "status": "A", "staged": true, "future_field": 99}
                ],
                "totally_new_key": {"nested": true}
              }
            }
            """, for: request)
        }

        let statusResponse = try await client.gitStatus(sessionID: "abc123")
        let status = try XCTUnwrap(statusResponse.git)
        XCTAssertEqual(status.branch, "main")
        XCTAssertNil(status.totals)
        XCTAssertNil(status.truncated)
        let file = try XCTUnwrap(status.files?.first)
        XCTAssertEqual(file.path, "a.txt")
        XCTAssertNil(file.additions)
        XCTAssertEqual(file.changeKind, .added)
        // Truncation defaults to "not truncated" and changedCount falls back to file count.
        XCTAssertEqual(status.changedCount, 1)
    }

    func testGitStatusFiltersIgnoredFilesByStatusString() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "git": {
                "is_git": true,
                "branch": "main",
                "files": [
                  {"path": ".DS_Store", "status": "Ignored", "additions": 0, "deletions": 0}
                ]
              }
            }
            """, for: request)
        }

        let statusResponse = try await client.gitStatus(sessionID: "abc123")
        let status = try XCTUnwrap(statusResponse.git)
        XCTAssertEqual(status.files?.count, 1)
        XCTAssertEqual(status.trackedFiles.count, 0)
        XCTAssertEqual(status.changedCount, 0)
        XCTAssertEqual(status.files?.first?.changeKind, .ignored)
    }

    func testGitStatusTruncatedFlagDecodes() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            { "git": { "is_git": true, "branch": "main", "files": [], "truncated": true,
              "totals": {"changed": 500} } }
            """, for: request)
        }

        let statusResponse = try await client.gitStatus(sessionID: "abc123")
        let status = try XCTUnwrap(statusResponse.git)
        XCTAssertEqual(status.truncated, true)
        XCTAssertEqual(status.changedCount, 500)
    }

    // MARK: - git/branches

    func testGitBranchesBuildsExpectedQueryAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/branches")
            XCTAssertEqual(try self.query(request)["session_id"], "abc123")

            return apiTestJSONResponse("""
            {
              "branches": {
                "is_git": true,
                "current": "main",
                "detached": false,
                "head": "main",
                "local": [
                  {
                    "name": "main",
                    "sha": "abc1234",
                    "updated": 1782080000,
                    "updated_relative": "2 hours ago",
                    "author": "Uzair",
                    "subject": "Latest local commit",
                    "upstream": "origin/main",
                    "ahead": 0,
                    "behind": 0
                  },
                  {
                    "name": "dev",
                    "sha": "def5678",
                    "updated": 1782070000,
                    "updated_relative": "5 hours ago",
                    "author": "Uzair",
                    "subject": "Dev branch",
                    "upstream": "",
                    "ahead": 0,
                    "behind": 0,
                    "future_field": true
                  }
                ],
                "remote": [
                  {
                    "name": "origin/main",
                    "sha": "abc1234",
                    "updated": 1782080000,
                    "updated_relative": "2 hours ago",
                    "author": "Uzair",
                    "subject": "Latest remote commit",
                    "upstream": "",
                    "ahead": 0,
                    "behind": 0
                  }
                ],
                "upstream": "origin/main",
                "ahead": 0,
                "behind": 0
              }
            }
            """, for: request)
        }

        let branchesResponse = try await client.gitBranches(sessionID: "abc123")
        let branches = try XCTUnwrap(branchesResponse.branches)
        XCTAssertEqual(branches.current, "main")
        XCTAssertEqual(branches.local?.map(\.name), ["main", "dev"])
        XCTAssertEqual(branches.local?.first?.sha, "abc1234")
        XCTAssertEqual(branches.local?.first?.updatedRelative, "2 hours ago")
        XCTAssertEqual(branches.local?.first?.upstream, "origin/main")
        XCTAssertEqual(branches.local?.first?.ahead, 0)
        XCTAssertEqual(branches.local?.first?.behind, 0)
        XCTAssertEqual(branches.remote?.map(\.name), ["origin/main"])
        XCTAssertEqual(branches.detached, false)
    }

    // MARK: - git/diff

    func testGitDiffBuildsExpectedQueryWithKindAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/diff")
            let q = try self.query(request)
            XCTAssertEqual(q["session_id"], "abc123")
            XCTAssertEqual(q["path"], "Sources/App.swift")
            XCTAssertEqual(q["kind"], "staged")

            return apiTestJSONResponse("""
            {
              "diff": {
                "path": "Sources/App.swift",
                "kind": "staged",
                "binary": false,
                "too_large": false,
                "additions": 2,
                "deletions": 1,
                "diff": "@@ -1,2 +1,3 @@\\n context\\n-old\\n+new\\n+added\\n"
              }
            }
            """, for: request)
        }

        let diffResponse = try await client.gitDiff(sessionID: "abc123", path: "Sources/App.swift", kind: "staged")
        let diff = try XCTUnwrap(diffResponse.diff)
        XCTAssertEqual(diff.path, "Sources/App.swift")
        XCTAssertEqual(diff.kind, "staged")
        XCTAssertEqual(diff.binary, false)
        XCTAssertEqual(diff.tooLarge, false)
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertTrue(diff.diff?.contains("+added") == true)
    }

    func testGitDiffDefaultsKindToUnstaged() async throws {
        let client = makeClient { request in
            XCTAssertEqual(try self.query(request)["kind"], "unstaged")
            return apiTestJSONResponse(#"{"diff": {"path": "a.txt", "kind": "unstaged", "diff": ""}}"#, for: request)
        }

        _ = try await client.gitDiff(sessionID: "abc123", path: "a.txt")
    }

    func testGitDiffDecodesBinaryAndTooLarge() async throws {
        let binaryClient = makeClient { request in
            apiTestJSONResponse("""
            {"diff": {"path": "logo.png", "kind": "unstaged", "binary": true, "too_large": false,
              "additions": 0, "deletions": 0, "diff": ""}}
            """, for: request)
        }
        let binaryResponse = try await binaryClient.gitDiff(sessionID: "abc123", path: "logo.png")
        let binary = try XCTUnwrap(binaryResponse.diff)
        XCTAssertEqual(binary.binary, true)
        XCTAssertEqual(binary.diff, "")

        let largeClient = makeClient { request in
            apiTestJSONResponse("""
            {"diff": {"path": "huge.txt", "kind": "unstaged", "binary": false, "too_large": true,
              "additions": 0, "deletions": 0, "diff": ""}}
            """, for: request)
        }
        let largeResponse = try await largeClient.gitDiff(sessionID: "abc123", path: "huge.txt")
        let large = try XCTUnwrap(largeResponse.diff)
        XCTAssertEqual(large.tooLarge, true)
    }

    func testGitDiffNonRepositorySurfacesHTTPError() async throws {
        let client = makeClient { request in
            self.errorResponse(#"{"error": "Not a git repository", "code": "git_failed"}"#, status: 400, for: request)
        }

        do {
            _ = try await client.gitDiff(sessionID: "abc123", path: "a.txt")
            XCTFail("Expected an HTTP error for a non-repo diff.")
        } catch let APIError.http(statusCode, _) {
            XCTAssertEqual(statusCode, 400)
        }
    }

    // MARK: - git writes

    func testRemoteActionsBuildExpectedRequestsAndDecodeStatus() async throws {
        let expectedPaths = ["/api/git/fetch", "/api/git/pull", "/api/git/push"]
        var receivedPaths: [String] = []
        let client = makeClient { request in
            receivedPaths.append(request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try self.jsonBody(request)["session_id"] as? String, "abc123")
            return apiTestJSONResponse(#"{"ok":true,"message":"done","status":{"is_git":true,"branch":"main"}}"#, for: request)
        }

        let responses = try await [
            client.gitFetch(sessionID: "abc123"),
            client.gitPull(sessionID: "abc123"),
            client.gitPush(sessionID: "abc123")
        ]

        XCTAssertEqual(receivedPaths, expectedPaths)
        XCTAssertTrue(responses.allSatisfy { $0.ok == true && $0.status?.branch == "main" })
    }

    func testCheckoutAndStashCheckoutBuildExpectedBodies() async throws {
        var requestIndex = 0
        let client = makeClient { request in
            let body = try self.jsonBody(request)
            XCTAssertEqual(body["session_id"] as? String, "abc123")
            XCTAssertEqual(body["ref"] as? String, "origin/feature")
            XCTAssertEqual(body["mode"] as? String, "remote")
            XCTAssertEqual(body["new_branch"] as? String, "feature")
            XCTAssertEqual(body["track"] as? Bool, true)
            if requestIndex == 0 {
                XCTAssertEqual(request.url?.path, "/api/git/checkout")
                XCTAssertEqual(body["dirty_mode"] as? String, "block")
            } else {
                XCTAssertEqual(request.url?.path, "/api/git/stash-checkout")
                XCTAssertNil(body["dirty_mode"])
            }
            requestIndex += 1
            return apiTestJSONResponse(#"{"ok":true,"current_branch":"feature","status":{"branch":"feature"},"branches":{"current":"feature"}}"#, for: request)
        }
        let target = GitCheckoutTarget(ref: "origin/feature", mode: .remote, newBranch: "feature", track: true)

        let checkout = try await client.gitCheckout(sessionID: "abc123", target: target)
        let stashCheckout = try await client.gitStashCheckout(sessionID: "abc123", target: target)

        XCTAssertEqual(checkout.currentBranch, "feature")
        XCTAssertEqual(checkout.resolvedStatus?.branch, "feature")
        XCTAssertEqual(stashCheckout.branches?.current, "feature")
    }

    func testCreateBranchSendsNewModeNotLocal() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/checkout")
            let body = try self.jsonBody(request)
            // "local" would just switch to ref and ignore new_branch; creating a branch
            // must use the server's "new" mode (issue #315 follow-up).
            XCTAssertEqual(body["mode"] as? String, "new")
            XCTAssertEqual(body["ref"] as? String, "main")
            XCTAssertEqual(body["new_branch"] as? String, "hermex/test2")
            return apiTestJSONResponse(#"{"ok":true,"current_branch":"hermex/test2","status":{"is_git":true,"branch":"hermex/test2"},"branches":{"is_git":true,"current":"hermex/test2"}}"#, for: request)
        }

        let target = GitCheckoutTarget(ref: "main", mode: .local, newBranch: "hermex/test2")
        let response = try await client.gitCheckout(sessionID: "abc123", target: target)
        XCTAssertEqual(response.currentBranch, "hermex/test2")
    }

    func testGitErrorEnvelopeExposesStructuredCodeAndMessage() async throws {
        let client = makeClient { request in
            self.errorResponse(
                #"{"error":"A session run is active","code":"active_stream"}"#,
                status: 409,
                for: request
            )
        }

        do {
            _ = try await client.gitPull(sessionID: "abc123")
            XCTFail("Expected the active-stream error.")
        } catch let error as APIError {
            XCTAssertEqual(error.serverCode, "active_stream")
            XCTAssertEqual(error.serverMessage, "A session run is active")
        }
    }

    // MARK: - Commit flow (issue #315, Slice C)

    func testStageAndUnstageBuildBodiesAndDecodeStatusUnderGitKey() async throws {
        var receivedPaths: [String] = []
        let client = makeClient { request in
            receivedPaths.append(request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try self.jsonBody(request)
            XCTAssertEqual(body["session_id"] as? String, "abc123")
            XCTAssertEqual(body["paths"] as? [String], ["Sources/App.swift", "README.md"])
            return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main","totals":{"staged":2}}}"#, for: request)
        }

        let stage = try await client.gitStage(sessionID: "abc123", paths: ["Sources/App.swift", "README.md"])
        let unstage = try await client.gitUnstage(sessionID: "abc123", paths: ["Sources/App.swift", "README.md"])

        XCTAssertEqual(receivedPaths, ["/api/git/stage", "/api/git/unstage"])
        XCTAssertEqual(stage.ok, true)
        XCTAssertEqual(stage.resolvedStatus?.branch, "main")
        XCTAssertEqual(stage.resolvedStatus?.totals?.staged, 2)
        XCTAssertEqual(unstage.resolvedStatus?.branch, "main")
    }

    func testDiscardBuildsBodyWithDeleteUntrackedFlag() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/discard")
            let body = try self.jsonBody(request)
            XCTAssertEqual(body["paths"] as? [String], ["junk.tmp"])
            XCTAssertEqual(body["delete_untracked"] as? Bool, true)
            return apiTestJSONResponse(#"{"ok":true,"git":{"is_git":true,"branch":"main"}}"#, for: request)
        }

        let response = try await client.gitDiscard(sessionID: "abc123", paths: ["junk.tmp"], deleteUntracked: true)
        XCTAssertEqual(response.resolvedStatus?.branch, "main")
    }

    func testCommitBuildsBodyAndDecodesShaAndStatusUnderStatusKey() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/commit")
            let body = try self.jsonBody(request)
            XCTAssertEqual(body["session_id"] as? String, "abc123")
            XCTAssertEqual(body["message"] as? String, "Fix the thing")
            return apiTestJSONResponse(#"{"ok":true,"commit":"a1b2c3d","status":{"is_git":true,"branch":"main","totals":{"changed":0}}}"#, for: request)
        }

        let response = try await client.gitCommit(sessionID: "abc123", message: "Fix the thing")
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.shortSHA, "a1b2c3d")
        XCTAssertEqual(response.resolvedStatus?.changedCount, 0)
    }

    func testCommitSelectedBuildsBodyWithPathsAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/git/commit-selected")
            let body = try self.jsonBody(request)
            XCTAssertEqual(body["message"] as? String, "Partial commit")
            XCTAssertEqual(body["paths"] as? [String], ["a.swift"])
            return apiTestJSONResponse(#"{"ok":true,"commit":"deadbee","paths":["a.swift"],"status":{"is_git":true,"branch":"main"}}"#, for: request)
        }

        let response = try await client.gitCommitSelected(sessionID: "abc123", message: "Partial commit", paths: ["a.swift"])
        XCTAssertEqual(response.shortSHA, "deadbee")
        XCTAssertEqual(response.paths, ["a.swift"])
        XCTAssertEqual(response.resolvedStatus?.branch, "main")
    }

    func testCommitMessageEndpointsBuildBodiesAndDecodeTruncation() async throws {
        var receivedPaths: [String] = []
        let client = makeClient { request in
            receivedPaths.append(request.url?.path ?? "")
            let body = try self.jsonBody(request)
            XCTAssertEqual(body["session_id"] as? String, "abc123")
            if request.url?.path == "/api/git/commit-message-selected" {
                XCTAssertEqual(body["paths"] as? [String], ["a.swift"])
                return apiTestJSONResponse(#"{"ok":true,"message":"selected msg","truncated":true}"#, for: request)
            }
            XCTAssertNil(body["paths"])
            return apiTestJSONResponse(#"{"ok":true,"message":"all msg","truncated":false}"#, for: request)
        }

        let all = try await client.gitCommitMessage(sessionID: "abc123")
        let selected = try await client.gitCommitMessageSelected(sessionID: "abc123", paths: ["a.swift"])

        XCTAssertEqual(receivedPaths, ["/api/git/commit-message", "/api/git/commit-message-selected"])
        XCTAssertEqual(all.message, "all msg")
        XCTAssertEqual(all.truncated, false)
        XCTAssertEqual(selected.message, "selected msg")
        XCTAssertEqual(selected.truncated, true)
    }

    func testCommitDestructiveDisabledSurfacesStructuredCode() async throws {
        let client = makeClient { request in
            self.errorResponse(
                #"{"error":"Destructive git writes are disabled","code":"destructive_git_disabled"}"#,
                status: 403,
                for: request
            )
        }

        do {
            _ = try await client.gitCommit(sessionID: "abc123", message: "msg")
            XCTFail("Expected the destructive-disabled error.")
        } catch let error as APIError {
            XCTAssertEqual(error.serverCode, "destructive_git_disabled")
        }
    }

    func testCommitMessageRequestsUseExtendedTimeout() async throws {
        let client = makeClient { request in
            XCTAssertGreaterThanOrEqual(request.timeoutInterval, 120, "LLM message generation needs a wide timeout, not the 60s default.")
            return apiTestJSONResponse(#"{"ok":true,"message":"m","truncated":false}"#, for: request)
        }

        _ = try await client.gitCommitMessage(sessionID: "abc123")
        _ = try await client.gitCommitMessageSelected(sessionID: "abc123", paths: ["a.swift"])
    }

    func testCommitEmptyMessageSurfacesBadRequest() async throws {
        let client = makeClient { request in
            self.errorResponse(#"{"error":"Commit message is required"}"#, status: 400, for: request)
        }

        do {
            _ = try await client.gitCommit(sessionID: "abc123", message: "")
            XCTFail("Expected the empty-message rejection.")
        } catch let error as APIError {
            XCTAssertEqual(error.serverMessage, "Commit message is required")
        }
    }
}

// MARK: - Hermes host (#1114)

/// `HermesGitClient` against a scripted Hermes host whose replies are the shapes
/// `hermes_cli/web_git.py` and `web_routers/files.py` answer at the pin (ca678285).
extension APIClientGitTests {
    /// A chat working in a subfolder reads the whole repository: the root is asked once, from
    /// the folder, and every read names the root, so root-relative rows address their files.
    @MainActor
    func testAHermesRepositoryIsReadAtItsRootFromASubfolder() async throws {
        let git = HermesGitHost.client(cwd: HermesGitHost.repository + "/Sources") { request in
            HermesGitHost.repositoryReply(request, rows: [("Sources/App.swift", 3, 1, "M", false)],
                                          flags: [("Sources/App.swift", false, true, false, false)])
        }

        let info = try await git.info()
        let loaded = try await git.status()
        let status = try XCTUnwrap(loaded)
        let diff = try await git.diff(for: try XCTUnwrap(status.files?.first))

        // `status()` sends its two reads at once, so they arrive in either order.
        let requests = HermesGitHost.requests.map(HermesGitHost.describe)
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.first, "/api/fs/git-root path=\(HermesGitHost.repository)/Sources")
        XCTAssertEqual(requests[1], "/api/git/status path=\(HermesGitHost.repository)")
        XCTAssertEqual(requests.dropFirst(2).prefix(2).sorted(), [
            "/api/git/review/list path=\(HermesGitHost.repository) scope=uncommitted",
            "/api/git/status path=\(HermesGitHost.repository)"
        ])
        XCTAssertEqual(requests.last,
                       "/api/git/review/diff path=\(HermesGitHost.repository) file=Sources/App.swift scope=uncommitted staged=false")
        XCTAssertEqual(info?.isGit, true)
        XCTAssertEqual(status.files?.map(\.displayPath), ["Sources/App.swift"])
        XCTAssertEqual(diff?.diff, HermesGitHost.diffText(for: "Sources/App.swift"))
    }

    /// A staged-only row asks for its staged diff, any other for its worktree diff, where the host
    /// synthesizes an all-add diff for an untracked file. A binary change and a diff past webui's
    /// 512 KiB cap read as the existing notices, not as text.
    @MainActor
    func testAHermesDiffAsksForTheRowsKindAndNamesBinaryAndOversizedChanges() async throws {
        let huge = String(repeating: "+x\n", count: 200_000)
        let git = HermesGitHost.client { request in
            guard request.url?.path == "/api/git/review/diff" else { return HermesGitHost.repositoryReply(request) }
            let text: String = switch HermesGitHost.query(request, "file") {
            case "logo.png": "diff --git a/logo.png b/logo.png\nBinary files a/logo.png and b/logo.png differ\n"
            case "huge.txt": "diff --git a/huge.txt b/huge.txt\n@@ -0,0 +1,200000 @@\n" + huge
            case let file?: HermesGitHost.diffText(for: file)
            case nil: ""
            }
            return .json(200, .object(["diff": .string(text)]))
        }
        let staged = GitFile(path: "New.swift", status: "A", staged: true, unstaged: false, untracked: false,
                             conflict: false, additions: 2, deletions: 0)
        let untracked = GitFile(path: "notes.txt", status: "?", staged: false, unstaged: true, untracked: true,
                                conflict: false, additions: 1, deletions: 0)

        let stagedDiff = try await git.diff(for: staged)
        let untrackedDiff = try await git.diff(for: untracked)
        let binary = try await git.diff(for: GitFile(path: "logo.png", status: "M", staged: false, unstaged: true,
                                                     untracked: false, conflict: false, additions: 0, deletions: 0))
        let oversized = try await git.diff(for: GitFile(path: "huge.txt", status: "?", staged: false, unstaged: true,
                                                        untracked: true, conflict: false, additions: 200_000, deletions: 0))

        let diffs = HermesGitHost.requests.filter { $0.url?.path == "/api/git/review/diff" }
        XCTAssertEqual(diffs.map { HermesGitHost.query($0, "staged") }, ["true", "false", "false", "false"])
        XCTAssertEqual(stagedDiff?.diff, HermesGitHost.diffText(for: "New.swift"))
        XCTAssertEqual(untrackedDiff?.diff, HermesGitHost.diffText(for: "notes.txt"))
        XCTAssertEqual(DiffHunk.parse(untrackedDiff?.diff ?? "").map(\.additions), [1])
        XCTAssertEqual(binary?.binary, true)
        XCTAssertEqual(oversized?.tooLarge, true)
        XCTAssertNil(oversized?.diff)
    }

    /// A failed git call is 400 `{detail}`, git's own stderr, which can name host paths: it reads
    /// as the existing repository-unavailable copy, never the detail.
    @MainActor
    func testAHermesRefusalNeverShowsGitsOutput() async throws {
        let detail = "fatal: not a git repository: '\(HermesGitHost.repository)/.git'"
        let git = HermesGitHost.client { request in
            request.url?.path == "/api/git/review/list"
                ? .json(400, .object(["detail": .string(detail)])) : HermesGitHost.repositoryReply(request)
        }

        do {
            _ = try await git.status()
            XCTFail("Expected the refusal to fail the status")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "Repository status unavailable"))
        }
    }
}

// MARK: - Hermes writes (#1115)

extension APIClientGitTests {
    /// The host's stage, unstage and revert act on the whole tree without a `file`, so each write
    /// names one file at the root. Only a file with something to do gets a request: stage skips a
    /// fully staged one, unstage an unstaged one; discard unstages a staged one before reverting it.
    @MainActor
    func testHermesWritesNameOneFileEachAtTheRoot() async throws {
        let git = HermesGitHost.client(cwd: HermesGitHost.repository + "/Sources") { request in
            HermesGitHost.repositoryReply(request, rows: [
                ("Sources/App.swift", 1, 0, "M", false), ("Sources/Staged.swift", 1, 0, "M", true), ("Both.swift", 1, 0, "M", true)
            ], flags: [("Sources/App.swift", false, true, false, false), ("Sources/Staged.swift", true, false, false, false)])
        }
        let edited = GitFile(path: "Sources/App.swift", status: "M", staged: false, unstaged: true, untracked: false,
                             conflict: false, additions: 1, deletions: 0)
        let staged = GitFile(path: "Sources/Staged.swift", status: "M", staged: true, unstaged: false, untracked: false,
                             conflict: false, additions: 1, deletions: 0)
        let pastTheCap = GitFile(path: "Both.swift", status: "M", staged: true, unstaged: nil, untracked: false,
                                 conflict: false, additions: 1, deletions: 0)

        _ = try await git.stage([edited, staged, pastTheCap])
        _ = try await git.unstage([edited, staged])
        _ = try await git.discard([edited, staged], deleteUntracked: false)

        XCTAssertEqual(HermesGitHost.writes, [
            "stage Sources/App.swift", "stage Both.swift",
            "unstage Sources/Staged.swift",
            "revert Sources/App.swift", "unstage Sources/Staged.swift", "revert Sources/Staged.swift"
        ])
    }

    /// The host's revert deletes an untracked file, and one new in the index once it is unstaged:
    /// only a confirmation that said so (`deleteUntracked`) lets those go.
    @MainActor
    func testAHermesDiscardDeletesNewFilesOnlyWhenConfirmed() async throws {
        let git = HermesGitHost.client { request in
            HermesGitHost.repositoryReply(request, rows: [("New.swift", 2, 0, "A", true), ("notes.txt", 1, 0, "?", false)],
                                          flags: [("New.swift", true, false, false, false), ("notes.txt", false, true, true, false)])
        }
        let untracked = GitFile(path: "notes.txt", status: "?", staged: false, unstaged: true, untracked: true,
                                conflict: false, additions: 1, deletions: 0)
        let added = GitFile(path: "New.swift", status: "A", staged: true, unstaged: false, untracked: false,
                            conflict: false, additions: 2, deletions: 0)

        _ = try await git.discard([untracked, added], deleteUntracked: false)
        let unconfirmed = HermesGitHost.writes
        _ = try await git.discard([untracked, added], deleteUntracked: true)

        XCTAssertEqual(unconfirmed, [])
        XCTAssertEqual(HermesGitHost.writes, ["revert notes.txt", "unstage New.swift", "revert New.swift"])
    }

    /// A refused write is 400 `{detail}` with git's stderr; it reads as the write-failure copy,
    /// never the detail.
    @MainActor
    func testAHermesWriteRefusalNeverShowsGitsOutput() async throws {
        let git = HermesGitHost.client { request in
            request.url?.path == "/api/git/review/push"
                ? .json(400, .object(["detail": .string("fatal: '\(HermesGitHost.repository)' rejected")]))
                : HermesGitHost.repositoryReply(request)
        }

        do {
            _ = try await git.push()
            XCTFail("Expected the refusal to fail the push")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "Git couldn’t finish this change on your Hermes host."))
        }
    }
}

// MARK: - Hermes write guards (#1115 review)

extension APIClientGitTests {
    /// A write names each file exactly as the host lists it, never trimmed. A blank name, which
    /// the host would read as the whole tree, is refused before anything is sent, and so is a
    /// name the host lists twice, as it does for ` a.txt` and `a.txt`: it trims the names it
    /// reports, so the write couldn't tell which one it reaches.
    @MainActor
    func testAHermesWriteRefusesAPathThatIsNotOneFile() async throws {
        let git = HermesGitHost.client { request in
            HermesGitHost.repositoryReply(request, rows: [
                ("a.txt", 1, 0, "M", false), ("a.txt", 1, 0, "?", false), (" b.txt ", 1, 0, "M", false)
            ], flags: [("a.txt", false, true, false, false), (" b.txt ", false, true, false, false)])
        }
        let blank = GitFile(path: " ", status: "?", staged: false, unstaged: true, untracked: true, conflict: false,
                            additions: 1, deletions: 0)
        let listedTwice = GitFile(path: "a.txt", status: "?", staged: false, unstaged: true, untracked: true, conflict: false,
                                  additions: 1, deletions: 0)
        let spaced = GitFile(path: " b.txt ", status: "M", staged: false, unstaged: true, untracked: false, conflict: false,
                             additions: 1, deletions: 0)

        for files in [[blank], [listedTwice], [spaced, blank]] {
            do {
                _ = try await git.discard(files, deleteUntracked: true)
                XCTFail("Expected \(files.map(\.path)) to be refused")
            } catch {
                XCTAssertEqual(error.localizedDescription, String(localized: "Git couldn’t finish this change on your Hermes host."))
            }
        }
        let refusedWrites = HermesGitHost.writes
        _ = try await git.stage([spaced])

        XCTAssertEqual(refusedWrites, [])
        XCTAssertEqual(HermesGitHost.writes, ["stage  b.txt "])
    }

    /// Stage and discard read the rows again at the write: a file another client left conflicted
    /// after the sheet loaded, here past the status cap with only its `U` letter to say so, is
    /// refused, and nothing is sent.
    @MainActor
    func testAHermesFileThatConflictsAfterTheSheetLoadedIsNeitherStagedNorDiscarded() async throws {
        nonisolated(unsafe) var conflicted = false
        let git = HermesGitHost.client { request in
            HermesGitHost.repositoryReply(request, rows: [("a.swift", 1, 0, conflicted ? "U" : "M", false)],
                                          flags: conflicted ? [] : [("a.swift", false, true, false, false)])
        }
        let loaded = try await git.status()?.files ?? []
        HermesHostFixture.script { conflicted = true }
        var refusals: [String] = []

        do { _ = try await git.stage(loaded) } catch { refusals.append(error.localizedDescription) }
        do { _ = try await git.discard(loaded, deleteUntracked: true) } catch { refusals.append(error.localizedDescription) }

        XCTAssertEqual(loaded.map(\.conflict), [false])
        XCTAssertEqual(refusals, [String(localized: "Conflicted files cannot be staged from this panel"),
                                  String(localized: "Conflicted files cannot be discarded from this panel")])
        XCTAssertEqual(HermesGitHost.writes, [])
    }

    /// The host's row for a staged rename names only its new path, so neither a discard nor an
    /// unstage could reach the old one: both are refused before anything is sent, and the index
    /// stays as it was.
    @MainActor
    func testAHermesRenameIsNeitherDiscardedNorUnstaged() async throws {
        let git = HermesGitHost.client { request in
            HermesGitHost.repositoryReply(request, rows: [("new.txt", 0, 0, "R", true), ("a.swift", 1, 0, "M", true)],
                                          flags: [("new.txt", true, false, false, false), ("a.swift", true, false, false, false)])
        }
        let files = try await git.status()?.files ?? []
        var refusals: [String] = []

        do { _ = try await git.discard(files, deleteUntracked: true) } catch { refusals.append(error.localizedDescription) }
        do { _ = try await git.unstage(files) } catch { refusals.append(error.localizedDescription) }

        XCTAssertEqual(refusals, [String(localized: "Renamed files cannot be discarded from this panel"),
                                  String(localized: "Renamed files cannot be unstaged from this panel")])
        XCTAssertEqual(HermesGitHost.writes, [])
    }

    /// Each write asks the chat that owns the repository as it begins, and each of its requests
    /// asks again as it goes out: a write begun under a turn sends nothing, and one a turn
    /// interrupts stops after the request already sent.
    @MainActor
    func testAHermesWriteStopsWhenTheOwningChatStartsATurn() async throws {
        let chat = HermesGitChatStub()
        let git = HermesGitHost.client(writeOwner: chat.owner) { request in
            HermesGitHost.repositoryReply(request, rows: [("a.swift", 1, 0, "M", false), ("b.swift", 1, 0, "M", false)],
                                          flags: [("a.swift", false, true, false, false), ("b.swift", false, true, false, false)])
        }
        let files = try await git.status()?.files ?? []
        var refusals: [HermesGitRefusal?] = []

        chat.turnRunning = true
        do { _ = try await git.push() } catch { refusals.append(error as? HermesGitRefusal) }
        let requestsUnderTheTurn = HermesGitHost.requests.count
        chat.turnRunning = false
        chat.turnStartsAfterDispatches = 1
        do { _ = try await git.stage(files) } catch { refusals.append(error as? HermesGitRefusal) }

        XCTAssertEqual(refusals, [.turnRunning, .turnRunning])
        XCTAssertEqual(requestsUnderTheTurn, 3, "Only the reads of the load: the refused push sent nothing")
        XCTAssertEqual(HermesGitHost.writes, ["stage a.swift"])
    }
}

/// The chat that owns a test repository's writes (`HermesGitClient.WriteOwner`): a turn is
/// running, or starts once `turnStartsAfterDispatches` requests have gone out.
@MainActor final class HermesGitChatStub {
    var turnRunning = false
    var turnStartsAfterDispatches: Int?
    private var dispatches = 0

    var owner: HermesGitClient.WriteOwner {
        { [self] in
            try check()
            return { [self] in
                if let limit = turnStartsAfterDispatches, dispatches >= limit { turnRunning = true }
                try check()
                dispatches += 1
            }
        }
    }

    private func check() throws {
        if turnRunning { throw HermesGitRefusal.turnRunning }
    }
}

/// A scripted Hermes host's repository for `APIClientGitTests` and `GitWorkspaceViewModelTests`.
enum HermesGitHost {
    static let repository = "/Users/agent/projects/app"
    private static let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                              username: "user", password: "secret")

    /// A Hermes chat's repository client on a host `script` answers, its commit messages written
    /// by `writeMessage`.
    @MainActor static func client(cwd: String = repository, writeMessage: HermesGitClient.MessageWriter? = nil,
                                  writeOwner: HermesGitClient.WriteOwner? = nil,
                                  _ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> HermesGitClient {
        HermesGitClient(context: HermesWorkspaceFileClientTests.context(cwd: cwd),
                        http: HermesConnection(connection: record, configuration: HermesHostFixture.configuration(script)),
                        writeMessage: writeMessage, writeOwner: writeOwner)
    }

    /// The host's reply for a repository at `root` whose uncommitted changes are `rows`
    /// (`review/list`) and whose status flags are `flags` (`status.files`, capped at 200 by the host).
    /// `unborn` is a repository before its first commit, with no HEAD.
    static func repositoryReply(
        _ request: URLRequest, root: String? = repository, branch: String = "main", detached: Bool = false,
        unborn: Bool = false, ahead: Int = 0, behind: Int = 0,
        rows: [(path: String, added: Int, removed: Int, status: String, staged: Bool)] = [],
        flags: [(path: String, staged: Bool, unstaged: Bool, untracked: Bool, conflicted: Bool)] = []
    ) -> HermesHostFixture.Reply? {
        switch request.url?.path {
        case "/api/fs/git-root":
            return .json(200, .object(["root": root.map(BotJSON.string) ?? .null]))
        case "/api/git/status":
            let count = { (flag: KeyPath<(path: String, staged: Bool, unstaged: Bool, untracked: Bool, conflicted: Bool), Bool>) in
                BotJSON.number(Double(flags.filter { $0[keyPath: flag] }.count))
            }
            return .json(200, .object([
                "branch": detached ? .null : .string(branch), "defaultBranch": .string("main"), "detached": .bool(detached),
                "ahead": .number(Double(ahead)), "behind": .number(Double(behind)),
                "staged": count(\.staged), "unstaged": count(\.unstaged), "untracked": count(\.untracked),
                "conflicted": count(\.conflicted), "changed": .number(Double(max(rows.count, flags.count))),
                "added": .number(Double(rows.reduce(0) { $0 + $1.added })),
                "removed": .number(Double(rows.reduce(0) { $0 + $1.removed })),
                "files": .array(flags.prefix(200).map {
                    .object(["path": .string($0.path), "staged": .bool($0.staged), "unstaged": .bool($0.unstaged),
                             "untracked": .bool($0.untracked), "conflicted": .bool($0.conflicted)])
                })
            ]))
        case "/api/git/review/list":
            return .json(200, .object(["base": .null, "files": .array(rows.map {
                .object(["path": .string($0.path), "added": .number(Double($0.added)), "removed": .number(Double($0.removed)),
                         "status": .string($0.status), "staged": .bool($0.staged)])
            })]))
        case "/api/git/review/diff", "/api/git/file-diff":
            return .json(200, .object(["diff": .string(diffText(for: query(request, "file") ?? ""))]))
        case "/api/git/review/rev-parse":
            return .json(200, .object(["sha": unborn ? .null : .string(headSHA)]))
        case "/api/git/review/commit-context":
            return .json(200, .object(["diff": .string(contextDiff), "recent": .string(recentSubjects)]))
        default:
            return nil
        }
    }

    static let headSHA = "abc1234def5678abc1234def5678abc1234def56"
    static let contextDiff = diffText(for: "staged.swift")
    static let recentSubjects = "feat(app): add the list\nfix(app): keep the row"

    /// The writes sent, in order, as `stage a.swift`, `unstage (all)` or `commit "message"`, each
    /// followed by ` path=…` unless it named the repository root. A file sent without its
    /// `:(literal)` prefix shows as `glob:a.swift`.
    @MainActor static var writes: [String] {
        requests.filter { $0.httpMethod == "POST" }.map { request in
            let body = HermesCronFixture.body(request)
            let route = request.url?.lastPathComponent ?? ""
            let file = body["file"].text.map { $0.hasPrefix(":(literal)") ? String($0.dropFirst(10)) : "glob:" + $0 }
            let detail = file ?? body["message"].text.map { "\"\($0)\"" + (body["push"].flag == false ? "" : " push") }
                ?? (route == "unstage" ? "(all)" : nil)
            let root = body["path"].text == repository ? nil : "path=\(body["path"].text ?? "none")"
            return ([route] + [detail, root].compactMap { $0 }).joined(separator: " ")
        }
    }

    /// A one-line all-add diff of `file`, whose only line is the file's name.
    static func diffText(for file: String) -> String {
        "diff --git a/\(file) b/\(file)\n--- /dev/null\n+++ b/\(file)\n@@ -0,0 +1 @@\n+\(file)\n"
    }

    /// The requests to the git routes, without the sign-in's.
    static var requests: [URLRequest] {
        HermesHostFixture.requests.filter {
            $0.url?.path.hasPrefix("/api/git/") == true || $0.url?.path == "/api/fs/git-root"
        }
    }

    /// A request's route and query, as `/api/git/status path=/repo`.
    static func describe(_ request: URLRequest) -> String {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        return ([request.url?.path ?? ""] + items.map { "\($0.name)=\($0.value ?? "")" }).joined(separator: " ")
    }

    static func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
            .first { $0.name == name }?.value
    }
}
