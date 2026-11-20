import Foundation
import Observation

protocol InsightsDataClient: Sendable {
    var insightsFeatures: InsightsFeatures { get }
    func sessions() async throws -> SessionsResponse
    func insights(days: Int) async throws -> InsightsResponse
    func providers() async throws -> ProvidersResponse
    func providerQuota(provider: String, refresh: Bool) async throws -> ProviderQuotaResponse
}

extension APIClient: InsightsDataClient {
    nonisolated var insightsFeatures: InsightsFeatures { .webui }
}

struct InsightsFeatures: Equatable, Sendable {
    let timeframes: [AnalyticsTimeframe]
    let approximatesMessages: Bool
    let fallsBackToSessions: Bool

    static let webui = InsightsFeatures(timeframes: [.today, .last7Days, .last30Days, .last90Days],
                                        approximatesMessages: false,
                                        fallsBackToSessions: true)
    static let hermes = InsightsFeatures(timeframes: [.last24Hours, .last7Days, .last30Days, .last90Days],
                                         approximatesMessages: true, fallsBackToSessions: false)
}

enum AnalyticsTimeframe: String, CaseIterable, Identifiable {
    case today
    case last24Hours
    case last7Days
    case last30Days
    case last90Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:
            String(localized: "Today")
        case .last24Hours:
            String(localized: "24 hours")
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
        case .today, .last24Hours:
            1
        case .last7Days:
            7
        case .last30Days:
            30
        case .last90Days:
            90
        }
    }

    var isHourly: Bool {
        self == .today
    }

    var showsChart: Bool {
        self != .last24Hours
    }

    func contains(_ session: SessionSummary, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let timestamp = session.analyticsTimestamp else {
            return false
        }

        let sessionDate = Date(timeIntervalSince1970: timestamp)

        switch self {
        case .today:
            return calendar.isDate(sessionDate, inSameDayAs: now)
        case .last24Hours, .last7Days, .last30Days, .last90Days:
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
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var lastError: Error?
    private(set) var dataSource: InsightsDataSource = .local
    private(set) var fallbackReason: String?
    private(set) var limitCards: [ProviderLimitCard] = []
    private(set) var isLoadingLimits = false
    private(set) var staleLimitIDs: Set<String> = []
    private var activeLoadID: UUID?
    private var limitsGeneration = 0

    private let client: any InsightsDataClient
    private let limitsScope: ProviderLimitsPublisher.Scope?
    private let limitsPublisher: ProviderLimitsPublisher?

    init(client: any InsightsDataClient, publishesLimits limitsScope: ProviderLimitsPublisher.Scope? = nil,
         publisher: ProviderLimitsPublisher? = nil) {
        self.client = client
        self.limitsScope = limitsScope
        limitsPublisher = limitsScope == nil ? nil : publisher ?? .shared
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
            guard features.fallsBackToSessions else {
                serverInsights = nil
                dataSource = .local
                errorMessage = error.localizedDescription
                return
            }
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

    func loadLimits(refresh: Bool = false) async {
        limitsGeneration += 1
        let generation = limitsGeneration
        let ticket = limitsScope.flatMap { limitsPublisher?.ticket(for: $0) }
        defer {
            if generation == limitsGeneration {
                isLoadingLimits = false
            }
        }

        let selection: [String]
        do {
            selection = providerQuotaSelection(from: try await client.providers())
        } catch {
            guard generation == limitsGeneration, !Task.isCancelled else { return }
            staleLimitIDs = Set(limitCards.map(\.id))
            return
        }

        guard generation == limitsGeneration, !Task.isCancelled else { return }
        guard !selection.isEmpty else {
            limitCards = []
            staleLimitIDs = []
            publishLimits(with: ticket)
            return
        }

        isLoadingLimits = true

        let fetchedAt = Date()
        let probes = await withTaskGroup(of: (Int, LimitProbe).self) { group in
            for (index, provider) in selection.enumerated() {
                group.addTask { [client] in
                    do {
                        let response = try await client.providerQuota(provider: provider, refresh: refresh)
                        return (index, LimitProbe(provider: provider, response: response, fetchedAt: fetchedAt))
                    } catch {
                        return (index, .failed)
                    }
                }
            }

            var probes = Array(repeating: LimitProbe.failed, count: selection.count)
            for await (index, probe) in group {
                probes[index] = probe
            }
            return probes
        }

        guard generation == limitsGeneration, !Task.isCancelled else { return }
        var cards: [ProviderLimitCard] = []
        var stale: Set<String> = []
        for (provider, probe) in zip(selection, probes) {
            switch probe {
            case .card(let card):
                cards.append(card)
            case .gone:
                break
            case .failed:
                if let previous = limitCards.first(where: { $0.id == provider }) {
                    cards.append(previous)
                    stale.insert(provider)
                }
            }
        }
        limitCards = cards
        staleLimitIDs = stale
        publishLimits(with: ticket)
    }

    private func publishLimits(with ticket: ProviderLimitsPublisher.Ticket?) {
        guard let ticket else { return }
        limitsPublisher?.publish(limitCards, stale: staleLimitIDs, with: ticket)
    }

    var features: InsightsFeatures {
        client.insightsFeatures
    }

    var timeframes: [AnalyticsTimeframe] {
        features.timeframes
    }

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

    var isRefreshing: Bool {
        isLoading && hasLoadedAnalytics
    }

    var showsLimits: Bool {
        !limitCards.isEmpty || isLoadingLimits
    }

    var sourceDescription: String {
        switch dataSource {
        case .server where loadedTimeframe == .last24Hours:
            return String(localized: "Source: server insights from the last 24 hours.")
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

    private var chosenMetric: UsageMetric?

    var metric: UsageMetric {
        get { chosenMetric ?? (estimatedCost > 0 ? .cost : .tokens) }
        set { chosenMetric = newValue }
    }

    var showsMetricToggle: Bool {
        !loadedTimeframe.isHourly
    }

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

    private var dailyBuckets: [UsageBucket] {
        guard let serverInsights else { return [] }
        return UsageBuckets.daily(from: serverInsights.dailyTokens ?? [], windowDays: periodDays)
    }

    var activeDayCount: Int {
        dailyBuckets.filter(\.hasActivity).count
    }

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

    var hourlyChartNote: String? {
        guard loadedTimeframe.isHourly else { return nil }
        return String(localized: "Sessions per hour — the server does not report hourly tokens or cost.")
    }

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
            value: (features.approximatesMessages ? "≈" : "") + usageFormattedTokens(totalMessages),
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
        guard loadedTimeframe != .last24Hours else { return nil }
        let activeDays = activeDayCount
        guard activeDays > 0 else { return nil }
        return String(localized: "\(usageFormattedTokens(totalTokens / activeDays)) per active day")
    }

    private func cachedInputDetail(cacheReadTokens: Int) -> String? {
        let observedInput = totalInputTokens + cacheReadTokens
        guard observedInput > 0 else { return nil }
        let share = Double(cacheReadTokens) / Double(observedInput) * 100
        return String(localized: "\(insightsFormattedPercent(share)) of observed input")
    }

    var topSessions: [SessionSummary] {
        guard dataSource != .server else { return [] }
        return analytics.topSessions
    }
}

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

private enum LimitProbe {
    case card(ProviderLimitCard)
    case gone
    case failed

    init(provider: String, response: ProviderQuotaResponse, fetchedAt: Date) {
        if let card = ProviderLimitCard(provider: provider, response: response, fetchedAt: fetchedAt) {
            self = .card(card)
            return
        }

        switch response.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "unsupported", "no_key", "invalid_key":
            self = .gone
        default:
            self = .failed
        }
    }
}
