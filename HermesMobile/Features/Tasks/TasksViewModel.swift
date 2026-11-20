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
    private(set) var deliveryOptions: [CronDeliveryOption]?
    private(set) var recentRuns: [CronRecentCompletion] = []
    private(set) var recentRunsTask: Task<Void, Never>?
    private(set) var isLoading = true
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var saveWarning: String?
    private(set) var lastError: Error?

    var filter: TaskFilter = .all

    private(set) var pendingActionJobIDs: Set<String> = []
    private var rowChanges = 0
    private var readsSent = 0
    private var newestReadShown = 0

    private struct ListRead {
        let number: Int
        let rowChanges: Int
    }

    private let server: URL
    let client: any CronDataClient
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void

    init(
        server: URL,
        client: (any CronDataClient)? = nil,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.server = server
        self.client = client ?? APIClient(baseURL: server)
        self.sleep = sleep
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        if client.cronFeatures.hasRecentRunsFeed {
            refreshRecentRuns()
        }

        do {
            let read = beginListRead()
            async let listResponse = client.cronJobs()
            async let deliveryOptionsResponse = listDeliveryOptions()

            show(try await listResponse, from: read)
            deliveryOptions = await deliveryOptionsResponse
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    private func beginListRead() -> ListRead {
        readsSent += 1
        return ListRead(number: readsSent, rowChanges: rowChanges)
    }

    private func show(_ list: CronJobList, from read: ListRead) {
        guard read.rowChanges == rowChanges, read.number > newestReadShown else { return }
        newestReadShown = read.number
        runningJobs = list.runningJobs
        jobs = list.jobs
        if let recent = list.recentRuns {
            recentRuns = CronRecentCompletion.newestFirst(recent)
        }
    }

    private func listDeliveryOptions() async -> [CronDeliveryOption]? {
        guard !client.cronFeatures.isProfileScoped else { return nil }
        return (try? await client.cronDeliveryOptions(profile: nil))?.platforms
    }

    var schedulerStallAge: Double? {
        jobs.filter { $0.enabled != false }
            .compactMap(\.schedulerHeartbeatAge)
            .filter { $0 > 180 }
            .max()
    }

    func clearSaveWarning() {
        saveWarning = nil
    }

    private func refreshRecentRuns() {
        recentRunsTask?.cancel()
        recentRunsTask = Task { [weak self, client] in
            let response = try? await client.cronRecent()
            guard let self, !Task.isCancelled, let response else { return }
            recentRuns = CronRecentCompletion.newestFirst(response.completions ?? [])
        }
    }

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

            saveWarning = response.warning
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
        rowChanges += 1
        switch mutation {
        case .upsert(let job):
            upsert(job)
        case .delete(let jobID):
            jobs.removeAll { $0.jobId == jobID }
            runningJobs.removeValue(forKey: jobID)
        }
    }

    func runNow(_ job: CronJob) async {
        var elapsed: Double?
        guard let jobID = await perform(job, action: { detail in
            detail.readList = { [weak self, client] in
                let read = self?.beginListRead()
                let list = try await client.cronJobs()
                if let self, let read, !Task.isCancelled { show(list, from: read) }
                return list
            }
            let didRun = await detail.runNow()
            elapsed = detail.runningElapsed
            return didRun
        }) else { return }
        runningJobs[jobID] = elapsed
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
            client: client,
            sleep: sleep
        )

        let succeeded = await action(detail)
        lastError = detail.lastError

        guard succeeded else {
            if !Task.isCancelled {
                actionErrorMessage = detail.actionErrorMessage ?? String(localized: "Could not update task.")
            }
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
