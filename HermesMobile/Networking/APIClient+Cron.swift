import Foundation

/// What the Tasks screens call, so one set of screens runs on either kind of server: a webui
/// server's `/api/crons/*` (`APIClient`) or a Hermes host's `/api/cron/*` (`HermesCronClient`,
/// #1040). Mutations name the job's Profile, which a Hermes host routes by and webui ignores;
/// `cronFeatures` says which parts of the screens the server backs.
protocol CronDataClient: Sendable {
    var cronFeatures: CronFeatures { get }
    func cronJobs() async throws -> CronJobList
    func cronRecent() async throws -> CronRecentCompletionsResponse
    /// Delivery targets, for one Profile where the server scopes them.
    func cronDeliveryOptions(profile: String?) async throws -> CronDeliveryOptionsResponse
    func createCron(
        prompt: String, schedule: String, name: String?, deliver: String?, skills: [String],
        model: String?, provider: String?, profile: String?, toastNotifications: Bool
    ) async throws -> CronMutationResponse
    func updateCron(
        jobID: String, prompt: String?, schedule: String?, name: String?, deliver: String?, skills: [String]?,
        model: String?, provider: String?, profile: String?, toastNotifications: Bool?
    ) async throws -> CronMutationResponse
    func runCron(jobID: String, profile: String?) async throws -> CronMutationResponse
    func pauseCron(jobID: String, profile: String?, reason: String?) async throws -> CronMutationResponse
    func resumeCron(jobID: String, profile: String?) async throws -> CronMutationResponse
    func deleteCron(jobID: String, profile: String?) async throws -> CronMutationResponse
    func cronOutput(jobID: String, limit: Int?) async throws -> CronOutputResponse
    func cronHistory(jobID: String, offset: Int, limit: Int) async throws -> CronRunHistoryResponse
    func cronRunDetail(jobID: String, filename: String) async throws -> CronRunDetailResponse
    /// The Task editor's sources. `profile` scopes the models and skills where the server
    /// keeps them per Profile.
    func cronModelGroups(profile: String?) async throws -> [ModelCatalogGroup]
    func cronProfiles() async throws -> [ProfileSummary]
    func cronSkills(profile: String?) async throws -> [SkillSummary]
}

/// The parts of Tasks one server backs. A webui server backs all of them. A Hermes host
/// (#1040) keeps every Task in a Profile, reports running state and recent runs in its list,
/// and has no toast setting; its Run Now and run history arrive with #1041 and #1042.
struct CronFeatures: Equatable, Sendable {
    /// Each Task belongs to one Profile: rows name it, the editor's sources follow it, and
    /// editing can't move a Task to another.
    let isProfileScoped: Bool
    let hasToastNotifications: Bool
    /// `/api/crons/recent`. Without it, recent runs come with the list.
    let hasRecentRunsFeed: Bool
    let hasRunNow: Bool
    let hasRunHistory: Bool

    static let webui = CronFeatures(isProfileScoped: false, hasToastNotifications: true, hasRecentRunsFeed: true,
                                    hasRunNow: true, hasRunHistory: true)
    static let hermes = CronFeatures(isProfileScoped: true, hasToastNotifications: false, hasRecentRunsFeed: false,
                                     hasRunNow: false, hasRunHistory: false)
}

/// One read of the Tasks list.
struct CronJobList: Equatable {
    var jobs: [CronJob]
    /// The running jobs by id, each with the seconds it has been running.
    var runningJobs: [String: Double]
    /// Recent completions, when they come with the list (a Hermes host); nil when the
    /// server has its own feed.
    var recentRuns: [CronRecentCompletion]?
}

extension APIClient: CronDataClient {
    nonisolated var cronFeatures: CronFeatures { .webui }

    /// `/api/crons` and `/api/crons/status`, read together.
    func cronJobs() async throws -> CronJobList {
        async let jobs = crons()
        async let status = cronStatus()
        let (jobsResult, statusResult) = try await (jobs, status)
        return CronJobList(jobs: jobsResult.jobs ?? [], runningJobs: statusResult.runningJobs ?? [:], recentRuns: nil)
    }

    // webui lists the same delivery targets, models and skills for every Profile, and finds
    // a job by its id alone.

    func cronDeliveryOptions(profile _: String?) async throws -> CronDeliveryOptionsResponse {
        try await cronDeliveryOptions()
    }

    func runCron(jobID: String, profile _: String?) async throws -> CronMutationResponse {
        try await runCron(jobID: jobID)
    }

    func pauseCron(jobID: String, profile _: String?, reason: String?) async throws -> CronMutationResponse {
        try await pauseCron(jobID: jobID, reason: reason)
    }

    func resumeCron(jobID: String, profile _: String?) async throws -> CronMutationResponse {
        try await resumeCron(jobID: jobID)
    }

    func deleteCron(jobID: String, profile _: String?) async throws -> CronMutationResponse {
        try await deleteCron(jobID: jobID)
    }

    func cronModelGroups(profile _: String?) async throws -> [ModelCatalogGroup] {
        try await models().catalogGroups
    }

    func cronProfiles() async throws -> [ProfileSummary] {
        try await profiles().profiles ?? []
    }

    func cronSkills(profile _: String?) async throws -> [SkillSummary] {
        try await skills().skills ?? []
    }
}

extension APIClient {
    func crons() async throws -> CronJobsResponse {
        try await send(endpoint: .crons, method: "GET")
    }

    func createCron(
        prompt: String,
        schedule: String,
        name: String?,
        deliver: String?,
        skills: [String],
        model: String?,
        provider: String?,
        profile: String?,
        toastNotifications: Bool
    ) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronCreate,
            method: "POST",
            body: CronCreateRequest(
                prompt: prompt,
                schedule: schedule,
                name: name,
                deliver: deliver,
                skills: skills,
                model: model,
                provider: provider,
                profile: profile,
                toastNotifications: toastNotifications
            )
        )
    }

    func updateCron(
        jobID: String,
        prompt: String?,
        schedule: String?,
        name: String?,
        deliver: String?,
        skills: [String]?,
        model: String?,
        provider: String?,
        profile: String?,
        toastNotifications: Bool?
    ) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronUpdate,
            method: "POST",
            body: CronUpdateRequest(
                jobId: jobID,
                prompt: prompt,
                schedule: schedule,
                name: name,
                deliver: deliver,
                skills: skills,
                model: model,
                provider: provider,
                profile: profile,
                toastNotifications: toastNotifications
            )
        )
    }

    func cronDeliveryOptions() async throws -> CronDeliveryOptionsResponse {
        try await send(endpoint: .cronDeliveryOptions, method: "GET")
    }

    /// Each job's most recent completion. Unordered on the wire; see
    /// `CronRecentCompletionsResponse.completions`.
    func cronRecent() async throws -> CronRecentCompletionsResponse {
        try await send(endpoint: .cronRecent, method: "GET")
    }

    func deleteCron(jobID: String) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronDelete,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: nil)
        )
    }

    func runCron(jobID: String) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronRun,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: nil)
        )
    }

    func pauseCron(jobID: String, reason: String? = nil) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronPause,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: reason)
        )
    }

    func resumeCron(jobID: String) async throws -> CronMutationResponse {
        try await send(
            endpoint: .cronResume,
            method: "POST",
            body: CronJobIDRequest(jobId: jobID, reason: nil)
        )
    }

    func cronStatus(jobID: String? = nil) async throws -> CronStatusResponse {
        try await send(endpoint: .cronStatus(jobID: jobID), method: "GET")
    }

    func cronOutput(jobID: String, limit: Int? = 5) async throws -> CronOutputResponse {
        try await send(endpoint: .cronOutput(jobID: jobID, limit: limit), method: "GET")
    }

    /// One page of a job's run history, newest first.
    ///
    /// Callers advance `offset` by the `limit` they passed, not by
    /// `response.runs.count`: see `CronRunHistoryResponse`.
    func cronHistory(jobID: String, offset: Int, limit: Int) async throws -> CronRunHistoryResponse {
        try await send(endpoint: .cronHistory(jobID: jobID, offset: offset, limit: limit), method: "GET")
    }

    /// One past run's full output. The GET twin of `runCron`'s POST on the same
    /// path.
    func cronRunDetail(jobID: String, filename: String) async throws -> CronRunDetailResponse {
        try await send(endpoint: .cronRunDetail(jobID: jobID, filename: filename), method: "GET")
    }
}

private struct CronCreateRequest: Encodable {
    let prompt: String
    let schedule: String
    let name: String?
    let deliver: String?
    let skills: [String]
    let model: String?
    let provider: String?
    let profile: String?
    let toastNotifications: Bool
}

private struct CronUpdateRequest: Encodable {
    let jobId: String
    let prompt: String?
    let schedule: String?
    let name: String?
    let deliver: String?
    let skills: [String]?
    let model: String?
    let provider: String?
    let profile: String?
    let toastNotifications: Bool?
}

private struct CronJobIDRequest: Encodable {
    let jobId: String
    let reason: String?
}

