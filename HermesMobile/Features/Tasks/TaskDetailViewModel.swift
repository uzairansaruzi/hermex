import Foundation
import Observation

@MainActor
@Observable
final class TaskDetailViewModel {
    private(set) var job: CronJob
    private(set) var runningElapsed: Double?

    private(set) var outputs: [CronOutputItem] = []
    /// Server-provided deliver targets; `nil` while unknown or when the
    /// endpoint is unavailable (the editor then falls back to free text).
    private(set) var deliveryOptions: [CronDeliveryOption]?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var actionErrorMessage: String?
    private(set) var lastError: Error?
    /// What the Tasks list should apply after the last action, or after a Hermes host's
    /// detail re-read its job from the list (#1040).
    private(set) var lastMutation: CronJobListMutation?

    // MARK: - Run history

    /// Loaded runs, newest first, accumulated across pages.
    private(set) var runs: [CronRunHistoryItem] = []
    /// The server's full run count, which is what "Load more" counts down.
    private(set) var runTotal: Int?
    private(set) var isLoadingHistory = false
    private(set) var isLoadingMoreRuns = false
    private(set) var historyErrorMessage: String?
    /// `true` once the server has answered 404 for the history endpoint: an
    /// older `hermes-webui` that predates it. The section then disappears
    /// rather than showing a permanent error. Always `true` on a server without
    /// run history (a Hermes host until #1042).
    private(set) var isHistoryUnavailable = false

    /// The output of the run whose sheet is open, tagged with its filename so a
    /// slow response can never be shown under a different run.
    private(set) var runOutput: CronRunOutput?
    private(set) var isLoadingRunOutput = false
    private(set) var runOutputErrorMessage: String?

    /// Runs are requested 50 at a time — the server's own default page size.
    static let historyPageSize = 50

    /// How far the next page starts. Advances by `historyPageSize`, never by
    /// the number of rows a page returned.
    private var historyOffset = 0
    /// Bumped by every first-page load, so `runs` and `historyOffset` always
    /// describe the same list. A page fetched before a refresh belongs to a
    /// list that no longer exists: splicing it on would leave the pages between
    /// them loaded nowhere and unreachable.
    private var historyGeneration = 0
    private var runOutputToken = 0
    /// Bumped by every change the server accepts, so a list read sent before one
    /// (`reloadJob`, a Run Now's reads) can't put back the state it replaced.
    private var mutationCount = 0

    // MARK: - Run Now on a Hermes host

    /// True from a Hermes host's Run Now until the host's outcome (#1041); see `runNowState`.
    private(set) var isRunNowPending = false
    /// How a pending Run Now reads the list. The Tasks list passes one that also shows each
    /// read on its rows; nil reads it from `client`.
    @ObservationIgnored var readList: (@MainActor () async throws -> CronJobList)?
    /// Waits between a pending Run Now's list reads; tests pass a scripted clock.
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void
    static let runNowReadInterval = Duration.seconds(5)
    /// Failed list reads in a row that end a pending Run Now: about 15 s of a host the phone
    /// can't reach.
    static let runNowReadAttempts = 3

    /// The server's Tasks, shared with the edit sheet this screen opens.
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
        isHistoryUnavailable = !self.client.cronFeatures.hasRunHistory
    }

    func load() async {
        guard let jobID = job.jobId else {
            errorMessage = String(localized: "Missing job identifier.")
            return
        }
        guard client.cronFeatures.hasRunHistory else {
            await reloadJob(jobID)
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isLoading = false }

        // Optional endpoints: failure must not break the detail view. A nil
        // delivery result keeps the editor's free-text deliver fallback, and
        // history is its own failure domain that reports inline.
        let profile = job.profile
        async let deliveryOptionsResponse = try? client.cronDeliveryOptions(profile: profile)
        async let historyResult = Self.fetchHistory(client: client, jobID: jobID, offset: 0)

        let generation = beginHistoryReload()

        do {
            let response = try await client.cronOutput(jobID: jobID, limit: 5)
            outputs = response.outputs ?? []
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }

        deliveryOptions = await deliveryOptionsResponse?.platforms
        applyFirstHistoryPage(await historyResult, generation: generation)
    }

    /// Reads the job again from the list, the only read that carries a Hermes host's running
    /// state (#1040), and hands it to the list too. A job the list no longer has, or one
    /// changed here while the read was out, keeps what is on screen.
    private func reloadJob(_ jobID: String) async {
        isLoading = true
        errorMessage = nil
        lastError = nil
        lastMutation = nil
        defer { isLoading = false }
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

    /// Loads the first page of run history, replacing what is on screen.
    ///
    /// A failed refresh keeps the runs already loaded — losing a list the user
    /// was reading is worse than showing it beside a retry.
    func loadHistory() async {
        guard let jobID = job.jobId else { return }

        let generation = beginHistoryReload()
        applyFirstHistoryPage(
            await Self.fetchHistory(client: client, jobID: jobID, offset: 0),
            generation: generation
        )
    }

    /// Opens a new history generation and returns it. Every first-page load
    /// goes through here so overlapping reloads cannot be mistaken for one
    /// another.
    private func beginHistoryReload() -> Int {
        historyGeneration += 1
        isLoadingHistory = true
        historyErrorMessage = nil
        return historyGeneration
    }

    /// `true` while the server still holds runs past the ones on screen.
    var canLoadMoreRuns: Bool {
        guard !isHistoryUnavailable, let runTotal else { return false }
        return historyOffset < runTotal
    }

    /// How many runs "Load more" would still be working through.
    var remainingRunCount: Int {
        guard let runTotal else { return 0 }
        return max(0, runTotal - runs.count)
    }

    /// The newest run — the one the header's "See full output" opens.
    var latestRun: CronRunHistoryItem? { runs.first }

    /// `true` when `run` is the run the job's failed last-run status describes.
    ///
    /// History carries no per-run status, and the job record only ever reports
    /// on its most recent run, so no older row may claim a verdict it has no
    /// evidence for.
    func isFailedRun(_ run: CronRunHistoryItem) -> Bool {
        job.hasFailedRun && run.filename == runs.first?.filename
    }

    func loadMoreRuns() async {
        // Nothing is paged while a reload is in flight: until its first page
        // lands, `historyOffset` still points into the list being replaced, so
        // any page fetched now would be a page of the wrong list.
        guard let jobID = job.jobId, canLoadMoreRuns, !isLoadingMoreRuns, !isLoadingHistory else { return }

        let offset = historyOffset
        let generation = historyGeneration
        isLoadingMoreRuns = true
        historyErrorMessage = nil
        defer { isLoadingMoreRuns = false }

        let result = await Self.fetchHistory(client: client, jobID: jobID, offset: offset)

        // A refresh landed while this page was in flight. The page describes a
        // list that no longer exists, so it is dropped rather than spliced onto
        // the new one, which would leave the pages between them unreachable.
        // The cursor is checked as well as the generation: a reload that began
        // before this request bumped the generation ahead of it, so matching
        // generations alone would not prove the two describe the same list.
        guard generation == historyGeneration, offset == historyOffset else { return }

        switch result {
        case let .success(response):
            // The requested window is consumed whether or not every file in it
            // could be read, so the cursor moves by `limit`.
            historyOffset = offset + Self.historyPageSize
            if let total = response.total {
                runTotal = total
            }
            appendRuns(response.runs)
        case let .failure(error):
            historyErrorMessage = error.localizedDescription
        }
    }

    /// Fetches one run's full text for the output sheet.
    ///
    /// Only the newest request may write `runOutput`, so tapping a second run
    /// while the first is still in flight cannot leave the sheet showing the
    /// wrong run's output.
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
            let response = try await client.cronRunDetail(jobID: jobID, filename: run.filename)
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

    /// Drops the sheet's output so a reopened sheet never flashes the previous
    /// run's text.
    func clearRunOutput() {
        runOutputToken += 1
        runOutput = nil
        runOutputErrorMessage = nil
        isLoadingRunOutput = false
    }

    /// Applies a first page, or its failure. A 404 retires the section for this
    /// server; any other error is transient and reports beside the runs already
    /// on screen.
    ///
    /// A page from a superseded generation is dropped, so a slow reload cannot
    /// replace — or, on a stale 404, erase — a list that a newer one has since
    /// loaded.
    private func applyFirstHistoryPage(
        _ result: Result<CronRunHistoryResponse, Error>,
        generation: Int
    ) {
        guard generation == historyGeneration else { return }
        isLoadingHistory = false

        switch result {
        case let .success(response):
            runs = response.runs
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

    /// Appends a page, skipping runs already on screen. `total` can shift under
    /// us while a job is writing new output, which is enough to make two pages
    /// overlap.
    private func appendRuns(_ page: [CronRunHistoryItem]) {
        var seen = Set(runs.map(\.filename))
        for run in page where seen.insert(run.filename).inserted {
            runs.append(run)
        }
    }

    /// Static so `load()` can start it with `async let` without capturing the
    /// view model in a child task.
    private static func fetchHistory(
        client: any CronDataClient,
        jobID: String,
        offset: Int
    ) async -> Result<CronRunHistoryResponse, Error> {
        do {
            return .success(try await client.cronHistory(jobID: jobID, offset: offset, limit: historyPageSize))
        } catch {
            return .failure(error)
        }
    }

    /// A 404, or a Hermes host without the route (#1040), means this server has no
    /// history endpoint, not that the request was wrong.
    private static func isMissingEndpoint(_ error: Error) -> Bool {
        if error as? BotFailure == .unsupported { return true }
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Where a Run Now on a Hermes host is (#1041): sent, with the host not yet showing the run
    /// (`requested`), or shown running by the list (`running`). It is `idle` again with the
    /// host's outcome, and always on a server whose Run Now answers as the run starts.
    enum RunNowState: Equatable { case idle, requested, running }

    var runNowState: RunNowState {
        guard isRunNowPending else { return .idle }
        return runningElapsed == nil ? .requested : .running
    }

    /// Runs the Task now. A webui server starts the run and answers at once, so the Task
    /// shows as running from the answer; a Hermes host answers once the run has finished
    /// (`followRunNow`). Returns true for the server's outcome.
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
        return await followRunNow()
    }

    /// A Hermes host's Run Now (#1041). The trigger goes out on its own task, which nothing
    /// here cancels, and the list is read every `runNowReadInterval` until the host gives its
    /// outcome: the trigger's reply, or a read showing the run finished. The Task shows as
    /// running only once a read does. A 504, a 524, a timeout or a dropped connection is a
    /// hop giving up on the request while the host goes on with the run, so the reads go on
    /// and no error shows. A refusal shows the host's reason unless a read right after it
    /// shows the Task running or finished, as a 409 "already running" does. Reads that keep
    /// failing leave the run unknown, so Run Now ends with the read's error rather than
    /// waiting on with nothing to show.
    ///
    /// Cancelling the caller, as a screen does when it goes away, ends the reads and leaves
    /// the run to the host. The trigger's reply goes to this run's own stream, so one that
    /// comes after that can never stand in for a later run's outcome.
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

        // A finished run stamps `last_run_at`. Comparing the host's own stamps keeps the
        // phone's clock out of it.
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

    /// Ends a pending Run Now with `error`, which the screen shows.
    private func failRunNow(_ error: Error) -> Bool {
        lastError = error
        actionErrorMessage = error.localizedDescription
        return false
    }

    private enum RunNowEvent: Sendable {
        case replied(Result<CronMutationResponse, Error>)
        case tick
    }

    /// What one list read says about a pending Run Now. `notYet` also covers a read that a
    /// change made here meanwhile superseded, or that no longer has the Task.
    private enum RunNowReading { case notYet, running, finished }

    /// The tick for a pending Run Now's next read.
    private func startRunNowTimer(_ continuation: AsyncStream<RunNowEvent>.Continuation) -> Task<Void, Never> {
        Task { [sleep] in
            guard (try? await sleep(Self.runNowReadInterval)) != nil, !Task.isCancelled else { return }
            continuation.yield(.tick)
        }
    }

    /// Reads the list for a pending Run Now and shows the Task as it reads, as `reloadJob`
    /// does, or throws the read's failure. The run has finished once the host no longer shows
    /// it running and its last run is newer than `lastRun`, the one before the tap.
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

    /// Shows the trigger's reply: the job as the run left it, running only if the host says so.
    private func showRunNowReply(_ response: CronMutationResponse, jobID: String) {
        mutationCount += 1
        guard let finished = response.job else { return }
        job = finished
        runningElapsed = CronJobList(hermesJobs: [finished]).runningJobs[jobID]
        lastMutation = .upsert(finished)
    }

    /// A failed trigger that a hop gave up on while the host goes on with the run: a gateway
    /// timeout (504) or Cloudflare's (524), the request timing out, or the connection dropping.
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

        // A Task that lives in a Profile stays in it: the host can't move a job (#1040).
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

/// One run's text, carried with the filename it belongs to so the sheet can
/// refuse to render output that arrived for a different run.
struct CronRunOutput: Equatable {
    let filename: String
    let text: String
}
