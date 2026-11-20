import Foundation

struct CronRecentCompletionsResponse: Decodable, Equatable {
    let completions: [CronRecentCompletion]?

    enum CodingKeys: String, CodingKey {
        case completions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completions = ((try? container.decodeIfPresent([LossyCronRecentCompletion].self, forKey: .completions)) ?? nil)?
            .compactMap(\.completion)
    }
}

struct CronRecentCompletion: Decodable, Equatable, Identifiable {
    var id: String {
        jobId ?? name ?? String(completedAt.timeIntervalSince1970)
    }

    let jobId: String?
    let name: String?
    let status: String?
    let completedAt: Date
    let sessionId: String?
    let messageCount: Int?

    enum Outcome {
        case completed, failed, stopped, unknown
    }

    var outcome: Outcome {
        switch status {
        case "ok": .completed
        case "error", "delivery_failed": .failed
        case "cancelled": .stopped
        default: .unknown
        }
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        return String(localized: "Untitled Task")
    }

    enum CodingKeys: String, CodingKey {
        case jobId
        case name
        case status
        case completedAt
        case sessionId
        case messageCount
    }

    init(jobId: String?, name: String?, status: String?, completedAt: Date, sessionId: String? = nil, messageCount: Int? = nil) {
        self.jobId = jobId
        self.name = name
        self.status = status
        self.completedAt = completedAt
        self.sessionId = sessionId
        self.messageCount = messageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let completedAt = (try? container.decodeIfPresent(CronDateValue.self, forKey: .completedAt)) ?? nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .completedAt,
                in: container,
                debugDescription: "Recent completion has no usable completed_at"
            )
        }

        self.completedAt = completedAt.date
        jobId = container.decodeLossyStringIfPresent(forKey: .jobId)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
        messageCount = container.decodeLossyIntIfPresent(forKey: .messageCount)
    }

    static func newestFirst(_ completions: [CronRecentCompletion]) -> [CronRecentCompletion] {
        completions.sorted { $0.completedAt > $1.completedAt }
    }
}

private struct LossyCronRecentCompletion: Decodable {
    let completion: CronRecentCompletion?

    init(from decoder: Decoder) throws {
        completion = try? CronRecentCompletion(from: decoder)
    }
}
