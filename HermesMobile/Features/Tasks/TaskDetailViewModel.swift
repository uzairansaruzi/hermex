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
    /// rather than showing a permanent error.
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

    private let client: APIClient

    init(job: CronJob, runningElapsed: Double?, server: URL, client: APIClient? = nil) {
        self.job = job
        self.runningElapsed = runningElapsed
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

        // Optional endpoints: failure must not break the detail view. A nil
        // delivery result keeps the editor's free-text deliver fallback, and
        // history is its own failure domain that reports inline.
        async let deliveryOptionsResponse = try? client.cronDeliveryOptions()
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
        client: APIClient,
        jobID: String,
        offset: Int
    ) async -> Result<CronRunHistoryResponse, Error> {
        do {
            return .success(try await client.cronHistory(jobID: jobID, offset: offset, limit: historyPageSize))
        } catch {
            return .failure(error)
        }
    }

    /// A 404 means this server has no history endpoint, not that the request
    /// was wrong.
    private static func isMissingEndpoint(_ error: Error) -> Bool {
        guard case let APIError.http(statusCode, _) = error else { return false }
        return statusCode == 404
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
                provider: draft.provider.trimmingCharacters(in: .whitespacesAndNewlines),
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
                actionErrorMessage = response.error ?? String(localized: "Could not delete task.")
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
                actionErrorMessage = response.error ?? String(localized: "Could not update task.")
                return false
            }

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
