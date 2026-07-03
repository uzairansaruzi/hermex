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
    let sessions: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case inputTokens
        case outputTokens
        case sessions
        case cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = container.decodeLossyStringIfPresent(forKey: .date)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
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
