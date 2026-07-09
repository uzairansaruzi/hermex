import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientAgentControlTests: APIClientTestCase {
    func testApprovalPendingBuildsExpectedQueryAndDecodesTolerantly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/approval/pending")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")

            return apiTestJSONResponse("""
            {
              "pending": {
                "approval_id": "approval-1",
                "command": "curl https://example.test/install.sh | bash",
                "description": "High risk shell command",
                "pattern_key": "pipe_to_shell",
                "pattern_keys": ["network_download", 42],
                "future_field": {"ignored": true}
              },
              "pending_count": "2"
            }
            """, for: request)
        }

        let response = try await client.approvalPending(sessionID: "abc123")

        XCTAssertEqual(response.pending?.approvalId, "approval-1")
        XCTAssertEqual(response.pending?.command, "curl https://example.test/install.sh | bash")
        XCTAssertEqual(response.pending?.description, "High risk shell command")
        XCTAssertEqual(response.pending?.patternKey, "pipe_to_shell")
        XCTAssertEqual(response.pending?.patternKeys, ["network_download", "42.0"])
        XCTAssertEqual(response.pendingCount, 2)
    }

    func testApprovalPendingDecodesSingularPatternKeyWhenPatternKeysMissing() throws {
        let response = try JSONDecoder().decode(
            ApprovalPendingResponse.self,
            from: Data("""
            {
              "pending": {
                "approval_id": "approval-2",
                "command": "python script.py",
                "description": "Run Python",
                "pattern_key": "python_exec"
              },
              "pending_count": 1,
              "ignored": true
            }
            """.utf8)
        )

        XCTAssertEqual(response.pending?.displayPatternKeys, ["python_exec"])
        XCTAssertEqual(response.pendingCount, 1)
    }

    func testPendingApprovalDecodesServerIdentifierAliases() throws {
        let decoder = JSONDecoder()

        let snake = try decoder.decode(
            PendingApproval.self,
            from: Data(#"{"approval_id":"approval-snake","command":"make install"}"#.utf8)
        )
        let camel = try decoder.decode(
            PendingApproval.self,
            from: Data(#"{"approvalId":"approval-camel","command":"make install"}"#.utf8)
        )
        let gatewayID = try decoder.decode(
            PendingApproval.self,
            from: Data(#"{"approval_id":"   ","id":"approval-gateway","command":"make install"}"#.utf8)
        )

        XCTAssertEqual(snake.approvalId, "approval-snake")
        XCTAssertEqual(camel.approvalId, "approval-camel")
        XCTAssertEqual(gatewayID.approvalId, "approval-gateway")
        XCTAssertEqual(gatewayID.id, "approval-gateway")
    }

    func testRespondApprovalBuildsExpectedBodyForAllChoices() async throws {
        var observedBodies: [[String: Any]] = []
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/approval/respond")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            observedBodies.append(body)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "choice": "\(body["choice"] as? String ?? "")"
            }
            """, for: request)
        }

        for choice in ApprovalChoice.allCases {
            _ = try await client.respondApproval(
                sessionID: "abc123",
                choice: choice,
                approvalID: choice == .deny ? nil : "approval-\(choice.rawValue)"
            )
        }

        XCTAssertEqual(observedBodies.count, 4)
        XCTAssertEqual(observedBodies.compactMap { $0["session_id"] as? String }, Array(repeating: "abc123", count: 4))
        XCTAssertEqual(observedBodies.compactMap { $0["choice"] as? String }, ["once", "session", "always", "deny"])
        XCTAssertEqual(observedBodies[0]["approval_id"] as? String, "approval-once")
        XCTAssertEqual(observedBodies[1]["approval_id"] as? String, "approval-session")
        XCTAssertEqual(observedBodies[2]["approval_id"] as? String, "approval-always")
        XCTAssertNil(observedBodies[3]["approval_id"])
    }

    func testApprovalRespondResponseDecodesStaleFieldsTolerantly() async throws {
        // Upstream signals a benign stale click with 200 {"ok": true, "stale_cleared": true}
        // and gateway relays with "relayed" (issue #25).
        let client = makeClient { request in
            apiTestJSONResponse(
                #"{"ok": true, "choice": "once", "stale_cleared": true, "relayed": "true", "future": {"x": 1}}"#,
                for: request
            )
        }

        let response = try await client.respondApproval(
            sessionID: "abc123",
            choice: .once,
            approvalID: "approval-1"
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.choice, .once)
        XCTAssertEqual(response.staleCleared, true)
        XCTAssertEqual(response.relayed, true)
        XCTAssertNil(response.stale)

        let stale = try JSONDecoder().decode(
            ApprovalRespondResponse.self,
            from: Data(#"{"ok": false, "error": "Approval prompt expired.", "stale": true}"#.utf8)
        )
        XCTAssertEqual(stale.ok, false)
        XCTAssertEqual(stale.stale, true)
        XCTAssertNil(stale.staleCleared)
    }

    func testSessionYoloGetAndPostUseUpstreamShape() async throws {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1

            switch requestCount {
            case 1:
                XCTAssertEqual(request.url?.path, "/api/session/yolo")
                XCTAssertEqual(request.httpMethod, "GET")

                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["session_id"], "abc123")

                return apiTestJSONResponse(#"{"yolo_enabled": false}"#, for: request)
            case 2:
                XCTAssertEqual(request.url?.path, "/api/session/yolo")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)

                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "abc123")
                XCTAssertEqual(body["enabled"] as? Bool, true)

                return apiTestJSONResponse(#"{"ok": true, "yolo_enabled": true}"#, for: request)
            default:
                XCTFail("Unexpected yolo request")
                throw URLError(.badURL)
            }
        }

        let initial = try await client.sessionYolo(sessionID: "abc123")
        let enabled = try await client.setSessionYolo(sessionID: "abc123", enabled: true)

        XCTAssertEqual(initial.yoloEnabled, false)
        XCTAssertEqual(enabled.ok, true)
        XCTAssertEqual(enabled.yoloEnabled, true)
        XCTAssertEqual(requestCount, 2)
    }

    func testSteerChatBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/steer")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "abc123")
            XCTAssertEqual(body?["text"] as? String, "prefer tests")

            return apiTestJSONResponse("""
            {
              "accepted": true,
              "fallback": null,
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let response = try await client.steerChat(sessionID: "abc123", text: "prefer tests")

        XCTAssertEqual(response.accepted, true)
        XCTAssertNil(response.fallback)
        XCTAssertEqual(response.streamId, "stream-123")
    }

    func testSubmitGoalBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/goal")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["session_id"] as? String, "abc123")
            XCTAssertEqual(body["args"] as? String, "Ship the release notes")
            XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body["model"] as? String, "gpt-5.4")
            XCTAssertEqual(body["model_provider"] as? String, "openai")
            XCTAssertEqual(body["profile"] as? String, "default")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "action": "set",
              "message": "Goal set.",
              "goal": {
                "goal": "Ship the release notes",
                "status": "active",
                "turns_used": "2",
                "max_turns": 20,
                "last_verdict": "continue",
                "last_reason": "still working",
                "paused_reason": null
              },
              "kickoff_prompt": "Continue the goal.",
              "decision": {
                "status": "active",
                "should_continue": true,
                "continuation_prompt": "Continue.",
                "verdict": "continue",
                "reason": "new goal",
                "message": "Keep going",
                "message_key": "goal.continue",
                "message_args": ["one", 2, true]
              }
            }
            """, for: request)
        }

        let response = try await client.submitGoal(
            sessionID: "abc123",
            args: "Ship the release notes",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            modelProvider: "openai",
            profile: "default"
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.action, "set")
        XCTAssertEqual(response.displayMessage, "Goal set.")
        XCTAssertEqual(response.goal?.goal, "Ship the release notes")
        XCTAssertEqual(response.goal?.status, "active")
        XCTAssertEqual(response.goal?.turnsUsed, 2)
        XCTAssertEqual(response.goal?.maxTurns, 20)
        XCTAssertEqual(response.goal?.lastVerdict, "continue")
        XCTAssertEqual(response.goal?.lastReason, "still working")
        XCTAssertNil(response.goal?.pausedReason)
        XCTAssertEqual(response.kickoffPromptText, "Continue the goal.")
        XCTAssertEqual(response.decision?.shouldContinue, true)
        XCTAssertEqual(response.decision?.continuationPrompt, "Continue.")
        XCTAssertEqual(response.decision?.messageKey, "goal.continue")
        XCTAssertEqual(response.decision?.messageArgs, [.string("one"), .number(2), .bool(true)])
    }

    func testStartBtwBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/btw")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "abc123")
            XCTAssertEqual(body?["question"] as? String, "what changed?")

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-btw",
              "session_id": "ephemeral-1",
              "parent_session_id": "abc123"
            }
            """, for: request)
        }

        let response = try await client.startBtw(sessionID: "abc123", question: "what changed?")

        XCTAssertEqual(response.streamId, "stream-btw")
        XCTAssertEqual(response.sessionId, "ephemeral-1")
        XCTAssertEqual(response.parentSessionId, "abc123")
    }

    func testStartBackgroundBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/background")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "abc123")
            XCTAssertEqual(body?["prompt"] as? String, "audit tests")

            return apiTestJSONResponse("""
            {
              "task_id": "task-1",
              "stream_id": "stream-bg",
              "session_id": "background-1"
            }
            """, for: request)
        }

        let response = try await client.startBackground(sessionID: "abc123", prompt: "audit tests")

        XCTAssertEqual(response.taskId, "task-1")
        XCTAssertEqual(response.streamId, "stream-bg")
        XCTAssertEqual(response.sessionId, "background-1")
    }

    func testBackgroundStatusBuildsExpectedQueryAndDecodesResults() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/background/status")
            XCTAssertEqual(request.httpMethod, "GET")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")

            return apiTestJSONResponse("""
            {
              "results": [
                {
                  "task_id": "task-1",
                  "prompt": "audit tests",
                  "answer": "looks good",
                  "completed_at": 1770000000
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.backgroundStatus(sessionID: "abc123")
        let result = try XCTUnwrap(response.results?.first)

        XCTAssertEqual(result.taskId, "task-1")
        XCTAssertEqual(result.prompt, "audit tests")
        XCTAssertEqual(result.answer, "looks good")
        XCTAssertEqual(result.completedAt, 1_770_000_000)
    }
}
