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
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["session_id"] as? String, "telegram-1")

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
        let request = try HermesREST.updateSession(key: "20261005_101500_a1b2c3", profile: "research", change: .unread(false),
                                                   identity: nil).request(base: URL(string: "https://hermes.example")!)

        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/sessions/20261005_101500_a1b2c3")
        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: try XCTUnwrap(request.httpBody)),
                       .object(["unread": .bool(false), "profile": .string("research")]))
        XCTAssertThrowsError(try HermesREST.updateSession(key: "../profiles", profile: "research", change: .unread(true),
                                                          identity: nil).request(base: URL(string: "https://hermes.example")!), "an id never names another route")
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
