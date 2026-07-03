import Foundation
import Observation

@MainActor
@Observable
final class TaskDetailViewModel {
    private(set) var job: CronJob
    private(set) var runningElapsed: Double?

    private(set) var outputs: [CronOutputItem] = []
    private(set) var runs: [CronRunHistoryItem] = []
    private(set) var relatedSession: CronRelatedSession?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var lastMutation: CronJobListMutation?

    private let client: APIClient

    var recentRunItems: [CronRunListItem] {
        CronRunListItem.items(runs: runs, outputs: outputs)
    }

    init(job: CronJob, runningElapsed: Double?, server: URL, client: APIClient? = nil) {
        self.job = job
        self.runningElapsed = runningElapsed
        relatedSession = job.relatedSession
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        guard let jobID = job.jobId else {
            errorMessage = String(localized: "Missing job identifier.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        do {
            let response = try await client.cronOutput(jobID: jobID, limit: 5)
            outputs = response.outputs ?? []
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }

        do {
            let response = try await client.cronHistory(jobID: jobID, limit: 5)
            runs = response.runs ?? []
        } catch {
            runs = []
        }

        do {
            let response = try await client.cronRecent(since: 0)
            if let related = Self.latestRelatedSession(from: response, jobID: jobID) {
                relatedSession = related
            }
        } catch {
            // Older servers may not expose /api/crons/recent; the direct job payload
            // and run output remain useful, so related-chat lookup is best-effort.
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    func runNow() async -> Bool {
        let success = await mutateJob { jobID in
            try await client.runCron(jobID: jobID)
        }
        if success {
            runningElapsed = 0
        }
        return success
    }

    func pause(reason: String? = nil) async -> Bool {
        let success = await mutateJob { jobID in
            try await client.pauseCron(jobID: jobID, reason: reason)
        }
        if success {
            runningElapsed = nil
        }
        return success
    }

    func resume() async -> Bool {
        return await mutateJob { jobID in
            try await client.resumeCron(jobID: jobID)
        }
    }

    func update(from draft: CronJobEditorDraft) async -> Bool {
        guard draft.validationMessage == nil else {
            actionErrorMessage = draft.validationMessage
            return false
        }

        return await mutateJob { jobID in
            try await client.updateCron(
                jobID: jobID,
                prompt: draft.trimmedPrompt,
                schedule: draft.trimmedSchedule,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                deliver: draft.deliver.trimmingCharacters(in: .whitespacesAndNewlines),
                skills: draft.skills,
                model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
                profile: draft.profile.trimmingCharacters(in: .whitespacesAndNewlines),
                toastNotifications: draft.toastNotifications
            )
        }
    }

    func delete() async -> Bool {
        guard let jobID = job.jobId else {
            actionErrorMessage = String(localized: "Missing job identifier.")
            return false
        }

        isMutating = true
        actionErrorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isMutating = false }

        do {
            let response = try await client.deleteCron(jobID: jobID)
            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not delete automation.")
                return false
            }

            lastMutation = .delete(jobID: jobID)
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func mutateJob(
        action: (String) async throws -> CronMutationResponse
    ) async -> Bool {
        guard let jobID = job.jobId else {
            actionErrorMessage = String(localized: "Missing job identifier.")
            return false
        }

        isMutating = true
        actionErrorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isMutating = false }

        do {
            let response = try await action(jobID)
            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not update automation.")
                return false
            }

            if let updatedJob = response.job {
                job = updatedJob
                if let updatedRelatedSession = updatedJob.relatedSession {
                    relatedSession = updatedRelatedSession
                }
                lastMutation = .upsert(updatedJob)
            }
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }

    private static func latestRelatedSession(from response: CronRecentResponse, jobID: String) -> CronRelatedSession? {
        response.completions?
            .filter { $0.jobId == jobID && $0.relatedSession != nil }
            .max { lhs, rhs in
                (lhs.completedAt ?? -Double.infinity) < (rhs.completedAt ?? -Double.infinity)
            }?
            .relatedSession
    }
}
