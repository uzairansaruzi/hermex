import XCTest
@testable import HermesMobile

/// Covers the two places run history can quietly go wrong: paging arithmetic,
/// which upstream makes non-obvious, and a slow run-output request landing
/// after the user has moved on. A Hermes host's runs (#1042) are its run sessions.
final class TaskRunHistoryTests: APIClientTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

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
        XCTAssertEqual(viewModel.outcome(of: CronRunHistoryItem(filename: "newest.md")), .failed("exit code 1"))
        // Each older file is a run that finished.
        XCTAssertEqual(viewModel.outcome(of: CronRunHistoryItem(filename: "older.md")), .completed)
    }

    // MARK: - Hermes host (#1042)

    /// One page of the newest 100 runs, read in the Task's Profile. The host reports no total,
    /// so there is no "Load more". Every row also carries its session's `system_prompt`.
    @MainActor
    func testHermesHistoryIsTheNewest100RunsInTheTasksProfile() async throws {
        let viewModel = try hermesViewModel { request in
            request.url?.path == "/api/cron/jobs/a1/runs" ? .json(200, HermesRunFixture.runs([
                HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642,
                                     ["input_tokens": .number(1200), "output_tokens": .number(340),
                                      "estimated_cost_usd": .number(0.02), "actual_cost_usd": .number(0.0123)]),
                HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230),
                .object(["started_at": .number(1_791_118_800), "is_active": .bool(false)])
            ])) : nil
        }

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.runs.map(\.filename), ["cron_a1_20261006_090000", "cron_a1_20261005_090000"])
        let newest = try XCTUnwrap(viewModel.runs.first)
        XCTAssertEqual(newest.startedAt, Date(timeIntervalSince1970: 1_791_291_600))
        XCTAssertEqual(newest.modified, Date(timeIntervalSince1970: 1_791_291_642))
        XCTAssertFalse(newest.isRunning)
        XCTAssertEqual(newest.usage, CronRunUsage(model: "hermex-stub", estimatedCostUsd: 0.0123, durationSeconds: 42,
                                                  inputTokens: 1200, outputTokens: 340, totalTokens: 1540))
        XCTAssertNil(viewModel.historyErrorMessage)
        XCTAssertFalse(viewModel.canLoadMoreRuns)
        XCTAssertEqual(viewModel.remainingRunCount, 0)
        let read = try XCTUnwrap(HermesHostFixture.requests.last { $0.url?.path == "/api/cron/jobs/a1/runs" })
        XCTAssertEqual(Set(URLComponents(url: read.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []),
                       [URLQueryItem(name: "profile", value: "research"), URLQueryItem(name: "limit", value: "100")])
    }

    @MainActor
    func testHermesTaskThatHasNotRunHasAnEmptyHistory() async throws {
        let viewModel = try hermesViewModel { request in
            request.url?.path == "/api/cron/jobs/a1/runs" ? .json(200, HermesRunFixture.runs([])) : nil
        }

        await viewModel.loadHistory()

        XCTAssertFalse(viewModel.isHistoryUnavailable)
        XCTAssertNil(viewModel.historyErrorMessage)
        XCTAssertEqual(viewModel.runs, [])
        XCTAssertFalse(viewModel.canLoadMoreRuns)
    }

    /// A page without its `runs` list is a failed read, not a Task that never ran: the runs on
    /// screen stay beside a retry.
    @MainActor
    func testHermesPageWithoutItsRunsIsAFailedRead() async throws {
        let reads = ReadCounter()
        let viewModel = try hermesViewModel { request in
            guard request.url?.path == "/api/cron/jobs/a1/runs" else { return nil }
            return reads.next() == 1
                ? .json(200, HermesRunFixture.runs([
                    HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642)
                ]))
                : .json(200, .object(["items": .array([]), "limit": .number(100)]))
        }
        await viewModel.loadHistory()

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.runs.map(\.filename), ["cron_a1_20261006_090000"])
        XCTAssertNotNil(viewModel.historyErrorMessage)
        XCTAssertFalse(viewModel.isHistoryUnavailable)
    }

    /// The host keeps one outcome per Task, so only the newest finished run shows it, with the
    /// Task's reason. A run still going shows as running, and older runs claim nothing.
    @MainActor
    func testHermesOnlyTheNewestFinishedRunCarriesTheTasksOutcome() async throws {
        let script: (URLRequest) -> HermesHostFixture.Reply? = { request in
            request.url?.path == "/api/cron/jobs/a1/runs" ? .json(200, HermesRunFixture.runs([
                HermesRunFixture.run("cron_a1_20261007_090000", started: 1_791_378_000, ended: nil),
                HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642),
                HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230)
            ])) : nil
        }
        let failed = try hermesViewModel(["last_status": .string("error"), "last_error": .string("RuntimeError: disk full")],
                                         script: script)
        await failed.loadHistory()

        XCTAssertEqual(failed.runs.map(failed.outcome), [.running, .failed("RuntimeError: disk full"), nil])
        XCTAssertEqual(failed.latestRun?.filename, "cron_a1_20261006_090000")

        let succeeded = try hermesViewModel(["last_status": .string("ok")], script: script)
        await succeeded.loadHistory()

        XCTAssertEqual(succeeded.runs.map(succeeded.outcome), [.running, .completed, nil])
    }

    /// The detail reads the job before its runs, so a run that finished as the detail opened is
    /// among them when the job's outcome is its outcome, and that run carries it.
    @MainActor
    func testHermesDetailReadsItsRunsOnlyAfterTheJob() async throws {
        let failed: [String: BotJSON] = ["last_run_at": .string("2026-10-06T09:00:42-04:00"),
                                         "last_status": .string("error"), "last_error": .string("exit code 1")]
        let viewModel = try hermesViewModel(["last_run_at": .string("2026-10-05T09:00:30-04:00"),
                                             "last_status": .string("ok")]) { request in
            switch request.url?.path {
            case "/api/cron/jobs": return .park
            case "/api/cron/jobs/a1/runs":
                return .json(200, HermesRunFixture.runs([
                    HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642),
                    HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230)
                ]))
            default: return nil
            }
        }
        let listRead = expectation(description: "the list read is out")
        HermesHostFixture.onPark = { listRead.fulfill() }

        let load = Task { await viewModel.load() }
        await fulfillment(of: [listRead], timeout: 5)
        XCTAssertEqual(HermesHostFixture.count("/api/cron/jobs/a1/runs"), 0, "No runs read before the job is in")
        HermesHostFixture.releaseParked(.json(200, .array([HermesCronFixture.job("a1", profile: "research", failed)])))
        await load.value

        XCTAssertEqual(viewModel.runs.map(viewModel.outcome), [.failed("exit code 1"), nil])
    }

    /// The host stamps a Task's outcome once its run has ended, so a run that ended after the
    /// job's `last_run_at` (it finished between the two reads) is newer than the outcome and
    /// claims none. The run that ended by then carries it, and its reply is the latest output.
    @MainActor
    func testHermesRunThatEndedAfterTheJobsOutcomeClaimsNone() async throws {
        let viewModel = try hermesViewModel([
            "last_run_at": .string("2026-10-05T09:00:30-04:00"), "last_status": .string("error"),
            "last_error": .string("exit code 1")
        ]) { request in
            switch request.url?.path {
            case "/api/cron/jobs/a1/runs":
                return .json(200, HermesRunFixture.runs([
                    HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642),
                    HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230)
                ]))
            case "/api/sessions/cron_a1_20261005_090000/messages":
                return .json(200, HermesRunFixture.messages([HermesRunFixture.message("assistant", "Exit code 1.")]))
            default: return nil
            }
        }

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.runs.map(viewModel.outcome), [nil, .failed("exit code 1")])
        XCTAssertEqual(viewModel.latestRun?.filename, "cron_a1_20261005_090000")
        XCTAssertEqual(viewModel.outputs.map(\.content), ["Exit code 1."])
    }

    /// A run's output is its session's final reply, read in the Task's Profile; the earlier
    /// reply that came with a tool call is not it. Nothing is read from the host's disk.
    @MainActor
    func testHermesRunOutputIsTheRunsFinalReply() async throws {
        let viewModel = try hermesViewModel { request in
            request.url?.path == "/api/sessions/cron_a1_20261006_090000/messages"
                ? .json(200, HermesRunFixture.messages([
                    HermesRunFixture.message("user", "[IMPORTANT: You are running as a scheduled cron job.] Check the disk"),
                    HermesRunFixture.message("assistant", "Let me run a quick check.", callsATool: true),
                    HermesRunFixture.message("tool", #"{"output": "91%"}"#),
                    HermesRunFixture.message("assistant", "## Disk\n\nThe disk is **91%** full.")
                ])) : nil
        }

        await viewModel.loadRunOutput(for: CronRunHistoryItem(filename: "cron_a1_20261006_090000"))

        XCTAssertEqual(viewModel.runOutput, CronRunOutput(filename: "cron_a1_20261006_090000",
                                                          text: "## Disk\n\nThe disk is **91%** full."))
        XCTAssertNil(viewModel.runOutputErrorMessage)
        XCTAssertEqual(HermesHostFixture.requests.last?.url?.query, "profile=research")
        XCTAssertFalse(HermesHostFixture.requests.contains { $0.url?.path.hasPrefix("/api/fs") == true })
    }

    /// A run that never gave a final reply has no output, and the sheet says so. A run the host
    /// no longer has (404) is unavailable, not empty.
    @MainActor
    func testHermesRunWithoutAReplyHasNoOutputAndAMissingRunIsUnavailable() async throws {
        let viewModel = try hermesViewModel { request in
            switch request.url?.path {
            case "/api/sessions/cron_a1_20261006_090000/messages":
                return .json(200, HermesRunFixture.messages([
                    HermesRunFixture.message("user", "Check the disk"),
                    HermesRunFixture.message("assistant", "Let me run a quick check.", callsATool: true),
                    HermesRunFixture.message("tool", #"{"output": "91%"}"#)
                ]))
            case "/api/sessions/cron_a1_20261005_090000/messages":
                return .json(404, .object(["detail": .string("Session not found")]))
            default: return nil
            }
        }

        await viewModel.loadRunOutput(for: CronRunHistoryItem(filename: "cron_a1_20261006_090000"))
        XCTAssertEqual(viewModel.runOutput, CronRunOutput(filename: "cron_a1_20261006_090000", text: ""))
        XCTAssertNil(viewModel.runOutputErrorMessage)

        await viewModel.loadRunOutput(for: CronRunHistoryItem(filename: "cron_a1_20261005_090000"))
        XCTAssertNil(viewModel.runOutput)
        XCTAssertEqual(viewModel.runOutputErrorMessage, "This run is no longer on the server.")
    }

    /// A history read sent before a reload, answering after it, never replaces the reload's runs.
    @MainActor
    func testHermesHistoryFromBeforeAReloadNeverReplacesTheReloadsRuns() async throws {
        let reads = ReadCounter()
        let viewModel = try hermesViewModel { request in
            guard request.url?.path == "/api/cron/jobs/a1/runs" else { return nil }
            return reads.next() == 1 ? .park : .json(200, HermesRunFixture.runs([
                HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642)
            ]))
        }
        let parked = expectation(description: "the first read is out")
        HermesHostFixture.onPark = { parked.fulfill() }

        let first = Task { await viewModel.loadHistory() }
        await fulfillment(of: [parked], timeout: 5)
        await viewModel.loadHistory()
        HermesHostFixture.releaseParked(.json(200, HermesRunFixture.runs([
            HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230)
        ])))
        await first.value

        XCTAssertEqual(viewModel.runs.map(\.filename), ["cron_a1_20261006_090000"])
        XCTAssertFalse(viewModel.isLoadingHistory)
    }

    /// Opening the detail reads the job from the list and its runs, each run read in the Task's
    /// Profile and none from the disk. The latest output is the reply of the newest finished
    /// run, the one the Task's failure describes, never of a run still going, and it is read
    /// only when that run failed, the one time the detail shows it.
    @MainActor
    func testHermesLatestOutputIsTheNewestFinishedRunsReplyReadOnlyWhenItFailed() async throws {
        let script: (URLRequest) -> HermesHostFixture.Reply? = { request in
            switch request.url?.path {
            case "/api/cron/jobs/a1/runs":
                return .json(200, HermesRunFixture.runs([
                    HermesRunFixture.run("cron_a1_20261007_090000", started: 1_791_378_000, ended: nil),
                    HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642),
                    HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230)
                ]))
            case "/api/sessions/cron_a1_20261007_090000/messages":
                return .json(200, HermesRunFixture.messages([HermesRunFixture.message("assistant", "Still checking.")]))
            case "/api/sessions/cron_a1_20261006_090000/messages":
                return .json(200, HermesRunFixture.messages([
                    HermesRunFixture.message("user", "Check the disk"),
                    HermesRunFixture.message("assistant", "The disk check failed.")
                ]))
            default: return nil
            }
        }
        let failed: [String: BotJSON] = ["last_status": .string("error"), "last_error": .string("exit code 1")]
        let viewModel = try hermesViewModel(failed) { request in
            request.url?.path == "/api/cron/jobs"
                ? .json(200, .array([HermesCronFixture.job("a1", profile: "research", failed)])) : script(request)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.runs.count, 3)
        XCTAssertEqual(viewModel.outputs.map(\.content), ["The disk check failed."])
        XCTAssertNil(viewModel.errorMessage)
        let reads = HermesHostFixture.requests.compactMap(\.url)
        XCTAssertEqual(reads.filter { $0.path.hasPrefix("/api/cron/jobs/") || $0.path.hasPrefix("/api/sessions/") }
            .map { "\($0.path)?\($0.query ?? "")" }, [
                "/api/cron/jobs/a1/runs?profile=research&limit=100",
                "/api/sessions/cron_a1_20261006_090000/messages?profile=research"
            ])
        XCTAssertFalse(reads.contains { $0.path.hasPrefix("/api/fs") })

        HermesHostFixture.reset()
        let healthy: [String: BotJSON] = ["last_status": .string("ok")]
        let succeeded = try hermesViewModel(healthy) { request in
            request.url?.path == "/api/cron/jobs"
                ? .json(200, .array([HermesCronFixture.job("a1", profile: "research", healthy)])) : script(request)
        }

        await succeeded.load()

        XCTAssertEqual(succeeded.runs.count, 3)
        XCTAssertEqual(succeeded.outputs, [])
        XCTAssertFalse(HermesHostFixture.requests.contains { $0.url?.path.hasPrefix("/api/sessions/") == true })
    }

    /// A Hermes host answers Run Now with the Task's outcome once the new run has finished.
    /// The detail reads its runs again, so the outcome and the latest output are that run's,
    /// and the run before it claims nothing.
    @MainActor
    func testAHermesRunNowGivesItsOutcomeToTheNewRunNotTheOneBefore() async throws {
        let reads = ReadCounter()
        let before = HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230)
        let new = HermesRunFixture.run("cron_a1_20261006_090000", started: 1_791_291_600, ended: 1_791_291_642)
        let clock = RunNowClock()
        let viewModel = TaskDetailViewModel(
            job: try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research", [
                "last_run_at": .string("2026-10-05T09:00:30-04:00"), "last_status": .string("ok")
            ])]).first),
            runningElapsed: nil,
            server: URL(string: "https://hermes.example")!,
            client: HermesCronFixture.client { request in
                switch request.url?.path {
                case "/api/cron/jobs/a1/runs":
                    return .json(200, HermesRunFixture.runs(reads.next() == 1 ? [before] : [new, before]))
                case "/api/cron/jobs/a1/trigger":
                    return .json(200, HermesCronFixture.job("a1", profile: "research", [
                        "last_run_at": .string("2026-10-06T09:00:42-04:00"), "last_status": .string("error"),
                        "last_error": .string("RuntimeError: disk full")
                    ]))
                case "/api/sessions/cron_a1_20261006_090000/messages":
                    return .json(200, HermesRunFixture.messages([HermesRunFixture.message("assistant", "The disk is full.")]))
                default: return nil
                }
            },
            sleep: clock.sleep
        )
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.runs.map(viewModel.outcome), [.completed])

        let didRun = await viewModel.runNow()

        XCTAssertTrue(didRun)
        XCTAssertEqual(viewModel.runs.map(\.filename), ["cron_a1_20261006_090000", "cron_a1_20261005_090000"])
        XCTAssertEqual(viewModel.runs.map(viewModel.outcome), [.failed("RuntimeError: disk full"), nil])
        XCTAssertEqual(viewModel.outputs.map(\.content), ["The disk is full."])
    }

    /// Until the runs are read again, an outcome newer than them belongs to no listed run: when
    /// the read after a Run Now fails, the run before it neither takes the new failure nor
    /// stands in for its output.
    @MainActor
    func testAnOutcomeNewerThanTheRunsOnScreenIsNoListedRuns() async throws {
        let reads = ReadCounter()
        let before = HermesRunFixture.run("cron_a1_20261005_090000", started: 1_791_205_200, ended: 1_791_205_230)
        let clock = RunNowClock()
        let viewModel = TaskDetailViewModel(
            job: try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research", [
                "last_run_at": .string("2026-10-05T09:00:30-04:00"), "last_status": .string("ok")
            ])]).first),
            runningElapsed: nil,
            server: URL(string: "https://hermes.example")!,
            client: HermesCronFixture.client { request in
                switch request.url?.path {
                case "/api/cron/jobs/a1/runs":
                    return reads.next() == 1 ? .json(200, HermesRunFixture.runs([before])) : .fail(URLError(.timedOut))
                case "/api/cron/jobs/a1/trigger":
                    return .json(200, HermesCronFixture.job("a1", profile: "research", [
                        "last_run_at": .string("2026-10-06T09:00:42-04:00"), "last_status": .string("error"),
                        "last_error": .string("RuntimeError: disk full")
                    ]))
                default: return nil
                }
            },
            sleep: clock.sleep
        )
        await viewModel.loadHistory()

        let didRun = await viewModel.runNow()

        XCTAssertTrue(didRun)
        XCTAssertNotNil(viewModel.historyErrorMessage)
        XCTAssertEqual(viewModel.runs.map(\.filename), ["cron_a1_20261005_090000"])
        XCTAssertEqual(viewModel.runs.map(viewModel.outcome), [nil])
        XCTAssertNil(viewModel.latestRun, "No listed run has the failure's full output")
        XCTAssertEqual(viewModel.outputs, [])
        XCTAssertEqual(HermesHostFixture.requests.filter { $0.url?.path.hasPrefix("/api/sessions/") == true }, [])
    }

    // MARK: - Helpers

    /// A Task on a Hermes host, in the `research` Profile, with `job` on top of the pinned shape.
    @MainActor
    private func hermesViewModel(
        _ job: [String: BotJSON] = [:],
        script: @escaping (URLRequest) -> HermesHostFixture.Reply?
    ) throws -> TaskDetailViewModel {
        TaskDetailViewModel(
            job: try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research", job)]).first),
            runningElapsed: nil,
            server: URL(string: "https://hermes.example")!,
            client: HermesCronFixture.client(script)
        )
    }

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

/// Counts a scripted host's reads from its own thread: the host's script runs under the
/// fixture's lock, so it can't ask the fixture.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// This read's number, from 1.
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// A Hermes host's runs and run sessions (#1042), in the shapes `scripts/local-hermes` answered
/// at the pin (0.21.5, ca678285).
enum HermesRunFixture {
    /// One row of `GET /api/cron/jobs/{id}/runs`: the run's session, `system_prompt` and all,
    /// active until it has ended.
    static func run(_ id: String, started: Double, ended: Double?, _ overrides: [String: BotJSON] = [:]) -> BotJSON {
        var fields: [String: BotJSON] = [
            "id": .string(id), "source": .string("cron"), "model": .string("hermex-stub"),
            "system_prompt": .string(String(repeating: "You are Hermes, a helpful agent. ", count: 400)),
            "started_at": .number(started), "ended_at": ended.map(BotJSON.number) ?? .null,
            "end_reason": ended == nil ? .null : .string("cron_complete"), "message_count": .number(4),
            "input_tokens": .number(0), "output_tokens": .number(0), "cache_read_tokens": .number(0),
            "estimated_cost_usd": .number(0), "actual_cost_usd": .null, "cost_status": .string("unknown"),
            "title": .string("Morning digest · Oct 06 09:00"),
            "preview": .string("[IMPORTANT: You are running as a scheduled cron job. DELIVER..."),
            "last_active": .number(ended ?? started), "is_active": .bool(ended == nil), "profile": .string("research")
        ]
        fields.merge(overrides) { $1 }
        return .object(fields)
    }

    static func runs(_ rows: [BotJSON]) -> BotJSON {
        .object(["runs": .array(rows), "limit": .number(100)])
    }

    /// `GET /api/sessions/{id}/messages`, oldest first.
    static func messages(_ rows: [BotJSON]) -> BotJSON {
        .object(["session_id": .string("cron_a1"), "profile": .string("research"), "messages": .array(rows),
                 "pagination": .object(["limit": .number(500), "offset": .number(0), "order": .string("latest")])])
    }

    static func message(_ role: String, _ content: String, callsATool: Bool = false) -> BotJSON {
        let call = BotJSON.object(["id": .string("call_2"), "type": .string("function"),
                                   "function": .object(["name": .string("terminal"), "arguments": .string("{}")])])
        return .object(["role": .string(role), "content": .string(content),
                        "tool_calls": callsATool ? .array([call]) : .null, "display_kind": .null])
    }
}

/// A field the job does not have does not get a row: a job that leaves the
/// model, profile or skills to the server has nothing to say about them.
final class TaskConfigurationFieldTests: XCTestCase {
    func testFieldsTheJobDoesNotHaveAreAbsent() {
        let fields = TaskConfigurationField.fields(for: Self.decodeJob("""
        {"job_id": "job-123", "name": "Reddit Trending Scanner",
         "schedule": {"kind": "cron", "expr": "0 7 * * *"},
         "deliver": "discord:#social-posts", "model": "  ", "skills": [],
         "toast_notifications": true}
        """))

        XCTAssertEqual(fields.map(\.title), ["Schedule", "Deliver", "Notifications"])
        // The humanised schedule leads; the raw expression is the second line.
        // The clock format is the locale's, so only the sentence is asserted.
        XCTAssertTrue(fields.first?.value.hasPrefix("Daily at ") == true, "got \(fields.first?.value ?? "nil")")
        XCTAssertEqual(fields.first?.detail, "0 7 * * *")
        XCTAssertEqual(fields.first { $0.title == "Notifications" }?.value, "On")
    }

    func testFieldsTheJobHasAreShownAndTrimmed() {
        let fields = TaskConfigurationField.fields(for: Self.decodeJob("""
        {"job_id": "job-1", "model": " sonnet-5 ", "provider": "anthropic",
         "profile": "work", "skills": ["summarize", " ", " notify "]}
        """))

        XCTAssertEqual(fields.map(\.title), ["Schedule", "Deliver", "Model", "Provider", "Profile", "Skills"])
        XCTAssertEqual(fields.first { $0.title == "Model" }?.value, "sonnet-5")
        XCTAssertEqual(fields.first { $0.title == "Skills" }?.value, "summarize, notify")
        // Nothing said about notifications, so nothing claimed about them.
        XCTAssertNil(fields.first { $0.title == "Notifications" })
    }

    /// Every job delivers somewhere, and `local` is the server's own default
    /// rather than a stand-in for a value it failed to send.
    func testDeliverFallsBackToTheServerDefault() {
        let fields = TaskConfigurationField.fields(for: Self.decodeJob("""
        {"job_id": "job-3"}
        """))

        XCTAssertEqual(fields.first { $0.title == "Deliver" }?.value, "local")
    }

    private static func decodeJob(_ json: String) -> CronJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(CronJob.self, from: Data(json.utf8))
    }
}
