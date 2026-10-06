import XCTest
@testable import HermesMobile

/// Tasks on a Hermes host (#1040): `HermesCronClient` against a scripted host whose replies
/// are the shapes `scripts/local-hermes` answered at the pin (0.21.5, ca678285).
@MainActor final class HermesCronClientTests: XCTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testTheListIsEveryProfilesJobsFromABareArray() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs" ? .json(200, .array([
                HermesCronFixture.job("a1", profile: "default", ["future_field": .object(["x": .number(1)])]),
                HermesCronFixture.job("b2", profile: "research", ["enabled": .bool(false), "state": .string("paused")]),
                HermesCronFixture.job("c3", profile: "research", ["enabled": .bool(false), "state": .string("completed"),
                                                                  "latest_execution": .object(["status": .string("completed")])])
            ])) : nil
        }

        let list = try await client.cronJobs()

        XCTAssertEqual(list.jobs.map(\.jobId), ["a1", "b2", "c3"])
        XCTAssertEqual(list.jobs.map(\.profile), ["default", "research", "research"])
        XCTAssertEqual(list.jobs.map(\.state), ["scheduled", "paused", "completed"])
        XCTAssertEqual(list.jobs.map(\.latestExecutionStatus), [nil, nil, "completed"])
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.url?.path, "/api/cron/jobs")
        XCTAssertNil(request.url?.query, "The host's default lists every Profile")
    }

    func testAJobRunsWhileItHoldsAFireClaimOrItsExecutionIsInFlight() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let claimedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-42))
        let statuses = ["claimed", "running", "completed", "failed", "unknown"]
        let jobs = try HermesCronFixture.decode(
            [HermesCronFixture.job("claim", profile: "default", ["fire_claim": .object(["at": .string(claimedAt), "by": .string("m:1")])])]
                + statuses.map { HermesCronFixture.job($0, profile: "default", ["latest_execution": .object(["status": .string($0)])]) }
                + [HermesCronFixture.job("idle", profile: "default")]
        )

        let list = CronJobList(hermesJobs: jobs, now: now)

        XCTAssertEqual(list.runningJobs, ["claim": 42, "claimed": 0, "running": 0])
    }

    func testRecentRunsAreEachJobsLastRun() throws {
        let jobs = try HermesCronFixture.decode([
            HermesCronFixture.job("ok", profile: "default", ["last_run_at": .string("2026-10-05T09:00:00-04:00"),
                                                             "last_status": .string("ok")]),
            HermesCronFixture.job("failed", profile: "research", ["last_run_at": .string("2026-10-05T10:00:00.123456-04:00"),
                                                                  "last_status": .string("error")]),
            HermesCronFixture.job("never", profile: "default")
        ])

        let recent = CronRecentCompletion.newestFirst(try XCTUnwrap(CronJobList(hermesJobs: jobs).recentRuns))

        XCTAssertEqual(recent.map(\.jobId), ["failed", "ok"])
        XCTAssertEqual(recent.map(\.didFail), [true, false])
    }

    func testCreateSendsTheEditorsFieldsToTheTasksProfile() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs" && request.httpMethod == "POST"
                ? .json(200, HermesCronFixture.job("new1", profile: "research")) : nil
        }

        let response = try await client.createCron(
            prompt: "Summarize the news", schedule: "0 9 * * *", name: nil, deliver: "local", skills: ["arxiv"],
            model: "gpt-5", provider: "openai", profile: "research", toastNotifications: true
        )

        XCTAssertEqual(response.job?.jobId, "new1")
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.url?.query, "profile=research")
        XCTAssertEqual(HermesCronFixture.body(request), .object([
            "schedule": .string("0 9 * * *"), "prompt": .string("Summarize the news"), "name": .string(""),
            "deliver": .string("local"), "skills": .array([.string("arxiv")]), "model": .string("gpt-5"),
            "provider": .string("openai")
        ]), "No toast setting, and the Profile only in the query")
    }

    func testASchedulerRegistrationFailureIsSavedWithTheHostsWarning() async throws {
        let warning = "Cron job 'new1' was saved, but its first scheduler registration failed (ValueError)."
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs" ? .json(424, .object(["detail": .object([
                "error": .string(warning), "job_id": .string("new1"), "job_saved": .bool(true)
            ])])) : nil
        }

        let response = try await client.createCron(prompt: "p", schedule: "0 9 * * *", name: "n", deliver: nil, skills: [],
                                                   model: nil, provider: nil, profile: "research", toastNotifications: false)

        XCTAssertEqual(response, CronMutationResponse(ok: true, job: nil, error: nil, warning: warning))
    }

    func testARefusalCarriesTheHostsDetail() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs" ? .json(400, .object(["detail": .string("Invalid schedule 'whenever'.")])) : nil
        }

        do {
            _ = try await client.createCron(prompt: "p", schedule: "whenever", name: nil, deliver: nil, skills: [],
                                            model: nil, provider: nil, profile: "research", toastNotifications: true)
            XCTFail("Expected the host's refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server rejected the request: Invalid schedule 'whenever'.")
        }
    }

    /// A Task that removed itself after its last run, or was deleted on Desktop, is the host's
    /// explained 404; a proxy's 502 and Cloudflare's 530 name what is down in front of Hermes.
    func testAFailureReadsAsTheHostOrTheHopThatAnswered() async throws {
        let replies: [(id: String, reply: HermesHostFixture.Reply, expected: String)] = [
            ("gone", .json(404, .object(["detail": .string("Job not found")])), "The server rejected the request: Job not found"),
            ("a1", .json(502, .string("Bad Gateway")),
             "Your proxy answered, but Hermes didn't. Check that the dashboard is running on the host."),
            ("b2", .json(530, .string("")),
             "Cloudflare can't reach your tunnel. Check that cloudflared and the dashboard are running on the host.")
        ]
        let client = HermesCronFixture.client { request in
            replies.first { request.url?.path == "/api/cron/jobs/\($0.id)/pause" }?.reply
        }

        for row in replies {
            do {
                _ = try await client.pauseCron(jobID: row.id, profile: "research", reason: nil)
                XCTFail("\(row.id): expected a failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, row.expected, row.id)
            }
        }
    }

    func testAnEditSendsOnlyUpdatesAndNeverTheJobOrItsProfile() async throws {
        let client = HermesCronFixture.client { request in
            request.httpMethod == "PUT" ? .json(200, HermesCronFixture.job("d804e8d67342", profile: "research",
                                                                          ["name": .string("Digest")])) : nil
        }

        let response = try await client.updateCron(
            jobID: "d804e8d67342", prompt: "Summarize", schedule: "every 30m", name: "Digest", deliver: "local",
            skills: [], model: "", provider: "", profile: "research", toastNotifications: false
        )

        XCTAssertEqual(response.job?.name, "Digest")
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.url?.path, "/api/cron/jobs/d804e8d67342")
        XCTAssertEqual(request.url?.query, "profile=research")
        XCTAssertEqual(HermesCronFixture.body(request), .object(["updates": .object([
            "prompt": .string("Summarize"), "schedule": .string("every 30m"), "name": .string("Digest"),
            "deliver": .string("local"), "skills": .array([]), "model": .string(""), "provider": .string("")
        ])]))
    }

    func testPauseResumeAndDeleteNameTheJobsProfile() async throws {
        let client = HermesCronFixture.client { request in
            switch request.url?.path {
            case "/api/cron/jobs/a1/pause": return .json(200, HermesCronFixture.job("a1", profile: "research",
                                                                                   ["state": .string("paused")]))
            case "/api/cron/jobs/a1/resume": return .json(200, HermesCronFixture.job("a1", profile: "research"))
            case "/api/cron/jobs/a1": return .json(200, .object(["ok": .bool(true)]))
            default: return nil
            }
        }

        let paused = try await client.pauseCron(jobID: "a1", profile: "research", reason: "Manual")
        let resumed = try await client.resumeCron(jobID: "a1", profile: "research")
        let deleted = try await client.deleteCron(jobID: "a1", profile: "research")

        XCTAssertEqual([paused.job?.state, resumed.job?.state], ["paused", "scheduled"])
        XCTAssertEqual(deleted.ok, true)
        let sent = HermesHostFixture.requests.suffix(3)
        XCTAssertEqual(sent.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")?\($0.url?.query ?? "")" }, [
            "POST /api/cron/jobs/a1/pause?profile=research", "POST /api/cron/jobs/a1/resume?profile=research",
            "DELETE /api/cron/jobs/a1?profile=research"
        ])
        XCTAssertEqual(sent.map { HermesCronFixture.body($0) }, [.null, .null, .null], "Pause and resume send no body")
    }

    /// Run Now is the host's trigger, which answers the job once the run has finished (#1041).
    func testRunNowTriggersTheJobInItsProfile() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs/a1/trigger" ? .json(200, HermesCronFixture.job("a1", profile: "research", [
                "last_run_at": .string("2026-10-05T23:33:41.890071-04:00"), "last_status": .string("ok")
            ])) : nil
        }

        let response = try await client.runCron(jobID: "a1", profile: "research")

        XCTAssertEqual(response.job?.lastStatus, "ok")
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual("\(request.httpMethod ?? "") \(request.url?.path ?? "")?\(request.url?.query ?? "")",
                       "POST /api/cron/jobs/a1/trigger?profile=research")
        XCTAssertEqual(HermesCronFixture.body(request), .null, "The trigger sends no body")
    }

    /// A tunnel's 524 and a request that times out or drops reach the screens as the hop's
    /// failures, which Run Now follows the run through; a refusal carries the host's reason.
    func testATriggerAHopGaveUpOnFailsAsTheHop() async {
        let client = HermesCronFixture.client { request in
            switch request.url?.path {
            case "/api/cron/jobs/a1/trigger": return .json(524, .string(""))
            case "/api/cron/jobs/b2/trigger": return .fail(URLError(.timedOut))
            case "/api/cron/jobs/c3/trigger": return .fail(URLError(.networkConnectionLost))
            case "/api/cron/jobs/d4/trigger":
                return .json(409, .object(["detail": .string("Job is already running or was claimed by another scheduler")]))
            default: return nil
            }
        }

        var failures: [String] = []
        for id in ["a1", "b2", "c3", "d4"] {
            do {
                _ = try await client.runCron(jobID: id, profile: "research")
                XCTFail("\(id): expected a failure")
            } catch BotFailure.rejected(let status) {
                failures.append("rejected \(status)")
            } catch APIError.network(let underlying as URLError) {
                failures.append("network \(underlying.code.rawValue)")
            } catch let refusal as HermesCronRefusal {
                failures.append("refused: \(refusal.detail)")
            } catch {
                XCTFail("\(id): \(error)")
            }
        }

        XCTAssertEqual(failures, ["rejected 524", "network \(URLError.timedOut.rawValue)",
                                  "network \(URLError.networkConnectionLost.rawValue)",
                                  "refused: Job is already running or was claimed by another scheduler"])
    }

    /// The editor's delivery and skill lists are the Task's Profile's; a disabled skill
    /// is left out.
    func testTheEditorsDeliveryTargetsAndSkillsFollowTheProfile() async throws {
        let client = HermesCronFixture.client { request in
            switch request.url?.path {
            case "/api/cron/delivery-targets":
                return .json(200, .object(["targets": .array([
                    .object(["id": .string("local"), "name": .string("Local (save only)"), "home_target_set": .bool(true)]),
                    .object(["id": .string("telegram"), "name": .string("Telegram"), "home_target_set": .bool(false)])
                ])]))
            case "/api/skills":
                return .json(200, .array([
                    .object(["name": .string("arxiv"), "category": .string("research"), "enabled": .bool(true)]),
                    .object(["name": .string("retired"), "enabled": .bool(false)])
                ]))
            default: return nil
            }
        }
        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://hermes.example")!, client: client,
                                                      profile: "research")

        await loader.loadDeliveryOptions()
        await loader.loadSkills()

        XCTAssertEqual(loader.deliveryOptions, [CronDeliveryOption(value: "local", label: "Local (save only)"),
                                                CronDeliveryOption(value: "telegram", label: "Telegram")])
        XCTAssertEqual(loader.skills.compactMap(\.name), ["arxiv"])
        let reads = HermesHostFixture.requests.filter { $0.url?.path == "/api/cron/delivery-targets" || $0.url?.path == "/api/skills" }
        XCTAssertEqual(reads.map { $0.url?.query }, ["profile=research", "profile=research"])
    }

    /// Choices made for the old Profile that the newly picked one doesn't offer are dropped;
    /// choices made since the pick, such as a custom skill typed while its list loaded,
    /// stay, and a list that didn't load checks nothing.
    func testAPickedProfileKeepsOnlyTheChoicesItOffers() {
        let earlier = CronJobEditorDraft(deliver: "telegram,discord:123", skillsText: "arxiv, web-search")
        var draft = earlier
        draft.applySkillSelection(earlier.skills + ["my-custom"])

        draft.keepChoices(madeBefore: earlier, offeredTargets: ["local", "discord"], offeredSkills: ["web-search"])
        XCTAssertEqual(draft.deliver, "discord:123")
        XCTAssertEqual(draft.skills, ["web-search", "my-custom"])

        draft.keepChoices(madeBefore: draft, offeredTargets: ["local"], offeredSkills: nil)
        XCTAssertEqual(draft.deliver, "local", "With no target left, delivery falls back to local")
        XCTAssertEqual(draft.skills, ["web-search", "my-custom"], "A skill list that didn't load checks nothing")

        var retargeted = earlier
        retargeted.deliver = "telegram"
        retargeted.keepChoices(madeBefore: earlier, offeredTargets: ["local"], offeredSkills: nil)
        XCTAssertEqual(retargeted.deliver, "telegram", "A target chosen since the pick stays")
    }
}

// MARK: - The Tasks screens' view models on a Hermes host

extension CronManagementViewModelTests {
    @MainActor
    func testHermesListShowsEveryProfilesTasksWithTheirRunningAndRecentState() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs" ? .json(200, .array([
                HermesCronFixture.job("a1", profile: "default", ["fire_claim": .object(["at": .string("2026-10-05T09:00:00-04:00")])]),
                HermesCronFixture.job("b2", profile: "research", ["last_run_at": .string("2026-10-05T08:00:00-04:00"),
                                                                  "last_status": .string("ok")])
            ])) : nil
        }
        let viewModel = TasksViewModel(server: URL(string: "https://hermes.example")!, client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.jobs.map(\.profileLabel), ["Default", "research"])
        XCTAssertEqual(viewModel.runningJobIDs, ["a1"])
        XCTAssertEqual(viewModel.recentRuns.map(\.jobId), ["b2"])
        XCTAssertNil(viewModel.deliveryOptions, "The editor reads targets for the Task's own Profile")
        XCTAssertNil(viewModel.recentRunsTask, "The host has no recent-runs feed")
        XCTAssertEqual(HermesHostFixture.requests.compactMap(\.url?.path).filter { $0.hasPrefix("/api/cron") }, ["/api/cron/jobs"])
    }

    /// Three missed 60 s ticks: past 180 s, and only for a Task that would fire.
    @MainActor
    func testHermesSchedulerNoticeStartsPastThreeMissedTicks() async throws {
        let rows: [(BotJSON, enabled: Bool, expected: Double?)] = [
            (.number(180), true, nil), (.number(181), true, 181), (.null, true, nil), (.number(900), false, nil)
        ]
        for row in rows {
            HermesHostFixture.reset()
            let client = HermesCronFixture.client { request in
                request.url?.path == "/api/cron/jobs" ? .json(200, .array([
                    HermesCronFixture.job("a1", profile: "default", ["scheduler_heartbeat_age_s": row.0,
                                                                     "enabled": .bool(row.enabled)])
                ])) : nil
            }
            let viewModel = TasksViewModel(server: URL(string: "https://hermes.example")!, client: client)

            await viewModel.load()

            XCTAssertEqual(viewModel.schedulerStallAge, row.expected, "\(row.0), enabled \(row.enabled)")
        }
    }

    /// A 424 saved the Task without returning it: the list reads it back and keeps the
    /// host's warning for the user.
    @MainActor
    func testHermesCreateTheSchedulerCouldNotRegisterIsSavedWithItsWarning() async throws {
        let client = HermesCronFixture.client { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST"?, "/api/cron/jobs"?):
                return .json(424, .object(["detail": .object(["error": .string("Saved, not registered.")])]))
            case ("GET"?, "/api/cron/jobs"?):
                return .json(200, .array([HermesCronFixture.job("new1", profile: "research")]))
            default: return nil
            }
        }
        let viewModel = TasksViewModel(server: URL(string: "https://hermes.example")!, client: client)

        let didCreate = await viewModel.create(from: CronJobEditorDraft(prompt: "p", schedule: "0 9 * * *", profile: "research"))

        XCTAssertTrue(didCreate)
        XCTAssertEqual(viewModel.saveWarning, "Saved, not registered.")
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["new1"])
    }

    /// The editor's Profile can't move a Task: the update routes by the job's own.
    @MainActor
    func testHermesEditKeepsTheTasksProfile() async throws {
        let client = HermesCronFixture.client { request in
            request.httpMethod == "PUT" ? .json(200, HermesCronFixture.job("a1", profile: "research")) : nil
        }
        let job = try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research")]).first)
        let viewModel = TaskDetailViewModel(job: job, runningElapsed: nil, server: URL(string: "https://hermes.example")!,
                                            client: client)
        var draft = CronJobEditorDraft(job: job)
        draft.applyProfileSelection("default")

        let didUpdate = await viewModel.update(from: draft)

        XCTAssertTrue(didUpdate)
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.url?.query, "profile=research")
        XCTAssertEqual(HermesCronFixture.body(request)["updates"].fields.map { Set($0.keys) },
                       ["prompt", "schedule", "name", "deliver", "skills", "model", "provider"])
    }

    @MainActor
    func testHermesPauseResumeAndDeleteUpdateTheListAndAFailureLeavesTheRow() async throws {
        let client = HermesCronFixture.client { request in
            switch request.url?.path {
            case "/api/cron/jobs":
                return .json(200, .array([HermesCronFixture.job("a1", profile: "research"),
                                          HermesCronFixture.job("b2", profile: "default")]))
            case "/api/cron/jobs/a1/pause":
                return .json(200, HermesCronFixture.job("a1", profile: "research", ["enabled": .bool(false), "state": .string("paused")]))
            case "/api/cron/jobs/a1/resume": return .json(200, HermesCronFixture.job("a1", profile: "research"))
            case "/api/cron/jobs/b2/resume": return .json(500, .string("Internal Server Error"))
            case "/api/cron/jobs/b2": return .json(200, .object(["ok": .bool(true)]))
            default: return nil
            }
        }
        let viewModel = TasksViewModel(server: URL(string: "https://hermes.example")!, client: client)
        await viewModel.load()

        await viewModel.pause(viewModel.jobs[0])
        XCTAssertEqual(viewModel.jobs.map(\.state), ["paused", "scheduled"])
        await viewModel.resume(viewModel.jobs[0])
        XCTAssertEqual(viewModel.jobs.map(\.state), ["scheduled", "scheduled"])

        await viewModel.resume(viewModel.jobs[1])
        XCTAssertEqual(viewModel.jobs.map(\.state), ["scheduled", "scheduled"], "A failure leaves the row as it was")
        XCTAssertEqual(viewModel.actionErrorMessage, "The Hermes server hit an internal error. Check the server logs, then try again.")

        await viewModel.delete(viewModel.jobs[1])
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["a1"])
        XCTAssertEqual(HermesHostFixture.requests.last?.url?.query, "profile=default")
    }

    /// The detail's Refresh reads the job from the list, which carries its running state,
    /// beside its runs (#1042).
    @MainActor
    func testHermesTaskDetailReadsTheJobFromTheList() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs" ? .json(200, .array([
                HermesCronFixture.job("a1", profile: "research", ["latest_execution": .object(["status": .string("running")])])
            ])) : nil
        }
        let job = try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research")]).first)
        let viewModel = TaskDetailViewModel(job: job, runningElapsed: nil, server: URL(string: "https://hermes.example")!,
                                            client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.runningElapsed, 0)
        XCTAssertEqual(HermesHostFixture.count("/api/cron/jobs"), 1)
        guard case .upsert(let forwarded)? = viewModel.lastMutation else {
            return XCTFail("The list gets the job the detail re-read")
        }
        XCTAssertEqual(forwarded.latestExecutionStatus, "running")
    }

    /// The opening list read was sent before a Pause that finished while it was out, so its
    /// answer is older than the Pause's and must not put the running Task back.
    @MainActor
    func testHermesTaskDetailKeepsAPauseThatFinishedDuringItsListRead() async throws {
        let client = HermesCronFixture.client { request in
            switch request.url?.path {
            case "/api/cron/jobs": return .park
            case "/api/cron/jobs/a1/pause":
                return .json(200, HermesCronFixture.job("a1", profile: "research", ["enabled": .bool(false), "state": .string("paused")]))
            default: return nil
            }
        }
        let job = try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research")]).first)
        let viewModel = TaskDetailViewModel(job: job, runningElapsed: nil, server: URL(string: "https://hermes.example")!,
                                            client: client)
        let listRead = expectation(description: "the list read is out")
        HermesHostFixture.onPark = { listRead.fulfill() }

        let load = Task { await viewModel.load() }
        await fulfillment(of: [listRead], timeout: 5)
        let didPause = await viewModel.pause()
        HermesHostFixture.releaseParked(.json(200, .array([
            HermesCronFixture.job("a1", profile: "research", ["latest_execution": .object(["status": .string("running")])])
        ])))
        await load.value

        XCTAssertTrue(didPause)
        XCTAssertEqual(viewModel.job.state, "paused")
        XCTAssertNil(viewModel.runningElapsed)
    }
}

/// Run Now on a Hermes host (#1041): the trigger runs the Task before it replies, so the
/// screens follow the run on the list, read on a scripted clock, until the host's outcome.
@MainActor final class HermesRunNowTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let clock = RunNowClock()

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    /// The host ran the Task before replying: the reply is the outcome, and nothing is read.
    func testATriggerReplyIsTheOutcome() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs/a1/trigger" ? .json(200, HermesCronFixture.job("a1", profile: "research", [
                "last_run_at": .string("2026-10-05T23:33:41.890071-04:00"), "last_status": .string("ok")
            ])) : nil
        }
        let viewModel = TaskDetailViewModel(job: try Self.job(), runningElapsed: nil, server: server, client: client,
                                            sleep: clock.sleep)

        let didRun = await viewModel.runNow()

        XCTAssertTrue(didRun)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(viewModel.job.lastStatus, "ok")
        XCTAssertNil(viewModel.runningElapsed, "The run is over")
        XCTAssertEqual(viewModel.runNowState, .idle)
        XCTAssertEqual(viewModel.lastMutation, .upsert(viewModel.job))
        let sent = HermesHostFixture.requests.filter { $0.url?.path.hasPrefix("/api/cron") == true }
        XCTAssertEqual(sent.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")?\($0.url?.query ?? "")" },
                       ["POST /api/cron/jobs/a1/trigger?profile=research"], "One trigger, in the Task's Profile")
    }

    /// A 524, a timeout or a dropped connection is a hop giving up on the request while the
    /// host goes on: no error, "Running" once the list shows the claim, and the list's outcome.
    func testARunTheTunnelGaveUpOnEndsInTheHostsOutcome() async throws {
        let failures: [(String, Error)] = [
            ("524", BotFailure.rejected(524)),
            ("timeout", APIError.network(underlying: URLError(.timedOut))),
            ("dropped", APIError.network(underlying: URLError(.networkConnectionLost)))
        ]
        for (label, failure) in failures {
            let clock = RunNowClock()
            let host = RunNowHost(lists: [[Self.running], [Self.finished]])
            let viewModel = TaskDetailViewModel(job: try Self.job(), runningElapsed: nil, server: server, client: host,
                                                sleep: clock.sleep)

            let run = Task { await viewModel.runNow() }
            await clock.waitUntilSleeping(1)
            XCTAssertEqual(viewModel.runNowState, .requested, "\(label): not running until the host says so")
            host.answerTrigger(0, .failure(failure))

            clock.advance()
            await clock.waitUntilSleeping(2)
            XCTAssertEqual(viewModel.runNowState, .running, label)
            XCTAssertNil(viewModel.actionErrorMessage, label)

            clock.advance()
            let didRun = await run.value

            XCTAssertTrue(didRun, label)
            XCTAssertEqual(viewModel.runNowState, .idle, label)
            XCTAssertEqual(viewModel.job.lastStatus, "error", "\(label): the host's outcome")
            XCTAssertNil(viewModel.actionErrorMessage, label)
            XCTAssertNil(viewModel.lastError, label)
            XCTAssertEqual(host.triggers, ["a1?profile=research"], label)
            XCTAssertEqual(host.listReads, 2, label)
        }
    }

    /// A 409 "already running" is read at once: the list shows the claim, so the Task is
    /// running and no error shows.
    func testAlreadyRunningShowsTheTaskRunning() async throws {
        let host = RunNowHost(lists: [[Self.running], [Self.finished]])
        let viewModel = TaskDetailViewModel(job: try Self.job(), runningElapsed: nil, server: server, client: host,
                                            sleep: clock.sleep)

        let run = Task { await viewModel.runNow() }
        await clock.waitUntilSleeping(1)
        host.answerTrigger(0, .failure(HermesCronRefusal(detail: "Job is already running or was claimed by another scheduler")))
        await clock.waitUntilSleeping(2)

        XCTAssertEqual(viewModel.runNowState, .running)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(host.listReads, 1, "Read as soon as the host refused")

        clock.advance()
        let didRun = await run.value
        XCTAssertTrue(didRun)
        XCTAssertEqual(viewModel.job.lastStatus, "error")
    }

    /// A refusal the list doesn't explain, such as a paused Task its provider can't force,
    /// shows the host's reason and ends Run Now.
    func testARefusalTheListDoesNotExplainShowsTheHostsReason() async throws {
        let host = RunNowHost(lists: [[HermesCronFixture.job("a1", profile: "research")]])
        let viewModel = TaskDetailViewModel(job: try Self.job(), runningElapsed: nil, server: server, client: host,
                                            sleep: clock.sleep)

        let run = Task { await viewModel.runNow() }
        await clock.waitUntilSleeping(1)
        host.answerTrigger(0, .failure(HermesCronRefusal(detail: "Cron provider 'chronos' does not support atomic forced firing of paused jobs")))
        let didRun = await run.value

        XCTAssertFalse(didRun)
        XCTAssertEqual(viewModel.runNowState, .idle)
        XCTAssertEqual(viewModel.actionErrorMessage,
                       "The server rejected the request: Cron provider 'chronos' does not support atomic forced firing of paused jobs")
        XCTAssertEqual(host.listReads, 1)
    }

    /// Run Now asks first only where it also resumes the Task, and is hidden where the host
    /// refuses it. Confirming runs the paused Task, which the host leaves resumed.
    func testAPausedTaskAsksFirstAndEndsResumed() async throws {
        let paused = try Self.job(["enabled": .bool(false), "state": .string("paused")])
        let completed = try Self.job(["enabled": .bool(false), "state": .string("completed")])
        XCTAssertEqual([CronFeatures.hermes.runNowResumes(paused), CronFeatures.hermes.runNowResumes(try Self.job()),
                        CronFeatures.webui.runNowResumes(paused)], [true, false, false])
        XCTAssertEqual([CronFeatures.hermes.offersRunNow(for: completed), CronFeatures.hermes.offersRunNow(for: paused),
                        CronFeatures.webui.offersRunNow(for: completed)], [false, true, true])

        let host = RunNowHost(lists: [])
        let viewModel = TaskDetailViewModel(job: paused, runningElapsed: nil, server: server, client: host, sleep: clock.sleep)
        let run = Task { await viewModel.runNow() }
        await clock.waitUntilSleeping(1)
        host.answerTrigger(0, .success(CronMutationResponse(ok: true, job: try Self.job(Self.finishedFields), error: nil)))
        let didRun = await run.value

        XCTAssertTrue(didRun)
        XCTAssertEqual(viewModel.job.enabled, true)
        XCTAssertEqual(viewModel.job.status, .error, "Resumed, with the run's own outcome")
        XCTAssertEqual(host.listReads, 0)
    }

    /// Leaving the screen ends the reads, sends nothing more, and shows no error.
    func testLeavingTheScreenStopsTheReadsAndNeverResendsTheTrigger() async throws {
        let host = RunNowHost(lists: [[Self.running]])
        let viewModel = TaskDetailViewModel(job: try Self.job(), runningElapsed: nil, server: server, client: host,
                                            sleep: clock.sleep)

        let run = Task { await viewModel.runNow() }
        await clock.waitUntilSleeping(1)
        clock.advance()
        await clock.waitUntilSleeping(2)
        run.cancel()
        let didRun = await run.value
        clock.advance()

        XCTAssertFalse(didRun)
        XCTAssertEqual(viewModel.runNowState, .idle)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(host.listReads, 1)
        XCTAssertEqual(host.triggers, ["a1?profile=research"])
        host.answerTrigger(0, .failure(BotFailure.rejected(524)))
    }

    /// The reply to a run the screen stopped following arrives during a later run, and only
    /// the later run's reply is its outcome.
    func testAStaleReplyNeverStandsInForALaterRun() async throws {
        let host = RunNowHost(lists: [])
        let viewModel = TaskDetailViewModel(job: try Self.job(), runningElapsed: nil, server: server, client: host,
                                            sleep: clock.sleep)
        let first = Task { await viewModel.runNow() }
        await clock.waitUntilSleeping(1)
        first.cancel()
        _ = await first.value

        let second = Task { await viewModel.runNow() }
        await clock.waitUntilSleeping(2)
        host.answerTrigger(0, .success(CronMutationResponse(ok: true, job: try Self.job([
            "last_run_at": .string("2026-10-05T09:00:00-04:00"), "last_status": .string("ok")
        ]), error: nil)))
        host.answerTrigger(1, .success(CronMutationResponse(ok: true, job: try Self.job(Self.finishedFields), error: nil)))
        let didRun = await second.value

        XCTAssertTrue(didRun)
        XCTAssertEqual(viewModel.job.lastStatus, "error", "The later run's outcome")
        XCTAssertEqual(viewModel.lastMutation, .upsert(viewModel.job))
        XCTAssertEqual(host.triggers.count, 2)
    }

    /// A row's Run Now goes through the same machine: the row moves to "Now" once the host
    /// shows the run, and out with the host's outcome.
    func testARowsRunNowShowsTheRunOnTheList() async throws {
        let host = RunNowHost(lists: [[HermesCronFixture.job("a1", profile: "research")], [Self.running], [Self.finished]])
        let viewModel = TasksViewModel(server: server, client: host, sleep: clock.sleep)
        await viewModel.load()
        let job = try XCTUnwrap(viewModel.jobs.first)

        let run = Task { await viewModel.runNow(job) }
        await clock.waitUntilSleeping(1)
        XCTAssertTrue(viewModel.isPendingAction(job))
        XCTAssertEqual(viewModel.runningJobIDs, [])

        clock.advance()
        await clock.waitUntilSleeping(2)
        XCTAssertEqual(viewModel.runningJobIDs, ["a1"])

        clock.advance()
        await run.value
        XCTAssertEqual(viewModel.runningJobIDs, [])
        XCTAssertEqual(viewModel.jobs.map(\.lastStatus), ["error"])
        XCTAssertFalse(viewModel.isPendingAction(job))
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(host.triggers, ["a1?profile=research"])
        host.answerTrigger(0, .failure(BotFailure.rejected(524)))
    }

    /// Leaving the Tasks screen stops a row's Run Now without an error alert on return.
    func testLeavingTheTasksScreenEndsARowsRunNowWithoutAnError() async throws {
        let host = RunNowHost(lists: [[HermesCronFixture.job("a1", profile: "research")]])
        let viewModel = TasksViewModel(server: server, client: host, sleep: clock.sleep)
        await viewModel.load()
        let job = try XCTUnwrap(viewModel.jobs.first)

        let run = Task { await viewModel.runNow(job) }
        await clock.waitUntilSleeping(1)
        run.cancel()
        await run.value

        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertFalse(viewModel.isPendingAction(job))
        host.answerTrigger(0, .failure(BotFailure.rejected(524)))
    }

    /// A row's Run Now read that was out while the list changed, by another row's Delete or
    /// by a refresh, can't put back what it replaced; the next read shows the list again.
    func testARowsRunNowReadNeverUndoesAChangeMadeWhileItWasOut() async throws {
        let idle = HermesCronFixture.job("a1", profile: "research")
        let active = HermesCronFixture.job("b2", profile: "research")
        let paused = HermesCronFixture.job("b2", profile: "research", ["enabled": .bool(false)])
        let cases: [(String, [[BotJSON]], @MainActor (TasksViewModel, CronJob) async -> Void, [String])] = [
            ("delete", [[idle, active], [Self.running, active], [Self.finished]],
             { await $0.delete($1) }, ["a1 active"]),
            ("refresh", [[idle, active], [Self.running, active], [Self.running, paused], [Self.finished, paused]],
             { viewModel, _ in await viewModel.load() }, ["a1 active", "b2 paused"])
        ]
        for (label, lists, change, expected) in cases {
            let clock = RunNowClock()
            let host = RunNowHost(lists: lists)
            let viewModel = TasksViewModel(server: server, client: host, sleep: clock.sleep)
            await viewModel.load()
            let jobs = viewModel.jobs

            let run = Task { await viewModel.runNow(jobs[0]) }
            await clock.waitUntilSleeping(1)
            host.duringListRead = { await change(viewModel, jobs[1]) }
            clock.advance()
            await clock.waitUntilSleeping(2)
            XCTAssertEqual(viewModel.jobs.map { "\($0.jobId ?? "") \($0.enabled == false ? "paused" : "active")" },
                           expected, "\(label): the change stays")

            clock.advance()
            await run.value
            XCTAssertEqual(viewModel.jobs.first?.lastStatus, "error", label)
            host.answerTrigger(0, .failure(BotFailure.rejected(524)))
        }
    }

    /// A host the phone can no longer reach after the tunnel gave up on the trigger ends Run
    /// Now on the third failed read, with why, rather than waiting on with nothing to show.
    func testReadsThatKeepFailingEndRunNowWithWhy() async throws {
        let host = RunNowHost(lists: [])
        let viewModel = TaskDetailViewModel(job: try Self.job(), runningElapsed: nil, server: server, client: host,
                                            sleep: clock.sleep)

        let run = Task { await viewModel.runNow() }
        await clock.waitUntilSleeping(1)
        host.answerTrigger(0, .failure(BotFailure.rejected(524)))
        clock.advance()
        await clock.waitUntilSleeping(2)
        clock.advance()
        await clock.waitUntilSleeping(3)
        XCTAssertEqual(viewModel.runNowState, .requested, "Two failed reads still wait")
        XCTAssertNil(viewModel.actionErrorMessage)

        clock.advance()
        let didRun = await run.value

        XCTAssertFalse(didRun)
        XCTAssertEqual(viewModel.runNowState, .idle)
        XCTAssertEqual(viewModel.actionErrorMessage,
                       "Could not connect to the server. Check that hermes-webui is running and the tunnel is connected.")
        XCTAssertEqual(host.listReads, 3)
        XCTAssertEqual(host.triggers, ["a1?profile=research"])
    }

    // MARK: - Fixtures

    /// The job claimed by a run in progress.
    private static let running = HermesCronFixture.job("a1", profile: "research", [
        "fire_claim": .object(["by": .string("host:1")]), "latest_execution": .object(["status": .string("running")])
    ])
    /// The job once its run has finished, with an outcome only the host knows.
    private static let finishedFields: [String: BotJSON] = [
        "last_run_at": .string("2026-10-05T23:34:44.738586-04:00"), "last_status": .string("error"),
        "last_error": .string("boom")
    ]
    private static let finished = HermesCronFixture.job("a1", profile: "research", finishedFields.merging([
        "latest_execution": .object(["status": .string("failed")])
    ]) { $1 })

    private static func job(_ overrides: [String: BotJSON] = [:]) throws -> CronJob {
        try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research", overrides)]).first)
    }
}

/// The Run Now machine's clock: each wait holds until `advance()`, and
/// `waitUntilSleeping(_:)` returns once that many waits have begun, so a test steps the
/// list reads one at a time without a timer.
@MainActor final class RunNowClock {
    private(set) var begun = 0
    private var sleepers: [Int: CheckedContinuation<Void, Error>] = [:]
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// What the view models wait on.
    var sleep: @MainActor @Sendable (Duration) async throws -> Void { { try await self.hold($0) } }

    private func hold(_ duration: Duration) async throws {
        XCTAssertEqual(duration, TaskDetailViewModel.runNowReadInterval)
        begun += 1
        let id = begun
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = continuation
                let met = watchers.filter { $0.count <= id }
                watchers.removeAll { $0.count <= id }
                met.forEach { $0.continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    func waitUntilSleeping(_ count: Int) async {
        guard begun < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    func advance() {
        let waiting = sleepers.values
        sleepers = [:]
        waiting.forEach { $0.resume() }
    }
}

/// A Hermes host for the Run Now machine: each trigger waits for the test's answer, and each
/// list read returns the next of `lists`, the last one again once they run out, or fails to
/// connect when there are none. A delete succeeds.
@MainActor final class RunNowHost: CronDataClient {
    nonisolated var cronFeatures: CronFeatures { .hermes }
    private(set) var triggers: [String] = []
    private(set) var listReads = 0
    /// Runs once, inside the next list read, before it answers.
    var duringListRead: (@MainActor () async -> Void)?
    private let lists: [[BotJSON]]
    private var answers: [Int: CheckedContinuation<CronMutationResponse, Error>] = [:]

    init(lists: [[BotJSON]]) { self.lists = lists }

    func answerTrigger(_ index: Int, _ result: Result<CronMutationResponse, Error>) {
        answers.removeValue(forKey: index)?.resume(with: result)
    }

    func runCron(jobID: String, profile: String?) async throws -> CronMutationResponse {
        triggers.append("\(jobID)?profile=\(profile ?? "")")
        let index = triggers.count - 1
        return try await withCheckedThrowingContinuation { answers[index] = $0 }
    }

    func cronJobs() async throws -> CronJobList {
        listReads += 1
        let read = listReads
        if let during = duringListRead {
            duringListRead = nil
            await during()
        }
        guard !lists.isEmpty else { throw APIError.network(underlying: URLError(.cannotConnectToHost)) }
        return CronJobList(hermesJobs: try HermesCronFixture.decode(lists[min(read, lists.count) - 1]))
    }

    func cronRecent() async throws -> CronRecentCompletionsResponse { throw BotFailure.unsupported }
    func cronDeliveryOptions(profile _: String?) async throws -> CronDeliveryOptionsResponse { throw BotFailure.unsupported }
    func createCron(prompt _: String, schedule _: String, name _: String?, deliver _: String?, skills _: [String],
                    model _: String?, provider _: String?, profile _: String?,
                    toastNotifications _: Bool) async throws -> CronMutationResponse { throw BotFailure.unsupported }
    func updateCron(jobID _: String, prompt _: String?, schedule _: String?, name _: String?, deliver _: String?,
                    skills _: [String]?, model _: String?, provider _: String?, profile _: String?,
                    toastNotifications _: Bool?) async throws -> CronMutationResponse { throw BotFailure.unsupported }
    func pauseCron(jobID _: String, profile _: String?, reason _: String?) async throws -> CronMutationResponse {
        throw BotFailure.unsupported
    }
    func resumeCron(jobID _: String, profile _: String?) async throws -> CronMutationResponse { throw BotFailure.unsupported }
    func deleteCron(jobID _: String, profile _: String?) async throws -> CronMutationResponse {
        CronMutationResponse(ok: true, job: nil, error: nil)
    }
    func cronOutput(jobID _: String, limit _: Int?) async throws -> CronOutputResponse { throw BotFailure.unsupported }
    func cronHistory(jobID _: String, profile _: String?, offset _: Int, limit _: Int) async throws -> CronRunHistoryResponse {
        throw BotFailure.unsupported
    }
    func cronRunDetail(jobID _: String, profile _: String?, filename _: String) async throws -> CronRunDetailResponse {
        throw BotFailure.unsupported
    }
    func cronModelGroups(profile _: String?) async throws -> [ModelCatalogGroup] { throw BotFailure.unsupported }
    func cronProfiles() async throws -> [ProfileSummary] { throw BotFailure.unsupported }
    func cronSkills(profile _: String?) async throws -> [SkillSummary] { throw BotFailure.unsupported }
}

/// A scripted Hermes host's cron replies, built from the pinned shapes.
@MainActor enum HermesCronFixture {
    static func client(_ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> HermesCronClient {
        let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        return HermesCronClient(http: HermesConnection(connection: record, configuration: HermesHostFixture.configuration(script)))
    }

    /// One job as `GET /api/cron/jobs` lists it at the pin, with `overrides` on top.
    static func job(_ id: String, profile: String, _ overrides: [String: BotJSON] = [:]) -> BotJSON {
        var fields = (try? JSONDecoder().decode(BotJSON.self, from: Data(#"""
        {"name": "Morning digest", "prompt": "Summarize the news", "skills": [], "skill": null, "model": null,
         "provider": null, "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"},
         "schedule_display": "0 9 * * *", "repeat": {"times": null, "completed": 0}, "enabled": true,
         "state": "scheduled", "paused_at": null, "next_run_at": "2026-10-06T09:00:00-04:00", "last_run_at": null,
         "last_status": null, "last_error": null, "last_delivery_error": null, "deliver": "local",
         "hermes_home": "/Users/someone/.hermes/profiles/x", "is_default_profile": false,
         "scheduler_heartbeat_age_s": null, "latest_execution": null}
        """#.utf8)))?.fields ?? [:]
        fields["id"] = .string(id)
        fields["profile"] = .string(profile)
        fields["profile_name"] = .string(profile)
        fields.merge(overrides) { $1 }
        return .object(fields)
    }

    static func decode(_ jobs: [BotJSON]) throws -> [CronJob] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([CronJob].self, from: JSONEncoder().encode(jobs))
    }

    /// A sent request's JSON body, or `.null` when it has none.
    static func body(_ request: URLRequest) -> BotJSON {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}
