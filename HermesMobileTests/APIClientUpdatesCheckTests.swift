import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientUpdatesCheckTests: APIClientTestCase {
    func testUpdatesCheckRequestHitsEndpointAndDecodesBehindCount() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/updates/check")

            return apiTestJSONResponse("""
            {
              "webui": {
                "name": "webui",
                "behind": 3,
                "current_sha": "abc1234",
                "latest_sha": "def5678",
                "branch": "master",
                "repo_url": "https://github.com/x/hermes-webui",
                "compare_url": "https://github.com/x/hermes-webui/compare/abc1234...def5678"
              },
              "agent": { "name": "agent", "behind": 0 },
              "checked_at": 1770000000
            }
            """, for: request)
        }

        let response = try await client.updatesCheck()

        XCTAssertEqual(response.webui?.behind, 3)
        XCTAssertEqual(response.webui?.currentSha, "abc1234")
        XCTAssertEqual(response.webui?.latestSha, "def5678")
        XCTAssertEqual(response.webui?.branch, "master")
        XCTAssertEqual(response.checkedAt, 1_770_000_000)
        XCTAssertEqual(response.webuiUpdateState, .updateAvailable(behind: 3))
    }

    func testForcedCheckRequestPostsForceTrueAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/updates/check")

            // The forced path must send { "force": true } so upstream runs a real
            // git fetch instead of returning the cached status (issue #308).
            let body = apiTestBodyData(from: request)
            let decodedBody = try XCTUnwrap(body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })
            XCTAssertEqual(decodedBody["force"] as? Bool, true)

            return apiTestJSONResponse("""
            {
              "webui": { "name": "webui", "behind": 2 },
              "checked_at": 1770000000
            }
            """, for: request)
        }

        let response = try await client.updatesCheckForced()

        XCTAssertEqual(response.webui?.behind, 2)
        XCTAssertEqual(response.forcedCheckOutcome, .updateAvailable(behind: 2))
    }

    func testForcedCheckOutcomeIsUpToDateWhenBehindIsZeroOrNull() throws {
        let zero = try decodeUpdatesCheck("""
        { "webui": { "name": "webui", "behind": 0 } }
        """)
        XCTAssertEqual(zero.forcedCheckOutcome, .upToDate)

        let null = try decodeUpdatesCheck("""
        { "webui": { "name": "webui", "behind": null } }
        """)
        XCTAssertEqual(null.forcedCheckOutcome, .upToDate)
    }

    func testForcedCheckOutcomeIsDisabledWhenChecksOff() throws {
        let response = try decodeUpdatesCheck("""
        { "disabled": true }
        """)

        // Distinct from `.error`: the popup wording differs (checks off vs failure).
        XCTAssertEqual(response.forcedCheckOutcome, .disabled)
    }

    func testForcedCheckOutcomeIsErrorOnFailureStaleOrMissingWebUI() throws {
        let errored = try decodeUpdatesCheck("""
        { "webui": { "name": "webui", "behind": 0, "error": "fetch failed" } }
        """)
        XCTAssertEqual(errored.forcedCheckOutcome, .error)

        let stale = try decodeUpdatesCheck("""
        { "webui": { "name": "webui", "behind": 5, "stale_check": true } }
        """)
        XCTAssertEqual(stale.forcedCheckOutcome, .error)

        let missing = try decodeUpdatesCheck("""
        { "checked_at": 1770000000 }
        """)
        XCTAssertEqual(missing.forcedCheckOutcome, .error)
    }

    func testWebUIUpdateStateIsUpToDateWhenBehindIsZero() throws {
        let response = try decodeUpdatesCheck("""
        { "webui": { "name": "webui", "behind": 0 }, "checked_at": 1 }
        """)

        XCTAssertEqual(response.webuiUpdateState, .upToDate)
    }

    func testDisabledPayloadDegradesToUnavailable() throws {
        let response = try decodeUpdatesCheck("""
        { "disabled": true }
        """)

        XCTAssertEqual(response.disabled, true)
        XCTAssertNil(response.webui)
        XCTAssertEqual(response.webuiUpdateState, .unavailable)
    }

    func testErrorOrStaleCheckDegradesToUnavailable() throws {
        let errored = try decodeUpdatesCheck("""
        { "webui": { "name": "webui", "behind": 0, "error": "fetch failed" } }
        """)
        XCTAssertEqual(errored.webuiUpdateState, .unavailable)

        let stale = try decodeUpdatesCheck("""
        { "webui": { "name": "webui", "behind": 5, "stale_check": true } }
        """)
        // Stale results are not trusted even when they claim a non-zero gap.
        XCTAssertEqual(stale.webuiUpdateState, .unavailable)
    }

    private func decodeUpdatesCheck(_ json: String) throws -> UpdatesCheckResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UpdatesCheckResponse.self, from: Data(json.utf8))
    }
}
