import XCTest
@testable import HermesMobile

/// Covers the two places run history can quietly go wrong: paging arithmetic,
/// which upstream makes non-obvious, and a slow run-output request landing
/// after the user has moved on.
final class TaskRunHistoryTests: APIClientTestCase {
    // MARK: - Decoding

    func testHistoryDecodesTolerantlyAndDropsRunsWithoutAFilename() throws {
        let response = try decodeHistory("""
        {
          "job_id": "job-123",
          "total": "120",
          "offset": 0,
          "runs": [
            {
              "filename": "2026-09-03.md",
              "size": 12684,
              "modified": 1772524800.5,
              "usage": {"model": "sonnet-5", "duration_seconds": 41.2, "total_tokens": "18240"},
              "unexpected_field": {"nested": true}
            },
            {"filename": "2026-09-02.md", "size": 11800, "modified": 1772438400, "usage": {}},
            {"size": 900, "modified": 1772352000}
          ]
        }
        """)

        XCTAssertEqual(response.total, 120)
        XCTAssertEqual(response.runs.map(\.filename), ["2026-09-03.md", "2026-09-02.md"])

        let first = try XCTUnwrap(response.runs.first)
        XCTAssertEqual(first.size, 12684)
        XCTAssertEqual(first.modified?.timeIntervalSince1970 ?? 0, 1_772_524_800.5, accuracy: 0.01)
        XCTAssertEqual(first.usage.model, "sonnet-5")
        XCTAssertEqual(first.usage.durationSeconds ?? 0, 41.2, accuracy: 0.01)
        XCTAssertEqual(first.usage.totalTokens, 18240)

        // The common case: the server parsed nothing out of the run.
        let second = try XCTUnwrap(response.runs.last)
        XCTAssertEqual(second.usage, CronRunUsage())
        XCTAssertNil(second.usage.model)
    }

    /// `size` and `modified` are numbers the server derives from `stat()`. A
    /// value outside `Int`'s range, or a non-finite mtime, must decode to
    /// nothing rather than trap on conversion or in date formatting.
    func testMalformedSizeAndModifiedDecodeWithoutTrapping() throws {
        let response = try decodeHistory("""
        {
          "job_id": "job-123",
          "total": null,
          "runs": [
            {"filename": "huge.md", "size": 1e30, "modified": "not-a-date"},
            {"filename": "odd.md", "size": "2048", "modified": "1772438400"},
            {"filename": "broken.md", "size": {"bytes": 12}, "usage": "unexpected"}
          ]
        }
        """)

        XCTAssertNil(response.total)
        XCTAssertEqual(response.runs.count, 3)
        XCTAssertNil(response.runs[0].size)
        XCTAssertNil(response.runs[0].modified)
        XCTAssertEqual(response.runs[1].size, 2048)
        XCTAssertEqual(response.runs[1].modified?.timeIntervalSince1970, 1_772_438_400)
        XCTAssertNil(response.runs[2].size)
        XCTAssertEqual(response.runs[2].usage, CronRunUsage())
    }

    // MARK: - Paging

    /// Upstream slices `all_files[offset:offset + limit]` and then skips any
    /// file it cannot `stat()`, so a page can return fewer rows than it
    /// consumed. Paging by `runs.count` would re-request rows already shown.
    @MainActor
    func testPagingAdvancesByRequestedLimitEvenWhenAPageReturnsFewerRows() async {
        let recorder = RequestRecorder()
        let pageSize = TaskDetailViewModel.historyPageSize
        let viewModel = makeViewModel { request in
            recorder.record(request)
            // Three rows for a fifty-row window: the rest failed to stat.
            return apiTestJSONResponse(Self.historyJSON(total: 120, offset: recorder.lastOffset ?? 0, count: 3), for: request)
        }

        await viewModel.loadHistory()
        await viewModel.loadMoreRuns()
        await viewModel.loadMoreRuns()

        XCTAssertEqual(recorder.offsets, [0, pageSize, pageSize * 2])
        XCTAssertEqual(recorder.limits, [pageSize, pageSize, pageSize])
        XCTAssertEqual(viewModel.runs.count, 9)
        XCTAssertEqual(viewModel.runTotal, 120)
        // 150 requested against a total of 120: there is nothing left to ask for.
        XCTAssertFalse(viewModel.canLoadMoreRuns)
    }

    @MainActor
    func testPagingStopsWhenTheFirstPageCoversTheTotal() async {
        let viewModel = makeViewModel { request in
            apiTestJSONResponse(Self.historyJSON(total: 50, offset: 0, count: 50), for: request)
        }

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.runs.count, 50)
        XCTAssertEqual(viewModel.remainingRunCount, 0)
        XCTAssertFalse(viewModel.canLoadMoreRuns)
    }

    /// A job writing new output between two pages shifts every row down one, so
    /// the second page can repeat what the first already showed.
    @MainActor
    func testOverlappingPagesDoNotDuplicateRuns() async {
        let recorder = RequestRecorder()
        let viewModel = makeViewModel { request in
            recorder.record(request)
            let names = (recorder.offsets.count == 1)
                ? ["run-1.md", "run-2.md", "run-3.md"]
                : ["run-3.md", "run-4.md"]
            return apiTestJSONResponse(Self.historyJSON(total: 120, filenames: names), for: request)
        }

        await viewModel.loadHistory()
        await viewModel.loadMoreRuns()

        XCTAssertEqual(viewModel.runs.map(\.filename), ["run-1.md", "run-2.md", "run-3.md", "run-4.md"])
    }

    /// A page fetched before a refresh describes a list that no longer exists.
    /// Splicing it onto the refreshed list would leave the pages between them
    /// loaded nowhere and unreachable, and push the cursor past both.
    @MainActor
    func testAPageInFlightWhenARefreshLandsIsDiscarded() async {
        let recorder = RequestRecorder()
        let pageSize = TaskDetailViewModel.historyPageSize
        let secondPageStarted = expectation(description: "second page request started")
        let releaseSecondPage = DispatchSemaphore(value: 0)

        let viewModel = makeViewModel { request in
            recorder.record(request)
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0

            // Hold only the first "Load more", so the refresh can overtake it.
            if recorder.offsets.count == 2 {
                secondPageStarted.fulfill()
                releaseSecondPage.wait()
            }

            let page = offset == pageSize ? "page-2.md" : "page-1.md"
            return apiTestJSONResponse(Self.historyJSON(total: 200, filenames: [page]), for: request)
        }

        await viewModel.loadHistory()
        let loadMore = Task { await viewModel.loadMoreRuns() }
        await fulfillment(of: [secondPageStarted], timeout: 5)

        // The user pulls to refresh while the page is still in flight.
        await viewModel.loadHistory()
        releaseSecondPage.signal()
        await loadMore.value

        XCTAssertEqual(viewModel.runs.map(\.filename), ["page-1.md"])
        // The cursor still points at the page after the one on screen.
        await viewModel.loadMoreRuns()
        XCTAssertEqual(recorder.offsets.last, pageSize)
    }

    /// While a reload is in flight the cursor still points into the list being
    /// replaced, so "Load more" must not fetch against it — a page taken from
    /// the old cursor would land on the new list.
    @MainActor
    func testLoadMoreIsRefusedWhileAReloadIsInFlight() async {
        let recorder = RequestRecorder()
        let pageSize = TaskDetailViewModel.historyPageSize
        let reloadStarted = expectation(description: "reload request started")
        let releaseReload = DispatchSemaphore(value: 0)

        let viewModel = makeViewModel { request in
            recorder.record(request)
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0

            // Hold the reload — the third request — open.
            if recorder.offsets.count == 3 {
                reloadStarted.fulfill()
                releaseReload.wait()
            }

            let page = offset == 0 ? "page-1.md" : "page-2.md"
            return apiTestJSONResponse(Self.historyJSON(total: 200, filenames: [page]), for: request)
        }

        await viewModel.loadHistory()
        await viewModel.loadMoreRuns()
        XCTAssertEqual(viewModel.runs.map(\.filename), ["page-1.md", "page-2.md"])

        let reload = Task { await viewModel.loadHistory() }
        await fulfillment(of: [reloadStarted], timeout: 5)

        // The cursor still reads 100 here, but it belongs to the list being
        // replaced, so no request may be made against it.
        await viewModel.loadMoreRuns()
        XCTAssertEqual(recorder.offsets, [0, pageSize, 0])

        releaseReload.signal()
        await reload.value

        XCTAssertEqual(viewModel.runs.map(\.filename), ["page-1.md"])
        await viewModel.loadMoreRuns()
        XCTAssertEqual(recorder.offsets.last, pageSize)
    }

    // MARK: - Failure containment

    @MainActor
    func testHistoryFailureLeavesTheRestOfTheScreenIntact() async {
        let viewModel = makeViewModel { request in
            if request.url?.path == "/api/crons/history" {
                return apiTestJSONResponse("{\"error\": \"boom\"}", for: request, status: 500)
            }
            return apiTestJSONResponse("""
            {"job_id": "job-123", "outputs": [{"filename": "latest.md", "content": "still here"}]}
            """, for: request)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.outputs.first?.content, "still here")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.historyErrorMessage)
        XCTAssertFalse(viewModel.isHistoryUnavailable)
    }

    /// A refresh that fails keeps the runs the user was already reading.
    @MainActor
    func testFailedRefreshKeepsTheRunsAlreadyLoaded() async {
        let recorder = RequestRecorder()
        let viewModel = makeViewModel { request in
            recorder.record(request)
            guard recorder.offsets.count == 1 else {
                return apiTestJSONResponse("{\"error\": \"boom\"}", for: request, status: 500)
            }
            return apiTestJSONResponse(Self.historyJSON(total: 120, filenames: ["run-1.md"]), for: request)
        }

        await viewModel.loadHistory()
        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.runs.map(\.filename), ["run-1.md"])
        XCTAssertNotNil(viewModel.historyErrorMessage)
    }

    /// A server that predates the endpoint answers 404. The section disappears
    /// instead of parking a permanent error on the screen.
    @MainActor
    func testMissingEndpointRetiresTheHistorySection() async {
        let viewModel = makeViewModel { request in
            apiTestJSONResponse("{\"error\": \"not found\"}", for: request, status: 404)
        }

        await viewModel.loadHistory()

        XCTAssertTrue(viewModel.isHistoryUnavailable)
        XCTAssertNil(viewModel.historyErrorMessage)
        XCTAssertTrue(viewModel.runs.isEmpty)
        XCTAssertFalse(viewModel.canLoadMoreRuns)
    }

    // MARK: - Run output

    @MainActor
    func testRunOutputStripsEscapesAndCarriesItsFilename() async {
        let viewModel = makeViewModel { request in
            apiTestJSONResponse("""
            {
              "job_id": "job-123",
              "filename": "run-1.md",
              "content": "\\u001b[0;32mFAIL\\u001b[0m — did not verify",
              "usage": {}
            }
            """, for: request)
        }

        await viewModel.loadRunOutput(for: CronRunHistoryItem(filename: "run-1.md"))

        XCTAssertEqual(viewModel.runOutput?.filename, "run-1.md")
        XCTAssertEqual(viewModel.runOutput?.text, "FAIL — did not verify")
        XCTAssertFalse(viewModel.isLoadingRunOutput)
    }

    /// Tapping a second run while the first is still in flight must leave the
    /// sheet showing the run that was tapped last.
    @MainActor
    func testLateRunOutputResponseCannotOverwriteANewerSelection() async {
        let slowRequestStarted = expectation(description: "slow run output request started")
        let releaseSlowRequest = DispatchSemaphore(value: 0)

        let viewModel = makeViewModel { request in
            let filename = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "filename" }?.value

            if filename == "slow.md" {
                slowRequestStarted.fulfill()
                releaseSlowRequest.wait()
                return apiTestJSONResponse("""
                {"job_id": "job-123", "filename": "slow.md", "content": "stale output"}
                """, for: request)
            }

            return apiTestJSONResponse("""
            {"job_id": "job-123", "filename": "fresh.md", "content": "fresh output"}
            """, for: request)
        }

        let slowLoad = Task { await viewModel.loadRunOutput(for: CronRunHistoryItem(filename: "slow.md")) }
        await fulfillment(of: [slowRequestStarted], timeout: 5)

        await viewModel.loadRunOutput(for: CronRunHistoryItem(filename: "fresh.md"))
        XCTAssertEqual(viewModel.runOutput?.filename, "fresh.md")

        releaseSlowRequest.signal()
        await slowLoad.value

        XCTAssertEqual(viewModel.runOutput?.filename, "fresh.md")
        XCTAssertEqual(viewModel.runOutput?.text, "fresh output")
        XCTAssertFalse(viewModel.isLoadingRunOutput)
    }

    /// Only the newest run can carry the job's last-run verdict; history says
    /// nothing about the status of older runs.
    @MainActor
    func testOnlyTheNewestRunInheritsTheJobsFailedStatus() async {
        let viewModel = makeViewModel(job: Self.failedJob()) { request in
            apiTestJSONResponse(Self.historyJSON(total: 3, filenames: ["newest.md", "older.md"]), for: request)
        }

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.latestRun?.filename, "newest.md")
        XCTAssertTrue(viewModel.isFailedRun(CronRunHistoryItem(filename: "newest.md")))
        XCTAssertFalse(viewModel.isFailedRun(CronRunHistoryItem(filename: "older.md")))
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        job: CronJob? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> TaskDetailViewModel {
        TaskDetailViewModel(
            job: job ?? Self.makeJob(),
            runningElapsed: nil,
            server: URL(string: "https://example.test")!,
            client: makeClient(handler: handler)
        )
    }

    private func decodeHistory(_ json: String) throws -> CronRunHistoryResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CronRunHistoryResponse.self, from: Data(json.utf8))
    }

    private static func makeJob() -> CronJob {
        decodeJob("""
        {"job_id": "job-123", "name": "Reddit Trending Scanner", "last_status": "ok"}
        """)
    }

    private static func failedJob() -> CronJob {
        decodeJob("""
        {"job_id": "job-123", "name": "trading-bot", "last_status": "error", "last_error": "exit code 1"}
        """)
    }

    private static func decodeJob(_ json: String) -> CronJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(CronJob.self, from: Data(json.utf8))
    }

    private static func historyJSON(total: Int, offset: Int = 0, count: Int) -> String {
        historyJSON(total: total, offset: offset, filenames: (0..<count).map { "run-\(offset + $0).md" })
    }

    private static func historyJSON(total: Int, offset: Int = 0, filenames: [String]) -> String {
        let runs = filenames.map { name in
            "{\"filename\": \"\(name)\", \"size\": 2048, \"modified\": 1772524800, \"usage\": {}}"
        }
        return """
        {"job_id": "job-123", "total": \(total), "offset": \(offset), "runs": [\(runs.joined(separator: ","))]}
        """
    }
}

/// Records the history requests a test made, so paging can be asserted on the
/// offsets the client actually asked for.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(offset: Int, limit: Int)] = []

    func record(_ request: URLRequest) {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return }

        let value = { (name: String) in items.first { $0.name == name }?.value.flatMap(Int.init) ?? -1 }
        lock.withLock { recorded.append((value("offset"), value("limit"))) }
    }

    var offsets: [Int] { lock.withLock { recorded.map(\.offset) } }
    var limits: [Int] { lock.withLock { recorded.map(\.limit) } }
    var lastOffset: Int? { lock.withLock { recorded.last?.offset } }
}
