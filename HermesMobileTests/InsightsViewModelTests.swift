import XCTest
@testable import HermesMobile

final class InsightsViewModelTests: XCTestCase {
    func testAggregateMathToleratesMissingUsageFields() throws {
        let sessions = try decodeSessions([
            sessionJSON(title: "Complete", inputTokens: 10, outputTokens: 20, estimatedCost: 0.12),
            sessionJSON(title: "Input only", inputTokens: 7, outputTokens: nil, estimatedCost: nil),
            sessionJSON(title: "Cost only", inputTokens: nil, outputTokens: nil, estimatedCost: 0.03)
        ])

        let analytics = SessionUsageAnalytics(sessions: sessions)

        XCTAssertEqual(analytics.sessionCount, 3)
        XCTAssertEqual(analytics.totalInputTokens, 17)
        XCTAssertEqual(analytics.totalOutputTokens, 20)
        XCTAssertEqual(analytics.totalTokens, 37)
        XCTAssertEqual(analytics.estimatedCost, 0.15, accuracy: 0.0001)
    }

    func testTimeframeFilteringUsesMostRecentSessionTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = try decodeSessions([
            sessionJSON(title: "Today", createdAt: now.addingTimeInterval(-60).timeIntervalSince1970),
            sessionJSON(title: "Updated recently", createdAt: now.addingTimeInterval(-100 * 24 * 60 * 60).timeIntervalSince1970, updatedAt: now.addingTimeInterval(-3 * 24 * 60 * 60).timeIntervalSince1970),
            sessionJSON(title: "Last message recently", createdAt: now.addingTimeInterval(-100 * 24 * 60 * 60).timeIntervalSince1970, updatedAt: now.addingTimeInterval(-40 * 24 * 60 * 60).timeIntervalSince1970, lastMessageAt: now.addingTimeInterval(-20 * 24 * 60 * 60).timeIntervalSince1970),
            sessionJSON(title: "Old", createdAt: now.addingTimeInterval(-45 * 24 * 60 * 60).timeIntervalSince1970),
            sessionJSON(title: "No timestamp", createdAt: nil)
        ])

        let today = sessions.filter { AnalyticsTimeframe.today.contains($0, now: now, calendar: calendar) }
        let last7Days = sessions.filter { AnalyticsTimeframe.last7Days.contains($0, now: now, calendar: calendar) }
        let last30Days = sessions.filter { AnalyticsTimeframe.last30Days.contains($0, now: now, calendar: calendar) }
        let last90Days = sessions.filter { AnalyticsTimeframe.last90Days.contains($0, now: now, calendar: calendar) }

        XCTAssertEqual(today.map(\.title), ["Today"])
        XCTAssertEqual(last7Days.map(\.title), ["Today", "Updated recently"])
        XCTAssertEqual(last30Days.map(\.title), ["Today", "Updated recently", "Last message recently"])
        XCTAssertEqual(last90Days.map(\.title), ["Today", "Updated recently", "Last message recently", "Old"])
    }

    func testTopSessionsSortsByTotalTokensWithinFilteredData() throws {
        let sessions = try decodeSessions([
            sessionJSON(title: "Low", inputTokens: 5, outputTokens: 5),
            sessionJSON(title: "High", inputTokens: 20, outputTokens: 1),
            sessionJSON(title: "Medium", inputTokens: nil, outputTokens: 12)
        ])

        let analytics = SessionUsageAnalytics(sessions: sessions)

        XCTAssertEqual(analytics.topSessions.map(\.title), ["High", "Medium", "Low"])
    }

    func testTimeframesMapToServerInsightDays() {
        XCTAssertEqual(AnalyticsTimeframe.allCases.map(\.serverDays), [1, 7, 30, 90])
        XCTAssertTrue(AnalyticsTimeframe.today.isHourly)
        XCTAssertFalse(AnalyticsTimeframe.last90Days.isHourly)
    }

    func testModelDisplayShareFallsBackFromZeroCostShareToTokenShare() throws {
        let insights = try decodeInsights("""
        {
          "models": [
            {
              "model": "deepseek-v4-flash",
              "sessions": 25,
              "total_tokens": 3000000,
              "cost_share": 0,
              "token_share": 26,
              "session_share": 37
            }
          ]
        }
        """)

        XCTAssertEqual(insights.models?.first?.displayShare, 26)
    }

    @MainActor
    func testLoadFallsBackToLocalAnalyticsWhenServerInsightsFails() async throws {
        let now = Date().timeIntervalSince1970
        let sessions = try decodeSessions([
            sessionJSON(title: "Recent", createdAt: now - 60, messageCount: 4, inputTokens: 10, outputTokens: 20, estimatedCost: 0.12),
            sessionJSON(title: "Older", createdAt: now - 3_600, messageCount: 2, inputTokens: 5, outputTokens: 7, estimatedCost: 0.03)
        ])
        let client = StubInsightsClient(
            insightsResult: .failure(StubInsightsError()),
            sessionsResult: .success(SessionsResponse(sessions: sessions, cliCount: nil, archivedCount: nil, serverTime: nil, serverTz: nil))
        )
        let viewModel = InsightsViewModel(client: client)
        viewModel.selectedTimeframe = .last7Days

        await viewModel.load()

        XCTAssertEqual(client.requestedDays, [7])
        XCTAssertEqual(viewModel.dataSource, .localFallback)
        XCTAssertEqual(viewModel.sessionCount, 2)
        XCTAssertEqual(viewModel.totalMessages, 6)
        XCTAssertEqual(viewModel.totalInputTokens, 15)
        XCTAssertEqual(viewModel.totalOutputTokens, 27)
        XCTAssertEqual(viewModel.totalTokens, 42)
        XCTAssertEqual(viewModel.estimatedCost, 0.15, accuracy: 0.0001)
        XCTAssertNil(viewModel.totalCacheReadTokens)
        XCTAssertNil(viewModel.totalCacheHitPercent)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.fallbackReason, "Server insights unavailable")
    }

    @MainActor
    func testFallbackTotalsIncludeSessionsWithoutUsableIDs() async throws {
        let now = Date().timeIntervalSince1970
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(SessionsResponse.self, from: Data("""
        {
          "sessions": [
            {
              "title": "Missing identity",
              "created_at": \(now - 60),
              "message_count": 4,
              "input_tokens": 10,
              "output_tokens": 20,
              "estimated_cost": 0.12
            },
            {
              "session_id": "   ",
              "title": "Blank identity",
              "created_at": \(now - 120),
              "message_count": 2,
              "input_tokens": 5,
              "output_tokens": 7,
              "estimated_cost": 0.03
            }
          ]
        }
        """.utf8))
        let client = StubInsightsClient(
            insightsResult: .failure(StubInsightsError()),
            sessionsResult: .success(response)
        )
        let viewModel = InsightsViewModel(client: client)
        viewModel.selectedTimeframe = .last7Days

        await viewModel.load()

        XCTAssertEqual(viewModel.sessionCount, 2)
        XCTAssertEqual(viewModel.totalMessages, 6)
        XCTAssertEqual(viewModel.totalTokens, 42)
        XCTAssertEqual(viewModel.estimatedCost, 0.15, accuracy: 0.0001)
    }

    @MainActor
    func testLoadUsesServerInsightsWhenAvailable() async throws {
        let client = StubInsightsClient(
            insightsResult: .success(try decodeInsights("""
            {
              "period_days": 30,
              "total_sessions": 5,
              "total_messages": 13,
              "total_input_tokens": 100,
              "total_output_tokens": 250,
              "total_tokens": 350,
              "total_cost": 0.42,
              "total_cache_read_tokens": 80,
              "total_cache_hit_percent": 64.2
            }
            """)),
            sessionsResult: .failure(StubInsightsError())
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.load()

        XCTAssertEqual(client.requestedDays, [30])
        XCTAssertEqual(viewModel.dataSource, .server)
        XCTAssertEqual(viewModel.periodDays, 30)
        XCTAssertEqual(viewModel.sessionCount, 5)
        XCTAssertEqual(viewModel.totalMessages, 13)
        XCTAssertEqual(viewModel.totalInputTokens, 100)
        XCTAssertEqual(viewModel.totalOutputTokens, 250)
        XCTAssertEqual(viewModel.totalTokens, 350)
        XCTAssertEqual(viewModel.estimatedCost, 0.42, accuracy: 0.0001)
        XCTAssertEqual(viewModel.totalCacheReadTokens, 80)
        XCTAssertEqual(try XCTUnwrap(viewModel.totalCacheHitPercent), 64.2, accuracy: 0.0001)
        XCTAssertTrue(viewModel.sessions.isEmpty)
    }

    @MainActor
    func testLoadKeepsExistingAnalyticsVisibleWhileTimeframeRefreshes() async throws {
        let client = DelayedInsightsClient(
            firstResponse: try decodeInsights("""
            {
              "period_days": 30,
              "total_sessions": 5,
              "total_tokens": 350
            }
            """)
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.load()
        XCTAssertEqual(viewModel.totalTokens, 350)
        XCTAssertEqual(viewModel.periodTitle, "30 days")

        viewModel.selectedTimeframe = .last7Days
        let refreshTask = Task { await viewModel.load() }
        await client.waitForPendingRequest()

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertEqual(viewModel.totalTokens, 350)
        XCTAssertEqual(viewModel.periodTitle, "30 days")

        client.completePendingRequest(with: .success(try decodeInsights("""
        {
          "period_days": 7,
          "total_sessions": 2,
          "total_tokens": 125
        }
        """)))
        await refreshTask.value

        XCTAssertEqual(viewModel.totalTokens, 125)
        XCTAssertEqual(viewModel.periodTitle, "7 days")
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testChartBucketsZeroFillTheWholeWindow() async throws {
        let viewModel = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "daily_tokens": [
            {"date": "2026-08-28", "input_tokens": 100, "output_tokens": 20, "cache_read_tokens": 50, "sessions": 2, "cost": 0.5},
            {"date": "2026-08-31", "input_tokens": 40, "output_tokens": 10, "cache_read_tokens": 0, "sessions": 1, "cost": 0.25}
          ]
        }
        """)

        let buckets = viewModel.chartBuckets

        XCTAssertEqual(buckets.count, 7)
        XCTAssertEqual(buckets.map(\.label).first, "Aug 25")
        XCTAssertEqual(buckets.map(\.label).last, "Aug 31")
        XCTAssertEqual(buckets[3].processedTokens, 120)
        XCTAssertEqual(buckets[3].sessions, 2)
        // The two days the server skipped, plus the padded lead-in, are real zeros.
        XCTAssertEqual(buckets[4].processedTokens, 0)
        XCTAssertEqual(buckets[5].processedTokens, 0)
        XCTAssertFalse(buckets[0].hasActivity)
        XCTAssertEqual(buckets[6].processedTokens, 50)
    }

    @MainActor
    func testChartBucketsSpanNinetyDayWindow() async throws {
        let viewModel = try await loadedViewModel(timeframe: .last90Days, json: """
        {
          "period_days": 90,
          "daily_tokens": [
            {"date": "2026-09-01", "input_tokens": 10, "output_tokens": 5, "sessions": 1, "cost": 0}
          ]
        }
        """)

        XCTAssertEqual(viewModel.chartBuckets.count, 90)
        XCTAssertEqual(viewModel.chartBuckets.last?.processedTokens, 15)
    }

    @MainActor
    func testHourlyWindowPlotsSessionsAndHidesTheMetricToggle() async throws {
        let hours = (0...23).map { #"{"hour": \#($0), "sessions": \#($0 == 9 ? 4 : 0)}"# }
        let viewModel = try await loadedViewModel(timeframe: .today, json: """
        {
          "period_days": 1,
          "total_sessions": 4,
          "daily_tokens": [{"date": "2026-09-03", "input_tokens": 900, "output_tokens": 100, "sessions": 4, "cost": 1.5}],
          "activity_by_hour": [\(hours.joined(separator: ","))]
        }
        """)

        let buckets = viewModel.chartBuckets

        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[9].sessions, 4)
        // Hour buckets carry sessions and nothing else, so nothing may be stacked.
        XCTAssertEqual(buckets[9].processedTokens, 0)
        XCTAssertEqual(buckets[9].segments(for: .tokens).map(\.segment), [.sessions])
        XCTAssertFalse(viewModel.showsMetricToggle)
        XCTAssertEqual(viewModel.heroFigure.label, "Sessions")
        XCTAssertEqual(viewModel.heroFigure.value, "4")
        XCTAssertNotNil(viewModel.hourlyChartNote)
    }

    @MainActor
    func testMetricTogglePicksTheHeroFigureAndTheStackedSegments() async throws {
        let viewModel = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "total_sessions": 3,
          "total_tokens": 350,
          "total_cost": 0.42,
          "daily_tokens": [
            {"date": "2026-09-01", "input_tokens": 100, "output_tokens": 250, "cache_read_tokens": 60, "sessions": 3, "cost": 0.42}
          ]
        }
        """)

        // A priced window opens on cost.
        XCTAssertEqual(viewModel.metric, .cost)
        XCTAssertEqual(viewModel.heroFigure.value, "$0.42")
        let bucket = try XCTUnwrap(viewModel.chartBuckets.last)
        XCTAssertEqual(bucket.segments(for: .cost).map(\.segment), [.cost])

        viewModel.metric = .tokens

        XCTAssertEqual(viewModel.heroFigure.label, "Processed tokens")
        XCTAssertEqual(viewModel.heroFigure.value, "350")
        XCTAssertEqual(bucket.segments(for: .tokens).map(\.segment), [.input, .output, .cacheRead])
        XCTAssertEqual(bucket.segments(for: .tokens).map(\.value), [100, 250, 60])
        XCTAssertTrue(viewModel.showsMetricToggle)
    }

    @MainActor
    func testBucketReadoutNamesEveryQuantityTheBarStacks() async throws {
        let viewModel = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "total_sessions": 3,
          "total_tokens": 350,
          "total_cost": 0.42,
          "daily_tokens": [
            {"date": "2026-09-01", "input_tokens": 100, "output_tokens": 250, "cache_read_tokens": 900, "sessions": 3, "cost": 0.42}
          ]
        }
        """)

        let bucket = try XCTUnwrap(viewModel.chartBuckets.last)

        // The bar is 1,250 tall; the figure beside it is 350. Both numbers have
        // to be spoken, or the chart contradicts its own readout.
        XCTAssertEqual(bucket.processedTokens, 350)
        XCTAssertEqual(bucket.cacheReadTokens, 900)
        XCTAssertEqual(bucket.segments(for: .tokens).map(\.value).reduce(0, +), 1250)

        let selection = UsageHeroFigure.selection(bucket, metric: .tokens)
        XCTAssertEqual(selection.value, "350")
        XCTAssertTrue(selection.caption.contains("900 cached"), selection.caption)
        XCTAssertTrue(selection.caption.contains("3 sessions"), selection.caption)

        XCTAssertTrue(bucket.accessibilityValue.contains("350 tokens"), bucket.accessibilityValue)
        XCTAssertTrue(bucket.accessibilityValue.contains("900 cached"), bucket.accessibilityValue)

        // A window with no cache reads says nothing about them.
        let plain = UsageBucket(id: 0, label: "Sep 1", detail: .day(input: 10, output: 5, cacheRead: 0, sessions: 1, cost: 0))
        XCTAssertFalse(UsageHeroFigure.selection(plain, metric: .tokens).caption.contains("cached"))
        XCTAssertFalse(plain.accessibilityValue.contains("cached"))
    }

    @MainActor
    func testMetricDefaultsToTokensWhenTheServerPricesTheWindowAtZero() async throws {
        let viewModel = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "total_tokens": 4197262,
          "total_cost": 0.0,
          "daily_tokens": [{"date": "2026-09-01", "input_tokens": 100, "output_tokens": 20, "sessions": 1, "cost": 0.0}]
        }
        """)

        XCTAssertEqual(viewModel.metric, .tokens)

        // The user can still ask for cost, and it stays asked for.
        viewModel.metric = .cost
        XCTAssertEqual(viewModel.metric, .cost)
    }

    @MainActor
    func testPerActiveDayDividesByDaysWithActivityNotWindowLength() async throws {
        let viewModel = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "total_tokens": 300,
          "daily_tokens": [
            {"date": "2026-08-30", "input_tokens": 100, "output_tokens": 0, "sessions": 1, "cost": 0},
            {"date": "2026-08-31", "input_tokens": 0, "output_tokens": 0, "sessions": 0, "cost": 0},
            {"date": "2026-09-01", "input_tokens": 100, "output_tokens": 0, "sessions": 1, "cost": 0},
            {"date": "2026-09-02", "input_tokens": 100, "output_tokens": 0, "sessions": 1, "cost": 0}
          ]
        }
        """)

        XCTAssertEqual(viewModel.activeDayCount, 3)
        let processed = try XCTUnwrap(viewModel.totalsCells.first { $0.id == "processedTokens" })
        XCTAssertEqual(processed.detail, "100 per active day")
    }

    @MainActor
    func testTotalsCellsDropCacheFiguresTheServerDoesNotReport() async throws {
        let withCache = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "total_input_tokens": 100,
          "total_cache_read_tokens": 300,
          "total_cache_hit_percent": 75
        }
        """)

        let cachedInput = try XCTUnwrap(withCache.totalsCells.first { $0.id == "cachedInput" })
        XCTAssertEqual(cachedInput.value, "300")
        XCTAssertEqual(cachedInput.detail, "75% of observed input")
        XCTAssertNotNil(withCache.totalsCells.first { $0.id == "cacheHitRate" })

        let withoutCache = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "total_input_tokens": 100
        }
        """)

        XCTAssertNil(withoutCache.totalsCells.first { $0.id == "cachedInput" })
        XCTAssertNil(withoutCache.totalsCells.first { $0.id == "cacheHitRate" })
    }

    @MainActor
    func testTotalsCellsNameActivityBucketsForWhatTheyAre() async throws {
        let viewModel = try await loadedViewModel(timeframe: .last7Days, json: """
        {
          "period_days": 7,
          "activity_by_day": [{"day": "Mon", "sessions": 3}, {"day": "Thu", "sessions": 20}],
          "activity_by_hour": [{"hour": 2, "sessions": 7}, {"hour": 16, "sessions": 4}]
        }
        """)

        let weekday = try XCTUnwrap(viewModel.totalsCells.first { $0.id == "busiestWeekday" })
        XCTAssertEqual(weekday.label, "Busiest weekday")
        XCTAssertEqual(weekday.value, "Thu")
        XCTAssertEqual(weekday.detail, "20 sessions")

        let hour = try XCTUnwrap(viewModel.totalsCells.first { $0.id == "busiestHour" })
        XCTAssertEqual(hour.detail, "7 sessions")
    }

    @MainActor
    func testRefreshSpinnerOnlyMarksAReFetchOfLoadedData() async throws {
        let client = DelayedInsightsClient(
            firstResponse: try decodeInsights(#"{"period_days": 30, "total_tokens": 350}"#)
        )
        let viewModel = InsightsViewModel(client: client)

        let firstLoad = Task { await viewModel.load() }
        await firstLoad.value
        XCTAssertFalse(viewModel.isRefreshing)

        viewModel.selectedTimeframe = .last7Days
        let refreshTask = Task { await viewModel.load() }
        await client.waitForPendingRequest()

        XCTAssertTrue(viewModel.isRefreshing)

        client.completePendingRequest(with: .success(try decodeInsights(#"{"period_days": 7}"#)))
        await refreshTask.value

        XCTAssertFalse(viewModel.isRefreshing)
    }

    @MainActor
    private func loadedViewModel(timeframe: AnalyticsTimeframe, json: String) async throws -> InsightsViewModel {
        let client = StubInsightsClient(
            insightsResult: .success(try decodeInsights(json)),
            sessionsResult: .failure(StubInsightsError())
        )
        let viewModel = InsightsViewModel(client: client)
        viewModel.selectedTimeframe = timeframe
        await viewModel.load()
        return viewModel
    }

    private func decodeSessions(_ objects: [String]) throws -> [SessionSummary] {
        let json = "[\(objects.joined(separator: ","))]"
        return try JSONDecoder().decode([SessionSummary].self, from: Data(json.utf8))
    }

    private func decodeInsights(_ json: String) throws -> InsightsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(InsightsResponse.self, from: Data(json.utf8))
    }

    private func sessionJSON(
        title: String,
        createdAt: Double? = 1_800_000_000,
        updatedAt: Double? = nil,
        lastMessageAt: Double? = nil,
        messageCount: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        estimatedCost: Double? = nil
    ) -> String {
        var fields = [
            #""sessionId":"\#(UUID().uuidString)""#,
            #""title":"\#(title)""#
        ]

        append("createdAt", createdAt, to: &fields)
        append("updatedAt", updatedAt, to: &fields)
        append("lastMessageAt", lastMessageAt, to: &fields)
        append("messageCount", messageCount, to: &fields)
        append("inputTokens", inputTokens, to: &fields)
        append("outputTokens", outputTokens, to: &fields)
        append("estimatedCost", estimatedCost, to: &fields)

        return "{\(fields.joined(separator: ","))}"
    }

    private func append(_ key: String, _ value: Double?, to fields: inout [String]) {
        guard let value else { return }
        fields.append(#""\#(key)":\#(value)"#)
    }

    private func append(_ key: String, _ value: Int?, to fields: inout [String]) {
        guard let value else { return }
        fields.append(#""\#(key)":\#(value)"#)
    }
}

private final class StubInsightsClient: InsightsDataClient {
    private let insightsResult: Result<InsightsResponse, Error>
    private let sessionsResult: Result<SessionsResponse, Error>
    private(set) var requestedDays: [Int] = []

    init(insightsResult: Result<InsightsResponse, Error>, sessionsResult: Result<SessionsResponse, Error>) {
        self.insightsResult = insightsResult
        self.sessionsResult = sessionsResult
    }

    func insights(days: Int) async throws -> InsightsResponse {
        requestedDays.append(days)
        return try insightsResult.get()
    }

    func sessions() async throws -> SessionsResponse {
        try sessionsResult.get()
    }
}

private struct StubInsightsError: LocalizedError {
    var errorDescription: String? {
        "Server insights unavailable"
    }
}

@MainActor
private final class DelayedInsightsClient: InsightsDataClient {
    private var firstResponse: InsightsResponse?
    private var pendingContinuation: CheckedContinuation<InsightsResponse, Error>?

    init(firstResponse: InsightsResponse) {
        self.firstResponse = firstResponse
    }

    func insights(days: Int) async throws -> InsightsResponse {
        if let response = firstResponse {
            firstResponse = nil
            return response
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func sessions() async throws -> SessionsResponse {
        throw StubInsightsError()
    }

    func waitForPendingRequest() async {
        while pendingContinuation == nil {
            await Task.yield()
        }
    }

    func completePendingRequest(with result: Result<InsightsResponse, Error>) {
        pendingContinuation?.resume(with: result)
        pendingContinuation = nil
    }
}
