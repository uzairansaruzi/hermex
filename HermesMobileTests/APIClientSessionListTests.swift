import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSessionListTests: APIClientTestCase {
    func testImportExternalSessionPostsSessionIDAndDecodesSourceMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/import_cli")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json, ["session_id": "telegram-1"])

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "telegram-1",
                "title": "Support chat",
                "is_cli_session": true,
                "raw_source": "telegram",
                "session_source": "messaging",
                "source_label": "Telegram",
                "read_only": false
              },
              "imported": true
            }
            """, for: request)
        }

        let response = try await client.importExternalSession(id: "telegram-1")

        XCTAssertEqual(response.session?.sessionId, "telegram-1")
        XCTAssertEqual(response.session?.sourceLabel, "Telegram")
        XCTAssertEqual(response.session?.readOnly, false)
    }

    func testSessionsDecodesSnakeCaseResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            // The default fetch must stay parameterless so the main list request
            // (and its server-side ordering) is unchanged (issue #17).
            XCTAssertNil(request.url?.query)

            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "abc123",
                  "title": "Planning",
                  "message_count": 7,
                  "last_message_at": 1770000000,
                  "pinned": true,
                  "archived": false
                }
              ],
              "cli_count": 2,
              "archived_count": 8,
              "server_time": 1770000001,
              "server_tz": "-0400"
            }
            """, for: request)
        }

        let response = try await client.sessions()

        XCTAssertEqual(response.sessions?.first?.sessionId, "abc123")
        XCTAssertEqual(response.sessions?.first?.title, "Planning")
        XCTAssertEqual(response.sessions?.first?.messageCount, 7)
        XCTAssertEqual(response.sessions?.first?.lastMessageAt, 1_770_000_000)
        XCTAssertEqual(response.sessions?.first?.pinned, true)
        XCTAssertEqual(response.cliCount, 2)
        XCTAssertEqual(response.archivedCount, 8)
    }

    func testSessionsDecodesDelegationAndReadOnlyMetadataTolerantly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions")
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "subagent-child",
                  "source_tag": "subagent",
                  "raw_source": "subagent",
                  "session_source": "other",
                  "source_label": "Subagent",
                  "parent_session_id": "parent-1",
                  "relationship_type": "child_session",
                  "read_only": true
                },
                {
                  "session_id": "legacy-read-only",
                  "is_read_only": true
                },
                {
                  "session_id": "older-server-row"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.sessions()
        let sessions = try XCTUnwrap(response.sessions)
        let child = try XCTUnwrap(sessions.first)

        XCTAssertEqual(child.sourceTag, "subagent")
        XCTAssertEqual(child.rawSource, "subagent")
        XCTAssertEqual(child.sessionSource, "other")
        XCTAssertEqual(child.sourceLabel, "Subagent")
        XCTAssertEqual(child.parentSessionId, "parent-1")
        XCTAssertEqual(child.relationshipType, "child_session")
        XCTAssertEqual(child.readOnly, true)
        XCTAssertNil(child.isReadOnly)
        XCTAssertTrue(child.isDelegatedSubagentSession)
        XCTAssertTrue(child.isSessionReadOnly)

        XCTAssertTrue(sessions[1].isSessionReadOnly)
        XCTAssertNil(sessions[2].sourceTag)
        XCTAssertNil(sessions[2].parentSessionId)
        XCTAssertNil(sessions[2].readOnly)
        XCTAssertFalse(sessions[2].isDelegatedSubagentSession)
        XCTAssertFalse(sessions[2].isSessionReadOnly)
    }

    func testSessionsIncludeArchivedBuildsQueryAndDecodesMergedRows() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["include_archived": "1", "archived_limit": "50"])

            // include_archived=1 merges archived rows into the visible list;
            // each row carries an `archived` flag (upstream routes.py @312d3fab).
            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "visible-1",
                  "title": "Visible",
                  "archived": false
                },
                {
                  "session_id": "archived-1",
                  "title": "Old research",
                  "archived": true
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.sessions(includeArchived: true, archivedLimit: 50)

        XCTAssertEqual(response.sessions?.compactMap(\.sessionId), ["visible-1", "archived-1"])
        XCTAssertEqual(response.sessions?.last?.archived, true)
        // Tolerant decoding: an older server that omits archived_count still decodes.
        XCTAssertNil(response.archivedCount)
    }

    func testSessionSearchRequestBuildsExpectedQueryAndDecodesContentMatch() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/search")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["q"], "billing plan")
            XCTAssertEqual(query["content"], "1")
            XCTAssertEqual(query["depth"], "5")

            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "content-123",
                  "title": "Planning",
                  "match_type": "content",
                  "match_preview": "...we compared the billing plan tiers...",
                  "unexpected": "ignored"
                }
              ],
              "query": "billing plan",
              "count": 1
            }
            """, for: request)
        }

        let response = try await client.searchSessions(query: "billing plan", content: true, depth: 5)

        XCTAssertEqual(response.query, "billing plan")
        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(response.sessions?.first?.sessionId, "content-123")
        XCTAssertEqual(response.sessions?.first?.matchType, "content")
        XCTAssertEqual(response.sessions?.first?.matchPreview, "...we compared the billing plan tiers...")
    }

    func testSessionSearchDecodesEmptyQueryResponseWithoutQueryOrCount() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/search")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["q"], "")
            XCTAssertEqual(query["content"], "1")
            XCTAssertEqual(query["depth"], "5")

            return apiTestJSONResponse("""
            {
              "sessions": [
                {
                  "session_id": "abc123",
                  "title": "Planning"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.searchSessions(query: "", content: true, depth: 5)

        XCTAssertEqual(response.sessions?.first?.sessionId, "abc123")
        XCTAssertNil(response.sessions?.first?.matchType)
        // A server older than `_session_search_preview` omits match_preview.
        XCTAssertNil(response.sessions?.first?.matchPreview)
        XCTAssertNil(response.query)
        XCTAssertNil(response.count)
    }
    /// One malformed row used to fail the whole array, so a single CLI or
    /// subagent session with a drifted field emptied the entire list and
    /// pull-to-refresh could never bring it back. Rows are decoded
    /// independently and each field is lossy, matching `SessionDetail` and
    /// `ProjectSummary`, which already worked this way.
    func testSessionListSurvivesOneMalformedRow() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {"sessions": [
              {"session_id": "good-1", "title": "Fine", "message_count": 3},
              {"session_id": "drifted", "title": "Odd", "message_count": "12", "created_at": "not-a-number"},
              {"session_id": 42},
              {"title": "Missing server identity"},
              {"session_id": "   ", "title": "Blank server identity"},
              {"session_id": "good-2", "title": "Also fine"}
            ]}
            """, for: request)
        }

        let response = try await client.sessions()
        let ids = (response.sessions ?? []).compactMap(\.sessionId)

        XCTAssertEqual(response.sessions?.count, 6)
        XCTAssertEqual(ids, ["good-1", "drifted", "42", "   ", "good-2"])
        XCTAssertNil(response.sessions?[3].sessionId)
        XCTAssertEqual(response.sessions?[4].sessionId, "   ")
        XCTAssertEqual(
            response.sessions?.first(where: { $0.sessionId == "drifted" })?.messageCount,
            12,
            "A numeric string still reads as a count."
        )
        XCTAssertEqual(
            response.sessions?.first(where: { $0.sessionId == "42" })?.sessionId,
            "42",
            "A numeric id is coerced rather than dropped."
        )
    }

    func testSessionsAllProfilesQueryAndOtherProfileCount() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["all_profiles": "1"])
            return apiTestJSONResponse("""
            {
              "sessions": [{ "session_id": "other-1", "title": "On builder" }],
              "other_profile_count": 0,
              "active_profile": "default",
              "all_profiles": true
            }
            """, for: request)
        }

        let response = try await client.sessions(allProfiles: true)
        XCTAssertEqual(response.sessions?.first?.sessionId, "other-1")
        XCTAssertEqual(response.otherProfileCount, 0)
        XCTAssertEqual(response.activeProfile, "default")
        XCTAssertEqual(response.allProfiles, true)
    }

    /// The active profile can be empty while other profiles hold the conversations
    /// (`other_profile_count`). Both the phone list and the watch backend go
    /// through `sidebarSessions`, so one refetch covers both surfaces.
    func testSidebarSessionsRefetchesAllProfilesWhenTheActiveProfileIsEmpty() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if query["all_profiles"] == "1" {
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    { "session_id": "builder-1", "title": "Watch layout", "message_count": 4 }
                  ],
                  "other_profile_count": 0,
                  "all_profiles": true
                }
                """, for: request)
            }
            XCTAssertTrue(query.isEmpty)
            return apiTestJSONResponse("""
            {
              "sessions": [],
              "other_profile_count": 6,
              "active_profile": "default"
            }
            """, for: request)
        }

        let response = try await client.sidebarSessions()
        XCTAssertEqual(response.sessions?.compactMap(\.sessionId), ["builder-1"])
        XCTAssertEqual(response.allProfiles, true)
    }

    func testSidebarSessionsKeepsTheActiveProfileWhenItAlreadyHasRows() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertNil(components?.query)
            return apiTestJSONResponse("""
            {
              "sessions": [{ "session_id": "here", "title": "Planning", "message_count": 2 }],
              "other_profile_count": 4
            }
            """, for: request)
        }

        let response = try await client.sidebarSessions()
        XCTAssertEqual(response.sessions?.first?.sessionId, "here")
        XCTAssertEqual(response.otherProfileCount, 4)
        XCTAssertNil(response.allProfiles)
    }

    /// Servers that omit `other_profile_count` used to skip the all-profiles
    /// refetch, so an empty Default page stayed empty.
    func testSidebarSessionsRefetchesAllProfilesWhenTheHiddenCountIsMissing() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if query["all_profiles"] == "1" {
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    { "session_id": "other-titled", "title": "Ship the watch", "message_count": 3 }
                  ],
                  "all_profiles": true
                }
                """, for: request)
            }
            XCTAssertTrue(query.isEmpty)
            return apiTestJSONResponse("""
            {
              "sessions": [],
              "active_profile": "default"
            }
            """, for: request)
        }

        let response = try await client.sidebarSessions()
        XCTAssertEqual(response.sessions?.compactMap(\.sessionId), ["other-titled"])
        XCTAssertEqual(response.sessions?.first?.title, "Ship the watch")
        XCTAssertNil(response.otherProfileCount)
        XCTAssertEqual(response.allProfiles, true)
    }

    func testSidebarSessionsDoesNotRefetchWhenTheServerCountsZeroHiddenRows() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertNil(components?.queryItems?.first { $0.name == "all_profiles" })
            return apiTestJSONResponse("""
            {
              "sessions": [],
              "other_profile_count": 0,
              "active_profile": "default"
            }
            """, for: request)
        }

        let response = try await client.sidebarSessions(revealAgentSessions: false)
        XCTAssertEqual(response.sessions ?? [], [])
        XCTAssertEqual(response.otherProfileCount, 0)
        XCTAssertNil(response.allProfiles)
    }

    /// Hermes desktop keeps chats in the agent database. WebUI hides that
    /// database until `show_cli_sessions` is on, which defaults off, so an
    /// empty sidebar is not the same thing as "no sessions yet".
    func testSidebarSessionsOpensTheAgentSessionGateWhenThePageIsEmpty() async throws {
        var calls: [String] = []
        let client = makeClient { request in
            let path = try XCTUnwrap(request.url).path
            let method = request.httpMethod ?? "GET"
            calls.append("\(method) \(path)")

            if path == "/api/settings", method == "POST" {
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
                XCTAssertEqual(json["show_cli_sessions"], true)
                return apiTestJSONResponse(#"{"show_cli_sessions": true}"#, for: request)
            }
            if path == "/api/settings" {
                return apiTestJSONResponse(#"{"show_cli_sessions": false}"#, for: request)
            }

            let sessionGets = calls.filter { $0 == "GET /api/sessions" }.count
            if sessionGets >= 2 {
                return apiTestJSONResponse("""
                {
                  "sessions": [
                    {
                      "session_id": "20260930_032120_ed17d8",
                      "title": "Desktop chat",
                      "message_count": 12,
                      "is_cli_session": true,
                      "session_source": "desktop"
                    }
                  ],
                  "other_profile_count": 0,
                  "cli_count": 1
                }
                """, for: request)
            }
            return apiTestJSONResponse("""
            {
              "sessions": [],
              "other_profile_count": 0,
              "active_profile": "default",
              "all_profiles": false
            }
            """, for: request)
        }

        let response = try await client.sidebarSessions()

        XCTAssertEqual(response.sessions?.map(\.sessionId), ["20260930_032120_ed17d8"])
        XCTAssertEqual(response.sessions?.first?.messageCount, 12)
        XCTAssertEqual(response.cliCount, 1)
        XCTAssertEqual(calls, [
            "GET /api/sessions",
            "GET /api/settings",
            "POST /api/settings",
            "GET /api/sessions"
        ])
    }

    func testSidebarSessionsRestoresTheAgentSessionGateWhenNothingWasHidden() async throws {
        var posted: [Bool] = []
        let client = makeClient { request in
            let path = try XCTUnwrap(request.url).path
            let method = request.httpMethod ?? "GET"
            if path == "/api/settings", method == "POST" {
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
                let enabled = try XCTUnwrap(json["show_cli_sessions"])
                posted.append(enabled)
                return apiTestJSONResponse(
                    #"{"show_cli_sessions": \#(enabled)}"#,
                    for: request
                )
            }
            if path == "/api/settings" {
                return apiTestJSONResponse(#"{"show_cli_sessions": false}"#, for: request)
            }
            return apiTestJSONResponse("""
            {
              "sessions": [],
              "other_profile_count": 0
            }
            """, for: request)
        }

        let response = try await client.sidebarSessions()

        XCTAssertEqual(response.sessions ?? [], [])
        XCTAssertEqual(posted, [true, false])
    }

    func testSidebarSessionsRestoresTheAgentSessionGateWhenTheRefetchFails() async throws {
        var sessionGets = 0
        var posted: [Bool] = []
        let client = makeClient { request in
            let path = try XCTUnwrap(request.url).path
            let method = request.httpMethod ?? "GET"
            if path == "/api/settings", method == "POST" {
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
                let enabled = try XCTUnwrap(json["show_cli_sessions"])
                posted.append(enabled)
                return apiTestJSONResponse(
                    #"{"show_cli_sessions": \#(enabled)}"#,
                    for: request
                )
            }
            if path == "/api/settings" {
                return apiTestJSONResponse(#"{"show_cli_sessions": false}"#, for: request)
            }
            sessionGets += 1
            if sessionGets >= 2 {
                return apiTestJSONResponse(#"{"detail":"unavailable"}"#, for: request, status: 500)
            }
            return apiTestJSONResponse("""
            {
              "sessions": [],
              "other_profile_count": 0
            }
            """, for: request)
        }

        let response = try await client.sidebarSessions()

        XCTAssertEqual(response.sessions ?? [], [])
        XCTAssertEqual(posted, [true, false])
    }

    func testDisplayTitleKeepsAZeroMessageRowAndAttentionObjectCounts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "goal-1",
              "title": "Untitled",
              "display_title": "Ship the watch",
              "message_count": 0,
              "attention": { "kind": "clarify", "count": 1, "severity": "question" }
            }
            """.utf8)
        )

        XCTAssertEqual(session.title, "Ship the watch")
        XCTAssertTrue(session.shouldAppearInSessionList)
        XCTAssertEqual(session.attentionCount, 1)
        XCTAssertTrue(session.signalsAttention)
        XCTAssertTrue(session.belongsOnSidebar(includeArchived: false))
    }

    // MARK: Hermes (#1046)

    /// The Sessions list sends every list parameter: the host's defaults order by creation,
    /// list empty sessions and keep machine-run sources.
    func testHermesSessionListNamesEveryListParameter() throws {
        let request = try HermesREST.sessionList(profile: "research", offset: 200)
            .request(base: URL(string: "https://hermes.example")!)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/sessions")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), [
            "profile": "research", "order": "recent", "archived": "exclude", "limit": "100", "offset": "200",
            "min_messages": "1", "exclude_sources": "cron,kanban,oneshot,subagent,tool"
        ])
    }

    /// A read mark goes to the session's own id under its Profile, and nothing else is sent.
    func testHermesReadMarkPatchesOnlyUnreadAndTheProfile() throws {
        let request = try HermesREST.updateSession(key: "20261005_101500_a1b2c3", profile: "research", change: .unread(false))
            .request(base: URL(string: "https://hermes.example")!)

        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/sessions/20261005_101500_a1b2c3")
        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: try XCTUnwrap(request.httpBody)),
                       .object(["unread": .bool(false), "profile": .string("research")]))
        XCTAssertThrowsError(try HermesREST.updateSession(key: "../profiles", profile: "research", change: .unread(true))
            .request(base: URL(string: "https://hermes.example")!), "an id never names another route")
    }

    /// A page in the 0.21.5 shape: unknown and missing fields are fine, a row without an id is
    /// skipped but still counts toward the page's length, and `total` is never read.
    func testHermesSessionPageDecodesTolerantlyAndSkipsAnUnreadableRow() throws {
        let page = try JSONDecoder().decode(HermesSessionPage.self, from: Data("""
        {"sessions": [
          {"id": "20261005_101500_a1b2c3", "title": "Plan the launch", "preview": "Help me plan...",
           "last_active": 1791200000.5, "started_at": 1791190000.0, "pinned": true, "archived": false,
           "unread": true, "model": "stub", "cwd": "/Users/someone/work", "message_count": 4,
           "profile": "research", "parent_session_id": null, "_lineage_root_id": "20261001_090000_root01",
           "_lineage_ids": ["20261001_090000_root01"], "billing_mode": null, "hidden": 0, "future_field": {"x": 1}},
          {"id": "20261005_111500_d4e5f6"},
          {"title": "A row without an id"},
          "not a row"
        ], "total": 500, "limit": 100, "offset": 0, "storage": {}}
        """.utf8))

        XCTAssertEqual(page.count, 4)
        XCTAssertEqual(page.rows.map(\.id), ["20261005_101500_a1b2c3", "20261005_111500_d4e5f6"])
        XCTAssertEqual(page.rows[0], HermesSessionRow(
            id: "20261005_101500_a1b2c3", title: "Plan the launch", preview: "Help me plan...", lastActive: 1791200000.5,
            startedAt: 1791190000.0, pinned: true, archived: false, unread: true, hidden: false, model: "stub", cwd: "/Users/someone/work",
            messageCount: 4, profile: "research", parentSessionID: nil, lineageRootID: "20261001_090000_root01"
        ))
        XCTAssertEqual(page.rows[1], HermesSessionRow(id: "20261005_111500_d4e5f6"))
        var pages = HermesSessionPages()
        pages.append(page)
        XCTAssertFalse(pages.hasMore, "four rows is a short page, whatever `total` says")
        XCTAssertThrowsError(try JSONDecoder().decode(HermesSessionPage.self, from: Data(#"{"detail": "busy"}"#.utf8)),
                             "a reply without its list is a failed read, not an empty Profile")
    }
}
