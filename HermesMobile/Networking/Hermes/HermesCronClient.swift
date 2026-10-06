import Foundation

/// The Tasks screens' client on a Hermes host (#1040): `/api/cron/*` and the Profile's skills
/// over the sign-in, headers and cookie jar the server's Bot screens share, and the editor's
/// model and Profile lists over the shared gateway socket. A mutation names the job's own
/// Profile (`?profile=`), which the host treats as a hint and checks. A refusal the host
/// explains reads as its `detail` (`accepted`). Every job also carries `hermes_home`, a host
/// path, which is never decoded. A run is the session it ran in (#1042), and its output is that
/// session's final reply: nothing is read from the host's disk.
@MainActor final class HermesCronClient: CronDataClient {
    nonisolated var cronFeatures: CronFeatures { .hermes }
    private let http: HermesConnection

    /// Tasks for `server`'s saved connection, on the sign-in its Bot screens share.
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

    /// The host has no toast setting, so `toastNotifications` is not sent. A 424 means the
    /// job was saved but the host's scheduler could not register it: it comes back as saved,
    /// without the job, carrying the host's warning, so the list reloads.
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

    /// Sends what the editor holds as `{updates}`. `profile` only routes the request: the
    /// host can't move a job, so neither it nor the job's id is ever an update.
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

    /// Resuming a one-shot whose time has passed is the host's unhandled 500.
    func resumeCron(jobID: String, profile: String?) async throws -> CronMutationResponse {
        try Self.job(try await send(.cronResume(id: jobID, profile: profile)))
    }

    func deleteCron(jobID: String, profile: String?) async throws -> CronMutationResponse {
        let ok = try Self.json(try await send(.cronDelete(id: jobID, profile: profile)))["ok"].flag
        return CronMutationResponse(ok: ok, job: nil, error: nil)
    }

    /// The host's trigger (#1041), which runs the Task before it answers with the job, so it
    /// gets the long deadline. A tunnel can still give up first (Cloudflare's 524 after about
    /// 100 s) while the run goes on; the screens follow it on the list. A paused Task is
    /// resumed as it runs; one already running is refused with 409 and the host's `detail`.
    func runCron(jobID: String, profile: String?) async throws -> CronMutationResponse {
        try Self.job(try Self.accepted(try await reply(.cronTrigger(id: jobID, profile: profile), deadline: .provisioning)))
    }

    /// `model.options` for the Profile, or the host's own when none is named.
    func cronModelGroups(profile: String?) async throws -> [ModelCatalogGroup] {
        let call: HermesCall
        if let profile, !profile.isEmpty { call = .profileModelOptions(profile: profile) } else { call = .configuredModelOptions }
        return HermesModelCatalog(try await gateway(call)).groups
    }

    /// `profiles.list`. A row's `path` is a host path and is not kept.
    func cronProfiles() async throws -> [ProfileSummary] {
        (try await gateway(.profilesList(includeSessions: false))["profiles"].list ?? []).compactMap { row in
            guard let name = row["name"].text, !name.isEmpty else { return nil }
            return ProfileSummary(name: name, path: nil, isDefault: row["is_default"].flag, isActive: nil,
                                  gatewayRunning: nil, model: row["model"].text, provider: row["provider"].text,
                                  hasEnv: nil, skillCount: nil)
        }
    }

    /// A disabled skill comes back `disabled`, which the editor leaves out.
    func cronSkills(profile: String?) async throws -> [SkillSummary] {
        (try Self.json(try await send(.skills(profile: profile))).list ?? []).compactMap { row in
            guard let name = row["name"].text, !name.isEmpty else { return nil }
            return SkillSummary(name: name, category: row["category"].text, description: row["description"].text,
                                path: nil, disabled: row["enabled"].flag.map { !$0 })
        }
    }

    // The screens never ask a Hermes host for these (`cronFeatures`): its recent runs come with
    // the list, and its latest output is the newest finished run's reply (`cronRunDetail`).

    func cronRecent() async throws -> CronRecentCompletionsResponse { throw BotFailure.unsupported }
    func cronOutput(jobID _: String, limit _: Int?) async throws -> CronOutputResponse { throw BotFailure.unsupported }

    /// The Task's newest 100 runs, the most the host lists and the one page it has: it takes no
    /// offset and reports no total, so the screens offer no more (#1042).
    func cronHistory(jobID: String, profile: String?, offset: Int, limit _: Int) async throws -> CronRunHistoryResponse {
        guard offset == 0 else { return CronRunHistoryResponse(jobId: jobID, runs: [], total: nil, offset: offset) }
        let page = try await send(.cronRuns(id: jobID, profile: profile, limit: 100))
        return CronRunHistoryResponse(jobId: jobID, runs: try Self.decoder.decode(HermesCronRuns.self, from: page).runs,
                                      total: nil, offset: offset)
    }

    /// One run's output: its session's final reply (`HermesREST.sessionMessages`), the last
    /// assistant message that is not a tool call, as a side session's result is; nil when it gave
    /// none. A run the host no longer has (404) is `HermesCronRunUnavailable`.
    func cronRunDetail(jobID: String, profile: String?, filename runID: String) async throws -> CronRunDetailResponse {
        let answer = try await reply(.sessionMessages(key: runID, profile: profile ?? ""))
        guard answer.status != 404 else { throw HermesCronRunUnavailable() }
        let messages = try Self.json(try Self.accepted(answer))["messages"].list ?? []
        return CronRunDetailResponse(jobId: jobID, filename: runID, content: HermesChatSideTasks.result(messages), snippet: nil)
    }

    // MARK: - Wire

    /// One request's body, or the failure `accepted` reads from its status.
    private func send(_ rest: HermesREST) async throws -> Data {
        try Self.accepted(try await reply(rest))
    }

    /// A dropped request reads as the webui's network failure, so a cancellation is
    /// recognised as one.
    private func reply(_ rest: HermesREST,
                       deadline: HermesConnection.Deadline = .standard) async throws -> (body: Data, status: Int) {
        do { return try await http.reply(rest, deadline: deadline) } catch let error as URLError {
            throw APIError.network(underlying: error)
        }
    }

    /// One gateway call on its own attachment to the connection's shared socket, left once
    /// the host answers.
    private func gateway(_ call: HermesCall) async throws -> BotJSON {
        let client = BotClient(http: http)
        defer { client.close() }
        try await client.connect()
        return try await client.call(call)
    }

    /// A 2xx reply's body. A 4xx the host explains in `detail`, such as a schedule it can't
    /// parse or a Task that is gone, reads as that reason. Hermes never answers 403, 502-504
    /// or 520-530 itself, so those get the Hermes connection's copy for the proxy or tunnel
    /// in front of it. Any other status is `APIError.http`, whose 500 is the host's unhandled error.
    private static func accepted(_ reply: (body: Data, status: Int)) throws -> Data {
        switch reply.status {
        case 200..<300: return reply.body
        case 403, 502...504, 520...530: throw BotFailure.rejected(reply.status)
        case 400..<500:
            if let detail = (try? json(reply.body))?["detail"].text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                throw HermesCronRefusal(detail: detail)
            }
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

    /// `CronJob` reads the host's snake_case keys the way it reads webui's.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// A Tasks request a Hermes host refused with its reason (`{detail}`).
struct HermesCronRefusal: LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { String(localized: "The server rejected the request: \(detail)") }
}

/// A run whose session the host no longer has (#1042).
struct HermesCronRunUnavailable: LocalizedError, Equatable {
    var errorDescription: String? { String(localized: "This run is no longer on the server.") }
}

/// `GET /api/cron/jobs/{id}/runs` as history rows (#1042). Each row is the run's whole session,
/// `system_prompt` included, of which only the fields a row shows are decoded. A row without
/// an id can't be opened, so it is left out; a page without its `runs` list is a failed read,
/// not a Task that never ran.
private struct HermesCronRuns: Decodable {
    let runs: [CronRunHistoryItem]

    enum CodingKeys: String, CodingKey { case runs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runs = try container.decode([Run].self, forKey: .runs).compactMap(\.item)
    }

    /// One row. A run lasted from `started_at` to `ended_at`, epoch seconds, and is `is_active`
    /// until it ends. Its cost is the provider's actual one when known, else the host's estimate;
    /// its tokens are its input and output.
    private struct Run: Decodable {
        let item: CronRunHistoryItem?

        enum CodingKeys: String, CodingKey {
            case id, startedAt, endedAt, isActive, model, inputTokens, outputTokens, estimatedCostUsd, actualCostUsd
        }

        init(from decoder: Decoder) throws {
            guard let row = try? decoder.container(keyedBy: CodingKeys.self),
                  let id = row.decodeLossyStringIfPresent(forKey: .id), !id.isEmpty else {
                item = nil
                return
            }
            // `Date(timeIntervalSince1970:)` takes NaN and infinity and traps later, in formatting.
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
            item = run
        }
    }
}

extension CronJobList {
    /// A Hermes host's list (#1040), whose running state and recent runs are read off the
    /// jobs. A job is running while it holds a fire claim or its latest execution is still
    /// claimed or running; it has run for the time since its claim, or 0 without one. Each
    /// job that has run contributes its last run, as webui's recent feed does.
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
