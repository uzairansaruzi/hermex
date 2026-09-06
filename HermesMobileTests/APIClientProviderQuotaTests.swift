import XCTest
@testable import HermesMobile

/// Decoding contract for `GET /api/provider/quota` (#415). The `available`
/// fixtures are the live payloads captured 2026-09-05; the rest cover the other
/// statuses upstream returns from the same handler.
final class APIClientProviderQuotaTests: APIClientTestCase {
    func testProviderQuotaBuildsProviderQueryWithoutRefreshByDefault() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/provider/quota")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["provider"], "openai-codex")
            XCTAssertNil(query["refresh"])

            return apiTestJSONResponse(#"{"ok": true, "status": "unsupported"}"#, for: request)
        }

        _ = try await client.providerQuota(provider: "openai-codex")
    }

    func testProviderQuotaAppendsRefreshWhenAsked() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["provider"], "openrouter")
            XCTAssertEqual(query["refresh"], "1")

            return apiTestJSONResponse(#"{"ok": true, "status": "unsupported"}"#, for: request)
        }

        _ = try await client.providerQuota(provider: "openrouter", refresh: true)
    }

    func testEndpointQueryConstruction() {
        let base = URL(string: "https://example.test")!

        let plain = Endpoint.providerQuota(provider: "anthropic").url(relativeTo: base)
        XCTAssertEqual(plain.path, "/api/provider/quota")
        XCTAssertEqual(plain.query, "provider=anthropic")

        let refreshed = Endpoint.providerQuota(provider: "anthropic", refresh: true).url(relativeTo: base)
        XCTAssertEqual(refreshed.query, "provider=anthropic&refresh=1")
    }

    func testDecodesLiveAccountLimitsPayloadAndIgnoresPool() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(Self.codexPayload, for: request)
        }

        let response = try await client.providerQuota(provider: "openai-codex")

        XCTAssertEqual(response.status, "available")
        XCTAssertEqual(response.displayName, "OpenAI Codex")
        XCTAssertEqual(response.supported, true)
        XCTAssertNil(response.quota)

        let limits = try XCTUnwrap(response.accountLimits)
        XCTAssertEqual(limits.plan, "Plus")
        XCTAssertEqual(limits.available, true)
        XCTAssertEqual(limits.fetchedAt, "2026-09-06T02:56:37.848820Z")
        XCTAssertEqual(limits.windows?.count, 2)

        let session = try XCTUnwrap(limits.windows?.first)
        XCTAssertEqual(session.label, "Session")
        XCTAssertEqual(try XCTUnwrap(session.remainingPercent), 100, accuracy: 0.0001)
        XCTAssertEqual(session.resetAt, "2026-09-06T07:55:41Z")
        XCTAssertEqual(session.detail, "Best of 1 available credentials")

        let weekly = try XCTUnwrap(limits.windows?.last)
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(try XCTUnwrap(weekly.usedPercent), 98, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(weekly.remainingPercent), 2, accuracy: 0.0001)
        XCTAssertNil(weekly.detail)
    }

    func testDecodesLiveOpenRouterCreditsPayload() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(Self.openRouterPayload, for: request)
        }

        let response = try await client.providerQuota(provider: "openrouter")

        XCTAssertEqual(response.status, "available")
        XCTAssertEqual(response.displayName, "OpenRouter")
        XCTAssertNil(response.accountLimits)

        let quota = try XCTUnwrap(response.quota)
        XCTAssertEqual(try XCTUnwrap(quota.limitRemaining), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(quota.usage), 10.0296785, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(quota.limit), 10, accuracy: 0.0001)
    }

    func testDecodesUncappedOpenRouterKey() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "ok": true, "provider": "openrouter", "display_name": "OpenRouter",
              "supported": true, "status": "available", "label": "OpenRouter credits",
              "quota": {"limit_remaining": null, "usage": 4.5, "limit": null},
              "message": "OpenRouter quota status loaded."
            }
            """, for: request)
        }

        let response = try await client.providerQuota(provider: "openrouter")
        let quota = try XCTUnwrap(response.quota)
        XCTAssertNil(quota.limitRemaining)
        XCTAssertNil(quota.limit)
        XCTAssertEqual(try XCTUnwrap(quota.usage), 4.5, accuracy: 0.0001)
    }

    func testDecodesUnsupportedPayload() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "ok": false, "provider": "opencode-free", "display_name": "OpenCode Free",
              "supported": false, "status": "unsupported", "quota": null,
              "message": "Quota status is not available for OpenCode Free."
            }
            """, for: request)
        }

        let response = try await client.providerQuota(provider: "opencode-free")

        XCTAssertEqual(response.status, "unsupported")
        XCTAssertEqual(response.supported, false)
        XCTAssertNil(response.quota)
        XCTAssertNil(response.accountLimits)
    }

    func testDecodesUnavailablePayloadWithNullAccountLimits() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "ok": false, "provider": "anthropic", "display_name": "Anthropic",
              "supported": true, "status": "unavailable", "quota": null,
              "account_limits": null,
              "message": "Anthropic account limits could not be read."
            }
            """, for: request)
        }

        let response = try await client.providerQuota(provider: "anthropic")

        XCTAssertEqual(response.status, "unavailable")
        XCTAssertNil(response.accountLimits)
        XCTAssertEqual(response.message, "Anthropic account limits could not be read.")
    }

    static let codexPayload = """
    {
      "ok": true, "provider": "openai-codex", "display_name": "OpenAI Codex",
      "supported": true, "status": "available", "label": "Account limits", "quota": null,
      "account_limits": {
        "plan": "Plus", "title": "Account limits", "available": true, "unavailable_reason": null,
        "fetched_at": "2026-09-06T02:56:37.848820Z",
        "windows": [
          {"label": "Session", "used_percent": 0.0, "remaining_percent": 100.0, "reset_at": "2026-09-06T07:55:41Z", "detail": "Best of 1 available credentials"},
          {"label": "Weekly",  "used_percent": 98.0, "remaining_percent": 2.0,  "reset_at": "2026-09-07T02:28:47Z", "detail": null}
        ],
        "details": ["1/1 credentials available", "Plans: Plus"],
        "pool": { "total_credentials": 1, "queried_credentials": 0 }
      },
      "message": "OpenAI Codex account limits loaded."
    }
    """

    static let openRouterPayload = """
    {
      "ok": true, "provider": "openrouter", "display_name": "OpenRouter",
      "supported": true, "status": "available", "label": "OpenRouter credits",
      "quota": {"limit_remaining": 0, "usage": 10.0296785, "limit": 10},
      "message": "OpenRouter quota status loaded."
    }
    """
}
