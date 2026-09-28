import Foundation

/// `GET /api/crons/recent`: one entry per job that has ever run, built from
/// each job's `last_run_at` and `last_status`. Upstream emits them in job
/// order, not by time, so the Tasks list sorts `completions` itself.
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

/// One job's latest finished run, as the recent-runs group shows it.
struct CronRecentCompletion: Decodable, Equatable, Identifiable {
    /// One completion per job on the wire, so the job is the identity; a
    /// nameless, idless entry falls back to its timestamp.
    var id: String {
        jobId ?? name ?? String(completedAt.timeIntervalSince1970)
    }

    let jobId: String?
    let name: String?
    let status: String?
    let completedAt: Date
    let sessionId: String?
    let messageCount: Int?

    var didFail: Bool {
        status == "error"
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

        // Without a time the row has nothing to sort or show, so it is dropped
        // by `LossyCronRecentCompletion` rather than rendered.
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

    /// Newest first, which is the only order the group is shown in.
    static func newestFirst(_ completions: [CronRecentCompletion]) -> [CronRecentCompletion] {
        completions.sorted { $0.completedAt > $1.completedAt }
    }
}

/// Wraps one array element so a single malformed completion is skipped
/// instead of failing the whole feed.
private struct LossyCronRecentCompletion: Decodable {
    let completion: CronRecentCompletion?

    init(from decoder: Decoder) throws {
        completion = try? CronRecentCompletion(from: decoder)
    }
}
