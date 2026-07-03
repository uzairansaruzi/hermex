import Foundation
import Observation

enum CronJobListMutation: Equatable {
    case upsert(CronJob)
    case delete(jobID: String)
}

@MainActor
@Observable
final class TasksViewModel {
    private(set) var jobs: [CronJob] = []
    private(set) var runningJobs: [String: Double] = [:]
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?

    private let client: APIClient

    init(server: URL, client: APIClient? = nil) {
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        do {
            async let jobsResponse = client.crons()
            async let statusResponse = client.cronStatus()

            let (jobsResult, statusResult) = try await (jobsResponse, statusResponse)
            runningJobs = statusResult.runningJobs ?? [:]
            jobs = (jobsResult.jobs ?? []).sorted(by: sortJobs)
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func runningElapsed(for job: CronJob) -> Double? {
        guard let jobID = job.jobId else { return nil }
        return runningJobs[jobID]
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    func create(from draft: CronJobEditorDraft) async -> Bool {
        guard draft.validationMessage == nil else {
            actionErrorMessage = draft.validationMessage
            return false
        }

        isMutating = true
        actionErrorMessage = nil
        lastError = nil
        defer { isMutating = false }

        do {
            let response = try await client.createCron(
                prompt: draft.trimmedPrompt,
                schedule: draft.trimmedSchedule,
                name: draft.trimmedName,
                deliver: draft.trimmedDeliver,
                skills: draft.skills,
                model: draft.trimmedModel,
                profile: draft.trimmedProfile,
                toastNotifications: draft.toastNotifications
            )

            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not create automation.")
                return false
            }

            if let job = response.job {
                apply(.upsert(job))
            } else {
                await load()
            }
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    func apply(_ mutation: CronJobListMutation) {
        switch mutation {
        case .upsert(let job):
            upsert(job)
        case .delete(let jobID):
            jobs.removeAll { $0.jobId == jobID }
            runningJobs.removeValue(forKey: jobID)
        }
    }

    var activeRunningCount: Int {
        runningJobs.count
    }

    private func upsert(_ job: CronJob) {
        let matchingIndex: Int?
        if let jobID = job.jobId {
            matchingIndex = jobs.firstIndex { $0.jobId == jobID }
        } else if let name = job.name {
            matchingIndex = jobs.firstIndex { $0.jobId == nil && $0.name == name }
        } else {
            matchingIndex = nil
        }

        if let index = matchingIndex {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        jobs.sort(by: sortJobs)
    }

    private func sortJobs(_ left: CronJob, _ right: CronJob) -> Bool {
        if runningElapsed(for: left) != nil, runningElapsed(for: right) == nil {
            return true
        }

        if runningElapsed(for: left) == nil, runningElapsed(for: right) != nil {
            return false
        }

        switch (left.nextRunAt?.date, right.nextRunAt?.date) {
        case let (leftDate?, rightDate?):
            return leftDate < rightDate
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }
}
