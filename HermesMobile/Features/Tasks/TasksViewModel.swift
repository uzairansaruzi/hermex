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
    /// Server-provided deliver targets; `nil` while unknown or when the
    /// endpoint is unavailable (the editor then falls back to free text).
    private(set) var deliveryOptions: [CronDeliveryOption]?
    /// Newest-first recent completions across every job. Empty until the feed
    /// answers, and stays empty on any feed failure; never gates `isLoading`.
    private(set) var recentRuns: [CronRecentCompletion] = []
    /// The in-flight feed request, so a reload cancels the one before it and
    /// tests can wait for the feed without polling.
    private(set) var recentRunsTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?

    /// Selected segment. View state only: never persisted, never carried
    /// between servers.
    var filter: TaskFilter = .all

    /// Jobs with a row action in flight, so a row cannot be double-fired and
    /// can show that it is waiting on the server.
    private(set) var pendingActionJobIDs: Set<String> = []

    private let server: URL
    private let client: APIClient

    init(server: URL, client: APIClient? = nil) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        refreshRecentRuns()

        do {
            async let jobsResponse = client.crons()
            async let statusResponse = client.cronStatus()
            // Optional endpoint: failure must not break the task list, and a
            // nil result keeps the editor's free-text deliver fallback.
            async let deliveryOptionsResponse = try? client.cronDeliveryOptions()

            let (jobsResult, statusResult) = try await (jobsResponse, statusResponse)
            runningJobs = statusResult.runningJobs ?? [:]
            jobs = jobsResult.jobs ?? []
            deliveryOptions = await deliveryOptionsResponse?.platforms
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches the recent-runs feed on its own task so a slow or missing
    /// endpoint never holds the task list in its loading state. A reload
    /// cancels the previous fetch, so a late answer cannot overwrite a newer
    /// one, and a failed refresh keeps the last good feed, the same way the
    /// task list keeps its jobs when its own reload fails. The task holds
    /// `self` weakly, so a screen that is gone by the time the feed answers
    /// is never written to.
    private func refreshRecentRuns() {
        recentRunsTask?.cancel()
        recentRunsTask = Task { [weak self, client] in
            let response = try? await client.cronRecent()
            guard let self, !Task.isCancelled, let response else { return }
            recentRuns = CronRecentCompletion.newestFirst(response.completions ?? [])
        }
    }

    /// The loaded job a recent run belongs to, or `nil` when the feed names a
    /// job the list does not have. Matches on id first; `/api/crons` has shipped
    /// with `id` null before, in which case the name is all there is.
    func job(for completion: CronRecentCompletion) -> CronJob? {
        if let jobID = completion.jobId, let job = jobs.first(where: { $0.jobId == jobID }) {
            return job
        }
        guard let name = completion.name, !name.isEmpty else { return nil }
        return jobs.first { $0.name == name }
    }

    func runningElapsed(for job: CronJob) -> Double? {
        guard let jobID = job.jobId else { return nil }
        return runningJobs[jobID]
    }

    var runningJobIDs: Set<String> {
        Set(runningJobs.keys)
    }

    /// The filtered, grouped agenda. `now` is injected so tests can pin the
    /// clock that decides today/tomorrow/this week.
    func sections(now: Date = .now, calendar: Calendar = .current) -> [TaskAgendaSection] {
        TaskAgenda.sections(
            jobs: jobs,
            runningJobIDs: runningJobIDs,
            filter: filter,
            now: now,
            calendar: calendar
        )
    }

    func count(for filter: TaskFilter) -> Int {
        TaskAgenda.count(of: filter, in: jobs, runningJobIDs: runningJobIDs)
    }

    func isPendingAction(_ job: CronJob) -> Bool {
        guard let jobID = job.jobId else { return false }
        return pendingActionJobIDs.contains(jobID)
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
                provider: draft.trimmedProvider,
                profile: draft.trimmedProfile,
                toastNotifications: draft.toastNotifications
            )

            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not create task.")
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

    // MARK: - Row actions

    // Row actions delegate to `TaskDetailViewModel` so the list and the detail
    // screen can never drift apart on what a mutation means. Nothing is applied
    // optimistically: the server's response is what moves the row, so a row
    // never claims a state the server has not confirmed.

    func runNow(_ job: CronJob) async {
        guard let jobID = await perform(job, action: { await $0.runNow() }) else { return }
        // The server accepted the run, so the job belongs in "Now" until the
        // next status poll replaces this with a real elapsed time.
        runningJobs[jobID] = 0
    }

    func pause(_ job: CronJob) async {
        guard let jobID = await perform(job, action: { await $0.pause() }) else { return }
        runningJobs.removeValue(forKey: jobID)
    }

    func resume(_ job: CronJob) async {
        _ = await perform(job, action: { await $0.resume() })
    }

    func delete(_ job: CronJob) async {
        _ = await perform(job, action: { await $0.delete() })
    }

    /// Runs one Task Detail mutation for `job` and folds the result back into
    /// the list. Returns the job's id on success, `nil` on failure or when the
    /// job has no id to mutate.
    @discardableResult
    private func perform(
        _ job: CronJob,
        action: (TaskDetailViewModel) async -> Bool
    ) async -> String? {
        guard let jobID = job.jobId, !pendingActionJobIDs.contains(jobID) else { return nil }

        pendingActionJobIDs.insert(jobID)
        actionErrorMessage = nil
        lastError = nil
        defer { pendingActionJobIDs.remove(jobID) }

        let detail = TaskDetailViewModel(
            job: job,
            runningElapsed: runningElapsed(for: job),
            server: server,
            client: client
        )

        let succeeded = await action(detail)
        lastError = detail.lastError

        guard succeeded else {
            actionErrorMessage = detail.actionErrorMessage ?? String(localized: "Could not update task.")
            return nil
        }

        if let mutation = detail.lastMutation {
            apply(mutation)
        }
        return jobID
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
    }
}
