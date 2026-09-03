import Foundation
import SwiftUI

/// The figure the Usage hero and chart plot over a multi-day window.
///
/// The 24-hour window has neither: `activity_by_hour` reports session counts and
/// nothing else, so that window ignores the metric entirely.
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

/// What one chart bar knows about itself.
///
/// A `day` bucket carries a full `daily_tokens` row. An `hour` bucket comes from
/// `activity_by_hour`, which reports session counts only — there is deliberately
/// nowhere to put tokens or cost on it.
enum UsageBucketDetail: Equatable {
    case day(input: Int, output: Int, cacheRead: Int, sessions: Int, cost: Double)
    case hour(sessions: Int)
}

/// One bar in the Usage chart, in window order.
struct UsageBucket: Identifiable, Equatable {
    /// Position in the window. Stable for as long as a window is on screen, which
    /// keeps chart identity from churning while values refresh.
    let id: Int
    /// Short axis label, localized ("Aug 28", "9 AM").
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

    var totalTokens: Int {
        switch detail {
        case let .day(input, output, _, _, _):
            input + output
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

    /// A bucket counts as active when it moved tokens or ran sessions. Cost is
    /// excluded on purpose: a server that prices everything at zero still has
    /// activity worth charting.
    var hasActivity: Bool {
        totalTokens > 0 || sessions > 0
    }
}

/// A stack layer, or a whole bar when the metric has nothing to stack.
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

/// One Swift Charts mark: a bucket's contribution for one segment.
struct UsageChartPoint: Identifiable, Equatable {
    let bucketID: Int
    let bucketLabel: String
    let segment: UsageChartSegment
    let value: Double

    var id: String { "\(bucketID)-\(segment.rawValue)" }
}

/// The three lines of the hero figure above the chart.
struct UsageHeroFigure: Equatable {
    let label: String
    let value: String
    let caption: String
}

enum UsageBuckets {
    /// Daily buckets for the 7 / 30 / 90-day windows.
    ///
    /// The server already returns one row per calendar day, but gaps are filled
    /// between the first and last returned date and the front is padded up to
    /// `windowDays` so the x-axis always spans the whole window. Every date is
    /// derived from the server's own strings, so the app never has to guess which
    /// calendar the server keeps.
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

        // Pad the leading edge so a short series still spans the requested window.
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

    /// Hourly buckets for the 24-hour window: hours 0–23 in order, session counts
    /// only, zero-filled for hours the server omits.
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
    /// The stack layers this bucket draws for `metric`, in bottom-to-top order.
    /// Token windows stack input, output, and cache reads; cost windows and the
    /// 24-hour window get a single layer, because the server reports one scalar.
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

/// Flattens buckets into chart marks, one per bucket and segment.
func usageChartPoints(buckets: [UsageBucket], metric: UsageMetric) -> [UsageChartPoint] {
    buckets.flatMap { bucket in
        bucket.segments(for: metric).map {
            UsageChartPoint(bucketID: bucket.id, bucketLabel: bucket.label, segment: $0.segment, value: $0.value)
        }
    }
}

/// The segments that earn a legend. A single-colour bar does not need one.
func usageChartLegendSegments(buckets: [UsageBucket], metric: UsageMetric) -> [UsageChartSegment] {
    guard metric == .tokens, buckets.contains(where: { if case .day = $0.detail { return true } else { return false } }) else {
        return []
    }
    return [.input, .output, .cacheRead]
}

extension UsageHeroFigure {
    /// The hero while the user drags across the chart: the selected bucket's own
    /// figures, not the window total.
    static func selection(_ bucket: UsageBucket, metric: UsageMetric) -> UsageHeroFigure {
        switch bucket.detail {
        case let .day(_, _, _, sessions, cost):
            let sessionsText = String(localized: "\(sessions) sessions")
            switch metric {
            case .tokens:
                let caption = cost > 0 ? "\(usageFormattedCost(cost)) · \(sessionsText)" : sessionsText
                return UsageHeroFigure(
                    label: bucket.label,
                    value: usageFormattedTokens(bucket.totalTokens),
                    caption: caption
                )
            case .cost:
                let tokensText = String(localized: "\(usageFormattedTokens(bucket.totalTokens)) tokens")
                return UsageHeroFigure(
                    label: bucket.label,
                    value: usageFormattedCost(cost),
                    caption: "\(tokensText) · \(sessionsText)"
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
    /// What VoiceOver reads for the bar, since the visual hero only appears while
    /// a sighted user is dragging. The bar's accessibility label is its `label`.
    var accessibilityValue: String {
        switch detail {
        case let .day(_, _, _, sessions, cost):
            var parts = [
                String(localized: "\(usageFormattedTokens(totalTokens)) tokens"),
                String(localized: "\(sessions) sessions")
            ]
            if cost > 0 {
                parts.append(usageFormattedCost(cost))
            }
            return parts.joined(separator: ", ")
        case let .hour(sessions):
            return String(localized: "\(sessions) sessions")
        }
    }
}

// MARK: - Formatting

/// The calendar the Usage screen reads server day strings with. The server sends
/// bare `YYYY-MM-DD` in its own local time, so days are treated as wall-clock
/// dates rather than instants.
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

/// Parses a server `daily_tokens[].date` string. Returns nil for anything else,
/// so a shape change drops the bar instead of inventing a date.
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

/// Locale-aware grouped token count ("1,234,567").
func usageFormattedTokens(_ value: Int, locale: Locale = .current) -> String {
    value.formatted(.number.locale(locale))
}

/// Formats a server-reported amount. The server prices in USD whatever the
/// user's locale is, so the currency code is fixed and only the presentation
/// localizes. Amounts under a cent keep four digits rather than rounding away to
/// nothing.
func usageFormattedCost(_ value: Double, locale: Locale = .current) -> String {
    let fractionDigits = (value > 0 && value < 0.01) ? 4 : 2
    return value.formatted(
        .currency(code: "USD").precision(.fractionLength(fractionDigits)).locale(locale)
    )
}
