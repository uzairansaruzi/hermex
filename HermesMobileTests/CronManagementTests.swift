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
            provider: "  openai  ",
            profile: "  work  ",
            toastNotifications: true
        )

        XCTAssertEqual(draft.trimmedName, "Morning digest")
        XCTAssertEqual(draft.trimmedPrompt, "Summarize updates")
        XCTAssertEqual(draft.trimmedSchedule, "0 7 * * *")
        XCTAssertEqual(draft.trimmedDeliver, "local")
        XCTAssertEqual(draft.skills, ["summarize", "notify", "swift"])
        XCTAssertEqual(draft.trimmedModel, "@openai:gpt-5.5")
        XCTAssertEqual(draft.trimmedProvider, "openai")
        XCTAssertEqual(draft.trimmedProfile, "work")
        XCTAssertNil(draft.validationMessage)
    }

    func testCronJobEditorDraftRoundTripsUnknownDeliverAndProvider() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(
            CronJob.self,
            from: Data("""
            {
              "id": "job-legacy",
              "prompt": "Run it",
              "schedule": "0 7 * * *",
              "deliver": "legacy-target",
              "provider": "openai"
            }
            """.utf8)
        )

        let draft = CronJobEditorDraft(job: job)

        XCTAssertEqual(draft.deliver, "legacy-target")
        XCTAssertEqual(draft.trimmedDeliver, "legacy-target")
        XCTAssertEqual(draft.provider, "openai")
    }

    func testCronDeliverPickerFallsBackWithoutUsableOptions() {
        XCTAssertNil(CronDeliverPicker.options(serverOptions: nil, currentValue: "local"))
        XCTAssertNil(CronDeliverPicker.options(serverOptions: [], currentValue: "local"))
        XCTAssertNil(
            CronDeliverPicker.options(
                serverOptions: [CronDeliveryOption(value: "  ", label: "Blank"), CronDeliveryOption(value: nil, label: "No value")],
                currentValue: "local"
            )
        )
        XCTAssertNil(
            CronDeliverPicker.options(
                serverOptions: [CronDeliveryOption(value: "local", label: "Local")],
                currentValue: "   "
            ),
            "A blank draft value has nothing safe to select, so free text is kept."
        )
    }

    func testCronDeliverPickerKeepsUnknownValueAsCustomRow() throws {
        let serverOptions = [
            CronDeliveryOption(value: "local", label: "Local (save output only)"),
            CronDeliveryOption(value: "origin", label: "Origin (reply to creator)"),
            CronDeliveryOption(value: "origin", label: "Duplicate ignored"),
            CronDeliveryOption(value: "telegram", label: nil)
        ]

        let options = try XCTUnwrap(
            CronDeliverPicker.options(serverOptions: serverOptions, currentValue: "legacy-target")
        )

        XCTAssertEqual(options.map(\.value), ["local", "origin", "telegram", "legacy-target"])
        XCTAssertEqual(options.map(\.isCustom), [false, false, false, true])
        XCTAssertEqual(options.first?.label, "Local (save output only)")
        XCTAssertEqual(options[2].label, "telegram", "Missing labels fall back to the raw value.")

        let knownValue = try XCTUnwrap(
            CronDeliverPicker.options(serverOptions: serverOptions, currentValue: "origin")
        )
        XCTAssertEqual(knownValue.map(\.value), ["local", "origin", "telegram"])
        XCTAssertFalse(knownValue.contains(where: \.isCustom))
    }

    func testCronDeliverPickerPreservesInitialAndLiveCustomValues() throws {
        let serverOptions = [
            CronDeliveryOption(value: "local", label: "Local"),
            CronDeliveryOption(value: "telegram", label: "Telegram")
        ]

        // The editor's initial legacy value keeps its custom row even after
        // the user selects a server option (currentValue moved on).
        let afterSelection = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "telegram",
                initialValue: "legacy-target"
            )
        )
        XCTAssertEqual(afterSelection.map(\.value), ["local", "telegram", "legacy-target"])
        XCTAssertEqual(afterSelection.map(\.isCustom), [false, false, true])

        // A value typed into the free-text fallback while options were still
        // loading gets its own row alongside the initial value's row, so the
        // picker selection always has a matching tag.
        let typedWhileLoading = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "typed-target",
                initialValue: "local"
            )
        )
        XCTAssertEqual(typedWhileLoading.map(\.value), ["local", "telegram", "typed-target"])
        XCTAssertEqual(typedWhileLoading.map(\.isCustom), [false, false, true])

        // Identical initial and current custom values collapse to one row.
        let sameCustom = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "legacy-target",
                initialValue: "legacy-target"
            )
        )
        XCTAssertEqual(sameCustom.map(\.value), ["local", "telegram", "legacy-target"])
        XCTAssertEqual(sameCustom.filter(\.isCustom).count, 1)

        // A blank initial value adds no row.
        let blankInitial = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "local",
                initialValue: "   "
            )
        )
        XCTAssertEqual(blankInitial.map(\.value), ["local", "telegram"])
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
    func testTasksViewModelLoadPopulatesDeliveryOptions() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/crons":
                return apiTestJSONResponse(#"{"jobs": []}"#, for: request)
            case "/api/crons/status":
                return apiTestJSONResponse(#"{"running": {}}"#, for: request)
            case "/api/crons/delivery-options":
                return apiTestJSONResponse(
                    #"{"platforms": [{"value": "local", "label": "Local (save output only)"}]}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.deliveryOptions?.count, 1)
        XCTAssertEqual(viewModel.deliveryOptions?.first?.value, "local")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTasksViewModelLoadToleratesDeliveryOptionsFailure() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/crons":
                return apiTestJSONResponse(#"{"jobs": [{"id": "job123", "name": "Digest"}]}"#, for: request)
            case "/api/crons/status":
                return apiTestJSONResponse(#"{"running": {}}"#, for: request)
            case "/api/crons/delivery-options":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error": "not found"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertNil(viewModel.deliveryOptions, "Endpoint failure must fall back to free-text deliver entry.")
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["job123"], "Jobs must still load when delivery options fail.")
        XCTAssertNil(viewModel.errorMessage)
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
