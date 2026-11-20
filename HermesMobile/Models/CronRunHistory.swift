import Foundation

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

struct CronRunHistoryItem: Decodable, Equatable, Identifiable {
    var id: String { filename }

    let filename: String
    let size: Int?
    let modified: Date?
    var startedAt: Date?
    var isRunning = false
    var scriptOutput: String?
    let usage: CronRunUsage

    var date: Date? { startedAt ?? modified }

    var isScriptOutputCut: Bool {
        guard let scriptOutput, scriptOutput.hasSuffix("…") else { return false }
        return (179...180).contains(scriptOutput.unicodeScalars.count)
    }

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
        modified = container.decodeLossyDoubleIfPresent(forKey: .modified)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        usage = ((try? container.decodeIfPresent(CronRunUsage.self, forKey: .usage)) ?? nil) ?? CronRunUsage()
    }
}

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

private struct LossyCronRun: Decodable {
    let run: CronRunHistoryItem?

    init(from decoder: Decoder) throws {
        run = try? CronRunHistoryItem(from: decoder)
    }
}
