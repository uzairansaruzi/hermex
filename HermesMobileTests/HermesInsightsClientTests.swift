import XCTest
@testable import HermesMobile

/// Insights on a Hermes host (#1074): `HermesInsightsClient` against a scripted host and gateway
/// socket. Replies come from `Fixtures/HermesAgent/analytics.json`, recorded by
/// `scripts/capture-hermes-fixtures --local` from `scripts/local-hermes` at the
/// `HERMES_AGENT_TESTED_SHA` pin, or are rows in its shape.
@MainActor final class HermesInsightsClientTests: XCTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    /// The recorded window, one hidden session long: totals, its day and its model from the
    /// analytics routes, and messages from `insights.get`, whose count leaves hidden sessions out.
    /// Every read names the window and the Profile.
    func testTheRecordedWindowMapsFromAllThreeReads() async throws {
        let recorded = try Self.recorded()
        let host = HermesInsightsHost(usage: recorded["usage"], models: recorded["models"], counts: recorded["insights"])

        let response = try await host.client(profile: "research").insights(days: 30)

        XCTAssertEqual(response.periodDays, 30)
        XCTAssertEqual(response.totalSessions, 1, "The analytics count every session in the window")
        XCTAssertEqual(response.totalMessages, 0, "insights.get counts visible sessions only")
        XCTAssertEqual([response.totalInputTokens, response.totalOutputTokens, response.totalTokens, response.totalCacheReadTokens],
                       [0, 0, 0, 0])
        XCTAssertEqual(response.totalCost, 0)
        XCTAssertNil(response.totalCacheHitPercent, "No cache reads, no hit rate")
        XCTAssertEqual(response.dailyTokens?.first?.date, "2026-10-06")
        XCTAssertEqual(response.dailyTokens?.first?.sessions, 1)
        XCTAssertEqual(response.models?.map(\.model), ["fixture-redacted"])
        XCTAssertEqual(response.models?.map(\.provider), ["custom"])
        XCTAssertEqual(response.models?.map(\.sessions), [1])
        XCTAssertNil(response.activityByHour)
        XCTAssertNil(response.activityByDay)

        let reads = HermesHostFixture.requests.filter { $0.url?.path.hasPrefix("/api/analytics/") == true }
        XCTAssertEqual(Set(reads.compactMap { $0.url?.path }), ["/api/analytics/usage", "/api/analytics/models"])
        for read in reads {
            let query = URLComponents(url: try XCTUnwrap(read.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(Set(query), [URLQueryItem(name: "days", value: "30"), URLQueryItem(name: "profile", value: "research")])
        }
        let call = try XCTUnwrap(host.sockets.first?.sentRequests.first { $0["method"].text == "insights.get" })
        XCTAssertEqual(call["params"], .object(["days": .number(30), "profile": .string("research")]))
    }

    /// Cost is the host's estimate, as webui's is. The hit rate is cache reads over everything the
    /// model was shown, as a whole percent.
    func testTotalsCostAndHitRateComeFromTheUsageTotals() throws {
        let response = try InsightsResponse(
            hermesUsage: Self.usage(totals: ["total_input": 300, "total_output": 100, "total_cache_read": 900,
                                             "total_estimated_cost": 1.25, "total_actual_cost": 2, "total_sessions": 4]),
            models: Self.models([]),
            counts: .object(["days": .number(7), "sessions": .number(3), "messages": .number(37)])
        )

        XCTAssertEqual(response.totalSessions, 4)
        XCTAssertEqual(response.totalMessages, 37)
        XCTAssertEqual(response.totalTokens, 400, "Processed tokens leave cache reads out, as webui's do")
        XCTAssertEqual(response.totalCacheReadTokens, 900)
        XCTAssertEqual(response.totalCost, 1.25)
        XCTAssertEqual(response.totalCacheHitPercent, 75)
    }

    /// The host's `input_tokens` leaves cached reads out, so a window read entirely from cache is
    /// a 100% hit rate, and an empty window, whose sums the host sends as null, has none.
    func testTheHitRateWithZeroInput() throws {
        let cached = try InsightsResponse(
            hermesUsage: Self.usage(totals: ["total_input": 0, "total_output": 20, "total_cache_read": 500]),
            models: Self.models([]), counts: .object([:])
        )
        let empty = try InsightsResponse(
            hermesUsage: Self.usage(totals: ["total_input": nil, "total_output": nil, "total_cache_read": nil,
                                             "total_estimated_cost": 0, "total_sessions": 0]),
            models: Self.models([]), counts: .object([:])
        )

        XCTAssertEqual(cached.totalCacheHitPercent, 100)
        XCTAssertNil(empty.totalCacheHitPercent)
        XCTAssertEqual([empty.totalTokens, empty.totalCacheReadTokens], [0, 0])
    }

    /// One model billed through two providers stays two rows, each naming its provider; shares
    /// are of the rows' own sums. A row without a provider names none.
    func testOneModelUnderTwoProvidersIsTwoRows() throws {
        let response = try InsightsResponse(
            hermesUsage: Self.usage(totals: [:]),
            models: Self.models([
                Self.model("gpt-5", provider: "openai", input: 200, output: 100, cacheRead: 600, cost: 3, sessions: 3),
                Self.model("gpt-5", provider: "openrouter", input: 80, output: 20, cacheRead: 0, cost: 1, sessions: 1),
                Self.model("local-model", provider: "", input: 0, output: 0, cacheRead: 0, cost: 0, sessions: 4)
            ]),
            counts: .object([:])
        )

        let models = try XCTUnwrap(response.models)
        XCTAssertEqual(models.map(\.model), ["gpt-5", "gpt-5", "local-model"])
        XCTAssertEqual(models.map(\.provider), ["openai", "openrouter", nil])
        XCTAssertEqual(models.map(\.totalTokens), [300, 100, 0])
        XCTAssertEqual(models.map(\.tokenShare), [75, 25, 0])
        XCTAssertEqual(models.map(\.costShare), [75, 25, 0])
        XCTAssertEqual(models.map(\.sessionShare), [38, 13, 50])
        XCTAssertEqual(models.map(\.cacheHitPercent), [75, nil, nil])
    }

    /// The host lists only days with sessions, by UTC date, so the chart is carried on to today
    /// (UTC); a window whose last row is today gains nothing.
    func testTheDailyRowsEndOnToday() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-06T02:00:00Z"))
        let row = { (day: String) -> BotJSON in
            .object(["day": .string(day), "input_tokens": .number(10), "output_tokens": .number(5), "cache_read_tokens": .number(2),
                     "estimated_cost": .number(0.5), "actual_cost": .number(0), "sessions": .number(1)])
        }

        let idle = try InsightsResponse(hermesUsage: Self.usage(totals: [:], daily: [row("2026-10-01")]),
                                        models: Self.models([]), counts: .object([:]), now: now)
        let active = try InsightsResponse(hermesUsage: Self.usage(totals: [:], daily: [row("2026-10-01"), row("2026-10-06")]),
                                          models: Self.models([]), counts: .object([:]), now: now)

        XCTAssertEqual(idle.dailyTokens?.map(\.date), ["2026-10-01", "2026-10-06"])
        XCTAssertEqual(idle.dailyTokens?.last?.sessions, 0)
        XCTAssertEqual(idle.dailyTokens?.first?.cost, 0.5)
        XCTAssertEqual(idle.dailyTokens?.first?.cacheReadTokens, 2)
        XCTAssertEqual(active.dailyTokens?.map(\.date), ["2026-10-01", "2026-10-06"])
    }

    /// A store the host can't read is the host's own 503, which names a host path that is never
    /// shown; a proxy's 503 keeps the Hermes connection's proxy copy.
    func testAnUnreadableStoreIsItsOwnErrorAndAProxyIsNot() async throws {
        let store = HermesInsightsHost(usage: Self.usage(totals: [:]), models: Self.models([]), counts: .object([:])) { request in
            request.url?.path == "/api/analytics/usage" ? .json(503, .object(["detail": .object([
                "error": .string("state_db_corrupt"), "message": .string("state.db corrupt — run `hermes doctor`."),
                "path": .string("/Users/someone/.hermes/state.db")
            ])])) : nil
        }
        do {
            _ = try await store.client(profile: "default").insights(days: 7)
            XCTFail("Expected the store failure")
        } catch {
            XCTAssertEqual(error as? HermesInsightsUnavailable, HermesInsightsUnavailable())
            XCTAssertFalse(error.localizedDescription.contains("/Users"))
        }
        HermesHostFixture.reset()

        let proxy = HermesInsightsHost(usage: Self.usage(totals: [:]), models: Self.models([]), counts: .object([:])) { request in
            request.url?.path == "/api/analytics/models" ? .json(503, .string("Service Unavailable")) : nil
        }
        do {
            _ = try await proxy.client(profile: "default").insights(days: 7)
            XCTFail("Expected the proxy failure")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(503))
        }
    }

    /// `insights.get`'s 5017 is the same unreadable store.
    func testTheGatewaysUnavailableStoreIsTheSameError() async throws {
        let host = HermesInsightsHost(usage: Self.usage(totals: [:]), models: Self.models([]),
                                      countsError: .object(["code": .number(5017), "message": .string("Session storage is unavailable")]))

        do {
            _ = try await host.client(profile: "default").insights(days: 90)
            XCTFail("Expected the store failure")
        } catch {
            XCTAssertEqual(error as? HermesInsightsUnavailable, HermesInsightsUnavailable())
        }
    }

    /// The host has no provider limits route and no sessions list here, so neither asks it anything.
    func testLimitsAndTheSessionsFallbackAskTheHostNothing() async throws {
        let host = HermesInsightsHost(usage: Self.usage(totals: [:]), models: Self.models([]), counts: .object([:]))
        let client = host.client(profile: "default")

        let providers = try await client.providers()

        XCTAssertEqual(providers.providers, [])
        XCTAssertEqual(providerQuotaSelection(from: providers), [])
        do {
            _ = try await client.sessions()
            XCTFail("A Hermes host has no sessions fallback")
        } catch {}
        XCTAssertEqual(HermesHostFixture.requests.count, 0)
    }

    // MARK: - Fixtures

    private static func recorded() throws -> BotJSON {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HermesAgent/analytics.json")
        guard let data = try? Data(contentsOf: file) else {
            throw XCTSkip("Could not read \(file.path); the source tree is not present (physical device or remote runner).")
        }
        let recorded = try JSONDecoder().decode(BotJSON.self, from: data)
        XCTAssertEqual(recorded["version"].text, HermesCompatibility.testedVersion, "Re-run scripts/capture-hermes-fixtures --local")
        return recorded
    }

    /// `/api/analytics/usage` in the recorded shape, with `totals` and `daily` as given.
    private static func usage(totals: [String: Double?], daily: [BotJSON] = []) -> BotJSON {
        .object([
            "daily": .array(daily), "by_model": .array([]), "by_task": .array([]), "period_days": .number(7),
            "totals": .object(totals.mapValues { $0.map(BotJSON.number) ?? .null }),
            "skills": .object([:]), "tools": .array([])
        ])
    }

    private static func models(_ rows: [BotJSON]) -> BotJSON {
        .object(["models": .array(rows), "totals": .object([:]), "period_days": .number(7)])
    }

    /// One `/api/analytics/models` row in the recorded shape.
    private static func model(_ name: String, provider: String, input: Int, output: Int, cacheRead: Int,
                              cost: Double, sessions: Int) -> BotJSON {
        .object([
            "model": .string(name), "provider": .string(provider), "input_tokens": .number(Double(input)),
            "output_tokens": .number(Double(output)), "cache_read_tokens": .number(Double(cacheRead)),
            "reasoning_tokens": .number(0), "estimated_cost": .number(cost), "actual_cost": .number(0),
            "sessions": .number(Double(sessions)), "api_calls": .number(1), "tool_calls": .number(0),
            "last_used_at": .number(1_791_326_370), "avg_tokens_per_session": .number(0), "capabilities": .object([:])
        ])
    }
}

/// A Hermes host that answers the two analytics reads over HTTP and `insights.get` over its gateway
/// socket. `script` may answer a request first.
@MainActor private final class HermesInsightsHost {
    private(set) var sockets: [BotScriptedSocket] = []
    private let configuration: URLSessionConfiguration
    private let counts: BotJSON?
    private let countsError: BotJSON?

    init(usage: BotJSON, models: BotJSON, counts: BotJSON? = nil, countsError: BotJSON? = nil,
         script: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) {
        self.counts = counts
        self.countsError = countsError
        configuration = HermesHostFixture.configuration { request in
            if let reply = script(request) { return reply }
            switch request.url?.path {
            case "/api/analytics/usage": return .json(200, usage)
            case "/api/analytics/models": return .json(200, models)
            default: return nil
            }
        }
    }

    func client(profile: String) -> HermesInsightsClient {
        let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        let counts = counts, countsError = countsError
        let http = HermesConnection(connection: record, configuration: configuration, gateway: .init { [weak self] _ in
            let socket = BotScriptedSocket()
            socket.reply = { request in
                if let countsError { return .object(["id": request["id"], "error": countsError]) }
                return .object(["id": request["id"], "result": counts ?? .object([:])])
            }
            self?.sockets.append(socket)
            return socket
        })
        return HermesInsightsClient(http: http, profile: profile)
    }
}
