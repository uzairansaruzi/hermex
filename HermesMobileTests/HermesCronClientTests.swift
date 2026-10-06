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

    /// Run history waits for #1042, so Refresh reads the job from the list instead.
    @MainActor
    func testHermesTaskDetailReadsTheJobFromTheListWithoutRunHistory() async throws {
        let client = HermesCronFixture.client { request in
            request.url?.path == "/api/cron/jobs" ? .json(200, .array([
                HermesCronFixture.job("a1", profile: "research", ["latest_execution": .object(["status": .string("running")])])
            ])) : nil
        }
        let job = try XCTUnwrap(HermesCronFixture.decode([HermesCronFixture.job("a1", profile: "research")]).first)
        let viewModel = TaskDetailViewModel(job: job, runningElapsed: nil, server: URL(string: "https://hermes.example")!,
                                            client: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.isHistoryUnavailable)
        XCTAssertEqual(viewModel.runningElapsed, 0)
        XCTAssertEqual(HermesHostFixture.requests.compactMap(\.url?.path).filter { $0.hasPrefix("/api/cron") }, ["/api/cron/jobs"])
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
