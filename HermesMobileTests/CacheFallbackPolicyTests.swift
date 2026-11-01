import XCTest
@testable import HermesMobile

final class CacheFallbackPolicyTests: XCTestCase {
    func testUsesCacheForConnectivityErrors() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .cannotFindHost,
            .dataNotAllowed,
            .timedOut
        ]

        for code in codes {
            XCTAssertTrue(
                CacheFallbackPolicy.shouldUseCache(for: APIError.network(underlying: URLError(code))),
                "\(code) should use cache fallback"
            )
        }
    }

    func testUsesCacheForTransientUnavailableHTTPStatuses() {
        for statusCode in [408, 502, 503, 504] {
            XCTAssertTrue(
                CacheFallbackPolicy.shouldUseCache(for: APIError.http(statusCode: statusCode, body: nil)),
                "HTTP \(statusCode) should use cache fallback"
            )
        }
    }

    func testDoesNotUseCacheForServerApplicationErrors() {
        let cases: [(name: String, error: Error)] = [
            ("invalid server URL", APIError.invalidServerURL),
            ("unauthorized", APIError.unauthorized),
            ("bad request", APIError.http(statusCode: 400, body: nil)),
            ("forbidden", APIError.http(statusCode: 403, body: nil)),
            ("not found", APIError.http(statusCode: 404, body: nil)),
            ("rate limited", APIError.http(statusCode: 429, body: nil)),
            ("server error", APIError.http(statusCode: 500, body: nil)),
            ("decoding", APIError.decoding(underlying: URLError(.badServerResponse))),
            ("cancelled", APIError.network(underlying: URLError(.cancelled))),
            ("bad URL", APIError.network(underlying: URLError(.badURL))),
            ("certificate", APIError.network(underlying: URLError(.secureConnectionFailed))),
            ("plain cancellation", CancellationError())
        ]

        for testCase in cases {
            XCTAssertFalse(
                CacheFallbackPolicy.shouldUseCache(for: testCase.error),
                "\(testCase.name) should not use cache fallback"
            )
        }
    }

    func testRawURLErrorUsesSameConnectivityRules() {
        XCTAssertTrue(CacheFallbackPolicy.shouldUseCache(for: URLError(.timedOut)))
        XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: URLError(.badURL)))
    }

    /// A Hermes host that can't be reached (#1054): its socket lost or never opened, or a proxy
    /// or tunnel answering for it. Its sign-in's own connectivity errors are raw `URLError`s.
    func testAnUnreachableHermesHostUsesCache() {
        let failures: [BotFailure] = [.transport, .rejected(408), .rejected(502), .rejected(503), .rejected(504),
                                      .rejected(522), .rejected(530)]
        for failure in failures {
            XCTAssertTrue(CacheFallbackPolicy.shouldUseCache(for: failure), "\(failure) should use cache fallback")
        }
    }

    /// A Hermes host that answered: a refusal the user acts on, a host error, or a stale call.
    func testAHermesRefusalDoesNotUseCache() {
        let failures: [BotFailure] = [.rejected(401), .rejected(404), .rejected(500), .rejected(4023), .rejected(-32601),
                                      .stale, .unsupported, .upgradeRefused(403), .blocked, .notDashboard]
        for failure in failures {
            XCTAssertFalse(CacheFallbackPolicy.shouldUseCache(for: failure), "\(failure) should not use cache fallback")
        }
    }
}
