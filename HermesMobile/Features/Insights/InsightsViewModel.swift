import Foundation
import Observation

protocol InsightsDataClient {
    func sessions() async throws -> SessionsResponse
    func insights(days: Int) async throws -> InsightsResponse
}

extension APIClient: InsightsDataClient {}

/// The windows the Usage screen offers. Each maps to a `days` value the insights
/// handler clamps to 1-365, and to a matching local filter for the session
/// metadata fallback.
enum AnalyticsTimeframe: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case last30Days
    case last90Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:
            // "Today", not "24h": the handler's days=1 means midnight-to-now,
            // and the local fallback filters on the same calendar day to match.
            String(localized: "Today")
        case .last7Days:
            String(localized: "7 days")
        case .last30Days:
            String(localized: "30 days")
        case .last90Days:
            String(localized: "90 days")
        }
    }

    var serverDays: Int {
        switch self {
        case .today:
            1
        case .last7Days:
            7
        case .last30Days:
            30
        case .last90Days:
            90
        }
    }

    /// True when the window plots hours rather than days. The server reports
    /// session counts per hour and nothing else, so this window has no metric.
    var isHourly: Bool {
        self == .today
    }

    func contains(_ session: SessionSummary, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let timestamp = session.analyticsTimestamp else {
            return false
        }

        let sessionDate = Date(timeIntervalSince1970: timestamp)

        switch self {
        case .today:
            return calendar.isDate(sessionDate, inSameDayAs: now)
        case .last7Days, .last30Days, .last90Days:
            let earliest = calendar.date(byAdding: .day, value: -serverDays, to: now) ?? now
            return sessionDate >= earliest && sessionDate <= now
        }
    }
}

struct SessionUsageAnalytics {
    let sessions: [SessionSummary]

    var totalInputTokens: Int {
        sessions.compactMap { $0.inputTokens }.reduce(0, +)
    }

    var totalOutputTokens: Int {
        sessions.compactMap { $0.outputTokens }.reduce(0, +)
    }

    var totalTokens: Int {
        totalInputTokens + totalOutputTokens
    }

    var totalMessages: Int {
        sessions.compactMap { $0.messageCount }.reduce(0, +)
    }

    var estimatedCost: Double {
        sessions.compactMap { $0.estimatedCost }.reduce(0, +)
    }

    var sessionCount: Int {
        sessions.count
    }

    var topSessions: [SessionSummary] {
        sessions.sorted {
            let leftTotal = ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0)
            let rightTotal = ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0)
            return leftTotal > rightTotal
        }
    }
}

enum InsightsDataSource: Equatable {
    case server
    case localFallback
    case local
}

@MainActor
@Observable
final class InsightsViewModel {
    private(set) var sessions: [SessionSummary] = []
    private(set) var serverInsights: InsightsResponse?
    var selectedTimeframe: AnalyticsTimeframe = .last30Days
    private(set) var loadedTimeframe: AnalyticsTimeframe = .last30Days
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private(set) var dataSource: InsightsDataSource = .local
    private(set) var fallbackReason: String?
    private var activeLoadID: UUID?

    private let client: any InsightsDataClient

    init(server: URL) {
        client = APIClient(baseURL: server)
    }

    init(client: any InsightsDataClient) {
        self.client = client
    }

    func load() async {
        let loadID = UUID()
        let timeframe = selectedTimeframe
        activeLoadID = loadID
        isLoading = true
        errorMessage = nil
        lastError = nil
        fallbackReason = nil
        let hadLoadedAnalytics = hasLoadedAnalytics
        defer {
            if activeLoadID == loadID {
                isLoading = false
            }
        }

        do {
            let response = try await client.insights(days: timeframe.serverDays)
            guard activeLoadID == loadID, !Task.isCancelled else { return }

            serverInsights = response
            sessions = []
            loadedTimeframe = timeframe
            dataSource = .server
        } catch is CancellationError {
            return
        } catch {
            guard activeLoadID == loadID, !Task.isCancelled else { return }
            lastError = error
            fallbackReason = error.localizedDescription

            do {
                let response = try await client.sessions()
                guard activeLoadID == loadID, !Task.isCancelled else { return }

                serverInsights = nil
                sessions = response.sessions ?? []
                loadedTimeframe = timeframe
                dataSource = .localFallback
            } catch is CancellationError {
                return
            } catch {
                guard activeLoadID == loadID, !Task.isCancelled else { return }
                lastError = error
                if hadLoadedAnalytics {
                    fallbackReason = error.localizedDescription
                } else {
                    errorMessage = error.localizedDescription
                    dataSource = .local
                }
            }
        }
    }

    // MARK: - Aggregates

    var analytics: SessionUsageAnalytics {
        SessionUsageAnalytics(sessions: filteredSessions)
    }

    var filteredSessions: [SessionSummary] {
        sessions.filter { loadedTimeframe.contains($0) }
    }

    var totalInputTokens: Int {
        serverInsights?.totalInputTokens ?? analytics.totalInputTokens
    }

    var totalOutputTokens: Int {
        serverInsights?.totalOutputTokens ?? analytics.totalOutputTokens
    }

    var totalTokens: Int {
        serverInsights?.totalTokens ?? analytics.totalTokens
    }

    var totalMessages: Int {
        serverInsights?.totalMessages ?? analytics.totalMessages
    }

    var estimatedCost: Double {
        serverInsights?.totalCost ?? analytics.estimatedCost
    }

    /// Cache stats only exist in server insights — nil hides the cards on
    /// the local fallback and on older servers that don't report them (#24).
    var totalCacheReadTokens: Int? {
        serverInsights?.totalCacheReadTokens
    }

    var totalCacheHitPercent: Double? {
        serverInsights?.totalCacheHitPercent
    }

    var sessionCount: Int {
        serverInsights?.totalSessions ?? analytics.sessionCount
    }

    var hasLoadedAnalytics: Bool {
        serverInsights != nil || dataSource == .localFallback
    }

    /// A re-fetch of something already on screen. The first load and a server
    /// that never answers both render a placeholder instead, so neither can pin
    /// the refresh spinner on.
    var isRefreshing: Bool {
        isLoading && hasLoadedAnalytics
    }

    var sourceDescription: String {
        switch dataSource {
        case .server:
            return String(localized: "Source: server insights from the last \(periodDays) days.")
        case .localFallback:
            if let fallbackReason, !fallbackReason.isEmpty {
                return String(localized: "Source: local session metadata fallback. Server insights failed: \(fallbackReason)")
            }
            return String(localized: "Source: local session metadata fallback.")
        case .local:
            return String(localized: "Source: local session metadata.")
        }
    }

    var periodTitle: String {
        loadedTimeframe.title
    }

    var periodDays: Int {
        serverInsights?.periodDays ?? selectedTimeframe.serverDays
    }

    var modelBreakdowns: [InsightsModelBreakdown] {
        serverInsights?.models ?? []
    }

    var activityByDay: [InsightsActivityByDay] {
        serverInsights?.activityByDay ?? []
    }

    var activityByHour: [InsightsActivityByHour] {
        serverInsights?.activityByHour ?? []
    }

    var peakDay: InsightsActivityByDay? {
        activityByDay.max { ($0.sessions ?? 0) < ($1.sessions ?? 0) }
    }

    var peakHour: InsightsActivityByHour? {
        activityByHour.max { ($0.sessions ?? 0) < ($1.sessions ?? 0) }
    }

    // MARK: - Chart

    /// The metric the user picked, or nil while the screen is following the data.
    private var chosenMetric: UsageMetric?

    /// The hero and chart metric. A window the server prices at zero opens on
    /// tokens rather than a confident $0.00, until the user says otherwise.
    var metric: UsageMetric {
        get { chosenMetric ?? (estimatedCost > 0 ? .cost : .tokens) }
        set { chosenMetric = newValue }
    }

    /// Hidden on the hourly window, which has only one figure to show.
    var showsMetricToggle: Bool {
        !loadedTimeframe.isHourly
    }

    /// The bars for the loaded window: one per hour on the 24-hour window, one
    /// per calendar day otherwise.
    var chartBuckets: [UsageBucket] {
        guard let serverInsights else { return [] }

        if loadedTimeframe.isHourly {
            return UsageBuckets.hourly(from: serverInsights.activityByHour ?? [])
        }

        return UsageBuckets.daily(
            from: serverInsights.dailyTokens ?? [],
            windowDays: periodDays
        )
    }

    /// Daily rows regardless of window, so "per active day" means the same thing
    /// on every screen.
    private var dailyBuckets: [UsageBucket] {
        guard let serverInsights else { return [] }
        return UsageBuckets.daily(from: serverInsights.dailyTokens ?? [], windowDays: periodDays)
    }

    /// Days in the window that actually did something. Dividing by the window
    /// length instead would quietly deflate every average.
    var activeDayCount: Int {
        dailyBuckets.filter(\.hasActivity).count
    }

    /// The window total, shown whenever the user is not dragging the chart.
    var heroFigure: UsageHeroFigure {
        if loadedTimeframe.isHourly {
            return UsageHeroFigure(
                label: String(localized: "Sessions"),
                value: sessionCount.formatted(.number),
                caption: String(localized: "Started or updated today.")
            )
        }

        switch metric {
        case .cost:
            return UsageHeroFigure(
                label: String(localized: "Estimated cost"),
                value: usageFormattedCost(estimatedCost),
                caption: String(localized: "Estimated by the server from session metadata.")
            )
        case .tokens:
            // "Processed", not "total": this is the server's `total_tokens`,
            // which excludes cache reads. The chart stacks those separately and
            // the totals grid names them, so the two labels have to agree.
            return UsageHeroFigure(
                label: String(localized: "Processed tokens"),
                value: usageFormattedTokens(totalTokens),
                caption: String(localized: "Across \(String(localized: "\(sessionCount) sessions")).")
            )
        }
    }

    var chartAccessibilityLabel: String {
        if loadedTimeframe.isHourly {
            return String(localized: "Sessions per hour, \(loadedTimeframe.title)")
        }

        switch metric {
        case .cost:
            return String(localized: "Estimated cost per day, \(loadedTimeframe.title)")
        case .tokens:
            return String(localized: "Tokens per day, \(loadedTimeframe.title)")
        }
    }

    /// The caption under the hourly chart, which plots something the metric
    /// toggle cannot describe.
    var hourlyChartNote: String? {
        guard loadedTimeframe.isHourly else { return nil }
        return String(localized: "Sessions per hour — the server does not report hourly tokens or cost.")
    }

    // MARK: - Totals

    /// The two-up grid under the chart. Cache cells drop out entirely on servers
    /// that do not report them (#24) and on the local fallback.
    var totalsCells: [UsageTotalsCell] {
        var cells: [UsageTotalsCell] = [
            UsageTotalsCell(
                id: "processedTokens",
                label: String(localized: "Processed tokens"),
                value: usageFormattedTokens(totalTokens),
                detail: perActiveDayDetail
            )
        ]

        if let cacheReadTokens = totalCacheReadTokens {
            cells.append(UsageTotalsCell(
                id: "cachedInput",
                label: String(localized: "Cached input"),
                value: usageFormattedTokens(cacheReadTokens),
                detail: cachedInputDetail(cacheReadTokens: cacheReadTokens)
            ))
        }

        if let cacheHitPercent = totalCacheHitPercent {
            cells.append(UsageTotalsCell(
                id: "cacheHitRate",
                label: String(localized: "Cache hit rate"),
                value: insightsFormattedPercent(cacheHitPercent),
                detail: String(localized: "reported by the server")
            ))
        }

        cells.append(UsageTotalsCell(
            id: "input",
            label: String(localized: "Input"),
            value: usageFormattedTokens(totalInputTokens),
            detail: String(localized: "uncached")
        ))

        cells.append(UsageTotalsCell(
            id: "output",
            label: String(localized: "Output"),
            value: usageFormattedTokens(totalOutputTokens),
            detail: nil
        ))

        cells.append(UsageTotalsCell(
            id: "messages",
            label: String(localized: "Messages"),
            value: usageFormattedTokens(totalMessages),
            detail: String(localized: "across \(String(localized: "\(sessionCount) sessions"))")
        ))

        if let peakDay, let day = peakDay.day, !day.isEmpty {
            cells.append(UsageTotalsCell(
                id: "busiestWeekday",
                label: String(localized: "Busiest weekday"),
                value: day,
                detail: String(localized: "\(peakDay.sessions ?? 0) sessions")
            ))
        }

        if let peakHour, let hour = peakHour.hour {
            cells.append(UsageTotalsCell(
                id: "busiestHour",
                label: String(localized: "Busiest hour"),
                value: usageHourLabel(hour),
                detail: String(localized: "\(peakHour.sessions ?? 0) sessions")
            ))
        }

        return cells
    }

    private var perActiveDayDetail: String? {
        let activeDays = activeDayCount
        guard activeDays > 0 else { return nil }
        return String(localized: "\(usageFormattedTokens(totalTokens / activeDays)) per active day")
    }

    /// Cached reads as a share of everything the model was shown, which is
    /// ordinary input plus cache reads — the same denominator the server uses.
    private func cachedInputDetail(cacheReadTokens: Int) -> String? {
        let observedInput = totalInputTokens + cacheReadTokens
        guard observedInput > 0 else { return nil }
        let share = Double(cacheReadTokens) / Double(observedInput) * 100
        return String(localized: "\(insightsFormattedPercent(share)) of observed input")
    }

    // MARK: - Top sessions

    /// All sessions sorted by total tokens (descending), with cost shown when available.
    /// Falls back to input-only or output-only if one is missing.
    var topSessions: [SessionSummary] {
        guard dataSource != .server else { return [] }
        return analytics.topSessions
    }
}

/// One cell in the Usage totals grid.
struct UsageTotalsCell: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let detail: String?
}

private extension SessionSummary {
    var analyticsTimestamp: Double? {
        lastMessageAt ?? updatedAt ?? createdAt
    }
}
