import Foundation
import Observation

@MainActor
@Observable
final class TaskDetailViewModel {
    private(set) var job: CronJob
    private(set) var runningElapsed: Double?

    private(set) var outputs: [CronOutputItem] = []
    private(set) var deliveryOptions: [CronDeliveryOption]?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    private(set) var lastMutation: CronJobListMutation?

    private(set) var runs: [CronRunHistoryItem] = []
    private(set) var runTotal: Int?
    private(set) var isLoadingHistory = false
    private(set) var isLoadingMoreRuns = false
    private(set) var historyErrorMessage: String?
    private(set) var isHistoryUnavailable = false

    private(set) var runOutput: CronRunOutput?
    private(set) var isLoadingRunOutput = false
    private(set) var runOutputErrorMessage: String?

    static let historyPageSize = 50

    private var historyOffset = 0
    private var historyGeneration = 0
    private var lastRunWhenRunsRead: Date?
    private var runOutputToken = 0
    private var mutationCount = 0

    private(set) var isRunNowPending = false
    @ObservationIgnored var readList: (@MainActor () async throws -> CronJobList)?
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void
    static let runNowReadInterval = Duration.seconds(5)
    static let runNowReadAttempts = 3

    let client: any CronDataClient

    init(
        job: CronJob,
        runningElapsed: Double?,
        server: URL,
        client: (any CronDataClient)? = nil,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.job = job
        self.runningElapsed = runningElapsed
        self.client = client ?? APIClient(baseURL: server)
        self.sleep = sleep
    }

    func load() async {
        guard let jobID = job.jobId else {
            errorMessage = String(localized: "Missing job identifier.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isLoading = false }

        let profile = job.profile
        let runsAreSessions = client.cronFeatures.runsAreSessions
        async let deliveryOptionsResponse = try? client.cronDeliveryOptions(profile: profile)
        let generation = beginHistoryReload()

        if runsAreSessions {
            await reloadJob(jobID)
        }
        let lastRun = job.lastRunAt?.date
        async let historyResult = Self.fetchHistory(client: client, jobID: jobID, profile: profile, offset: 0)

        if !runsAreSessions {
            do {
                let response = try await client.cronOutput(jobID: jobID, limit: 5)
                outputs = response.outputs ?? []
            } catch {
                lastError = error
                errorMessage = error.localizedDescription
            }
        }

        deliveryOptions = await deliveryOptionsResponse?.platforms
        applyFirstHistoryPage(await historyResult, generation: generation, lastRun: lastRun)
        await loadLatestReply(jobID, generation: generation)
    }

    private func reloadJob(_ jobID: String) async {
        let mutationsBefore = mutationCount
        do {
            let list = try await client.cronJobs()
            guard mutationCount == mutationsBefore,
                  let fresh = list.jobs.first(where: { $0.jobId == jobID }) else { return }
            job = fresh
            runningElapsed = list.runningJobs[jobID]
            lastMutation = .upsert(fresh)
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func loadHistory() async {
        guard let jobID = job.jobId else { return }

        let generation = beginHistoryReload()
        let lastRun = job.lastRunAt?.date
        applyFirstHistoryPage(
            await Self.fetchHistory(client: client, jobID: jobID, profile: job.profile, offset: 0),
            generation: generation,
            lastRun: lastRun
        )
        await loadLatestReply(jobID, generation: generation)
    }

    private func loadLatestReply(_ jobID: String, generation: Int) async {
        guard client.cronFeatures.runsAreSessions, generation == historyGeneration else { return }
        guard job.hasFailedRun, let run = latestRun else {
            outputs = []
            return
        }
        let reply = try? await client.cronRunDetail(jobID: jobID, profile: job.profile, run: run)
        guard generation == historyGeneration else { return }
        outputs = [CronOutputItem(filename: run.filename, content: reply?.content)]
    }

    private func beginHistoryReload() -> Int {
        historyGeneration += 1
        isLoadingHistory = true
        historyErrorMessage = nil
        return historyGeneration
    }

    var canLoadMoreRuns: Bool {
        guard !isHistoryUnavailable, let runTotal else { return false }
        return historyOffset < runTotal
    }

    var remainingRunCount: Int {
        guard let runTotal else { return 0 }
        return max(0, runTotal - runs.count)
    }

    var latestRun: CronRunHistoryItem? {
        let finished = runs.lazy.filter { !$0.isRunning }
        guard client.cronFeatures.runsAreSessions else { return finished.first }
        let lastRun = job.lastRunAt?.date
        guard lastRun == lastRunWhenRunsRead else { return nil }
        return finished.first { run in
            guard let ended = run.modified, let lastRun else { return true }
            return ended <= lastRun
        }
    }

    enum RunOutcome: Equatable {
        case running, completed
        case failed(String?)
    }

    func outcome(of run: CronRunHistoryItem) -> RunOutcome? {
        if run.isRunning { return .running }
        let runsAreSessions = client.cronFeatures.runsAreSessions
        guard run.id == latestRun?.id else { return runsAreSessions ? nil : .completed }
        if job.hasFailedRun { return .failed(job.failureSummary) }
        return !runsAreSessions || job.lastStatus == "ok" ? .completed : nil
    }

    func loadMoreRuns() async {
        guard let jobID = job.jobId, canLoadMoreRuns, !isLoadingMoreRuns, !isLoadingHistory else { return }

        let offset = historyOffset
        let generation = historyGeneration
        isLoadingMoreRuns = true
        historyErrorMessage = nil
        defer { isLoadingMoreRuns = false }

        let result = await Self.fetchHistory(client: client, jobID: jobID, profile: job.profile, offset: offset)

        guard generation == historyGeneration, offset == historyOffset else { return }

        switch result {
        case let .success(response):
            historyOffset = offset + Self.historyPageSize
            if let total = response.total {
                runTotal = total
            }
            appendRuns(response.runs)
        case let .failure(error):
            historyErrorMessage = error.localizedDescription
        }
    }

    func loadRunOutput(for run: CronRunHistoryItem) async {
        guard let jobID = job.jobId else {
            runOutputErrorMessage = String(localized: "Missing job identifier.")
            return
        }

        runOutputToken += 1
        let token = runOutputToken
        runOutput = nil
        runOutputErrorMessage = nil
        isLoadingRunOutput = true

        do {
            let response = try await client.cronRunDetail(jobID: jobID, profile: job.profile, run: run)
            guard token == runOutputToken else { return }
            isLoadingRunOutput = false
            runOutput = CronRunOutput(
                filename: run.filename,
                text: (response.content ?? response.snippet ?? "").strippingANSIEscapes()
            )
        } catch {
            guard token == runOutputToken else { return }
            isLoadingRunOutput = false
            runOutputErrorMessage = error.localizedDescription
        }
    }

    func clearRunOutput() {
        runOutputToken += 1
        runOutput = nil
        runOutputErrorMessage = nil
        isLoadingRunOutput = false
    }

    private func applyFirstHistoryPage(
        _ result: Result<CronRunHistoryResponse, Error>,
        generation: Int,
        lastRun: Date?
    ) {
        guard generation == historyGeneration else { return }
        isLoadingHistory = false

        switch result {
        case let .success(response):
            runs = response.runs
            lastRunWhenRunsRead = lastRun
            runTotal = response.total
            historyOffset = Self.historyPageSize
            isHistoryUnavailable = false
        case let .failure(error):
            if Self.isMissingEndpoint(error) {
                isHistoryUnavailable = true
                runs = []
                runTotal = nil
                historyOffset = 0
            } else {
                historyErrorMessage = error.localizedDescription
            }
        }
    }

    private func appendRuns(_ page: [CronRunHistoryItem]) {
        var seen = Set(runs.map(\.filename))
        for run in page where seen.insert(run.filename).inserted {
            runs.append(run)
        }
    }

    private static func fetchHistory(
        client: any CronDataClient,
        jobID: String,
        profile: String?,
        offset: Int
    ) async -> Result<CronRunHistoryResponse, Error> {
        do {
            return .success(try await client.cronHistory(jobID: jobID, profile: profile, offset: offset,
                                                         limit: historyPageSize))
        } catch {
            return .failure(error)
        }
    }

    private static func isMissingEndpoint(_ error: Error) -> Bool {
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    enum RunNowState: Equatable { case idle, requested, running }

    var runNowState: RunNowState {
        guard isRunNowPending else { return .idle }
        return runningElapsed == nil ? .requested : .running
    }

    func runNow() async -> Bool {
        guard client.cronFeatures.runNowWaitsForRun else {
            let success = await mutateJob { jobID in
                try await client.runCron(jobID: jobID, profile: job.profile)
            }
            if success {
                runningElapsed = 0
            }
            return success
        }
        guard await followRunNow() else { return false }
        if historyGeneration > 0, !Task.isCancelled {
            await loadHistory()
        }
        return true
    }

    private func followRunNow() async -> Bool {
        guard let jobID = job.jobId else {
            actionErrorMessage = String(localized: "Missing job identifier.")
            return false
        }
        guard !isRunNowPending else { return false }

        isRunNowPending = true
        actionErrorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isRunNowPending = false }

        let lastRun = job.lastRunAt?.date
        let (events, continuation) = AsyncStream<RunNowEvent>.makeStream()
        Task { [client, profile = job.profile] in
            do {
                continuation.yield(.replied(.success(try await client.runCron(jobID: jobID, profile: profile))))
            } catch {
                continuation.yield(.replied(.failure(error)))
            }
        }
        var timer = startRunNowTimer(continuation)
        var failedReads = 0
        defer {
            timer.cancel()
            continuation.finish()
        }

        for await event in events {
            var refusal: Error?
            switch event {
            case .replied(.success(let response)):
                showRunNowReply(response, jobID: jobID)
                return true
            case .replied(.failure(let error)) where Self.isUnansweredTrigger(error):
                continue
            case .replied(.failure(let error)) where error is HermesCronRefusal:
                refusal = error
                timer.cancel()
            case .replied(.failure(let error)):
                return failRunNow(error)
            case .tick:
                break
            }

            let reading: RunNowReading
            do {
                reading = try await readRunNow(jobID, since: lastRun)
                failedReads = 0
            } catch {
                guard !Task.isCancelled else { return false }
                failedReads += 1
                if refusal == nil, failedReads < Self.runNowReadAttempts {
                    timer = startRunNowTimer(continuation)
                    continue
                }
                return failRunNow(refusal ?? error)
            }
            guard !Task.isCancelled else { return false }
            if reading == .finished { return true }
            if let refusal, reading != .running { return failRunNow(refusal) }
            timer = startRunNowTimer(continuation)
        }
        return false
    }

    private func failRunNow(_ error: Error) -> Bool {
        lastError = error
        actionErrorMessage = error.localizedDescription
        return false
    }

    private enum RunNowEvent: Sendable {
        case replied(Result<CronMutationResponse, Error>)
        case tick
    }

    private enum RunNowReading { case notYet, running, finished }

    private func startRunNowTimer(_ continuation: AsyncStream<RunNowEvent>.Continuation) -> Task<Void, Never> {
        Task { [sleep] in
            guard (try? await sleep(Self.runNowReadInterval)) != nil, !Task.isCancelled else { return }
            continuation.yield(.tick)
        }
    }

    private func readRunNow(_ jobID: String, since lastRun: Date?) async throws -> RunNowReading {
        let mutationsBefore = mutationCount
        let read = readList ?? { [client] in try await client.cronJobs() }
        let list = try await read()
        guard !Task.isCancelled, mutationCount == mutationsBefore,
              let fresh = list.jobs.first(where: { $0.jobId == jobID }) else { return .notYet }
        job = fresh
        runningElapsed = list.runningJobs[jobID]
        lastMutation = .upsert(fresh)
        if runningElapsed != nil { return .running }
        guard let ran = fresh.lastRunAt?.date, ran > lastRun ?? .distantPast else { return .notYet }
        return .finished
    }

    private func showRunNowReply(_ response: CronMutationResponse, jobID: String) {
        mutationCount += 1
        guard let finished = response.job else { return }
        job = finished
        runningElapsed = CronJobList(hermesJobs: [finished]).runningJobs[jobID]
        lastMutation = .upsert(finished)
    }

    private static func isUnansweredTrigger(_ error: Error) -> Bool {
        if case .rejected(let status)? = error as? BotFailure { return status == 504 || status == 524 }
        guard case .network(let underlying)? = error as? APIError, let code = (underlying as? URLError)?.code else {
            return false
        }
        return code == .timedOut || code == .networkConnectionLost
    }

    func pause(reason: String? = nil) async -> Bool {
        let success = await mutateJob { jobID in
            try await client.pauseCron(jobID: jobID, profile: job.profile, reason: reason)
        }
        if success {
            runningElapsed = nil
        }
        return success
    }

    func resume() async -> Bool {
        return await mutateJob { jobID in
            try await client.resumeCron(jobID: jobID, profile: job.profile)
        }
    }

    func update(from draft: CronJobEditorDraft) async -> Bool {
        guard draft.validationMessage == nil else {
            actionErrorMessage = draft.validationMessage
            return false
        }

        let profile = client.cronFeatures.isProfileScoped
            ? job.profile
            : draft.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return await mutateJob { jobID in
            try await client.updateCron(
                jobID: jobID,
                prompt: draft.trimmedPrompt,
                schedule: draft.trimmedSchedule,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                deliver: draft.deliver.trimmingCharacters(in: .whitespacesAndNewlines),
                skills: draft.skills,
                model: draft.model.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: draft.provider.trimmingCharacters(in: .whitespacesAndNewlines),
                profile: profile,
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
            let response = try await client.deleteCron(jobID: jobID, profile: job.profile)
            guard response.ok != false else {
                actionErrorMessage = response.error ?? String(localized: "Could not delete task.")
                return false
            }

            mutationCount += 1
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
                actionErrorMessage = response.error ?? String(localized: "Could not update task.")
                return false
            }

            mutationCount += 1
            if let updatedJob = response.job {
                job = updatedJob
                lastMutation = .upsert(updatedJob)
            }
            return true
        } catch {
            lastError = error
            actionErrorMessage = error.localizedDescription
            return false
        }
    }
}

struct CronRunOutput: Equatable {
    let filename: String
    let text: String
}
