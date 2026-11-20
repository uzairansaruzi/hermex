import Foundation

protocol CronDataClient: Sendable {
    var cronFeatures: CronFeatures { get }
    func cronJobs() async throws -> CronJobList
    func cronRecent() async throws -> CronRecentCompletionsResponse
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
    func cronHistory(jobID: String, profile: String?, offset: Int, limit: Int) async throws -> CronRunHistoryResponse
    func cronRunDetail(jobID: String, profile: String?, run: CronRunHistoryItem) async throws -> CronRunDetailResponse
    func cronModelGroups(profile: String?) async throws -> [ModelCatalogGroup]
    func cronProfiles() async throws -> [ProfileSummary]
    func cronSkills(profile: String?) async throws -> [SkillSummary]
}

struct CronFeatures: Equatable, Sendable {
    let isProfileScoped: Bool
    let hasToastNotifications: Bool
    let hasRecentRunsFeed: Bool
    let runNowWaitsForRun: Bool
    let runsAreSessions: Bool

    static let webui = CronFeatures(isProfileScoped: false, hasToastNotifications: true, hasRecentRunsFeed: true,
                                    runNowWaitsForRun: false, runsAreSessions: false)
    static let hermes = CronFeatures(isProfileScoped: true, hasToastNotifications: false, hasRecentRunsFeed: false,
                                     runNowWaitsForRun: true, runsAreSessions: true)

    func offersRunNow(for job: CronJob) -> Bool {
        !(runNowWaitsForRun && job.state == "completed")
    }

    func runNowResumes(_ job: CronJob) -> Bool {
        runNowWaitsForRun && job.enabled == false
    }
}

struct CronJobList: Equatable {
    var jobs: [CronJob]
    var runningJobs: [String: Double]
    var recentRuns: [CronRecentCompletion]?
}

extension APIClient: CronDataClient {
    nonisolated var cronFeatures: CronFeatures { .webui }

    func cronJobs() async throws -> CronJobList {
        async let jobs = crons()
        async let status = cronStatus()
        let (jobsResult, statusResult) = try await (jobs, status)
        return CronJobList(jobs: jobsResult.jobs ?? [], runningJobs: statusResult.runningJobs ?? [:], recentRuns: nil)
    }

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

    func cronHistory(jobID: String, profile _: String?, offset: Int, limit: Int) async throws -> CronRunHistoryResponse {
        try await cronHistory(jobID: jobID, offset: offset, limit: limit)
    }

    func cronRunDetail(jobID: String, profile _: String?, run: CronRunHistoryItem) async throws -> CronRunDetailResponse {
        try await cronRunDetail(jobID: jobID, filename: run.filename)
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

    func cronHistory(jobID: String, offset: Int, limit: Int) async throws -> CronRunHistoryResponse {
        try await send(endpoint: .cronHistory(jobID: jobID, offset: offset, limit: limit), method: "GET")
    }

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

