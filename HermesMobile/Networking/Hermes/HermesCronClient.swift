import Foundation

@MainActor final class HermesCronClient: CronDataClient {
    nonisolated var cronFeatures: CronFeatures { .hermes }
    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    func cronJobs() async throws -> CronJobList {
        CronJobList(hermesJobs: try Self.decoder.decode([CronJob].self, from: try await send(.cronJobs)))
    }

    func cronDeliveryOptions(profile: String?) async throws -> CronDeliveryOptionsResponse {
        let targets = try Self.json(try await send(.cronDeliveryTargets(profile: profile)))["targets"].list ?? []
        return CronDeliveryOptionsResponse(platforms: targets.compactMap { target in
            target["id"].text.map { CronDeliveryOption(value: $0, label: target["name"].text) }
        })
    }

    func createCron(
        prompt: String, schedule: String, name: String?, deliver: String?, skills: [String],
        model: String?, provider: String?, profile: String?, toastNotifications _: Bool
    ) async throws -> CronMutationResponse {
        var fields: [String: BotJSON] = [
            "schedule": .string(schedule), "prompt": .string(prompt), "name": .string(name ?? ""),
            "deliver": .string(deliver ?? "local"), "skills": .array(skills.map(BotJSON.string))
        ]
        if let model { fields["model"] = .string(model) }
        if let provider { fields["provider"] = .string(provider) }
        let answer = try await reply(.cronCreate(profile: profile, fields: fields))
        if answer.status == 424 {
            let warning = (try? Self.json(answer.body))?["detail"]["error"].text
            return CronMutationResponse(ok: true, job: nil, error: nil, warning: warning)
        }
        return try Self.job(try Self.accepted(answer))
    }

    func updateCron(
        jobID: String, prompt: String?, schedule: String?, name: String?, deliver: String?, skills: [String]?,
        model: String?, provider: String?, profile: String?, toastNotifications _: Bool?
    ) async throws -> CronMutationResponse {
        var updates: [String: BotJSON] = [:]
        for (key, value) in [("prompt", prompt), ("schedule", schedule), ("name", name), ("deliver", deliver),
                             ("model", model), ("provider", provider)] {
            if let value { updates[key] = .string(value) }
        }
        if let skills { updates["skills"] = .array(skills.map(BotJSON.string)) }
        return try Self.job(try await send(.cronUpdate(id: jobID, profile: profile, updates: updates)))
    }

    func pauseCron(jobID: String, profile: String?, reason _: String?) async throws -> CronMutationResponse {
        try Self.job(try await send(.cronPause(id: jobID, profile: profile)))
    }

    func resumeCron(jobID: String, profile: String?) async throws -> CronMutationResponse {
        try Self.job(try await send(.cronResume(id: jobID, profile: profile)))
    }

    func deleteCron(jobID: String, profile: String?) async throws -> CronMutationResponse {
        let ok = try Self.json(try await send(.cronDelete(id: jobID, profile: profile)))["ok"].flag
        return CronMutationResponse(ok: ok, job: nil, error: nil)
    }

    func runCron(jobID: String, profile: String?) async throws -> CronMutationResponse {
        try Self.job(try Self.accepted(try await reply(.cronTrigger(id: jobID, profile: profile), deadline: .provisioning)))
    }

    func cronModelGroups(profile: String?) async throws -> [ModelCatalogGroup] {
        let call: HermesCall
        if let profile, !profile.isEmpty { call = .profileModelOptions(profile: profile) } else { call = .configuredModelOptions }
        return HermesModelCatalog(try await gateway(call)).groups
    }

    func cronProfiles() async throws -> [ProfileSummary] {
        (try await gateway(.profilesList(includeSessions: false))["profiles"].list ?? []).compactMap { row in
            guard let name = row["name"].text, !name.isEmpty else { return nil }
            return ProfileSummary(name: name, path: nil, isDefault: row["is_default"].flag, isActive: nil,
                                  gatewayRunning: nil, model: row["model"].text, provider: row["provider"].text,
                                  hasEnv: nil, skillCount: nil)
        }
    }

    func cronSkills(profile: String?) async throws -> [SkillSummary] {
        try HermesSkillsClient.skills(try await send(.skills(profile: profile)))
    }

    func cronRecent() async throws -> CronRecentCompletionsResponse { throw BotFailure.unsupported }
    func cronOutput(jobID _: String, limit _: Int?) async throws -> CronOutputResponse { throw BotFailure.unsupported }

    func cronHistory(jobID: String, profile: String?, offset: Int, limit _: Int) async throws -> CronRunHistoryResponse {
        guard offset == 0 else { return CronRunHistoryResponse(jobId: jobID, runs: [], total: nil, offset: offset) }
        let page = try await send(.cronRuns(id: jobID, profile: profile, limit: 100))
        return CronRunHistoryResponse(jobId: jobID, runs: try Self.decoder.decode(HermesCronRuns.self, from: page).runs,
                                      total: nil, offset: offset)
    }

    func cronRunDetail(jobID: String, profile: String?, run: CronRunHistoryItem) async throws -> CronRunDetailResponse {
        if let output = run.scriptOutput {
            return CronRunDetailResponse(jobId: jobID, filename: run.filename, content: output, snippet: nil)
        }
        let answer = try await reply(.sessionMessages(key: run.filename, profile: profile ?? ""))
        guard answer.status != 404 else { throw HermesCronRunUnavailable() }
        let messages = try Self.json(try Self.accepted(answer))["messages"].list ?? []
        return CronRunDetailResponse(jobId: jobID, filename: run.filename, content: HermesChatSideTasks.result(messages),
                                     snippet: nil)
    }

    private func send(_ rest: HermesREST) async throws -> Data {
        try Self.accepted(try await reply(rest))
    }

    private func reply(_ rest: HermesREST,
                       deadline: HermesConnection.Deadline = .standard) async throws -> (body: Data, status: Int) {
        do { return try await http.reply(rest, deadline: deadline) } catch let error as URLError {
            throw APIError.network(underlying: error)
        }
    }

    private func gateway(_ call: HermesCall) async throws -> BotJSON {
        let client = BotClient(http: http)
        defer { client.close() }
        try await client.connect()
        return try await client.call(call)
    }

    static func accepted(_ reply: (body: Data, status: Int)) throws -> Data {
        switch reply.status {
        case 200..<300: return reply.body
        case 502...504, 520...530: throw BotFailure.rejected(reply.status)
        case 400..<500:
            if let detail = (try? json(reply.body))?["detail"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                throw HermesCronRefusal(detail: detail)
            }
            if reply.status == 403 { throw BotFailure.rejected(403) }
        default: break
        }
        throw APIError.http(statusCode: reply.status, body: String(data: reply.body, encoding: .utf8))
    }

    private static func job(_ body: Data) throws -> CronMutationResponse {
        CronMutationResponse(ok: true, job: try decoder.decode(CronJob.self, from: body), error: nil)
    }

    private static func json(_ body: Data) throws -> BotJSON {
        do { return try JSONDecoder().decode(BotJSON.self, from: body) } catch { throw APIError.decoding(underlying: error) }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

struct HermesCronRefusal: LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { String(localized: "The server rejected the request: \(detail)") }
}

struct HermesCronRunUnavailable: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "This run is no longer on the server.") }
}

private struct HermesCronRuns: Decodable {
    let runs: [CronRunHistoryItem]

    enum CodingKeys: String, CodingKey { case runs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runs = try container.decode([Run].self, forKey: .runs).compactMap(\.item)
    }

    private struct Run: Decodable {
        let item: CronRunHistoryItem?

        enum CodingKeys: String, CodingKey {
            case id, source, preview, startedAt, endedAt, isActive, model, inputTokens, outputTokens, estimatedCostUsd,
                 actualCostUsd
        }

        init(from decoder: Decoder) throws {
            guard let row = try? decoder.container(keyedBy: CodingKeys.self),
                  let id = row.decodeLossyStringIfPresent(forKey: .id), !id.isEmpty else {
                item = nil
                return
            }
            let date = { (key: CodingKeys) in
                row.decodeLossyDoubleIfPresent(forKey: key).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            }
            let started = date(.startedAt), ended = date(.endedAt)
            let input = row.decodeLossyIntIfPresent(forKey: .inputTokens)
            let output = row.decodeLossyIntIfPresent(forKey: .outputTokens)
            let tokens = (input ?? 0).addingReportingOverflow(output ?? 0)
            var run = CronRunHistoryItem(filename: id, modified: ended, usage: CronRunUsage(
                model: row.decodeLossyStringIfPresent(forKey: .model),
                estimatedCostUsd: row.decodeLossyDoubleIfPresent(forKey: .actualCostUsd)
                    ?? row.decodeLossyDoubleIfPresent(forKey: .estimatedCostUsd),
                durationSeconds: started.flatMap { start in ended.map { $0.timeIntervalSince(start) } },
                inputTokens: input,
                outputTokens: output,
                totalTokens: (input == nil && output == nil) || tokens.overflow ? nil : tokens.partialValue
            ))
            run.startedAt = started
            run.isRunning = row.decodeLossyBoolIfPresent(forKey: .isActive) ?? false
            if row.decodeLossyStringIfPresent(forKey: .source) == "cron_output" {
                run.scriptOutput = row.decodeLossyStringIfPresent(forKey: .preview) ?? ""
            }
            item = run
        }
    }
}

extension CronJobList {
    init(hermesJobs jobs: [CronJob], now: Date = .now) {
        self.jobs = jobs
        runningJobs = jobs.reduce(into: [:]) { running, job in
            let executing = job.latestExecutionStatus.map { ["claimed", "running"].contains($0) } ?? false
            guard let id = job.jobId, job.fireClaim != nil || executing else { return }
            running[id] = job.fireClaim?.at.map { max(0, now.timeIntervalSince($0)) } ?? 0
        }
        recentRuns = jobs.compactMap { job in
            job.lastRunAt.map { CronRecentCompletion(jobId: job.jobId, name: job.name, status: job.lastStatus, completedAt: $0.date) }
        }
    }
}
