import XCTest
@testable import HermesMobile

final class APIClientUpdatesApplyTests: APIClientTestCase {
    func testApplyUpdateRequestHitsEndpointWithWebuiTargetAndDecodesSuccess() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/updates/apply")

            // Confirm the body targets the webui repo (issue #180 scope).
            let body = apiTestBodyData(from: request)
            let decodedBody = try XCTUnwrap(body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })
            XCTAssertEqual(decodedBody["target"] as? String, "webui")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "message": "webui updated successfully",
              "target": "webui",
              "restart_scheduled": true
            }
            """, for: request)
        }

        let response = try await client.applyUpdate()

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.target, "webui")
        XCTAssertEqual(response.restartScheduled, true)
        XCTAssertEqual(response.outcome, .applying)
    }

    func testRestartBlockedResponseIsNotTreatedAsFailure() throws {
        let response = try decodeApply("""
        {
          "ok": false,
          "message": "Cannot update webui while 1 active chat stream is running. Wait for the response to finish, then retry the update.",
          "target": "webui",
          "restart_blocked": true,
          "active_streams": 1,
          "active_runs": 0
        }
        """)

        XCTAssertEqual(response.restartBlocked, true)
        XCTAssertEqual(response.activeStreams, 1)
        XCTAssertEqual(response.outcome, .restartBlocked)
        XCTAssertTrue(response.displayMessage(default: "fallback").contains("active chat stream"))
    }

    func testGenericNotOkResponseIsFailed() throws {
        let response = try decodeApply("""
        { "ok": false, "message": "Update already in progress" }
        """)

        XCTAssertEqual(response.outcome, .failed)
    }

    func testSuccessWithStashConflictStillCountsAsApplying() throws {
        // The server updated and is restarting (ok + restart_scheduled), but set
        // local changes aside in a stash. That's still a success the app should
        // recover from — not a hard failure.
        let response = try decodeApply("""
        {
          "ok": true,
          "message": "webui updated to the latest version. Your local modifications conflicted...",
          "target": "webui",
          "restart_scheduled": true,
          "stash_conflict": true
        }
        """)

        XCTAssertEqual(response.stashConflict, true)
        XCTAssertEqual(response.outcome, .applying)
    }

    func testDisplayMessageFallsBackWhenMessageMissingOrBlank() throws {
        let missing = try decodeApply(#"{ "ok": false }"#)
        XCTAssertEqual(missing.displayMessage(default: "fallback"), "fallback")

        let blank = try decodeApply(#"{ "ok": false, "message": "   " }"#)
        XCTAssertEqual(blank.displayMessage(default: "fallback"), "fallback")

        let present = try decodeApply(#"{ "ok": false, "message": "  boom  " }"#)
        XCTAssertEqual(present.displayMessage(default: "fallback"), "boom")
    }

    func testTolerantDecodingIgnoresUnknownAndMissingFields() throws {
        // Unknown future keys and an otherwise-empty payload must not crash.
        let response = try decodeApply("""
        { "future_key": "ignored", "nested": { "anything": [1, 2, 3] } }
        """)

        XCTAssertNil(response.ok)
        XCTAssertNil(response.message)
        XCTAssertEqual(response.outcome, .failed)
    }

    private func decodeApply(_ json: String) throws -> UpdatesApplyResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UpdatesApplyResponse.self, from: Data(json.utf8))
    }
}
