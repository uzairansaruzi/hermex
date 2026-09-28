import Foundation

/// One page of a task's run history, from `GET /api/crons/history`.
///
/// `total` counts every run the server holds, not the rows in this page. The
/// two differ on purpose: upstream slices `all_files[offset:offset + limit]`
/// and then drops any entry whose `stat()` throws, so a page can return fewer
/// rows than it consumed. Callers page by the `limit` they asked for and stop
/// at `total`; advancing by `runs.count` silently re-reads rows it already has.
struct CronRunHistoryResponse: Decodable, Equatable {
    let jobId: String?
    let runs: [CronRunHistoryItem]
    let total: Int?
    let offset: Int?

    enum CodingKeys: String, CodingKey {
        case jobId
        case runs
        case total
        case offset
    }

    init(jobId: String?, runs: [CronRunHistoryItem], total: Int?, offset: Int?) {
        self.jobId = jobId
        self.runs = runs
        self.total = total
        self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = container.decodeLossyStringIfPresent(forKey: .jobId)
        total = container.decodeLossyIntIfPresent(forKey: .total)
        offset = container.decodeLossyIntIfPresent(forKey: .offset)
        runs = ((try? container.decodeIfPresent([LossyCronRun].self, forKey: .runs)) ?? nil)?
            .compactMap(\.run) ?? []
    }
}

/// One past run: enough to render a row, and the `filename` handle the
/// run-detail endpoint needs.
struct CronRunHistoryItem: Decodable, Equatable, Identifiable {
    var id: String { filename }

    /// Unique within a job's output directory, which is what makes it a safe
    /// list identity as well as the detail request's key.
    let filename: String
    /// Bytes on disk. `nil` when the server sent something unusable rather
    /// than a number.
    let size: Int?
    /// The file's mtime, which is when the run finished.
    let modified: Date?
    /// Parsed out of the run's markdown front matter, and frequently empty.
    let usage: CronRunUsage

    enum CodingKeys: String, CodingKey {
        case filename
        case size
        case modified
        case usage
    }

    init(filename: String, size: Int? = nil, modified: Date? = nil, usage: CronRunUsage = CronRunUsage()) {
        self.filename = filename
        self.size = size
        self.modified = modified
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // A run with no filename cannot be opened, so it is dropped by
        // `LossyCronRun` rather than rendered as a dead row.
        guard let filename = container.decodeLossyStringIfPresent(forKey: .filename),
              !filename.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .filename,
                in: container,
                debugDescription: "Cron run is missing a filename"
            )
        }

        self.filename = filename
        size = container.decodeLossyIntIfPresent(forKey: .size)
        // `Date(timeIntervalSince1970:)` accepts NaN and infinity and then traps
        // deep inside date formatting, so a non-finite mtime becomes no date.
        modified = container.decodeLossyDoubleIfPresent(forKey: .modified)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        usage = ((try? container.decodeIfPresent(CronRunUsage.self, forKey: .usage)) ?? nil) ?? CronRunUsage()
    }
}

/// The optional token, cost and timing metadata upstream scrapes out of a run's
/// markdown front matter.
///
/// Every field is a decoration. The server returns `{}` for most runs, so no
/// layout may reserve space for these — a row shows what is there and nothing
/// where there is not.
struct CronRunUsage: Decodable, Equatable {
    let model: String?
    let provider: String?
    let estimatedCostUsd: Double?
    let durationSeconds: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case provider
        case estimatedCostUsd
        case durationSeconds
        case inputTokens
        case outputTokens
        case totalTokens
    }

    init(
        model: String? = nil,
        provider: String? = nil,
        estimatedCostUsd: Double? = nil,
        durationSeconds: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.model = model
        self.provider = provider
        self.estimatedCostUsd = estimatedCostUsd
        self.durationSeconds = durationSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = container.decodeLossyStringIfPresent(forKey: .model)
        provider = container.decodeLossyStringIfPresent(forKey: .provider)
        estimatedCostUsd = container.decodeLossyDoubleIfPresent(forKey: .estimatedCostUsd)
        durationSeconds = container.decodeLossyDoubleIfPresent(forKey: .durationSeconds)
        inputTokens = container.decodeLossyIntIfPresent(forKey: .inputTokens)
        outputTokens = container.decodeLossyIntIfPresent(forKey: .outputTokens)
        totalTokens = container.decodeLossyIntIfPresent(forKey: .totalTokens)
    }
}

/// One run's full text, from `GET /api/crons/run` — the read that shares its
/// path with the POST that triggers a run.
struct CronRunDetailResponse: Decodable, Equatable {
    let jobId: String?
    let filename: String?
    let content: String?
    let snippet: String?
    let usage: CronRunUsage

    enum CodingKeys: String, CodingKey {
        case jobId
        case filename
        case content
        case snippet
        case usage
    }

    init(jobId: String?, filename: String?, content: String?, snippet: String?, usage: CronRunUsage = CronRunUsage()) {
        self.jobId = jobId
        self.filename = filename
        self.content = content
        self.snippet = snippet
        self.usage = usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = container.decodeLossyStringIfPresent(forKey: .jobId)
        filename = container.decodeLossyStringIfPresent(forKey: .filename)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        snippet = try? container.decodeIfPresent(String.self, forKey: .snippet)
        usage = ((try? container.decodeIfPresent(CronRunUsage.self, forKey: .usage)) ?? nil) ?? CronRunUsage()
    }
}

/// Decodes a run without ever throwing, so one malformed entry drops out of the
/// page instead of failing the whole request.
private struct LossyCronRun: Decodable {
    let run: CronRunHistoryItem?

    init(from decoder: Decoder) throws {
        run = try? CronRunHistoryItem(from: decoder)
    }
}
