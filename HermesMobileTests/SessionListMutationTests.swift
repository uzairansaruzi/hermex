import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class SessionListMutationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testLoadFallsBackToCachedSessionsForNetworkTimeout() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let otherServerURL = try XCTUnwrap(URL(string: "https://other.example.test"))
        try CacheStore.cacheSessions(
            [
                SessionSummary(
                    sessionId: "cached-project-one",
                    title: "Cached project one",
                    archived: false,
                    projectId: "project-1",
                    profile: "work"
                ),
                SessionSummary(
                    sessionId: "cached-project-two",
                    title: "Cached project two",
                    archived: false,
                    projectId: "project-2",
                    profile: "work"
                ),
                SessionSummary(
                    sessionId: "cached-subagent",
                    title: "Cached delegated work",
                    archived: false,
                    projectId: "project-1",
                    profile: "work",
                    sourceTag: "subagent",
                    readOnly: true
                )
            ],
            serverURL: serverURL,
            in: context
        )
        try CacheStore.cacheSessions(
            [
                SessionSummary(sessionId: "other-server", title: "Other server", archived: false)
            ],
            serverURL: otherServerURL,
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            throw URLError(.timedOut)
        }

        await viewModel.load(modelContext: context)

        XCTAssertEqual(
            Set(viewModel.sessions.compactMap(\.sessionId)),
            Set(["cached-project-one", "cached-project-two", "cached-subagent"])
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: "project-1",
                automatedVisibility: AutomatedSessionVisibility(showsCron: true, showsCli: true)
            ).compactMap(\.sessionId),
            ["cached-project-one"]
        )
        XCTAssertEqual(
            Set(viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: "project-1",
                automatedVisibility: .showAll
            ).compactMap(\.sessionId)),
            Set(["cached-project-one", "cached-subagent"])
        )
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadSurfacesNetworkTimeoutWhenCacheIsEmpty() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            throw URLError(.timedOut)
        }

        await viewModel.load(modelContext: context)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(
            viewModel.errorMessage,
            "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
        )
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testSessionLoadErrorStaysScopedWhenRemoteSearchFails() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                throw URLError(.timedOut)
            case "/api/sessions/search":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load(modelContext: context)
        let sessionLoadError = try XCTUnwrap(viewModel.sessionLoadError)
        XCTAssertTrue(CacheFallbackPolicy.shouldUseCache(for: sessionLoadError))
        XCTAssertEqual(
            viewModel.errorMessage,
            "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
        )

        await viewModel.searchSessions(query: "later", debounceNanoseconds: 0)

        XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: try XCTUnwrap(viewModel.lastError)))
        XCTAssertTrue(CacheFallbackPolicy.shouldUseCache(for: try XCTUnwrap(viewModel.sessionLoadError)))
        XCTAssertEqual(
            viewModel.errorMessage,
            "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
        )
    }

    @MainActor
    func testLoadDoesNotReplaceSuccessfulOnlineSessionsWithStaleCache() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheSessions(
            [
                SessionSummary(sessionId: "stale-session", title: "Stale planning", archived: false)
            ],
            serverURL: serverURL,
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "fresh-session",
                  "title": "Fresh planning",
                  "archived": false,
                  "project_id": "project-1",
                  "profile": "work"
                }
              ]
            }
            """, for: request)
        }

        await viewModel.load(modelContext: context)

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["fresh-session"])
        XCTAssertEqual(viewModel.sessions.first?.projectId, "project-1")
        XCTAssertEqual(viewModel.sessions.first?.profile, "work")
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            try CacheStore.cachedSessions(serverURL: serverURL, in: context).compactMap(\.sessionId),
            ["fresh-session"]
        )
    }

    @MainActor
    func testLoadFiltersEmptyUntitledPlaceholdersButKeepsRealUntitledRows() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "empty-placeholder",
                  "title": "Untitled Session",
                  "message_count": 0,
                  "archived": false
                },
                {
                  "session_id": "empty-placeholder-missing-count",
                  "title": "Untitled Session",
                  "archived": false
                },
                {
                  "session_id": "contentful-untitled",
                  "title": "Untitled Session",
                  "message_count": 2,
                  "archived": false
                },
                {
                  "session_id": "recent-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "last_message_at": 1770000000,
                  "archived": false
                },
                {
                  "session_id": "streaming-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "active_stream_id": "stream-123",
                  "archived": false
                },
                {
                  "session_id": "pending-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "has_pending_user_message": true,
                  "archived": false
                },
                {
                  "session_id": "worktree-untitled",
                  "title": "Untitled",
                  "message_count": 0,
                  "worktree_path": "/tmp/hermes-worktree",
                  "archived": false
                },
                {
                  "session_id": "named-empty",
                  "title": "Planning",
                  "message_count": 0,
                  "archived": false
                }
              ]
            }
            """, for: request)
        }

        await viewModel.load(modelContext: context)

        let expectedIDs = [
            "contentful-untitled",
            "streaming-untitled",
            "pending-untitled",
            "worktree-untitled",
            "named-empty"
        ]
        let loadedIDs = viewModel.sessions.compactMap(\.sessionId)
        XCTAssertEqual(Set(loadedIDs), Set(expectedIDs))
        XCTAssertEqual(loadedIDs.count, expectedIDs.count)

        let cachedIDs = try CacheStore.cachedSessions(serverURL: serverURL, in: context).compactMap(\.sessionId)
        XCTAssertEqual(Set(cachedIDs), Set(expectedIDs))
        XCTAssertEqual(cachedIDs.count, expectedIDs.count)
    }

    @MainActor
    func testLoadDoesNotUseCachedSessionsForRealServerError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheSessions(
            [
                SessionSummary(sessionId: "cached-session", title: "Cached planning", archived: false)
            ],
            serverURL: serverURL,
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
        }

        await viewModel.load(modelContext: context)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.errorMessage, "The Hermes server hit an internal error. Check the server logs, then try again.")
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testCreateSessionReturnsEmptyPlaceholderWithoutInsertingIntoSessionList() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/workspaces":
                return apiTestJSONResponse("""
                {
                  "workspaces": [
                    {"path": "/tmp/workspace", "name": "Workspace"}
                  ],
                  "last": "/tmp/workspace"
                }
                """, for: request)
            case "/api/session/new":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertNil(body["model"] as? String)
                XCTAssertNil(body["model_provider"] as? String)
                XCTAssertNil(body["profile"] as? String)

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "new-123",
                    "title": "Untitled Session",
                    "workspace": "/tmp/workspace",
                    "updated_at": 1770000000,
                    "last_message_at": 1770000000,
                    "archived": false
                  }
                }
                """, for: request)
            case "/api/sessions":
                XCTFail("New-chat creation should not block on a full session-list reload.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let created = await viewModel.createSession(modelContext: context)

        XCTAssertEqual(created?.sessionId, "new-123")
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertTrue(try CacheStore.cachedSessions(serverURL: serverURL, in: context).isEmpty)
        XCTAssertEqual(requestedPaths, ["/api/workspaces", "/api/session/new"])
        XCTAssertFalse(viewModel.isCreatingSession)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testCreateSessionKeepsWorktreeBackedUntitledSessionWithoutCounts() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse("""
                {
                  "workspaces": [
                    {"path": "/tmp/workspace", "name": "Workspace"}
                  ],
                  "last": "/tmp/workspace"
                }
                """, for: request)
            case "/api/session/new":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "worktree-new",
                    "title": "Untitled Session",
                    "workspace": "/tmp/workspace",
                    "worktree_path": "/tmp/hermes-worktree",
                    "archived": false
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let created = await viewModel.createSession(modelContext: context)

        XCTAssertEqual(created?.sessionId, "worktree-new")
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["worktree-new"])
        XCTAssertEqual(
            try CacheStore.cachedSessions(serverURL: serverURL, in: context).compactMap(\.sessionId),
            ["worktree-new"]
        )
    }

    @MainActor
    func testLoadActiveProfileUsesProfilesEndpointAndStoresCurrentProfile() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestedPaths.append(request.url?.path ?? "nil")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {
                      "name": "default",
                      "is_default": true,
                      "model": "gpt-5"
                    },
                    {
                      "name": "work",
                      "is_active": true,
                      "model": "claude-sonnet-4-5",
                      "provider": "anthropic"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()

        XCTAssertEqual(requestedPaths, ["/api/profiles"])
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "claude-sonnet-4-5")
        XCTAssertEqual(viewModel.activeProfileProvider, "anthropic")
        XCTAssertEqual(viewModel.profileOptions.compactMap(\.normalizedName), ["default", "work"])
        XCTAssertFalse(viewModel.isSingleProfileMode)
        XCTAssertFalse(viewModel.isLoadingActiveProfile)
        XCTAssertNil(viewModel.activeProfileErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testLoadActiveProfileStoresSingleProfileMode() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    { "name": "default", "is_default": true, "is_active": true }
                  ],
                  "single_profile_mode": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()

        XCTAssertTrue(viewModel.isSingleProfileMode)
        XCTAssertEqual(viewModel.activeProfileName, "default")
    }

    @MainActor
    func testLoadActiveProfileCanRefreshChangedProfile() async throws {
        var profileLoadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles":
                profileLoadCount += 1

                if profileLoadCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "active": "default",
                      "profiles": [
                        {"name": "default", "is_active": true, "model": "gpt-5", "provider": "openai"},
                        {"name": "work", "model": "claude-sonnet-4-5", "provider": "anthropic"}
                      ]
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "default", "model": "gpt-5", "provider": "openai"},
                    {"name": "work", "is_active": true, "model": "claude-sonnet-4-5", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()
        XCTAssertEqual(viewModel.activeProfileDisplayName, "Default")
        XCTAssertEqual(viewModel.activeProfileModel, "gpt-5")

        await viewModel.loadActiveProfile()
        XCTAssertEqual(profileLoadCount, 2)
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "claude-sonnet-4-5")
        XCTAssertEqual(viewModel.activeProfileProvider, "anthropic")
        XCTAssertNil(viewModel.activeProfileErrorMessage)
    }

    @MainActor
    func testSwitchActiveProfileCallsServerAndUpdatesPickerState() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "is_active": true, "model": "gpt-5", "provider": "openai"},
                    {"name": "work", "model": "claude-sonnet-4-5", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            case "/api/profile/switch":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["name"] as? String, "work")
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "default_model": "claude-sonnet-4-5",
                  "profiles": [
                    {"name": "default", "model": "gpt-5", "provider": "openai"},
                    {"name": "work", "is_active": true, "model": "claude-sonnet-4-5", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()
        let workProfile = try XCTUnwrap(viewModel.profileOptions.first { $0.normalizedName == "work" })
        let didSwitch = await viewModel.switchActiveProfile(workProfile)

        XCTAssertTrue(didSwitch)
        XCTAssertEqual(requestedPaths, ["/api/profiles", "/api/profile/switch"])
        XCTAssertEqual(viewModel.activeProfileName, "work")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "work")
        XCTAssertEqual(viewModel.activeProfileModel, "claude-sonnet-4-5")
        XCTAssertEqual(viewModel.activeProfileProvider, "anthropic")
        XCTAssertFalse(viewModel.isSwitchingActiveProfile)
        XCTAssertNil(viewModel.switchingActiveProfileName)
        XCTAssertNil(viewModel.activeProfileErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testSwitchActiveProfileFailureKeepsExistingProfileState() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "is_active": true, "model": "gpt-5", "provider": "openai"},
                    {"name": "work", "model": "claude-sonnet-4-5", "provider": "anthropic"}
                  ]
                }
                """, for: request)
            case "/api/profile/switch":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"switch failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadActiveProfile()
        let workProfile = try XCTUnwrap(viewModel.profileOptions.first { $0.normalizedName == "work" })
        let didSwitch = await viewModel.switchActiveProfile(workProfile)

        XCTAssertFalse(didSwitch)
        XCTAssertEqual(viewModel.activeProfileName, "default")
        XCTAssertEqual(viewModel.activeProfileDisplayName, "Default")
        XCTAssertEqual(viewModel.activeProfileModel, "gpt-5")
        XCTAssertFalse(viewModel.isSwitchingActiveProfile)
        XCTAssertNil(viewModel.switchingActiveProfileName)
        XCTAssertNotNil(viewModel.activeProfileErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadActiveProfileFailureDoesNotOverwriteSessionListState() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/profiles":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"profile failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        await viewModel.loadActiveProfile()

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-abc"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isLoadingActiveProfile)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.activeProfileErrorMessage)
        XCTAssertNil(viewModel.activeProfileName)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testInactiveActiveStreamStatusReloadsSessionsToClearStreamingIndicator() async throws {
        var loadCount = 0
        var requestPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestPaths.append(path)

            switch path {
            case "/api/sessions":
                loadCount += 1
                let activeStreamIDField = loadCount == 1 ? #","active_stream_id":"stream-123""# : ""
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "session-streaming",
                      "title": "Streaming work",
                      "archived": false\(activeStreamIDField)
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/stream/status":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let streamID = components?.queryItems?.first { $0.name == "stream_id" }?.value
                XCTAssertEqual(streamID, "stream-123")
                return apiTestJSONResponse(
                    #"{"active":false,"stream_id":"stream-123"}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        XCTAssertEqual(viewModel.sessions.first?.activeStreamId, "stream-123")

        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-123"])

        XCTAssertEqual(refreshResult, .reloaded)
        XCTAssertNil(viewModel.sessions.first?.activeStreamId)
        XCTAssertEqual(requestPaths, ["/api/sessions", "/api/chat/stream/status", "/api/sessions"])
    }

    @MainActor
    func testActiveStreamStatusDoesNotReloadSessionsWhileStillActive() async throws {
        var loadCount = 0
        var statusCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                loadCount += 1
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "session-streaming",
                      "title": "Streaming work",
                      "archived": false,
                      "active_stream_id": "stream-123"
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/stream/status":
                statusCount += 1
                return apiTestJSONResponse(
                    #"{"active":true,"stream_id":"stream-123"}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-123"])

        XCTAssertEqual(refreshResult, .unchanged)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(statusCount, 1)
        XCTAssertEqual(viewModel.sessions.first?.activeStreamId, "stream-123")
    }

    @MainActor
    func testActiveStreamStatusUnauthorizedIsPreservedForAuthHandling() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"unauthorized"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(streamIDs: ["stream-123"])

        XCTAssertEqual(refreshResult, .failed)
        guard let lastError = viewModel.lastError,
              case APIError.unauthorized = lastError
        else {
            XCTFail("Expected unauthorized lastError, got \(String(describing: viewModel.lastError))")
            return
        }
    }

    @MainActor
    func testPinArchiveMoveAndDeleteCallServerMutationThenReloadSessions() async throws {
        var loadCount = 0
        var mutationPaths: [String] = []
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: loadCount), for: request)
            case "/api/session/pin":
                mutationPaths.append("/api/session/pin")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["pinned"] as? Bool, true)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            case "/api/session/archive":
                mutationPaths.append("/api/session/archive")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["archived"] as? Bool, true)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            case "/api/session/move":
                mutationPaths.append("/api/session/move")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["project_id"] as? String, "project-1")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            case "/api/session/delete":
                mutationPaths.append("/api/session/delete")
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let didPin = await viewModel.setPinned(true, for: session)
        XCTAssertTrue(didPin)
        XCTAssertEqual(viewModel.sessions.first?.pinned, true)

        let didArchive = await viewModel.archive(session)
        XCTAssertTrue(didArchive)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        await viewModel.move(session, to: "project-1")
        XCTAssertEqual(viewModel.sessions.first?.projectId, "project-1")

        let didDelete = await viewModel.delete(session)
        XCTAssertTrue(didDelete)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        XCTAssertEqual(loadCount, 5)
        XCTAssertEqual(
            mutationPaths,
            ["/api/session/pin", "/api/session/archive", "/api/session/move", "/api/session/delete"]
        )
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    func testSessionMutatorDuplicateBranchesThenLoadsReturnedSession() async throws {
        var requestedPaths: [String] = []
        let client = try makeClient { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/session/branch":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["title"] as? String, "Planning (copy)")
                return apiTestJSONResponse(#"{"session_id":"copy-123"}"#, for: request)
            case "/api/session":
                XCTAssertEqual(request.url?.query?.contains("session_id=copy-123"), true)
                return apiTestJSONResponse(
                    """
                    {
                      "session": {
                        "session_id": "copy-123",
                        "title": "Planning (copy)",
                        "archived": false
                      }
                    }
                    """,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        let result = try await SessionMutator(client: client).duplicate(
            sessionID: "session-abc",
            title: "Planning (copy)"
        )

        XCTAssertEqual(requestedPaths, ["/api/session/branch", "/api/session"])
        XCTAssertEqual(result.session?.sessionId, "copy-123")
        XCTAssertEqual(result.session?.title, "Planning (copy)")
        XCTAssertNil(result.errorMessage)
    }

    @MainActor
    func testConcurrentSessionMutationsAreIgnoredWhileSameSessionIsInFlight() async throws {
        let firstPinRequestStarted = expectation(description: "first pin request started")
        let requestCounts = LockedSessionMutationRequestCounts()
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                let currentLoadCount = requestCounts.incrementLoadCount()
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: currentLoadCount), for: request)
            case "/api/session/pin":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")

                let currentPinRequestCount = requestCounts.incrementPinRequestCount()

                if currentPinRequestCount == 1 {
                    firstPinRequestStarted.fulfill()
                    Thread.sleep(forTimeInterval: 0.2)
                }

                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let firstMutation = Task { @MainActor in
            await viewModel.setPinned(true, for: session)
        }
        await fulfillment(of: [firstPinRequestStarted], timeout: 1)
        XCTAssertTrue(viewModel.isMutating(session))

        let duplicatePinMutation = Task { @MainActor in
            await viewModel.setPinned(false, for: session)
        }
        let duplicateMutation = Task { @MainActor in
            await viewModel.duplicate(session)
        }
        let moveMutation = Task { @MainActor in
            await viewModel.move(session, to: "project-1")
        }

        let didSkipDuplicatePin = await duplicatePinMutation.value
        _ = await duplicateMutation.value
        await moveMutation.value
        let didPin = await firstMutation.value

        let finalCounts = requestCounts.snapshot

        XCTAssertTrue(didPin)
        XCTAssertFalse(didSkipDuplicatePin)
        XCTAssertEqual(finalCounts.pinRequestCount, 1)
        XCTAssertEqual(finalCounts.loadCount, 2)
        XCTAssertFalse(viewModel.isMutating(session))
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testRenameSessionUpdatesLocalRowAndCachedSession() async throws {
        var requestedPaths: [String] = []
        let context = try makeContext()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/sessions":
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/session/rename":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["title"] as? String, "Launch Notes")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "session": {
                    "session_id": "session-abc",
                    "title": "Launch Notes"
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.load(modelContext: context)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let didRename = await viewModel.rename(session, to: "  Launch Notes  ", modelContext: context)
        let cachedSessions = try CacheStore.cachedSessions(serverURL: server, in: context)

        XCTAssertTrue(didRename)
        XCTAssertEqual(requestedPaths, ["/api/sessions", "/api/session/rename"])
        XCTAssertEqual(viewModel.sessions.first?.title, "Launch Notes")
        XCTAssertEqual(viewModel.sessions.first?.workspace, session.workspace)
        XCTAssertEqual(cachedSessions.first?.title, "Launch Notes")
        XCTAssertFalse(viewModel.isRenamingSession)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testRenameSessionBlocksBlankTitleBeforeNetworkRequest() async throws {
        let viewModel = try makeViewModel { request in
            XCTFail("Blank session titles should not make network requests: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let session = try makeSessionSummary(
            id: "session-abc",
            title: "Planning",
            pinned: false,
            archived: false
        )

        let didRename = await viewModel.rename(session, to: "   ")

        XCTAssertFalse(didRename)
        XCTAssertEqual(viewModel.actionErrorMessage, "Enter a session title.")
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isRenamingSession)
    }

    @MainActor
    func testRenameSessionFailureKeepsOldTitleAndShowsActionError() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)

            switch path {
            case "/api/sessions":
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/session/rename":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"rename failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(path)")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let beforeSessions = viewModel.sessions
        let session = try XCTUnwrap(beforeSessions.first)
        let didRename = await viewModel.rename(session, to: "Launch Notes")

        XCTAssertFalse(didRename)
        XCTAssertEqual(requestedPaths, ["/api/sessions", "/api/session/rename"])
        XCTAssertEqual(viewModel.sessions, beforeSessions)
        XCTAssertEqual(viewModel.sessions.first?.title, "Planning")
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isRenamingSession)
    }

    @MainActor
    func testRenameSessionIsBlockedForCachedOfflineData() async throws {
        var requestedPaths: [String] = []
        let context = try makeContext()
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let cachedSession = try makeSessionSummary(
            id: "session-abc",
            title: "Cached Planning",
            pinned: false,
            archived: false
        )
        try CacheStore.cacheSession(cachedSession, serverURL: server, in: context)

        let viewModel = try makeViewModel { request in
            let path = request.url?.path ?? "nil"
            requestedPaths.append(path)
            throw URLError(.notConnectedToInternet)
        }

        await viewModel.load(modelContext: context)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let didRename = await viewModel.rename(session, to: "Launch Notes", modelContext: context)

        XCTAssertFalse(didRename)
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertEqual(requestedPaths, ["/api/sessions"])
        XCTAssertEqual(viewModel.sessions.first?.title, "Cached Planning")
        XCTAssertEqual(viewModel.actionErrorMessage, "Reconnect to the server to rename a session.")
        XCTAssertFalse(viewModel.isRenamingSession)
    }

    func testCreateProjectThenMovesSessionAndUpdatesLocalLists() async throws {
        var loadCount = 0
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/sessions":
                loadCount += 1
                if loadCount == 1 {
                    return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
                }

                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "session-abc",
                      "title": "Planning",
                      "project_id": "project-new",
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/create":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["name"] as? String, "Client Work")
                XCTAssertEqual(body["color"] as? String, "#7cb9ff")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-new",
                    "name": "Client Work",
                    "color": "#7cb9ff",
                    "created_at": 1770000000
                  }
                }
                """, for: request)
            case "/api/session/move":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["project_id"] as? String, "project-new")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try await MainActor.run {
            try XCTUnwrap(viewModel.sessions.first)
        }
        let didMove = await viewModel.createProject(
            named: "  Client Work  ",
            color: "#7cb9ff",
            moving: session
        )

        XCTAssertTrue(didMove)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let projectName = await MainActor.run { viewModel.projects.first?.name }
        let movedProjectID = await MainActor.run { viewModel.sessions.first?.projectId }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertEqual(projectIDs, ["project-new"])
        XCTAssertEqual(projectName, "Client Work")
        XCTAssertEqual(movedProjectID, "project-new")
        XCTAssertEqual(
            requestedPaths,
            ["/api/sessions", "/api/projects/create", "/api/session/move", "/api/sessions"]
        )
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
    }

    func testCreateProjectBlocksBlankNameBeforeNetworkRequest() async throws {
        let viewModel = try await makeViewModel { request in
            XCTFail("Blank project names should not make network requests: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let session = try makeSessionSummary(
            id: "session-abc",
            title: "Planning",
            pinned: false,
            archived: false
        )

        let didMove = await viewModel.createProject(
            named: "  ",
            color: "#7cb9ff",
            moving: session
        )

        XCTAssertFalse(didMove)
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }

        XCTAssertEqual(actionErrorMessage, "Enter a project name.")
        XCTAssertNil(lastError)
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
    }

    func testCreateProjectMoveFailureKeepsSessionUnmovedAndShowsError() async throws {
        var loadCount = 0
        let viewModel = try await makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                loadCount += 1
                XCTAssertEqual(loadCount, 1)
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/projects/create":
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-new",
                    "name": "Client Work",
                    "color": "#7cb9ff"
                  }
                }
                """, for: request)
            case "/api/session/move":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"move failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = await MainActor.run { viewModel.sessions }
        let session = try XCTUnwrap(before.first)
        let didMove = await viewModel.createProject(
            named: "Client Work",
            color: "#7cb9ff",
            moving: session
        )

        XCTAssertFalse(didMove)
        XCTAssertEqual(loadCount, 1)
        let sessions = await MainActor.run { viewModel.sessions }
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }

        XCTAssertEqual(sessions, before)
        XCTAssertEqual(projectIDs, ["project-new"])
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
    }

    func testCreateEmptyProjectCreatesProjectWithoutMovingAnySession() async throws {
        var loadCount = 0
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/projects/create":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["name"] as? String, "Client Work")
                XCTAssertEqual(body["color"] as? String, "#7cb9ff")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-new",
                    "name": "Client Work",
                    "color": "#7cb9ff",
                    "created_at": 1770000000
                  }
                }
                """, for: request)
            case "/api/session/move":
                XCTFail("createEmptyProject must not move any session")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let didCreate = await viewModel.createEmptyProject(
            named: "  Client Work  ",
            color: "#7cb9ff"
        )

        XCTAssertTrue(didCreate)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let projectName = await MainActor.run { viewModel.projects.first?.name }
        let sessionProjectID = await MainActor.run { viewModel.sessions.first?.projectId }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }
        let isMovingSession = await MainActor.run { viewModel.isMovingSession }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertEqual(projectIDs, ["project-new"])
        XCTAssertEqual(projectName, "Client Work")
        // The existing session stays unassigned: no move request was made.
        XCTAssertNil(sessionProjectID)
        XCTAssertFalse(requestedPaths.contains("/api/session/move"))
        XCTAssertEqual(
            requestedPaths,
            ["/api/sessions", "/api/projects/create", "/api/sessions"]
        )
        XCTAssertFalse(isCreatingProject)
        XCTAssertFalse(isMovingSession)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
    }

    func testCreateEmptyProjectBlocksBlankNameBeforeNetworkRequest() async throws {
        let viewModel = try await makeViewModel { request in
            XCTFail("Blank project names should not make network requests: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        let didCreate = await viewModel.createEmptyProject(
            named: "   ",
            color: "#7cb9ff"
        )

        XCTAssertFalse(didCreate)
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }

        XCTAssertEqual(actionErrorMessage, "Enter a project name.")
        XCTAssertNil(lastError)
        XCTAssertFalse(isCreatingProject)
    }

    func testCreateEmptyProjectMissingProjectInResponseShowsError() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects/create":
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didCreate = await viewModel.createEmptyProject(
            named: "Client Work",
            color: "#7cb9ff"
        )

        XCTAssertFalse(didCreate)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }

        XCTAssertEqual(requestedPaths, ["/api/projects/create"])
        XCTAssertTrue(projectIDs.isEmpty)
        XCTAssertEqual(actionErrorMessage, "The server did not return the new project.")
        XCTAssertFalse(isCreatingProject)
    }

    func testCreateEmptyProjectNetworkFailureSetsError() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects/create":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"server boom"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didCreate = await viewModel.createEmptyProject(
            named: "Client Work",
            color: "#7cb9ff"
        )

        XCTAssertFalse(didCreate)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isCreatingProject = await MainActor.run { viewModel.isCreatingProject }

        XCTAssertEqual(requestedPaths, ["/api/projects/create"])
        XCTAssertTrue(projectIDs.isEmpty)
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isCreatingProject)
    }

    func testRenameProjectUpdatesLocalProject() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/rename":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["project_id"] as? String, "project-1")
                XCTAssertEqual(body["name"] as? String, "Client Archive")
                XCTAssertEqual(body["color"] as? String, "#f5c542")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "project": {
                    "project_id": "project-1",
                    "name": "Client Archive",
                    "color": "#f5c542"
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let didRename = await viewModel.rename(project, named: "  Client Archive  ", color: "#f5c542")
        let projects = await MainActor.run { viewModel.projects }
        let isRenamingProject = await MainActor.run { viewModel.isRenamingProject }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertTrue(didRename)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.projectId, "project-1")
        XCTAssertEqual(projects.first?.name, "Client Archive")
        XCTAssertEqual(projects.first?.color, "#f5c542")
        XCTAssertEqual(requestedPaths, ["/api/projects", "/api/projects/rename"])
        XCTAssertFalse(isRenamingProject)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
    }

    func testRenameProjectBlocksBlankNameBeforeNetworkRequest() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Blank project names should not make rename requests: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let didRename = await viewModel.rename(project, named: "  ", color: "#7cb9ff")
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isRenamingProject = await MainActor.run { viewModel.isRenamingProject }

        XCTAssertFalse(didRename)
        XCTAssertEqual(requestedPaths, ["/api/projects"])
        XCTAssertEqual(actionErrorMessage, "Enter a project name.")
        XCTAssertNil(lastError)
        XCTAssertFalse(isRenamingProject)
    }

    func testRenameProjectFailureKeepsProject() async throws {
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/rename":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"rename failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadProjects()
        let beforeProjects = await MainActor.run { viewModel.projects }
        let project = try XCTUnwrap(beforeProjects.first)
        let didRename = await viewModel.rename(project, named: "Client Archive", color: "#f5c542")
        let projects = await MainActor.run { viewModel.projects }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isRenamingProject = await MainActor.run { viewModel.isRenamingProject }

        XCTAssertFalse(didRename)
        XCTAssertEqual(requestedPaths, ["/api/projects", "/api/projects/rename"])
        XCTAssertEqual(projects, beforeProjects)
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isRenamingProject)
    }

    func testDeleteProjectRemovesProjectAndReloadsUnassignedSessions() async throws {
        var sessionLoadCount = 0
        var requestedPaths: [String] = []
        let viewModel = try await makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "")

            switch path {
            case "/api/sessions":
                sessionLoadCount += 1
                if sessionLoadCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "sessions": [
                        {
                          "session_id": "session-abc",
                          "title": "Planning",
                          "project_id": "project-1",
                          "archived": false
                        }
                      ]
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "session-abc",
                      "title": "Planning",
                      "project_id": null,
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/delete":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["project_id"] as? String, "project-1")
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let didDelete = await viewModel.delete(project)
        let projectIDs = await MainActor.run { viewModel.projects.compactMap(\.projectId) }
        let sessionProjectID = await MainActor.run { viewModel.sessions.first?.projectId }
        let isDeletingProject = await MainActor.run { viewModel.isDeletingProject }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }

        XCTAssertTrue(didDelete)
        XCTAssertEqual(projectIDs, [])
        XCTAssertNil(sessionProjectID)
        XCTAssertFalse(isDeletingProject)
        XCTAssertNil(actionErrorMessage)
        XCTAssertNil(lastError)
        XCTAssertEqual(
            requestedPaths,
            ["/api/sessions", "/api/projects", "/api/projects/delete", "/api/sessions"]
        )
    }

    func testDeleteProjectFailureKeepsProjectAndSessions() async throws {
        var sessionLoadCount = 0
        let viewModel = try await makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                sessionLoadCount += 1
                XCTAssertEqual(sessionLoadCount, 1)
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "session-abc",
                      "title": "Planning",
                      "project_id": "project-1",
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            case "/api/projects":
                return apiTestJSONResponse("""
                {
                  "projects": [
                    {
                      "project_id": "project-1",
                      "name": "Client Work",
                      "color": "#7cb9ff"
                    }
                  ]
                }
                """, for: request)
            case "/api/projects/delete":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"delete failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        await viewModel.loadProjects()
        let project = try await MainActor.run {
            try XCTUnwrap(viewModel.projects.first)
        }
        let beforeSessions = await MainActor.run { viewModel.sessions }
        let beforeProjects = await MainActor.run { viewModel.projects }
        let didDelete = await viewModel.delete(project)
        let sessions = await MainActor.run { viewModel.sessions }
        let projects = await MainActor.run { viewModel.projects }
        let actionErrorMessage = await MainActor.run { viewModel.actionErrorMessage }
        let lastError = await MainActor.run { viewModel.lastError }
        let isDeletingProject = await MainActor.run { viewModel.isDeletingProject }

        XCTAssertFalse(didDelete)
        XCTAssertEqual(sessionLoadCount, 1)
        XCTAssertEqual(sessions, beforeSessions)
        XCTAssertEqual(projects, beforeProjects)
        XCTAssertNotNil(actionErrorMessage)
        XCTAssertNotNil(lastError)
        XCTAssertFalse(isDeletingProject)
    }

    @MainActor
    func testMutationErrorSurfacesMessageWithoutReloadingOrCorruptingSessions() async throws {
        var loadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                loadCount += 1
                return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
            case "/api/session/archive":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"archive failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didArchive = await viewModel.archive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didArchive)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testSuccessfulMutationReturnsFalseWhenFollowUpReloadFails() async throws {
        var loadCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                loadCount += 1
                if loadCount == 1 {
                    return apiTestJSONResponse(self.sessionListJSON(forLoadCount: 1), for: request)
                }

                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"reload failed"}"#.utf8))
            case "/api/session/archive":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["archived"] as? Bool, true)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didArchive = await viewModel.archive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didArchive)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.sessionLoadError)
    }

    @MainActor
    func testArchivedSessionUnarchiveRemovesRowAndSendsSingleServerMutation() async throws {
        var archiveRequestCount = 0
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                // The archived screen must opt in to archived rows — without
                // include_archived=1 the server returns none (issue #17).
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["include_archived"], "1")
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
                archiveRequestCount += 1
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["archived"] as? Bool, false)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let didUnarchive = await viewModel.unarchive(session)
        let didSkipDuplicateUnarchive = await viewModel.unarchive(session)

        XCTAssertTrue(didUnarchive)
        XCTAssertFalse(didSkipDuplicateUnarchive)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-def"])
        XCTAssertEqual(archiveRequestCount, 1)
        XCTAssertFalse(viewModel.isUnarchiving)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testArchivedSessionUnarchiveFailureRestoresRemovedRow() async throws {
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                // The archived screen must opt in to archived rows — without
                // include_archived=1 the server returns none (issue #17).
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["include_archived"], "1")
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"unarchive failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertFalse(viewModel.isUnarchiving)
        XCTAssertNotNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testArchivedSessionUnarchiveRejectionSurfacesServerMessage() async throws {
        // Mirrors the live contract: subagent and read-only imported CLI sessions
        // reject archive-state changes with HTTP 400 + an `error` message, which
        // must reach the user verbatim rather than a generic failure (issue #17).
        let serverMessage = "Subagent sessions are view-only and cannot be archived from WebUI"
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"\#(serverMessage)"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        let actionErrorMessage = try XCTUnwrap(viewModel.actionErrorMessage)
        XCTAssertTrue(
            actionErrorMessage.contains(serverMessage),
            "Expected the server's message in: \(actionErrorMessage)"
        )
    }

    @MainActor
    func testArchivedSessionUnarchiveOkResponseWithErrorFieldSurfacesMessageAndRestoresRow() async throws {
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
                return apiTestJSONResponse(#"{"ok": false, "error": "Session not writable"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertEqual(viewModel.actionErrorMessage, "Session not writable")
    }

    @MainActor
    func testArchivedSessionUnarchiveOkFalseWithoutErrorFieldFailsAndRestoresRow() async throws {
        // An explicit `ok: false` with no `error` string must still be treated
        // as a failure — reporting success here would permanently drop the row
        // from the archived list even though the server did not restore it.
        let viewModel = try makeArchivedViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse(self.archivedSessionListJSON(), for: request)
            case "/api/session/archive":
                return apiTestJSONResponse(#"{"ok": false}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let before = viewModel.sessions
        let didUnarchive = await viewModel.unarchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertFalse(didUnarchive)
        XCTAssertEqual(viewModel.sessions, before)
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertFalse(viewModel.isUnarchiving)
    }

    @MainActor
    func testLoadStoresArchivedCountFromResponseForArchivedEntry() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            XCTAssertNil(request.url?.query)
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "session-abc",
                  "title": "Planning",
                  "archived": false
                }
              ],
              "archived_count": 8
            }
            """, for: request)
        }

        XCTAssertNil(viewModel.archivedCount)

        await viewModel.load()

        XCTAssertEqual(viewModel.archivedCount, 8)
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["session-abc"])
    }

    @MainActor
    func testDuplicateBranchesWithCopyTitleLoadsDetailAndInsertsWhenReloadOmitsCopy() async throws {
        var branchCount = 0
        var didRequestDuplicatedDetail = false
        let source = try makeSessionSummary(
            id: "session-abc",
            title: "Planning",
            pinned: false,
            archived: false
        )
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session/branch":
                branchCount += 1
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["title"] as? String, "Planning (copy)")

                if branchCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session_id": "copy-123",
                      "parent_session_id": "session-abc"
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "error": "copy failed"
                }
                """, for: request)
            case "/api/session":
                didRequestDuplicatedDetail = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "copy-123",
                    "title": "Planning (copy)",
                    "archived": false
                  }
                }
                """, for: request)
            case "/api/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "session-abc",
                      "title": "Planning",
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let duplicated = await viewModel.duplicate(source)
        let missingID = await viewModel.duplicate(source)

        XCTAssertTrue(didRequestDuplicatedDetail)
        XCTAssertEqual(duplicated?.sessionId, "copy-123")
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["copy-123", "session-abc"])
        XCTAssertNil(missingID)
        XCTAssertEqual(viewModel.actionErrorMessage, "copy failed")
    }

    @MainActor
    func testRemoteSessionSearchAppendsLoadedContentMatchesAfterLocalMatchesAndPreservesProjectScope() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "local-title",
                      "title": "Needle planning",
                      "project_id": "project-1",
                      "last_message_at": 30,
                      "archived": false
                    },
                    {
                      "session_id": "content-project",
                      "title": "Budget",
                      "project_id": "project-1",
                      "last_message_at": 20,
                      "archived": false
                    },
                    {
                      "session_id": "content-other-project",
                      "title": "Roadmap",
                      "project_id": "project-2",
                      "last_message_at": 40,
                      "archived": false
                    },
                    {
                      "session_id": "archived-session",
                      "title": "Archived",
                      "project_id": "project-1",
                      "archived": true
                    }
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["q"], "needle")
                XCTAssertEqual(query["content"], "1")
                XCTAssertEqual(query["depth"], "5")

                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"session_id": "content-project", "title": "Budget", "match_type": "content"},
                    {"session_id": "content-other-project", "title": "Roadmap", "match_type": "content"},
                    {"session_id": "local-title", "title": "Needle planning", "match_type": "content"},
                    {"session_id": "unknown-session", "title": "Unknown", "match_type": "content"},
                    {"session_id": "archived-session", "title": "Archived", "match_type": "content"},
                    {"session_id": "title-only", "title": "Needle remote", "match_type": "title"}
                  ],
                  "query": "needle",
                  "count": 6
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        await viewModel.searchSessions(query: "needle", debounceNanoseconds: 0)

        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: "project-1").compactMap(\.sessionId),
            ["local-title", "content-project"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: "project-2").compactMap(\.sessionId),
            ["content-other-project"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "needle", selectedProjectID: nil).compactMap(\.sessionId),
            ["local-title", "content-other-project", "content-project"]
        )
    }

    @MainActor
    func testRemoteSessionSearchIgnoresStaleResultsWhenQueryChanges() async throws {
        let oldSearchStarted = expectation(description: "old search started")
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "old-content",
                      "title": "First result",
                      "archived": false
                    },
                    {
                      "session_id": "new-content",
                      "title": "Second result",
                      "archived": false
                    }
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                let searchQuery = query["q"] ?? ""

                if searchQuery == "old" {
                    oldSearchStarted.fulfill()
                    Thread.sleep(forTimeInterval: 0.15)
                    return apiTestJSONResponse("""
                    {
                      "sessions": [
                        {"session_id": "old-content", "title": "First result", "match_type": "content"}
                      ],
                      "query": "old",
                      "count": 1
                    }
                    """, for: request)
                }

                if searchQuery == "new" {
                    return apiTestJSONResponse("""
                    {
                      "sessions": [
                        {"session_id": "new-content", "title": "Second result", "match_type": "content"}
                      ],
                      "query": "new",
                      "count": 1
                    }
                    """, for: request)
                }

                XCTFail("Unexpected search query: \(searchQuery)")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let oldTask = Task {
            await viewModel.searchSessions(query: "old", debounceNanoseconds: 0)
        }
        await fulfillment(of: [oldSearchStarted], timeout: 1)

        await viewModel.searchSessions(query: "new", debounceNanoseconds: 0)
        await oldTask.value

        XCTAssertEqual(viewModel.remoteContentSearchSessionIDs, ["new-content"])
        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "new", selectedProjectID: nil).compactMap(\.sessionId),
            ["new-content"]
        )
    }

    // MARK: - Cron/CLI session classification (#256)

    func testCronSessionDetectedBySessionIdPrefix() {
        XCTAssertTrue(SessionSummary(sessionId: "cron_abc123").isCronSession)
        // Case-insensitive.
        XCTAssertTrue(SessionSummary(sessionId: "CRON_abc123").isCronSession)
    }

    func testCronSessionDetectedBySourceMarkers() {
        XCTAssertTrue(SessionSummary(sessionId: "s1", sourceTag: "cron").isCronSession)
        XCTAssertTrue(SessionSummary(sessionId: "s2", sessionSource: "cron").isCronSession)
        XCTAssertTrue(SessionSummary(sessionId: "s3", sourceLabel: "cron").isCronSession)
        // Tolerates surrounding whitespace / casing from the server.
        XCTAssertTrue(SessionSummary(sessionId: "s4", sourceTag: "  Cron  ").isCronSession)
    }

    func testNonCronSessionsAreNotFlagged() {
        // A `cron_` substring that is not a prefix must not match.
        XCTAssertFalse(SessionSummary(sessionId: "session_cron_x").isCronSession)
        // Plain WebUI session with no automation markers.
        XCTAssertFalse(SessionSummary(sessionId: "s5", sessionSource: "webui").isCronSession)
        // No source metadata at all (tolerant default → treated as normal).
        XCTAssertFalse(SessionSummary(sessionId: "s6").isCronSession)
    }

    func testDelegatedSubagentRequiresExplicitSourceMarker() {
        XCTAssertTrue(SessionSummary(sessionId: "s1", sourceTag: "subagent").isDelegatedSubagentSession)
        XCTAssertTrue(SessionSummary(sessionId: "s2", rawSource: " SubAgent ").isDelegatedSubagentSession)
        XCTAssertTrue(SessionSummary(sessionId: "s3", sessionSource: "subagent").isDelegatedSubagentSession)
        XCTAssertTrue(SessionSummary(sessionId: "s4", sourceLabel: "Subagent").isDelegatedSubagentSession)

        XCTAssertFalse(
            SessionSummary(
                sessionId: "fork",
                sourceTag: "fork",
                parentSessionId: "parent",
                relationshipType: "fork"
            ).isDelegatedSubagentSession
        )
        XCTAssertFalse(
            SessionSummary(
                sessionId: "continuation",
                sessionSource: "webui",
                parentSessionId: "parent",
                relationshipType: "compression_continuation"
            ).isDelegatedSubagentSession
        )
        XCTAssertFalse(SessionSummary(sessionId: "parent-only", parentSessionId: "parent").isDelegatedSubagentSession)
        XCTAssertFalse(SessionSummary(sessionId: "cron_1", sourceTag: "cron").isDelegatedSubagentSession)
        XCTAssertFalse(SessionSummary(sessionId: "cli", isCliSession: true).isDelegatedSubagentSession)
        XCTAssertFalse(SessionSummary(sessionId: "normal").isDelegatedSubagentSession)
    }

    func testClaudeCodeSessionRequiresExplicitSourceMetadata() {
        XCTAssertTrue(SessionSummary(sessionId: "s1", sourceTag: "claude_code").isClaudeCodeSession)
        XCTAssertTrue(
            SessionSummary(sessionId: "s2", rawSource: "  Claude_Code ").isClaudeCodeSession
        )

        XCTAssertFalse(
            SessionSummary(
                sessionId: "descriptive-only",
                title: "Claude Code session",
                model: "claude-sonnet",
                isCliSession: true,
                sessionSource: "claude_code",
                sourceLabel: "Claude Code"
            ).isClaudeCodeSession
        )
        XCTAssertFalse(SessionSummary(sessionId: "normal").isClaudeCodeSession)
    }

    func testReadOnlyRowsOfferExportButNoMutationActions() {
        let currentShape = SessionSummary(sessionId: "current", readOnly: true)
        let legacyShape = SessionSummary(sessionId: "legacy", isReadOnly: true)
        let normal = SessionSummary(sessionId: "normal")

        XCTAssertFalse(SessionRowActionPolicy.offersMutationActions(for: currentShape))
        XCTAssertFalse(SessionRowActionPolicy.offersMutationActions(for: legacyShape))
        XCTAssertFalse(
            SessionRowActionPolicy.offersMutationActions(
                for: SessionSummary(sessionId: "subagent", sourceTag: "subagent")
            )
        )
        XCTAssertTrue(SessionRowActionPolicy.offersMutationActions(for: normal))

        XCTAssertTrue(SessionRowActionPolicy.canExport(currentShape, isViewingCachedData: false))
        XCTAssertFalse(SessionRowActionPolicy.canExport(currentShape, isViewingCachedData: true))
        XCTAssertFalse(
            SessionRowActionPolicy.canExport(
                SessionSummary(sessionId: nil, readOnly: true),
                isViewingCachedData: false
            )
        )
    }

    func testAutomatedVisibilityShowAllKeepsEveryKind() {
        let visibility = AutomatedSessionVisibility.showAll
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "subagent", sourceTag: "subagent")))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    func testAutomatedVisibilityHidesSubagentsByDefaultAndShowsThemWhenEnabled() {
        let child = SessionSummary(sessionId: "subagent", sourceTag: "subagent")
        XCTAssertFalse(AutomatedSessionVisibility(showsCron: true, showsCli: true).shows(child))
        XCTAssertTrue(
            AutomatedSessionVisibility(
                showsCron: true,
                showsCli: true,
                showsSubagents: true
            ).shows(child)
        )
    }

    func testAutomatedVisibilityHidesCronIndependently() {
        let visibility = AutomatedSessionVisibility(showsCron: false, showsCli: true)
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "c1", sourceTag: "cron")))
        // CLI and normal sessions stay visible.
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    func testAutomatedVisibilityHidesCliIndependently() {
        let visibility = AutomatedSessionVisibility(showsCron: true, showsCli: false)
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        // Cron and normal sessions stay visible.
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    func testAutomatedVisibilityAppliesClaudeCodeChildPreferenceUnderCliParent() {
        let claudeCode = SessionSummary(
            sessionId: "claude-code",
            isCliSession: true,
            sourceTag: "claude_code"
        )
        let ordinaryCli = SessionSummary(sessionId: "ordinary-cli", isCliSession: true)

        let childHidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: false
        )
        XCTAssertFalse(childHidden.shows(claudeCode))
        XCTAssertTrue(childHidden.shows(ordinaryCli))

        let childShown = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: true
        )
        XCTAssertTrue(childShown.shows(claudeCode))

        let parentHidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: false,
            showsClaudeCode: true
        )
        XCTAssertFalse(parentHidden.shows(claudeCode))
        XCTAssertFalse(parentHidden.shows(ordinaryCli))
    }

    func testAutomatedVisibilityHidesBothKinds() {
        let visibility = AutomatedSessionVisibility(showsCron: false, showsCli: false)
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cron_1")))
        XCTAssertFalse(visibility.shows(SessionSummary(sessionId: "cli-1", isCliSession: true)))
        XCTAssertTrue(visibility.shows(SessionSummary(sessionId: "normal")))
    }

    @MainActor
    func testVisibleSessionsFiltersCronAndCliIndependently() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {"session_id": "normal-1", "title": "Normal one", "last_message_at": 50, "archived": false},
                {"session_id": "cron_job_1", "title": "Nightly digest", "last_message_at": 40, "archived": false},
                {"session_id": "tagged-cron", "title": "Tagged cron", "source_tag": "cron", "last_message_at": 30, "archived": false},
                {"session_id": "cli-1", "title": "CLI import", "is_cli_session": true, "last_message_at": 20, "archived": false},
                {"session_id": "normal-2", "title": "Normal two", "last_message_at": 10, "archived": false}
              ]
            }
            """, for: request)
        }

        await viewModel.load()

        // Default keeps every row.
        XCTAssertEqual(
            Set(viewModel.visibleSessions(searchText: "", selectedProjectID: nil).compactMap(\.sessionId)),
            ["normal-1", "cron_job_1", "tagged-cron", "cli-1", "normal-2"]
        )

        // Hiding cron only removes cron rows; CLI and normal rows stay.
        XCTAssertEqual(
            Set(viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: nil,
                automatedVisibility: AutomatedSessionVisibility(showsCron: false, showsCli: true)
            ).compactMap(\.sessionId)),
            ["normal-1", "cli-1", "normal-2"]
        )

        // Hiding CLI only removes the CLI row; cron and normal rows stay.
        XCTAssertEqual(
            Set(viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: nil,
                automatedVisibility: AutomatedSessionVisibility(showsCron: true, showsCli: false)
            ).compactMap(\.sessionId)),
            ["normal-1", "cron_job_1", "tagged-cron", "normal-2"]
        )

        // Hiding both leaves only the normal WebUI sessions, newest first.
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: nil,
                automatedVisibility: AutomatedSessionVisibility(showsCron: false, showsCli: false)
            ).compactMap(\.sessionId),
            ["normal-1", "normal-2"]
        )
    }

    @MainActor
    func testVisibleSessionsFiltersSubagentsAcrossSearchAndProjects() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"session_id": "normal-p1", "title": "Planning", "project_id": "p1", "last_message_at": 40},
                    {"session_id": "subagent-p1", "title": "Delegated research", "project_id": "p1", "source_tag": "subagent", "read_only": true, "last_message_at": 30},
                    {"session_id": "fork-p1", "title": "Ordinary fork", "project_id": "p1", "parent_session_id": "normal-p1", "relationship_type": "fork", "last_message_at": 20},
                    {"session_id": "normal-p2", "title": "Other project", "project_id": "p2", "last_message_at": 10}
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"session_id": "subagent-p1", "title": "Delegated research", "match_type": "content"},
                    {"session_id": "normal-p2", "title": "Other project", "match_type": "content"}
                  ],
                  "query": "needle",
                  "count": 2
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let hidden = AutomatedSessionVisibility(showsCron: true, showsCli: true)
        let shown = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsSubagents: true
        )

        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["normal-p1", "fork-p1"]
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: "p1",
                automatedVisibility: shown
            ).compactMap(\.sessionId),
            ["normal-p1", "subagent-p1", "fork-p1"]
        )
        XCTAssertTrue(
            viewModel.visibleSessions(
                searchText: "delegated",
                selectedProjectID: nil,
                automatedVisibility: hidden
            ).isEmpty
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "delegated",
                selectedProjectID: nil,
                automatedVisibility: shown
            ).compactMap(\.sessionId),
            ["subagent-p1"]
        )

        await viewModel.searchSessions(query: "needle", debounceNanoseconds: 0)

        XCTAssertTrue(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).isEmpty
        )
        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: "p1",
                automatedVisibility: shown
            ).compactMap(\.sessionId),
            ["subagent-p1"]
        )
    }

    @MainActor
    func testVisibleSessionsFiltersClaudeCodeAcrossSearchAndProjects() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/sessions":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"session_id": "normal-p1", "title": "Planning", "project_id": "p1", "last_message_at": 40},
                    {"session_id": "claude-p1", "title": "Imported transcript", "project_id": "p1", "source_tag": "claude_code", "raw_source": "claude_code", "is_cli_session": true, "read_only": true, "last_message_at": 30},
                    {"session_id": "cli-p1", "title": "Terminal chat", "project_id": "p1", "source_tag": "cli", "is_cli_session": true, "last_message_at": 20},
                    {"session_id": "normal-p2", "title": "Other project", "project_id": "p2", "last_message_at": 10}
                  ]
                }
                """, for: request)
            case "/api/sessions/search":
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {"session_id": "claude-p1", "title": "Imported transcript", "match_type": "content"},
                    {"session_id": "cli-p1", "title": "Terminal chat", "match_type": "content"}
                  ],
                  "query": "needle",
                  "count": 2
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.load()
        let hidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: false
        )

        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "",
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["normal-p1", "cli-p1"]
        )

        await viewModel.searchSessions(query: "needle", debounceNanoseconds: 0)

        XCTAssertEqual(
            viewModel.visibleSessions(
                searchText: "needle",
                selectedProjectID: "p1",
                automatedVisibility: hidden
            ).compactMap(\.sessionId),
            ["cli-p1"]
        )
    }

    @MainActor
    private func makeViewModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> SessionListViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = try makeClient(server: server, handler: handler)

        return SessionListViewModel(server: server, client: client)
    }

    private func makeClient(
        server: URL? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let resolvedServer: URL
        if let server {
            resolvedServer = server
        } else {
            resolvedServer = try XCTUnwrap(URL(string: "https://example.test"))
        }

        return APIClient(baseURL: resolvedServer, session: session)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    @MainActor
    private func makeArchivedViewModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ArchivedSessionsViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: session)

        return ArchivedSessionsViewModel(server: server, client: client)
    }

    private func sessionListJSON(forLoadCount loadCount: Int) -> String {
        switch loadCount {
        case 2:
            return """
            {
              "sessions": [
                {
                  "session_id": "session-abc",
                  "title": "Planning",
                  "pinned": true,
                  "archived": false
                }
              ]
            }
            """
        case 3:
            return """
            {
              "sessions": [
                {
                  "session_id": "session-abc",
                  "title": "Planning",
                  "pinned": true,
                  "archived": true
                }
              ]
            }
            """
        case 4:
            return """
            {
              "sessions": [
                {
                  "session_id": "session-abc",
                  "title": "Planning",
                  "project_id": "project-1",
                  "archived": false
                }
              ]
            }
            """
        case 5:
            return """
            {
              "sessions": []
            }
            """
        default:
            return """
            {
              "sessions": [
                {
                  "session_id": "session-abc",
                  "title": "Planning",
                  "pinned": false,
                  "archived": false
                }
              ]
            }
            """
        }
    }

    private func archivedSessionListJSON() -> String {
        """
        {
          "sessions": [
            {
              "session_id": "session-abc",
              "title": "Planning",
              "archived": true
            },
            {
              "session_id": "session-def",
              "title": "Research",
              "archived": true
            },
            {
              "session_id": "session-active",
              "title": "Visible in main list",
              "archived": false
            }
          ]
        }
        """
    }

    private func makeSessionSummary(
        id: String,
        title: String,
        pinned: Bool,
        archived: Bool
    ) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "\(id)",
              "title": "\(title)",
              "pinned": \(pinned),
              "archived": \(archived)
            }
            """.utf8)
        )
    }
}

private final class LockedSessionMutationRequestCounts {
    private let lock = NSLock()
    private var loadRequestCount = 0
    private var pinMutationRequestCount = 0

    func incrementLoadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }

        loadRequestCount += 1
        return loadRequestCount
    }

    func incrementPinRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }

        pinMutationRequestCount += 1
        return pinMutationRequestCount
    }

    var snapshot: (loadCount: Int, pinRequestCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        return (loadRequestCount, pinMutationRequestCount)
    }
}
