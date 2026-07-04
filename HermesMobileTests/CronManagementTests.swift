import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class CronManagementModelTests: XCTestCase {
    func testCronMutationResponseDecodesAliasesAndStringSchedule() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            CronMutationResponse.self,
            from: Data("""
            {
              "ok": true,
              "job": {
                "job_id": "job-aliased",
                "name": "Aliased task",
                "prompt": 42,
                "schedule": "0 9 * * *",
                "enabled": "true",
                "state": "scheduled",
                "model": "@openai:gpt-5.5",
                "profile": "work",
                "toast_notifications": "yes"
              }
            }
            """.utf8)
        )

        let job = try XCTUnwrap(response.job)
        XCTAssertEqual(job.jobId, "job-aliased")
        XCTAssertEqual(job.prompt, "42")
        XCTAssertEqual(job.scheduleText, "0 9 * * *")
        XCTAssertEqual(job.status, .active)
        XCTAssertEqual(job.model, "@openai:gpt-5.5")
        XCTAssertEqual(job.profile, "work")
        XCTAssertEqual(job.toastNotifications, true)
    }

    func testCronJobEditorDraftNormalizesFieldsAndSkills() {
        let draft = CronJobEditorDraft(
            name: "  Morning digest  ",
            prompt: "  Summarize updates  ",
            schedule: "  0 7 * * *  ",
            deliver: "  local  ",
            skillsText: "summarize, notify\nswift",
            model: "  @openai:gpt-5.5  ",
            profile: "  work  ",
            toastNotifications: true
        )

        XCTAssertEqual(draft.trimmedName, "Morning digest")
        XCTAssertEqual(draft.trimmedPrompt, "Summarize updates")
        XCTAssertEqual(draft.trimmedSchedule, "0 7 * * *")
        XCTAssertEqual(draft.trimmedDeliver, "local")
        XCTAssertEqual(draft.skills, ["summarize", "notify", "swift"])
        XCTAssertEqual(draft.trimmedModel, "@openai:gpt-5.5")
        XCTAssertEqual(draft.trimmedProfile, "work")
        XCTAssertNil(draft.validationMessage)
    }

    func testCronJobEditorDraftRequiresPromptAndSchedule() {
        XCTAssertEqual(
            CronJobEditorDraft(prompt: "", schedule: "0 7 * * *").validationMessage,
            "Prompt is required."
        )
        XCTAssertEqual(
            CronJobEditorDraft(prompt: "Run it", schedule: "   ").validationMessage,
            "Schedule is required."
        )
    }

    func testCronJobDecodesRelatedSessionFieldsForChatLinks() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let job = try decoder.decode(
            CronJob.self,
            from: Data("""
            {
              "id": "job123",
              "name": "Morning digest",
              "session_id": "cron_job123_20260702_120000",
              "message_count": "6",
              "session_title": "Morning digest run",
              "owner_profile": "default",
              "read_only": "false"
            }
            """.utf8)
        )

        XCTAssertEqual(job.relatedSession?.sessionId, "cron_job123_20260702_120000")
        XCTAssertEqual(job.relatedSession?.title, "Morning digest run")
        XCTAssertEqual(job.relatedSession?.messageCount, 6)
        XCTAssertEqual(job.ownerProfile, "default")
        XCTAssertEqual(job.readOnly, false)
    }

    func testCronRelatedSessionTrimsIDsAndBuildsCronSessionSummary() throws {
        let relatedSession = CronRelatedSession(
            sessionId: "  cron_job123_20260702_120000  ",
            title: "  ",
            messageCount: 6
        )

        let session = try XCTUnwrap(relatedSession)
        let summary = session.sessionSummary(profile: "default")

        XCTAssertEqual(session.sessionId, "cron_job123_20260702_120000")
        XCTAssertEqual(session.displayTitle, "Related Chat")
        XCTAssertEqual(summary.sessionId, "cron_job123_20260702_120000")
        XCTAssertEqual(summary.title, "Related Chat")
        XCTAssertEqual(summary.messageCount, 6)
        XCTAssertEqual(summary.profile, "default")
        XCTAssertEqual(summary.sourceTag, "cron")
        XCTAssertEqual(summary.sessionSource, "cron")
        XCTAssertEqual(summary.sourceLabel, "cron")
    }

    func testCronRunHistoryItemUsesStableFallbackIDWhenFilenameIsMissing() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            CronRunHistoryResponse.self,
            from: Data("""
            {
              "runs": [
                {"size": "42", "modified": 1777892400}
              ]
            }
            """.utf8)
        )
        let run = try XCTUnwrap(response.runs?.first)
        XCTAssertEqual(run.id, "run-1777892400.0-42")
        XCTAssertEqual(run.id, run.id)
    }

    func testCronRunHistoryItemDisplayTitleUsesFilenameOrFallback() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            CronRunHistoryResponse.self,
            from: Data("""
            {
              "runs": [
                {"filename": " latest.md ", "modified": 1777892400},
                {"filename": "   ", "modified": 1777892500}
              ]
            }
            """.utf8)
        )

        let runs = try XCTUnwrap(response.runs)
        XCTAssertEqual(runs[0].displayTitle, "latest.md")
        XCTAssertEqual(runs[1].displayTitle, "Untitled run")
    }

    func testCronOutputItemsMatchRunHistoryByTrimmedFilename() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let history = try decoder.decode(
            CronRunHistoryResponse.self,
            from: Data("""
            {
              "runs": [
                {"filename": " latest.md ", "size": 42, "modified": 1777892400},
                {"filename": "other.md", "size": 12, "modified": 1777892300}
              ]
            }
            """.utf8)
        )
        let output = try decoder.decode(
            CronOutputResponse.self,
            from: Data("""
            {
              "outputs": [
                {"filename": "latest.md", "content": "## Response\\n\\nDone"}
              ]
            }
            """.utf8)
        )

        let runs = try XCTUnwrap(history.runs)
        let outputs = try XCTUnwrap(output.outputs)
        XCTAssertEqual(outputs.output(matching: runs[0])?.content, "## Response\n\nDone")
        XCTAssertNil(outputs.output(matching: runs[1]))
    }

    func testCronJobDraftSuggesterBuildsWeekdayMorningDraftFromDescriptor() {

        let suggestion = CronJobDraftSuggester.suggest(
            from: "Summarize overnight workspace activity every weekday at 7:30am"
        )

        XCTAssertEqual(suggestion.draft.name, "Summarize overnight workspace activity")
        XCTAssertEqual(suggestion.draft.prompt, "Summarize overnight workspace activity every weekday at 7:30am")
        XCTAssertEqual(suggestion.draft.schedule, "30 7 * * 1-5")
        XCTAssertEqual(suggestion.draft.deliver, "local")
        XCTAssertTrue(suggestion.draft.toastNotifications)
        XCTAssertNil(suggestion.draft.validationMessage)
    }

    func testCronJobDraftSuggesterBuildsIntervalDraftFromDescriptor() {
        let suggestion = CronJobDraftSuggester.suggest(
            from: "Check deployment health every 45 minutes"
        )

        XCTAssertEqual(suggestion.draft.name, "Check deployment health")
        XCTAssertEqual(suggestion.draft.prompt, "Check deployment health every 45 minutes")
        XCTAssertEqual(suggestion.draft.schedule, "every 45m")
        XCTAssertNil(suggestion.draft.validationMessage)
    }

    func testCronJobDraftSuggesterBuildsSingleWeekdayEveningDraftFromDescriptor() {
        let suggestion = CronJobDraftSuggester.suggest(
            from: "Send app portfolio revenue report on Monday at 6:15pm"
        )

        XCTAssertEqual(suggestion.draft.name, "Send app portfolio revenue report")
        XCTAssertEqual(suggestion.draft.schedule, "15 18 * * 1")
        XCTAssertNil(suggestion.draft.validationMessage)
    }

    func testCronJobDraftSuggesterNormalizesWhitespaceAndLeavesEmptyDescriptorInvalid() {
        let suggestion = CronJobDraftSuggester.suggest(from: "  \n  ")

        XCTAssertEqual(suggestion.descriptor, "")
        XCTAssertEqual(suggestion.draft.name, "")
        XCTAssertEqual(suggestion.draft.prompt, "")
        XCTAssertEqual(suggestion.draft.schedule, "")
        XCTAssertEqual(suggestion.draft.validationMessage, "Prompt is required.")
    }
}

final class CronManagementViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testTasksViewModelCreateInsertsReturnedJob() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/create")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job-created",
                "name": "Created",
                "prompt": "Run it",
                "schedule": {"kind": "cron", "expr": "0 7 * * *"},
                "enabled": true,
                "state": "scheduled"
              }
            }
            """, for: request)
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        let didCreate = await viewModel.create(
            from: CronJobEditorDraft(
                name: "Created",
                prompt: "Run it",
                schedule: "0 7 * * *"
            )
        )

        XCTAssertTrue(didCreate)
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["job-created"])
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testTasksViewModelLoadDoesNotSurfaceCancellationAsError() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testTasksViewModelLoadSurfacesNonCancellationError() async throws {
        let client = makeClient { _ in
            throw URLError(.timedOut)
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testTaskDetailViewModelPauseUpdatesJobAndPublishesMutation() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/pause")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job123",
                "name": "Digest",
                "prompt": "Run it",
                "schedule": {"kind": "cron", "expr": "0 7 * * *"},
                "enabled": true,
                "state": "paused"
              }
            }
            """, for: request)
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob("""
            {
              "id": "job123",
              "name": "Digest",
              "prompt": "Run it",
              "schedule": {"kind": "cron", "expr": "0 7 * * *"},
              "enabled": true,
              "state": "scheduled"
            }
            """),
            runningElapsed: 12,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didPause = await viewModel.pause()

        XCTAssertTrue(didPause)
        XCTAssertEqual(viewModel.job.status, .paused)
        XCTAssertNil(viewModel.runningElapsed)
        guard case .upsert(let updatedJob) = viewModel.lastMutation else {
            XCTFail("Expected upsert mutation.")
            return
        }
        XCTAssertEqual(updatedJob.jobId, "job123")
    }

    @MainActor
    func testTaskDetailViewModelLoadHydratesOutputsRunsAndRelatedSession() async throws {
        var requestedPaths: [String] = []
        let client = makeClient { request in
            let path = try XCTUnwrap(request.url?.path)
            requestedPaths.append(path)

            switch path {
            case "/api/crons/output":
                return apiTestJSONResponse("""
                {
                  "job_id": "job123",
                  "outputs": [
                    {"filename": "latest.md", "content": "## Response\\n\\nDone"}
                  ]
                }
                """, for: request)
            case "/api/crons/history":
                return apiTestJSONResponse("""
                {
                  "job_id": "job123",
                  "runs": [
                    {"filename": "latest.md", "size": 42, "modified": 1777892400}
                  ],
                  "total": 1,
                  "offset": 0
                }
                """, for: request)
            case "/api/crons/recent":
                return apiTestJSONResponse("""
                {
                  "since": 0,
                  "completions": [
                    {
                      "job_id": "job123",
                      "name": "Older digest",
                      "completed_at": 1777892300,
                      "session_id": "cron_job123_20260702_115830",
                      "message_count": 3
                    },
                    {
                      "job_id": "job123",
                      "name": "Morning digest",
                      "completed_at": 1777892400,
                      "session_id": "cron_job123_20260702_120000",
                      "message_count": 6
                    }
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected request: \(path)")
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"unexpected"}"#.utf8))
            }
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob(#"{"id": "job123", "name": "Digest"}"#),
            runningElapsed: nil,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertEqual(requestedPaths, ["/api/crons/output", "/api/crons/history", "/api/crons/recent"])
        XCTAssertEqual(viewModel.outputs.map(\.filename), ["latest.md"])
        XCTAssertEqual(viewModel.runs.map(\.filename), ["latest.md"])
        XCTAssertEqual(viewModel.relatedSession?.sessionId, "cron_job123_20260702_120000")
        XCTAssertEqual(viewModel.relatedSession?.displayTitle, "Morning digest")
        XCTAssertEqual(viewModel.relatedSession?.messageCount, 6)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testCronRunListItemsPairHistoryRowsWithOutputAndAppendOutputOnlyRows() async throws {
        var requestedPaths: [String] = []
        let client = makeClient { request in
            let path = try XCTUnwrap(request.url?.path)
            requestedPaths.append(path)

            switch path {
            case "/api/crons/output":
                return apiTestJSONResponse("""
                {
                  "job_id": "job123",
                  "outputs": [
                    {"filename": "latest.md", "content": "Latest output"},
                    {"filename": "orphan.md", "content": "Output without history"}
                  ]
                }
                """, for: request)
            case "/api/crons/history":
                return apiTestJSONResponse("""
                {
                  "job_id": "job123",
                  "runs": [
                    {"filename": "latest.md", "size": 42, "modified": 1777892400}
                  ]
                }
                """, for: request)
            case "/api/crons/recent":
                return apiTestJSONResponse(#"{"since":0,"completions":[]}"#, for: request)
            default:
                XCTFail("Unexpected request: \(path)")
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"unexpected"}"#.utf8))
            }
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob(#"{"id": "job123", "name": "Digest"}"#),
            runningElapsed: nil,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertEqual(requestedPaths, ["/api/crons/output", "/api/crons/history", "/api/crons/recent"])
        XCTAssertEqual(viewModel.recentRunItems.map(\.filename), ["latest.md", "orphan.md"])
        XCTAssertEqual(viewModel.recentRunItems.map(\.id), ["run-0-latest.md", "output-1-orphan.md"])
        XCTAssertEqual(viewModel.recentRunItems[0].outputContent, "Latest output")
        XCTAssertEqual(viewModel.recentRunItems[0].size, 42)
        XCTAssertEqual(viewModel.recentRunItems[0].modified, 1_777_892_400)
        XCTAssertEqual(viewModel.recentRunItems[1].outputContent, "Output without history")
        XCTAssertNil(viewModel.recentRunItems[1].size)
        XCTAssertNil(viewModel.recentRunItems[1].modified)
    }

    @MainActor
    func testTaskDetailViewModelLoadPreservesJobRelatedSessionWhenRecentEndpointIsUnavailable() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/crons/output":
                return apiTestJSONResponse(#"{"job_id":"job123","outputs":[]}"#, for: request)
            case "/api/crons/history":
                return apiTestJSONResponse(#"{"job_id":"job123","runs":[]}"#, for: request)
            case "/api/crons/recent":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"not found"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"unexpected"}"#.utf8))
            }
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob("""
            {
              "id": "job123",
              "name": "Digest",
              "session_id": "cron_job123_initial",
              "session_title": "Initial cron chat",
              "message_count": 3
            }
            """),
            runningElapsed: nil,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.relatedSession?.sessionId, "cron_job123_initial")
        XCTAssertEqual(viewModel.relatedSession?.displayTitle, "Initial cron chat")
        XCTAssertEqual(viewModel.relatedSession?.messageCount, 3)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTaskDetailViewModelMutationUpdatesRelatedSessionFromReturnedJob() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/pause")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job123",
                "name": "Digest",
                "session_id": "cron_job123_after_pause",
                "session_title": "Paused digest chat",
                "message_count": "8"
              }
            }
            """, for: request)
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob(#"{"id": "job123", "name": "Digest"}"#),
            runningElapsed: 12,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didPause = await viewModel.pause()

        XCTAssertTrue(didPause)
        XCTAssertEqual(viewModel.relatedSession?.sessionId, "cron_job123_after_pause")
        XCTAssertEqual(viewModel.relatedSession?.displayTitle, "Paused digest chat")
        XCTAssertEqual(viewModel.relatedSession?.messageCount, 8)
    }

    @MainActor
    func testTaskDetailViewModelDeletePublishesDeleteMutation() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/delete")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {"id": "job123"}
            }
            """, for: request)
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob(#"{"id": "job123", "name": "Digest"}"#),
            runningElapsed: nil,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didDelete = await viewModel.delete()

        XCTAssertTrue(didDelete)
        XCTAssertEqual(viewModel.lastMutation, .delete(jobID: "job123"))
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }

    private func decodeCronJob(_ json: String) throws -> CronJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CronJob.self, from: Data(json.utf8))
    }
}
