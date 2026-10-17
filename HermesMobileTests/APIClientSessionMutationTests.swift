import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSessionMutationTests: APIClientTestCase {
    func testPostRequestsEncodeSnakeCaseBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/pin")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["pinned"] as? Bool, false)
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "pinned": false
              }
            }
            """, for: request)
        }

        let response = try await client.pinSession(id: "abc123", pinned: false)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(response.session?.pinned, false)
    }

    func testBranchSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/branch")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["title"] as? String, "Planning (copy)")
            XCTAssertNil(json?["keep_count"])
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "session_id": "copy123",
              "title": "Planning (copy)",
              "parent_session_id": "abc123"
            }
            """, for: request)
        }

        let response = try await client.branchSession(id: "abc123", title: "Planning (copy)")

        XCTAssertEqual(response.sessionId, "copy123")
        XCTAssertEqual(response.title, "Planning (copy)")
        XCTAssertEqual(response.parentSessionId, "abc123")
    }

    func testBranchSessionIncludesKeepCountForMessageFork() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/branch")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["keep_count"] as? Int, 29)
            XCTAssertNil(json?["title"])
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "session_id": "fork123",
              "title": "Planning (fork)",
              "parent_session_id": "abc123"
            }
            """, for: request)
        }

        let response = try await client.branchSession(id: "abc123", keepCount: 29)

        XCTAssertEqual(response.sessionId, "fork123")
        XCTAssertEqual(response.title, "Planning (fork)")
        XCTAssertEqual(response.parentSessionId, "abc123")
    }

    func testCompressSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/compress")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["focus_topic"] as? String, "architecture notes")
            XCTAssertNil(json?["sessionId"])
            XCTAssertNil(json?["focusTopic"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "focus_topic": "architecture notes",
              "summary": {
                "headline": "Compressed: 8 -> 3 messages",
                "token_line": "Rough transcript estimate: ~1200 -> ~320 tokens",
                "reference_message": "[CONTEXT COMPACTION] Compression completed."
              },
              "session": {
                "session_id": "abc123",
                "title": "Planning",
                "messages": []
              }
            }
            """, for: request)
        }

        let response = try await client.compressSession(id: "abc123", focusTopic: "architecture notes")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.focusTopic, "architecture notes")
        XCTAssertEqual(response.summary?.headline, "Compressed: 8 -> 3 messages")
        XCTAssertEqual(response.summary?.tokenLine, "Rough transcript estimate: ~1200 -> ~320 tokens")
        XCTAssertEqual(response.summary?.referenceMessage, "[CONTEXT COMPACTION] Compression completed.")
        XCTAssertEqual(response.session?.sessionId, "abc123")
    }

    func testCompressionSummaryExtractsCompressedTokenEstimate() {
        let arrowSummary = SessionCompressionSummary(
            headline: "Compressed: 20 -> 10 messages",
            tokenLine: "Approx request size: ~30,100 \u{2192} ~10,347 tokens",
            note: nil,
            referenceMessage: nil
        )
        let asciiSummary = SessionCompressionSummary(
            headline: nil,
            tokenLine: "Rough transcript estimate: ~1200 -> ~320 tokens",
            note: nil,
            referenceMessage: nil
        )

        XCTAssertEqual(arrowSummary.compressedTokenEstimate, 10_347)
        XCTAssertEqual(asciiSummary.compressedTokenEstimate, 320)
    }

    func testClearSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/clear")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "title": "Untitled"
              }
            }
            """, for: request)
        }

        let response = try await client.clearSession(id: "abc123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.title, "Untitled")
    }

    func testUndoSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/undo")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "removed_count": 2,
              "removed_preview": "Summarize the logs"
            }
            """, for: request)
        }

        let response = try await client.undoSession(id: "abc123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.removedCount, 2)
        XCTAssertEqual(response.removedPreview, "Summarize the logs")
    }

    func testRetrySessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/retry")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertNil(json?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "last_user_text": "Summarize the logs",
              "removed_count": 2
            }
            """, for: request)
        }

        let response = try await client.retrySession(id: "abc123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.lastUserText, "Summarize the logs")
        XCTAssertEqual(response.removedCount, 2)
    }

    func testSessionMetadataRequestOmitsMessageLimitWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "copy123")
            XCTAssertEqual(query["messages"], "0")
            XCTAssertNil(query["msg_limit"])

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "copy123",
                "title": "Planning (copy)",
                "message_count": 4
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "copy123", includeMessages: false, messageLimit: nil)

        XCTAssertEqual(response.session?.sessionId, "copy123")
        XCTAssertEqual(response.session?.title, "Planning (copy)")
        XCTAssertEqual(response.session?.messageCount, 4)
    }

    func testMoveSessionBuildsExpectedBodyAndDecodesMovedSession() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/move")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["project_id"] as? String, "proj123")
            XCTAssertNil(json?["sessionId"])
            XCTAssertNil(json?["projectId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "project_id": "proj123"
              }
            }
            """, for: request)
        }

        let response = try await client.moveSession(id: "abc123", projectID: "proj123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(response.session?.projectId, "proj123")
    }

    func testMoveSessionToNoProjectOmitsProjectID() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/move")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertNil(json?["project_id"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "project_id": null
              }
            }
            """, for: request)
        }

        let response = try await client.moveSession(id: "abc123", projectID: nil)

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.session?.projectId)
    }

    func testSessionMutatorMove503WithServerPayloadMapsToStreamingBusyError() async throws {
        // Upstream refuses a move while the session streams: 503 + JSON error payload.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/move")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error": "Session is busy (streaming). Please try again in a moment."}"#.utf8))
        }

        do {
            try await SessionMutator(client: client).move(sessionID: "abc123", to: "proj123")
            XCTFail("Expected SessionMoveWhileStreamingError")
        } catch is SessionMoveWhileStreamingError {
            XCTAssertEqual(
                SessionMoveWhileStreamingError().errorDescription,
                String(localized: "This session is still responding, so it can't be moved yet. Try again when it finishes.")
            )
        }
    }

    func testSessionMutatorMoveProxy503WithoutJSONPayloadKeepsGenericAPIError() async throws {
        // A tunnel/proxy 503 serves HTML, not the server's JSON payload; keep the
        // generic connectivity message for that case (issue #25).
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>Service Unavailable</html>".utf8))
        }

        do {
            try await SessionMutator(client: client).move(sessionID: "abc123", to: nil)
            XCTFail("Expected APIError.http(503)")
        } catch let error as APIError {
            guard case .http(let statusCode, _) = error else {
                return XCTFail("Expected APIError.http, got \(error)")
            }
            XCTAssertEqual(statusCode, 503)
        }
    }

    func testArchiveSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/archive")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["session_id"] as? String, "abc123")
            XCTAssertEqual(json?["archived"] as? Bool, true)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "session": {
                "session_id": "abc123",
                "archived": true
              }
            }
            """, for: request)
        }

        let response = try await client.archiveSession(id: "abc123", archived: true)

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.session?.archived, true)
    }

    func testTruncateSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/truncate")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["keep_count"] as? Int, 3)

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "My chat",
                "messages": [
                  {"role": "user", "content": "Hello", "message_id": "m1"},
                  {"role": "assistant", "content": "Hi there", "message_id": "m2"},
                  {"role": "user", "content": "Thanks", "message_id": "m3"}
                ],
                "_messages_offset": 0
              }
            }
            """, for: request)
        }

        let response = try await client.truncateSession(id: "session-abc", keepCount: 3)

        XCTAssertEqual(response.session?.sessionId, "session-abc")
        XCTAssertEqual(response.session?.messages?.count, 3)
        XCTAssertEqual(response.session?.messagesOffset, 0)
    }

    // MARK: Hermes (#1048)

    /// Each change PATCHes one field of that session, with its Profile in the body, as the
    /// host's `SessionRename` takes it. A host from before the write fence (#1300) answers the
    /// snapshot read 404, so its PATCH carries no write identity.
    @MainActor
    func testHermesSessionChangesPatchOneFieldWithTheProfileInTheBody() async throws {
        var patches: [(path: String, body: BotJSON)] = []
        let client = try await hermesClient { request in
            guard request.httpMethod == "PATCH", let path = request.url?.path else { return nil }
            patches.append((path, Self.hermesBody(request)))
            return .json(200, .object(["ok": .bool(true), "title": .string("Plan the launch")]))
        }

        try await client.updateSession(.pinned(true), key: "20261005_101500_a1b2c3", profile: "research")
        try await client.updateSession(.archived(false), key: "20261005_101500_a1b2c3", profile: "research")
        let kept = try await client.updateSession(.title("Plan the launch"), key: "20261005_101500_a1b2c3", profile: "research")

        XCTAssertEqual(kept, "Plan the launch")
        XCTAssertEqual(patches.map(\.path), Array(repeating: "/api/sessions/20261005_101500_a1b2c3", count: 3))
        XCTAssertEqual(patches.map(\.body), [
            .object(["pinned": .bool(true), "profile": .string("research")]),
            .object(["archived": .bool(false), "profile": .string("research")]),
            .object(["title": .string("Plan the launch"), "profile": .string("research")])
        ])
    }

    /// Behind the write fence (#1300) each PATCH carries its own request id and the revision the
    /// snapshot read just before it, and never `expected_generation`.
    @MainActor
    func testHermesFencedSessionChangeCarriesTheSnapshotsRevision() async throws {
        var revision = 12
        var patches: [BotJSON] = []
        let client = try await hermesClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions/tip/mutation-snapshot"):
                return .json(200, .object(["session_id": .string("tip"), "exists": .bool(true),
                                           "runtime_revision": .number(Double(revision)), "runtime_generation": .number(3)]))
            case ("PATCH", "/api/sessions/tip"):
                patches.append(Self.hermesBody(request))
                revision += 5
                return .json(200, .object(["ok": .bool(true)]))
            default: return nil
            }
        }

        try await client.updateSession(.archived(true), key: "tip", profile: "research")
        try await client.updateSession(.pinned(true), key: "tip", profile: "research")

        XCTAssertEqual(patches.map { $0["expected_revision"] }, [.number(12), .number(17)])
        let ids = patches.compactMap { $0["request_id"].text }
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(patches.map { $0["expected_generation"] }, [.null, .null])
    }

    /// Headless `hermes serve` from before the fence answers the snapshot read with its own
    /// catch-all, so its PATCH also goes out bare.
    @MainActor
    func testHermesHeadlessServeHostTakesTheChangeBare() async throws {
        var patch = BotJSON.null
        let client = try await hermesClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions/tip/mutation-snapshot"):
                return .json(404, .object(["error": .string("Headless backend (hermes serve): web UI disabled")]))
            case ("PATCH", "/api/sessions/tip"):
                patch = Self.hermesBody(request)
                return .json(200, .object(["ok": .bool(true)]))
            default: return nil
            }
        }

        try await client.updateSession(.pinned(true), key: "tip", profile: "default")

        XCTAssertEqual(patch["pinned"], .bool(true))
        XCTAssertEqual(patch["request_id"], .null)
    }

    /// A fence 409 is never resent: it comes back as the refusal its `detail` names.
    @MainActor
    func testHermesFenceRefusalIsNotResent() async throws {
        let rows: [(detail: String, refusal: HermesSessionFenceRefusal)] = [
            ("revision_conflict", .changed),
            ("client_upgrade_required: this client predates the session write fence", .updateRequired)
        ]
        var detail = ""
        let client = try await hermesClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/sessions/tip/mutation-snapshot"):
                return .json(200, .object(["exists": .bool(true), "runtime_revision": .number(4)]))
            case ("PATCH", _): return .json(409, .object(["detail": .string(detail)]))
            default: return nil
            }
        }
        for row in rows {
            detail = row.detail
            let sent = HermesHostFixture.requests.filter { $0.httpMethod == "PATCH" }.count
            do {
                try await client.updateSession(.pinned(true), key: "tip", profile: "default")
                XCTFail("The host refused the write: \(row.detail)")
            } catch {
                XCTAssertEqual(error as? HermesSessionFenceRefusal, row.refusal, row.detail)
            }
            XCTAssertEqual(HermesHostFixture.requests.filter { $0.httpMethod == "PATCH" }.count, sent + 1, row.detail)
        }
    }

    /// A title the host refuses comes back in its own words; any other refusal stays a status.
    @MainActor
    func testHermesRefusedTitleCarriesTheHostsMessage() async throws {
        let detail = "Title too long (101 chars, max 100)"
        var status = 400
        let client = try await hermesClient { request in
            request.httpMethod == "PATCH" ? .json(status, .object(["detail": .string(detail)])) : nil
        }

        do {
            try await client.updateSession(.title(String(repeating: "x", count: 101)), key: "tip", profile: "default")
            XCTFail("The host refused the title")
        } catch {
            XCTAssertEqual(error as? HermesSessionRefusal, HermesSessionRefusal(message: detail))
        }
        status = 404
        do {
            try await client.updateSession(.pinned(true), key: "tip", profile: "default")
            XCTFail("The host has no such session")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(404))
        }
    }

    /// Export reads that exact session under its Profile and hands back the host's bytes.
    @MainActor
    func testHermesExportReadsThatSessionUnderItsProfile() async throws {
        let export = BotJSON.object(["id": .string("tip"), "system_prompt": .string("You are Hermes"), "messages": .array([])])
        let client = try await hermesClient { request in
            request.url?.path == "/api/sessions/tip/export" ? .json(200, export) : nil
        }

        let data = try await client.exportSession(key: "tip", profile: "research")

        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: data), export)
        let request = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions/tip/export" })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.query, "profile=research")
    }

    // MARK: Hermes (#1051)

    /// An import posts its body and hands back the host's result. A payload the host refuses
    /// carries its first error and every session it named; a 413 stays a status.
    @MainActor
    func testHermesImportPostsTheSessionAndCarriesTheHostsRefusal() async throws {
        var status = 200
        var posted = BotJSON.null
        let client = try await hermesClient { request in
            guard request.url?.path == "/api/sessions/import" else { return nil }
            posted = Self.hermesBody(request)
            switch status {
            case 400:
                return .json(400, .object(["detail": .object(["ok": .bool(false), "errors": .array([.object([
                    "index": .number(0), "error": .string("messages[0].role must be a non-empty string"), "session_id": .string("x")
                ])])])]))
            case 413: return .json(413, .object(["detail": .string("Session import payload is too large")]))
            default: return .json(200, .object(["ok": .bool(true), "imported": .number(1), "imported_ids": .array([.string("x")])]))
            }
        }
        let body = BotJSON.object(["sessions": .array([.object(["id": .string("x"), "messages": .array([])])]),
                                   "profile": .string("research")])
        let encoded = try JSONEncoder().encode(body)

        let result = try await client.importSessions(body: encoded)
        XCTAssertEqual(result["imported_ids"], .array([.string("x")]))
        XCTAssertEqual(posted["sessions"], body["sessions"])
        XCTAssertEqual(posted["profile"], body["profile"])
        XCTAssertFalse((posted["request_id"].text ?? "").isEmpty, "The write fence's identity (#1300)")
        XCTAssertEqual(posted["expected_revision"], .number(0))
        let request = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions/import" })
        XCTAssertEqual(request.httpMethod, "POST")

        status = 400
        do {
            _ = try await client.importSessions(body: encoded)
            XCTFail("The host refused the payload")
        } catch {
            XCTAssertEqual(error as? HermesSessionRefusal, HermesSessionRefusal(
                message: "messages[0].role must be a non-empty string",
                entries: [.init(index: 0, sessionID: "x", reason: "messages[0].role must be a non-empty string")]
            ), "Every session the host named is kept (#1213)")
        }
        status = 413
        do {
            _ = try await client.importSessions(body: encoded)
            XCTFail("The payload was too large")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(413))
        }
    }

    /// A session's own row is read under its Profile; a session the host lacks is nil.
    @MainActor
    func testHermesSessionRowReadsThatSessionOrNothing() async throws {
        let row = BotJSON.object(["id": .string("tip"), "parent_session_id": .string("root"),
                                  "model_config": .string("{\"_branched_from\": \"root\"}")])
        let client = try await hermesClient { request in
            switch request.url?.path {
            case "/api/sessions/tip": return .json(200, row)
            case "/api/sessions/gone": return .json(404, .object(["detail": .string("Session not found")]))
            default: return nil
            }
        }

        let read = try await client.sessionRow(key: "tip", profile: "research")
        let gone = try await client.sessionRow(key: "gone", profile: "research")

        XCTAssertEqual(read, row)
        XCTAssertNil(gone)
        let request = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/sessions/tip" })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.query, "profile=research")
    }

    /// A connected client on a scripted host whose REST routes `answer` serves first.
    @MainActor
    private func hermesClient(_ answer: @escaping (URLRequest) -> HermesHostFixture.Reply?) async throws -> BotClient {
        addTeardownBlock { HermesHostFixture.reset() }
        let record = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        let client = BotClient(http: BotSocketHost().connection(record))
        _ = HermesHostFixture.configuration(answer)
        try await client.connect()
        return client
    }

    private static func hermesBody(_ request: URLRequest) -> BotJSON {
        apiTestBodyData(from: request).flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) } ?? .null
    }
}
