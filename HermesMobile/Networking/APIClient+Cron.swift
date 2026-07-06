import Foundation

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

