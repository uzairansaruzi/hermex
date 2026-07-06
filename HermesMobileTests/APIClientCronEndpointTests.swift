import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientCronEndpointTests: APIClientTestCase {
    func testCronsBuildsExpectedPathAndDecodesTolerantJobList() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)

            return apiTestJSONResponse("""
            {
              "jobs": [
                {
                  "id": "job123",
                  "name": "Morning digest",
                  "prompt": "Summarize overnight activity",
                  "schedule": {"kind": "cron", "expr": "0 7 * * *", "unexpected": true},
                  "schedule_display": "0 7 * * *",
                  "enabled": true,
                  "state": "scheduled",
                  "next_run_at": "2026-05-05T11:00:00Z",
                  "last_run_at": 1777892400,
                  "last_status": "ok",
                  "deliver": "local",
                  "skills": ["summarize", "notify"],
                  "ignored_new_field": {"nested": "value"}
                },
                {
                  "id": "legacy-broken",
                  "schedule": {"kind": "cron", "expr": "0 8 * * *"},
                  "repeat": {"times": null, "completed": 17},
                  "enabled": false,
                  "state": "completed",
                  "next_run_at": null,
                  "last_status": "ok"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.crons()
        let first = try XCTUnwrap(response.jobs?.first)
        let second = try XCTUnwrap(response.jobs?.last)

        XCTAssertEqual(first.jobId, "job123")
        XCTAssertEqual(first.displayName, "Morning digest")
        XCTAssertEqual(first.scheduleText, "0 7 * * *")
        let nextRunAt = try XCTUnwrap(first.nextRunAt)
        let lastRunAt = try XCTUnwrap(first.lastRunAt)
        XCTAssertEqual(nextRunAt.date.timeIntervalSince1970, 1_777_978_800, accuracy: 0.1)
        XCTAssertEqual(lastRunAt.date.timeIntervalSince1970, 1_777_892_400, accuracy: 0.1)
        XCTAssertFalse(nextRunAt.formatted.isEmpty)
        XCTAssertEqual(first.skills, ["summarize", "notify"])
        XCTAssertEqual(first.status, .active)

        XCTAssertEqual(second.status, .needsAttention)
        XCTAssertEqual(second.displayName, "0 8 * * *")
    }

    func testCronStatusWithoutJobIDBuildsExpectedPathAndDecodesRunningMap() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/status")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)

            return apiTestJSONResponse("""
            {
              "running": {
                "job123": 12.4,
                "job456": 61
              }
            }
            """, for: request)
        }

        let response = try await client.cronStatus()

        XCTAssertEqual(response.runningJobs?["job123"], 12.4)
        XCTAssertEqual(response.runningJobs?["job456"], 61)
        XCTAssertNil(response.running)
    }

    func testCronStatusWithJobIDBuildsExpectedQueryAndDecodesSingleStatus() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/status")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["job_id"], "job123")

            return apiTestJSONResponse("""
            {
              "job_id": "job123",
              "running": true,
              "elapsed": 12.4
            }
            """, for: request)
        }

        let response = try await client.cronStatus(jobID: "job123")

        XCTAssertEqual(response.jobId, "job123")
        XCTAssertEqual(response.running, true)
        XCTAssertEqual(response.elapsed, 12.4)
        XCTAssertNil(response.runningJobs)
    }

    func testCronOutputBuildsExpectedQueryAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/output")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["job_id"], "job123")
            XCTAssertEqual(query["limit"], "5")

            return apiTestJSONResponse("""
            {
              "job_id": "job123",
              "outputs": [
                {
                  "filename": "2026-05-04_10-00-00.md",
                  "content": "## Response\\n\\nAll clear."
                },
                {
                  "filename": "2026-05-04_09-00-00.md",
                  "content": ""
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.cronOutput(jobID: "job123", limit: 5)

        XCTAssertEqual(response.jobId, "job123")
        XCTAssertEqual(response.outputs?.count, 2)
        XCTAssertEqual(response.outputs?.first?.filename, "2026-05-04_10-00-00.md")
        XCTAssertEqual(response.outputs?.first?.content, "## Response\n\nAll clear.")
        XCTAssertEqual(response.outputs?.last?.filename, "2026-05-04_09-00-00.md")
        XCTAssertEqual(response.outputs?.last?.content, "")
    }

    func testCronCreateBuildsExpectedBodyAndDecodesMutationResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/create")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["prompt"] as? String, "Summarize overnight activity")
            XCTAssertEqual(body?["schedule"] as? String, "0 7 * * *")
            XCTAssertEqual(body?["name"] as? String, "Morning digest")
            XCTAssertEqual(body?["deliver"] as? String, "local")
            XCTAssertEqual(body?["skills"] as? [String], ["summarize", "notify"])
            XCTAssertEqual(body?["model"] as? String, "@openai:gpt-5.5")
            XCTAssertNil(body?["provider"], "Omitted provider must not be sent so the server default applies.")
            XCTAssertEqual(body?["profile"] as? String, "work")
            XCTAssertEqual(body?["toast_notifications"] as? Bool, true)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "job_id": "job-new",
                "name": "Morning digest",
                "prompt": "Summarize overnight activity",
                "schedule": "0 7 * * *",
                "enabled": true,
                "state": "scheduled",
                "model": "@openai:gpt-5.5",
                "profile": "work",
                "toast_notifications": true
              }
            }
            """, for: request)
        }

        let response = try await client.createCron(
            prompt: "Summarize overnight activity",
            schedule: "0 7 * * *",
            name: "Morning digest",
            deliver: "local",
            skills: ["summarize", "notify"],
            model: "@openai:gpt-5.5",
            provider: nil,
            profile: "work",
            toastNotifications: true
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.job?.jobId, "job-new")
        XCTAssertEqual(response.job?.scheduleText, "0 7 * * *")
        XCTAssertEqual(response.job?.model, "@openai:gpt-5.5")
        XCTAssertEqual(response.job?.toastNotifications, true)
    }

    func testCronUpdateBuildsExpectedBodyAndDecodesMutationResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/update")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["job_id"] as? String, "job123")
            XCTAssertEqual(body?["prompt"] as? String, "Updated prompt")
            XCTAssertEqual(body?["schedule"] as? String, "0 8 * * *")
            XCTAssertEqual(body?["name"] as? String, "Updated digest")
            XCTAssertEqual(body?["deliver"] as? String, "local")
            XCTAssertEqual(body?["skills"] as? [String], ["swift"])
            XCTAssertEqual(body?["model"] as? String, "@anthropic:claude")
            XCTAssertEqual(body?["provider"] as? String, "anthropic")
            XCTAssertEqual(body?["profile"] as? String, "personal")
            XCTAssertEqual(body?["toast_notifications"] as? Bool, false)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job123",
                "name": "Updated digest",
                "prompt": "Updated prompt",
                "schedule": {"kind": "cron", "expr": "0 8 * * *"},
                "enabled": true,
                "state": "scheduled",
                "model": "@anthropic:claude",
                "provider": "anthropic",
                "profile": "personal",
                "toast_notifications": false
              }
            }
            """, for: request)
        }

        let response = try await client.updateCron(
            jobID: "job123",
            prompt: "Updated prompt",
            schedule: "0 8 * * *",
            name: "Updated digest",
            deliver: "local",
            skills: ["swift"],
            model: "@anthropic:claude",
            provider: "anthropic",
            profile: "personal",
            toastNotifications: false
        )

        XCTAssertEqual(response.job?.jobId, "job123")
        XCTAssertEqual(response.job?.displayName, "Updated digest")
        XCTAssertEqual(response.job?.scheduleText, "0 8 * * *")
        XCTAssertEqual(response.job?.model, "@anthropic:claude")
        XCTAssertEqual(response.job?.provider, "anthropic")
        XCTAssertEqual(response.job?.toastNotifications, false)
    }

    func testCronCreateSendsProviderWhenSet() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/create")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["provider"] as? String, "openai")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job-provider",
                "prompt": "Run it",
                "schedule": "0 7 * * *",
                "provider": "openai"
              }
            }
            """, for: request)
        }

        let response = try await client.createCron(
            prompt: "Run it",
            schedule: "0 7 * * *",
            name: nil,
            deliver: nil,
            skills: [],
            model: nil,
            provider: "openai",
            profile: nil,
            toastNotifications: true
        )

        XCTAssertEqual(response.job?.provider, "openai")
    }

    func testCronDeliveryOptionsBuildsExpectedPathAndDecodesTolerantly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/delivery-options")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.url?.query)

            return apiTestJSONResponse("""
            {
              "platforms": [
                {"value": "local", "label": "Local (save output only)"},
                {"value": "origin", "label": "Origin (reply to creator)"},
                {"value": "slack", "label": "Slack", "unexpected_field": {"nested": true}},
                {"value": "telegram"}
              ],
              "ignored_new_field": 7
            }
            """, for: request)
        }

        let response = try await client.cronDeliveryOptions()
        let platforms = try XCTUnwrap(response.platforms)

        XCTAssertEqual(platforms.map(\.value), ["local", "origin", "slack", "telegram"])
        XCTAssertEqual(platforms.first?.label, "Local (save output only)")
        XCTAssertNil(platforms.last?.label)
    }

    func testCronDeliveryOptionsToleratesUnexpectedPlatformsShape() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"platforms": "unexpected"}"#, for: request)
        }

        let response = try await client.cronDeliveryOptions()

        XCTAssertNil(response.platforms)
    }

    func testCronJobIDMutationsBuildExpectedPathsAndBodies() async throws {
        var expectedRequests: [(path: String, reason: String?)] = [
            ("/api/crons/run", nil),
            ("/api/crons/pause", "Manual pause"),
            ("/api/crons/resume", nil),
            ("/api/crons/delete", nil)
        ]

        let client = makeClient { request in
            let expected = expectedRequests.removeFirst()
            XCTAssertEqual(request.url?.path, expected.path)
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["job_id"] as? String, "job123")
            XCTAssertEqual(body?["reason"] as? String, expected.reason)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {
                "id": "job123",
                "name": "Digest",
                "enabled": true,
                "state": "scheduled"
              }
            }
            """, for: request)
        }

        let runResponse = try await client.runCron(jobID: "job123")
        let pauseResponse = try await client.pauseCron(jobID: "job123", reason: "Manual pause")
        let resumeResponse = try await client.resumeCron(jobID: "job123")
        let deleteResponse = try await client.deleteCron(jobID: "job123")

        XCTAssertEqual(runResponse.job?.jobId, "job123")
        XCTAssertEqual(pauseResponse.job?.jobId, "job123")
        XCTAssertEqual(resumeResponse.job?.jobId, "job123")
        XCTAssertEqual(deleteResponse.job?.jobId, "job123")
        XCTAssertTrue(expectedRequests.isEmpty)
    }

    func testCronOutputOmitsLimitWhenNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/crons/output")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["job_id"], "job456")
            XCTAssertNil(query["limit"])

            return apiTestJSONResponse("""
            {
              "job_id": "job456",
              "outputs": []
            }
            """, for: request)
        }

        let response = try await client.cronOutput(jobID: "job456", limit: nil)
        XCTAssertEqual(response.outputs?.count, 0)
    }
}
