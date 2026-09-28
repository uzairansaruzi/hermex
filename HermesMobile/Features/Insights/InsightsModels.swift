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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = container.decodeLossyStringIfPresent(forKey: .model)
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

/// Formats a server-reported 0–100 percentage (e.g. `cache_hit_percent`) with a
/// localized percent symbol and at most one fraction digit ("87.5%", "12%").
func insightsFormattedPercent(_ value: Double, locale: Locale = .current) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
}

// MARK: - Provider limits (#415)

/// One provider's quota card on the Usage screen. Built from
/// `GET /api/provider/quota`; nothing about it is persisted, so switching
/// servers simply rebuilds the screen with that server's providers.
struct ProviderLimitCard: Identifiable, Equatable {
    /// The provider slug, which is also the card's stable list identity.
    let id: String
    /// The server's `display_name`, shown verbatim.
    let title: String
    /// The subscription plan capsule ("Plus"). Absent on credits cards.
    let plan: String?
    let rows: [ProviderLimitRow]
    /// `account_limits.fetched_at` for account cards, or the client's fetch time
    /// for credits cards, whose payload carries no timestamp.
    let updatedAt: Date?
}

/// One line inside a limit card: a rate-limit window, or the single "Credits"
/// row of a prepaid provider.
struct ProviderLimitRow: Identifiable, Equatable {
    let id: String
    /// The window `label` verbatim, or the localized "Credits".
    let label: String
    /// The bold right-hand amount ("2% left", "$0.00 left"). Nil when the server
    /// reported no usable number.
    let amount: String?
    /// Remaining share of the bar, 0...1. Nil hides the bar entirely — a window
    /// with a null `remaining_percent`, or credits with no spending cap.
    let fraction: Double?
    /// Drives the tint tier. Nil tints with the accent.
    let remainingPercent: Double?
    /// The reset instant. The countdown line is rendered from it at draw time so
    /// nothing has to tick.
    let resetAt: Date?
    /// A static secondary line ("$10.03 used of $10.00"), used by credits rows
    /// in place of a countdown.
    let note: String?
}

/// How urgent a remaining balance is. Accent normally, orange at 25% or less,
/// red at 10% or less — matched by `ProviderLimitsCard`'s colors.
enum ProviderLimitTint: Equatable {
    case normal
    case warning
    case critical
}

/// Tiers a remaining percentage. A nil percentage has no signal to tier on and
/// stays neutral rather than alarming.
func providerLimitTint(remainingPercent: Double?) -> ProviderLimitTint {
    guard let remainingPercent else { return .normal }

    if remainingPercent <= 10 { return .critical }
    if remainingPercent <= 25 { return .warning }
    return .normal
}

/// "2% left" from a server 0–100 remaining percentage. Rounded to a whole
/// percent to match the reference design, and clamped so a server that reports
/// out-of-range never renders "-3% left".
func providerLimitPercentLeftText(_ remainingPercent: Double) -> String {
    let clamped = min(max(remainingPercent, 0), 100)
    return String(localized: "\(Int(clamped.rounded()))% left")
}

/// "$0.00 left" from a credits balance, in the user's locale.
func providerLimitAmountLeftText(_ amount: Double, locale: Locale = .current) -> String {
    String(localized: "\(usageFormattedCost(amount, locale: locale)) left")
}

/// The bar's fill, 0...1, from a server 0–100 remaining percentage.
func providerLimitFraction(remainingPercent: Double) -> Double {
    min(max(remainingPercent / 100, 0), 1)
}

/// "Resets in 4h 59m" under 24 hours, "Resets in 1d 3h" beyond it, and
/// "Resets soon" once the window has turned over or is under a minute out.
/// `width` is `.narrow` on screen and `.wide` for VoiceOver, which reads
/// "4 hours, 59 minutes" instead of spelling out "m".
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

/// "Updated 41 sec ago" — the card footer. One unit only, so a stale card reads
/// "Updated 2 hr ago" rather than a running clock. Computed at render; nothing
/// schedules a refresh of it.
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

/// Parses the ISO-8601 instants upstream emits for `reset_at` and `fetched_at`.
/// Both shapes appear live: whole seconds ("2026-09-06T07:55:41Z") and
/// microsecond precision ("2026-09-06T02:56:37.848820Z"), the latter more
/// precise than `ISO8601DateFormatter` accepts — so the fraction is dropped and
/// re-parsed rather than failing the row.
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
    /// Builds the card for one `GET /api/provider/quota` response, or nil when
    /// there is nothing worth a card. Only `status == "available"` with either a
    /// non-empty set of windows or a usable credits object renders; every other
    /// status (`unsupported`, `unavailable`, `no_key`, `invalid_key`) and every
    /// empty payload hides silently.
    ///
    /// `fetchedAt` is the client's request time, used as the credits card's
    /// footer timestamp — that payload carries none of its own.
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

        // Credits. A quota object whose every number is null describes nothing,
        // so it hides like any other unusable payload.
        guard let quota = response.quota, quota.limitRemaining != nil || quota.usage != nil else {
            return nil
        }

        // Only a positive cap makes a meaningful bar; an uncapped key shows the
        // balance and what it has spent, with nothing to fill.
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

/// The providers worth probing for quota beyond whichever one is active.
/// Upstream implements account limits for the OAuth providers and credits for
/// OpenRouter; everything else answers `unsupported`, so probing it would only
/// cost a round trip.
let providerQuotaCandidates = ["openai-codex", "anthropic", "openrouter"]

/// The selection rule: the active provider first, then the known quota
/// providers, deduplicated, keeping only entries `/api/providers` reports with a
/// configured key. Order is stable so cards do not reshuffle between loads.
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

/// `active_provider` comes from config while entry `id`s are canonical slugs, so
/// both sides are trimmed and lowercased before they are compared.
func normalizedProviderSlug(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
        return nil
    }

    return trimmed
}
