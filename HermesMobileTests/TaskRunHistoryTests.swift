import XCTest
@testable import HermesMobile

final class TaskRunHistoryTests: APIClientTestCase {

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

        let second = try XCTUnwrap(response.runs.last)
        XCTAssertEqual(second.usage, CronRunUsage())
        XCTAssertNil(second.usage.model)
    }

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

    @MainActor
    func testPagingAdvancesByRequestedLimitEvenWhenAPageReturnsFewerRows() async {
        let recorder = RequestRecorder()
        let pageSize = TaskDetailViewModel.historyPageSize
        let viewModel = makeViewModel { request in
            recorder.record(request)
            return apiTestJSONResponse(Self.historyJSON(total: 120, offset: recorder.lastOffset ?? 0, count: 3), for: request)
        }

        await viewModel.loadHistory()
        await viewModel.loadMoreRuns()
        await viewModel.loadMoreRuns()

        XCTAssertEqual(recorder.offsets, [0, pageSize, pageSize * 2])
        XCTAssertEqual(recorder.limits, [pageSize, pageSize, pageSize])
        XCTAssertEqual(viewModel.runs.count, 9)
        XCTAssertEqual(viewModel.runTotal, 120)
        XCTAssertFalse(viewModel.canLoadMoreRuns)
    }

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

        await viewModel.loadHistory()
        releaseSecondPage.signal()
        await loadMore.value

        XCTAssertEqual(viewModel.runs.map(\.filename), ["page-1.md"])
        await viewModel.loadMoreRuns()
        XCTAssertEqual(recorder.offsets.last, pageSize)
    }

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

        await viewModel.loadMoreRuns()
        XCTAssertEqual(recorder.offsets, [0, pageSize, 0])

        releaseReload.signal()
        await reload.value

        XCTAssertEqual(viewModel.runs.map(\.filename), ["page-1.md"])
        await viewModel.loadMoreRuns()
        XCTAssertEqual(recorder.offsets.last, pageSize)
    }

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

    @MainActor
    func testOnlyTheNewestRunInheritsTheJobsFailedStatus() async {
        let viewModel = makeViewModel(job: Self.failedJob()) { request in
            apiTestJSONResponse(Self.historyJSON(total: 3, filenames: ["newest.md", "older.md"]), for: request)
        }

        await viewModel.loadHistory()

        XCTAssertEqual(viewModel.latestRun?.filename, "newest.md")
        XCTAssertEqual(viewModel.outcome(of: CronRunHistoryItem(filename: "newest.md")), .failed("exit code 1"))
        XCTAssertEqual(viewModel.outcome(of: CronRunHistoryItem(filename: "older.md")), .completed)
    }

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

    @MainActor
    func testHermesScriptOnlyRunOpensToItsRowsPreviewWithoutARequest() async throws {
        let cut = String(String(repeating: "Backup of /srv finished: 12 files, 0 errors. ", count: 4).prefix(179)) + "…"
        let viewModel = try hermesViewModel { request in
            request.url?.path == "/api/cron/jobs/a1/runs" ? .json(200, HermesRunFixture.runs([
                HermesRunFixture.scriptRun("cron_output:a1:2026-10-06_09-00-00", preview: cut),
                HermesRunFixture.scriptRun("cron_output:a1:2026-10-05_09-00-00", preview: "Waiting…"),
                HermesRunFixture.scriptRun("cron_output:a1:exec:1", preview: nil)
            ])) : nil
        }
        await viewModel.loadHistory()
        let sent = HermesHostFixture.requests.count
        let output = try XCTUnwrap(viewModel.runs.first), silent = try XCTUnwrap(viewModel.runs.last)

        await viewModel.loadRunOutput(for: output)
        XCTAssertEqual(viewModel.runOutput, CronRunOutput(filename: output.filename, text: cut))
        XCTAssertTrue(output.isScriptOutputCut)
        XCTAssertFalse(viewModel.runs[1].isScriptOutputCut)

        await viewModel.loadRunOutput(for: silent)
        XCTAssertEqual(viewModel.runOutput, CronRunOutput(filename: silent.filename, text: ""))
        XCTAssertNil(viewModel.runOutputErrorMessage)
        XCTAssertEqual(HermesHostFixture.requests.count, sent)
    }

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

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int { lock.withLock { count += 1; return count } }
}

enum HermesRunFixture {
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

    static func scriptRun(_ id: String, preview: String?, at time: Double = 1_791_291_600) -> BotJSON {
        .object([
            "id": .string(id), "title": .string(preview ?? "Script-only run"), "preview": preview.map(BotJSON.string) ?? .null,
            "source": .string("cron_output"), "started_at": .number(time), "last_active": .number(time),
            "ended_at": .number(time), "input_tokens": .number(0), "output_tokens": .number(0),
            "message_count": .number(0), "tool_call_count": .number(0), "model": .null, "cwd": .null,
            "archived": .bool(false), "is_active": .bool(false)
        ])
    }

    static func runs(_ rows: [BotJSON]) -> BotJSON {
        .object(["runs": .array(rows), "limit": .number(100)])
    }

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

final class TaskConfigurationFieldTests: XCTestCase {
    func testFieldsTheJobDoesNotHaveAreAbsent() {
        let fields = TaskConfigurationField.fields(for: Self.decodeJob("""
        {"job_id": "job-123", "name": "Reddit Trending Scanner",
         "schedule": {"kind": "cron", "expr": "0 7 * * *"},
         "deliver": "discord:#social-posts", "model": "  ", "skills": [],
         "toast_notifications": true}
        """))

        XCTAssertEqual(fields.map(\.title), ["Schedule", "Deliver", "Notifications"])
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
        XCTAssertNil(fields.first { $0.title == "Notifications" })
    }

    private static func decodeJob(_ json: String) -> CronJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(CronJob.self, from: Data(json.utf8))
    }
}
