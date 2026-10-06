import Foundation

/// The Usage screen's client on a Hermes host (#1074): one Profile's analytics over the sign-in,
/// headers and cookie jar the server's Bot screens share. A window is three reads made together:
/// `/api/analytics/usage` (totals, cost and the daily chart) and `/api/analytics/models` (the
/// models card), both `?days=&profile=`, and `insights.get` over the shared gateway socket for
/// the message count. They become webui's `InsightsResponse` (`init(hermesUsage:models:counts:now:)`).
/// The host reports no hours, no provider limits until #710, and has no sessions list here
/// (`insightsFeatures`), so Limits stay empty and a failed read is the screen's error. A store
/// the host can't read, its 503 or `insights.get`'s 5017, is `HermesInsightsUnavailable`.
@MainActor final class HermesInsightsClient: InsightsDataClient {
    nonisolated var insightsFeatures: InsightsFeatures { .hermes }
    /// The Profile every read names: the inbox's selected one.
    let profile: String
    private let http: HermesConnection

    /// `profile`'s usage on `server`'s saved connection, on the sign-in its Bot screens share.
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

    /// No provider is offered, so the Limits group never probes or shows (#710 adds the route).
    func providers() async throws -> ProvidersResponse {
        ProvidersResponse(providers: [], activeProvider: nil)
    }

    // The screen never asks a Hermes host for these (`insightsFeatures`).

    func sessions() async throws -> SessionsResponse { throw BotFailure.unsupported }
    func providerQuota(provider _: String, refresh _: Bool) async throws -> ProviderQuotaResponse {
        throw BotFailure.unsupported
    }

    // MARK: - Wire

    /// One analytics read's JSON. The host's own 503 names a store it can't read; any other
    /// failure reads as the Tasks screens' do (`HermesCronClient.accepted`), and a dropped request
    /// as the webui's network failure.
    private func read(_ rest: HermesREST) async throws -> BotJSON {
        let reply: (body: Data, status: Int)
        do { reply = try await http.reply(rest) } catch let error as URLError { throw APIError.network(underlying: error) }
        let body = try? JSONDecoder().decode(BotJSON.self, from: reply.body)
        if reply.status == 503, body?["detail"]["error"].text?.hasPrefix("state_db") == true { throw HermesInsightsUnavailable() }
        _ = try HermesCronClient.accepted(reply)
        guard let body else { throw APIError.decoding(underlying: HermesInsightsShapeError()) }
        return body
    }

    /// One gateway call on its own attachment to the connection's shared socket, left once the
    /// host answers.
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
}

/// The host could not read the Profile's session store (#1074).
struct HermesInsightsUnavailable: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "Hermes couldn’t read this Profile’s session history. Run hermes doctor on the host, then try again.")
    }
}

/// An analytics reply without the lists or totals every window has.
private struct HermesInsightsShapeError: Error {}

extension InsightsResponse {
    /// A Hermes host's window (#1074) as webui's insights. Totals, sessions, cost and the daily
    /// chart come from `usage`, the models card from `models`, and messages from `counts`
    /// (`insights.get`), which counts only visible sessions among the newest 500, so the screen
    /// marks them approximate. Cost is the host's estimate, as webui's is. The host leaves cache
    /// reads out of `input_tokens` and reports no cache writes, so the hit rate, cache reads over
    /// input plus cache reads, reads a little above webui's. A sum over an empty window arrives as
    /// null and reads as 0. `daily` lists only days with sessions, by UTC date, so the chart is
    /// carried on to `now`'s UTC day. Each model and billing provider is its own row, in the host's
    /// order, with shares of the rows' own sums. A reply missing its totals or lists is a failed read.
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

/// How a Hermes host's analytics numbers read (#1074).
private enum HermesAnalytics {
    /// A token or session count: a whole number from 0 to 2^53, so no sum of a few can overflow;
    /// null, negative or unreadable reads as 0.
    static func count(_ value: BotJSON) -> Int {
        guard let number = value.number, number.isFinite else { return 0 }
        return Int(min(max(number.rounded(), 0), 9_007_199_254_740_992))
    }

    /// A dollar amount, 0 when null, negative or unreadable.
    static func amount(_ value: BotJSON) -> Double {
        guard let number = value.number, number.isFinite else { return 0 }
        return max(number, 0)
    }

    /// Cache reads as a whole percent of everything the model was shown, capped at 100, as webui's
    /// `prompt_cache_hit_percent`: nil without cache reads.
    static func cacheHitPercent(cacheRead: Int, input: Int) -> Double? {
        guard cacheRead > 0 else { return nil }
        return min(100, (Double(cacheRead) / (Double(input) + Double(cacheRead)) * 100).rounded())
    }

    /// `part` as a whole percent of `whole`, 0 when the whole is.
    static func share(_ part: Double, of whole: Double) -> Int {
        whole > 0 ? Int((part / whole * 100).rounded()) : 0
    }

    /// `yyyy-MM-dd` in UTC, the calendar the host groups its days in.
    static let utcDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
