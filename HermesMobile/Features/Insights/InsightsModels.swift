import Foundation

struct InsightsResponse: Decodable, Equatable {
    let periodDays: Int?
    let totalSessions: Int?
    let totalMessages: Int?
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let totalTokens: Int?
    let totalCost: Double?
    let totalCacheReadTokens: Int?
    let totalCacheHitPercent: Double?
    let models: [InsightsModelBreakdown]?
    let dailyTokens: [InsightsDailyToken]?
    let activityByDay: [InsightsActivityByDay]?
    let activityByHour: [InsightsActivityByHour]?

    enum CodingKeys: String, CodingKey {
        case periodDays
        case totalSessions
        case totalMessages
        case totalInputTokens
        case totalOutputTokens
        case totalTokens
        case totalCost
        case totalCacheReadTokens
        case totalCacheHitPercent
        case models
        case dailyTokens
        case activityByDay
        case activityByHour
    }
}

extension InsightsResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        periodDays = container.decodeLossyIntIfPresent(forKey: .periodDays)
        totalSessions = container.decodeLossyIntIfPresent(forKey: .totalSessions)
        totalMessages = container.decodeLossyIntIfPresent(forKey: .totalMessages)
        totalInputTokens = container.decodeLossyIntIfPresent(forKey: .totalInputTokens)
        totalOutputTokens = container.decodeLossyIntIfPresent(forKey: .totalOutputTokens)
        totalTokens = container.decodeLossyIntIfPresent(forKey: .totalTokens)
        totalCost = container.decodeLossyCurrencyDoubleIfPresent(forKey: .totalCost)
        totalCacheReadTokens = container.decodeLossyIntIfPresent(forKey: .totalCacheReadTokens)
        totalCacheHitPercent = container.decodeLossyCurrencyDoubleIfPresent(forKey: .totalCacheHitPercent)
        models = (try? container.decodeIfPresent([InsightsModelBreakdown].self, forKey: .models)) ?? nil
        dailyTokens = (try? container.decodeIfPresent([InsightsDailyToken].self, forKey: .dailyTokens)) ?? nil
        activityByDay = (try? container.decodeIfPresent([InsightsActivityByDay].self, forKey: .activityByDay)) ?? nil
        activityByHour = (try? container.decodeIfPresent([InsightsActivityByHour].self, forKey: .activityByHour)) ?? nil
    }
}

struct InsightsModelBreakdown: Decodable, Equatable {
    let model: String?
    let provider: String?
    let sessions: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int?
    let cost: Double?
    let cacheHitPercent: Double?
    let sessionShare: Int?
    let tokenShare: Int?
    let costShare: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case provider
        case sessions
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case totalTokens
        case cost
        case cacheHitPercent
        case sessionShare
        case tokenShare
        case costShare
    }
}

extension InsightsModelBreakdown {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        provider = container.decodeLossyStringIfPresent(forKey: .provider)
        sessions = container.decodeLossyIntIfPresent(forKey: .sessions)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        cacheReadTokens = container.decodeLossyIntIfPresent(forKey: .cacheReadTokens)
        totalTokens = container.decodeLossyIntIfPresent(forKey: .totalTokens)
        cost = container.decodeLossyCurrencyDoubleIfPresent(forKey: .cost)
        cacheHitPercent = container.decodeLossyCurrencyDoubleIfPresent(forKey: .cacheHitPercent)
        sessionShare = container.decodeLossyIntIfPresent(forKey: .sessionShare)
        tokenShare = container.decodeLossyIntIfPresent(forKey: .tokenShare)
        costShare = container.decodeLossyIntIfPresent(forKey: .costShare)
    }

    var displayShare: Int? {
        let shares = [costShare, tokenShare, sessionShare].compactMap { $0 }
        return shares.first { $0 > 0 } ?? shares.first
    }
}

struct InsightsDailyToken: Decodable, Equatable {
    let date: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let sessions: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case sessions
        case cost
    }
}

extension InsightsDailyToken {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = container.decodeLossyStringIfPresent(forKey: .date)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        cacheReadTokens = container.decodeLossyIntIfPresent(forKey: .cacheReadTokens)
        sessions = container.decodeLossyIntIfPresent(forKey: .sessions)
        cost = container.decodeLossyCurrencyDoubleIfPresent(forKey: .cost)
    }
}

struct InsightsActivityByDay: Decodable, Equatable {
    let day: String?
    let sessions: Int?

    enum CodingKeys: String, CodingKey {
        case day
        case sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = container.decodeLossyStringIfPresent(forKey: .day)
        sessions = container.decodeLossyIntIfPresent(forKey: .sessions)
    }
}

struct InsightsActivityByHour: Decodable, Equatable {
    let hour: Int?
    let sessions: Int?

    enum CodingKeys: String, CodingKey {
        case hour
        case sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hour = container.decodeLossyIntIfPresent(forKey: .hour)
        sessions = container.decodeLossyIntIfPresent(forKey: .sessions)
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyCurrencyDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }

        guard let stringValue = try? decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        let normalized = stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")

        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }
}

func insightsFormattedPercent(_ value: Double, locale: Locale = .current) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
}

struct ProviderLimitCard: Identifiable, Equatable {
    let id: String
    let title: String
    let plan: String?
    let rows: [ProviderLimitRow]
    let updatedAt: Date?
}

struct ProviderLimitRow: Identifiable, Equatable {
    let id: String
    let label: String
    let amount: String?
    let fraction: Double?
    let remainingPercent: Double?
    let resetAt: Date?
    let note: String?
}

enum ProviderLimitTint: Equatable {
    case normal
    case warning
    case critical
}

func providerLimitTint(remainingPercent: Double?) -> ProviderLimitTint {
    guard let remainingPercent else { return .normal }

    if remainingPercent <= 10 { return .critical }
    if remainingPercent <= 25 { return .warning }
    return .normal
}

func providerLimitPercentLeftText(_ remainingPercent: Double) -> String {
    let clamped = min(max(remainingPercent, 0), 100)
    return String(localized: "\(Int(clamped.rounded()))% left")
}

func providerLimitAmountLeftText(_ amount: Double, locale: Locale = .current) -> String {
    String(localized: "\(usageFormattedCost(amount, locale: locale)) left")
}

func providerLimitFraction(remainingPercent: Double) -> Double {
    min(max(remainingPercent / 100, 0), 1)
}

func providerLimitResetText(
    _ resetAt: Date?,
    now: Date,
    width: Duration.UnitsFormatStyle.UnitWidth = .narrow,
    locale: Locale = .current
) -> String? {
    guard let resetAt else { return nil }

    let remaining = resetAt.timeIntervalSince(now)
    guard remaining >= 60 else {
        return String(localized: "Resets soon")
    }

    let allowed: Set<Duration.UnitsFormatStyle.Unit> = remaining < 24 * 60 * 60
        ? [.hours, .minutes]
        : [.days, .hours]

    let formatted = Duration.seconds(remaining).formatted(
        .units(allowed: allowed, width: width, zeroValueUnits: .hide).locale(locale)
    )

    return String(localized: "Resets in \(formatted)")
}

func providerLimitUpdatedText(_ fetchedAt: Date?, now: Date, locale: Locale = .current) -> String? {
    guard let fetchedAt else { return nil }

    let elapsed = max(0, now.timeIntervalSince(fetchedAt))
    let allowed: Set<Duration.UnitsFormatStyle.Unit>
    switch elapsed {
    case ..<60:
        allowed = [.seconds]
    case ..<3600:
        allowed = [.minutes]
    case ..<86400:
        allowed = [.hours]
    default:
        allowed = [.days]
    }

    let formatted = Duration.seconds(elapsed).formatted(
        .units(
            allowed: allowed,
            width: .abbreviated,
            maximumUnitCount: 1,
            zeroValueUnits: .show(length: 1)
        ).locale(locale)
    )

    return String(localized: "Updated \(formatted) ago")
}

func providerQuotaDate(_ raw: String?) -> Date? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }

    if let date = ProviderQuotaDateParsing.fractional.date(from: trimmed) {
        return date
    }

    if let date = ProviderQuotaDateParsing.plain.date(from: trimmed) {
        return date
    }

    guard let dot = trimmed.firstIndex(of: "."),
          let zoneStart = trimmed[dot...].firstIndex(where: { $0 == "Z" || $0 == "z" || $0 == "+" || $0 == "-" })
    else {
        return nil
    }

    return ProviderQuotaDateParsing.plain.date(from: String(trimmed[..<dot] + trimmed[zoneStart...]))
}

private enum ProviderQuotaDateParsing {
    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension ProviderLimitCard {
    init?(provider: String, response: ProviderQuotaResponse, fetchedAt: Date) {
        guard response.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available" else {
            return nil
        }

        let title = response.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? provider

        if let limits = response.accountLimits, limits.available != false {
            let rows = (limits.windows ?? []).enumerated().compactMap { index, window -> ProviderLimitRow? in
                guard let label = window.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                    return nil
                }

                return ProviderLimitRow(
                    id: "\(provider)-\(index)-\(label)",
                    label: label,
                    amount: window.remainingPercent.map(providerLimitPercentLeftText),
                    fraction: window.remainingPercent.map(providerLimitFraction),
                    remainingPercent: window.remainingPercent,
                    resetAt: providerQuotaDate(window.resetAt),
                    note: nil
                )
            }

            guard !rows.isEmpty else { return nil }

            let plan = limits.plan?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(
                id: provider,
                title: resolvedTitle,
                plan: plan?.isEmpty == false ? plan : nil,
                rows: rows,
                updatedAt: providerQuotaDate(limits.fetchedAt)
            )
            return
        }

        guard let quota = response.quota, quota.limitRemaining != nil || quota.usage != nil else {
            return nil
        }

        let fraction: Double? = {
            guard let remaining = quota.limitRemaining, let limit = quota.limit, limit > 0 else { return nil }
            return min(max(remaining / limit, 0), 1)
        }()

        let note: String? = {
            guard let usage = quota.usage else { return nil }
            if let limit = quota.limit {
                return String(localized: "\(usageFormattedCost(usage)) used of \(usageFormattedCost(limit))")
            }
            return String(localized: "\(usageFormattedCost(usage)) used")
        }()

        self.init(
            id: provider,
            title: resolvedTitle,
            plan: nil,
            rows: [
                ProviderLimitRow(
                    id: "\(provider)-credits",
                    label: String(localized: "Credits"),
                    amount: quota.limitRemaining.map { providerLimitAmountLeftText($0) },
                    fraction: fraction,
                    remainingPercent: fraction.map { $0 * 100 },
                    resetAt: nil,
                    note: note
                )
            ],
            updatedAt: fetchedAt
        )
    }
}

let providerQuotaCandidates = ["openai-codex", "anthropic", "openrouter"]

func providerQuotaSelection(from response: ProvidersResponse) -> [String] {
    let keyed = Set(
        (response.providers ?? [])
            .filter { $0.hasKey == true }
            .compactMap { normalizedProviderSlug($0.id) }
    )

    let candidates = [normalizedProviderSlug(response.activeProvider)].compactMap { $0 } + providerQuotaCandidates

    var seen: Set<String> = []
    var selected: [String] = []
    for candidate in candidates where keyed.contains(candidate) {
        guard seen.insert(candidate).inserted else { continue }
        selected.append(candidate)
    }

    return selected
}

func normalizedProviderSlug(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
        return nil
    }

    return trimmed
}
