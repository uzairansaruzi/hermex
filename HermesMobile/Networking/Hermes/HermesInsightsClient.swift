import Foundation

@MainActor final class HermesInsightsClient: InsightsDataClient {
    nonisolated var insightsFeatures: InsightsFeatures { .hermes }
    let profile: String
    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL, profile: String) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server), profile: profile)
    }

    init(http: HermesConnection, profile: String) {
        self.http = http
        self.profile = profile
    }

    func insights(days: Int) async throws -> InsightsResponse {
        async let usage = read(.analyticsUsage(days: days, profile: profile))
        async let models = read(.analyticsModels(days: days, profile: profile))
        async let counts = gateway(.insightsGet(days: days, profile: profile))
        return try await InsightsResponse(hermesUsage: usage, models: models, counts: counts)
    }

    func providers() async throws -> ProvidersResponse {
        guard try await BotDashboardClient(http: http).companionRoutes().supports("GET /provider-quota") else {
            return ProvidersResponse(providers: [], activeProvider: nil)
        }
        let options = try await gateway(.profileModelOptions(profile: profile))
        let providers = (options["providers"].list ?? []).compactMap { row -> ProviderSummary? in
            guard let slug = row["slug"].text, !slug.isEmpty else { return nil }
            return ProviderSummary(id: slug, displayName: row["name"].text, hasKey: row["authenticated"].flag != false)
        }
        return ProvidersResponse(providers: providers, activeProvider: options["provider"].text)
    }

    func providerQuota(provider: String, refresh: Bool) async throws -> ProviderQuotaResponse {
        let reply = try await http.reply(.companionProviderQuota(provider: provider, profile: profile, refresh: refresh),
                                         deadline: .provisioning)
        return try Self.quotaDecoder.decode(ProviderQuotaResponse.self, from: HermesCronClient.accepted(reply))
    }

    func sessions() async throws -> SessionsResponse { throw BotFailure.unsupported }

    private func read(_ rest: HermesREST) async throws -> BotJSON {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest) } catch let error as URLError { throw APIError.network(underlying: error) }
        let body = try? JSONDecoder().decode(BotJSON.self, from: reply.body)
        if reply.status == 503, body?["detail"]["error"].text?.hasPrefix("state_db") == true { throw HermesInsightsUnavailable() }
        _ = try HermesCronClient.accepted(reply)
        guard let body else { throw APIError.decoding(underlying: HermesInsightsShapeError()) }
        return body
    }

    private func gateway(_ call: HermesCall) async throws -> BotJSON {
        let client = BotClient(http: http)
        defer { client.close() }
        do {
            try await client.connect()
            return try await client.call(call)
        } catch BotFailure.rejected(5017) {
            throw HermesInsightsUnavailable()
        }
    }

    private static let quotaDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

struct HermesInsightsUnavailable: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "Hermes couldn’t read this Profile’s session history. Run hermes doctor on the host, then try again.")
    }
}

private struct HermesInsightsShapeError: Error {}

extension InsightsResponse {
    init(hermesUsage usage: BotJSON, models: BotJSON, counts: BotJSON, now: Date = .now) throws {
        let totals = usage["totals"]
        guard totals.fields != nil, let daily = usage["daily"].list, let rows = models["models"].list else {
            throw APIError.decoding(underlying: HermesInsightsShapeError())
        }
        let count = HermesAnalytics.count, amount = HermesAnalytics.amount
        let input = count(totals["total_input"]), output = count(totals["total_output"])
        let cacheRead = count(totals["total_cache_read"])

        var days = daily.map { row in
            InsightsDailyToken(date: row["day"].text, inputTokens: count(row["input_tokens"]), outputTokens: count(row["output_tokens"]),
                               cacheReadTokens: count(row["cache_read_tokens"]), sessions: count(row["sessions"]),
                               cost: amount(row["estimated_cost"]))
        }
        let today = HermesAnalytics.utcDay.string(from: now)
        if days.compactMap(\.date).max().map({ $0 < today }) ?? true {
            days.append(InsightsDailyToken(date: today, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, sessions: 0, cost: 0))
        }

        let named = { (value: BotJSON) in value.text.flatMap { $0.isEmpty ? nil : $0 } }
        let breakdowns = rows.map { row in
            (model: named(row["model"]), provider: named(row["provider"]), input: count(row["input_tokens"]),
             output: count(row["output_tokens"]), cacheRead: count(row["cache_read_tokens"]), sessions: count(row["sessions"]),
             cost: amount(row["estimated_cost"]))
        }
        let allSessions = breakdowns.reduce(0) { $0 + Double($1.sessions) }
        let allTokens = breakdowns.reduce(0) { $0 + Double($1.input + $1.output) }
        let allCost = breakdowns.reduce(0) { $0 + $1.cost }

        self.init(
            periodDays: usage["period_days"].integer,
            totalSessions: count(totals["total_sessions"]),
            totalMessages: count(counts["messages"]),
            totalInputTokens: input,
            totalOutputTokens: output,
            totalTokens: input + output,
            totalCost: amount(totals["total_estimated_cost"]),
            totalCacheReadTokens: cacheRead,
            totalCacheHitPercent: HermesAnalytics.cacheHitPercent(cacheRead: cacheRead, input: input),
            models: breakdowns.map { row in
                InsightsModelBreakdown(
                    model: row.model, provider: row.provider, sessions: row.sessions, inputTokens: row.input,
                    outputTokens: row.output, cacheReadTokens: row.cacheRead, totalTokens: row.input + row.output, cost: row.cost,
                    cacheHitPercent: HermesAnalytics.cacheHitPercent(cacheRead: row.cacheRead, input: row.input),
                    sessionShare: HermesAnalytics.share(Double(row.sessions), of: allSessions),
                    tokenShare: HermesAnalytics.share(Double(row.input + row.output), of: allTokens),
                    costShare: HermesAnalytics.share(row.cost, of: allCost)
                )
            },
            dailyTokens: days,
            activityByDay: nil,
            activityByHour: nil
        )
    }
}

private enum HermesAnalytics {
    static func count(_ value: BotJSON) -> Int {
        guard let number = value.number, number.isFinite else { return 0 }
        return Int(min(max(number.rounded(), 0), 9_007_199_254_740_992))
    }

    static func amount(_ value: BotJSON) -> Double {
        guard let number = value.number, number.isFinite else { return 0 }
        return max(number, 0)
    }

    static func cacheHitPercent(cacheRead: Int, input: Int) -> Double? {
        guard cacheRead > 0 else { return nil }
        return min(100, (Double(cacheRead) / (Double(input) + Double(cacheRead)) * 100).rounded())
    }

    static func share(_ part: Double, of whole: Double) -> Int {
        whole > 0 ? Int((part / whole * 100).rounded()) : 0
    }

    static let utcDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
