import Foundation
import SwiftUI

enum UsageMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost:
            String(localized: "Cost")
        case .tokens:
            String(localized: "Tokens")
        }
    }
}

enum UsageBucketDetail: Equatable {
    case day(input: Int, output: Int, cacheRead: Int, sessions: Int, cost: Double)
    case hour(sessions: Int)
}

struct UsageBucket: Identifiable, Equatable {
    let id: Int
    let label: String
    let detail: UsageBucketDetail

    var sessions: Int {
        switch detail {
        case let .day(_, _, _, sessions, _):
            sessions
        case let .hour(sessions):
            sessions
        }
    }

    var processedTokens: Int {
        switch detail {
        case let .day(input, output, _, _, _):
            input + output
        case .hour:
            0
        }
    }

    var cacheReadTokens: Int {
        switch detail {
        case let .day(_, _, cacheRead, _, _):
            cacheRead
        case .hour:
            0
        }
    }

    var cost: Double {
        switch detail {
        case let .day(_, _, _, _, cost):
            cost
        case .hour:
            0
        }
    }

    var hasActivity: Bool {
        processedTokens > 0 || cacheReadTokens > 0 || sessions > 0
    }
}

enum UsageChartSegment: String, Identifiable, CaseIterable {
    case input
    case output
    case cacheRead
    case cost
    case sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .input:
            String(localized: "Input")
        case .output:
            String(localized: "Output")
        case .cacheRead:
            String(localized: "Cache read")
        case .cost:
            String(localized: "Cost")
        case .sessions:
            String(localized: "Sessions")
        }
    }

    var color: Color {
        switch self {
        case .input:
            .blue
        case .output:
            .orange
        case .cacheRead:
            .teal
        case .cost:
            .indigo
        case .sessions:
            .purple
        }
    }
}

struct UsageHeroFigure: Equatable {
    let label: String
    let value: String
    let caption: String
}

enum UsageBuckets {
    static func daily(
        from rows: [InsightsDailyToken],
        windowDays: Int,
        calendar: Calendar = usageCalendar
    ) -> [UsageBucket] {
        let parsed: [(date: Date, row: InsightsDailyToken)] = rows.compactMap { row in
            guard let date = usageDate(fromServerDay: row.date, calendar: calendar) else { return nil }
            return (date, row)
        }

        guard let first = parsed.map(\.date).min(), let last = parsed.map(\.date).max() else {
            return []
        }

        let byDay = Dictionary(parsed.map { ($0.date, $0.row) }, uniquingKeysWith: { _, latest in latest })
        var dates: [Date] = []
        var cursor = first
        while cursor <= last {
            dates.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        while dates.count < windowDays, let earlier = calendar.date(byAdding: .day, value: -1, to: dates[0]) {
            dates.insert(earlier, at: 0)
        }

        return dates.enumerated().map { index, date in
            let row = byDay[date]
            return UsageBucket(
                id: index,
                label: usageDayLabel(date, calendar: calendar),
                detail: .day(
                    input: row?.inputTokens ?? 0,
                    output: row?.outputTokens ?? 0,
                    cacheRead: row?.cacheReadTokens ?? 0,
                    sessions: row?.sessions ?? 0,
                    cost: row?.cost ?? 0
                )
            )
        }
    }

    static func hourly(
        from rows: [InsightsActivityByHour],
        calendar: Calendar = usageCalendar
    ) -> [UsageBucket] {
        let sessionsByHour = Dictionary(
            rows.compactMap { row -> (Int, Int)? in
                guard let hour = row.hour, (0...23).contains(hour) else { return nil }
                return (hour, row.sessions ?? 0)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        guard !sessionsByHour.isEmpty else { return [] }

        return (0...23).map { hour in
            UsageBucket(
                id: hour,
                label: usageHourLabel(hour, calendar: calendar),
                detail: .hour(sessions: sessionsByHour[hour] ?? 0)
            )
        }
    }
}

extension UsageBucket {
    func segments(for metric: UsageMetric) -> [(segment: UsageChartSegment, value: Double)] {
        switch detail {
        case let .day(input, output, cacheRead, _, cost):
            switch metric {
            case .tokens:
                return [
                    (.input, Double(input)),
                    (.output, Double(output)),
                    (.cacheRead, Double(cacheRead))
                ]
            case .cost:
                return [(.cost, cost)]
            }
        case let .hour(sessions):
            return [(.sessions, Double(sessions))]
        }
    }
}

func usageChartLegendSegments(buckets: [UsageBucket], metric: UsageMetric) -> [UsageChartSegment] {
    guard metric == .tokens, buckets.contains(where: { if case .day = $0.detail { return true } else { return false } }) else {
        return []
    }
    return [.input, .output, .cacheRead]
}

extension UsageHeroFigure {
    static func selection(_ bucket: UsageBucket, metric: UsageMetric) -> UsageHeroFigure {
        switch bucket.detail {
        case let .day(_, _, cacheRead, sessions, cost):
            let sessionsText = String(localized: "\(sessions) sessions")
            let cachedText = cacheRead > 0
                ? String(localized: "\(usageFormattedTokens(cacheRead)) cached")
                : nil

            switch metric {
            case .tokens:
                let caption = [cost > 0 ? usageFormattedCost(cost) : nil, cachedText, sessionsText]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return UsageHeroFigure(
                    label: bucket.label,
                    value: usageFormattedTokens(bucket.processedTokens),
                    caption: caption
                )
            case .cost:
                let tokensText = String(localized: "\(usageFormattedTokens(bucket.processedTokens)) tokens")
                let caption = [tokensText, cachedText, sessionsText]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return UsageHeroFigure(
                    label: bucket.label,
                    value: usageFormattedCost(cost),
                    caption: caption
                )
            }
        case let .hour(sessions):
            return UsageHeroFigure(
                label: bucket.label,
                value: sessions.formatted(.number),
                caption: String(localized: "sessions started or updated in this hour")
            )
        }
    }
}

extension UsageBucket {
    var accessibilityValue: String {
        switch detail {
        case let .day(_, _, cacheRead, sessions, cost):
            var parts = [String(localized: "\(usageFormattedTokens(processedTokens)) tokens")]
            if cacheRead > 0 {
                parts.append(String(localized: "\(usageFormattedTokens(cacheRead)) cached"))
            }
            parts.append(String(localized: "\(sessions) sessions"))
            if cost > 0 {
                parts.append(usageFormattedCost(cost))
            }
            return parts.joined(separator: ", ")
        case let .hour(sessions):
            return String(localized: "\(sessions) sessions")
        }
    }
}

let usageCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

private let usageServerDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

func usageDate(fromServerDay value: String?, calendar: Calendar = usageCalendar) -> Date? {
    guard let value, !value.isEmpty, let date = usageServerDayFormatter.date(from: value) else {
        return nil
    }
    return calendar.startOfDay(for: date)
}

func usageDayLabel(_ date: Date, calendar: Calendar = usageCalendar, locale: Locale = .current) -> String {
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    return date.formatted(style.month(.abbreviated).day())
}

func usageHourLabel(_ hour: Int, calendar: Calendar = usageCalendar, locale: Locale = .current) -> String {
    var components = DateComponents()
    components.year = 2001
    components.month = 1
    components.day = 1
    components.hour = hour
    guard let date = calendar.date(from: components) else {
        return String(format: "%02d:00", hour)
    }
    return date.formatted(
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour()
    )
}

func usageFormattedTokens(_ value: Int, locale: Locale = .current) -> String {
    value.formatted(.number.locale(locale))
}

func usageFormattedCost(_ value: Double, locale: Locale = .current) -> String {
    let fractionDigits = (value > 0 && value < 0.01) ? 4 : 2
    return value.formatted(
        .currency(code: "USD").precision(.fractionLength(fractionDigits)).locale(locale)
    )
}
