import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientConfigurationTests: APIClientTestCase {
    func testReasoningDisplayPrefersStructuredThinkingAndStripsVisibleAnswerEcho() {
        let finalAnswer = """
        **Terminal:** `/Users/hermes` directory listed.

        **Search files:** 5 `config.yaml` matches found.
        """
        let messages = [
            ChatMessage(
                role: "user",
                content: "Use terminal and search files",
                timestamp: 1_770_000_000,
                messageId: "user-tools"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_001,
                messageId: "assistant-tools",
                contentParts: [
                    .object([
                        "type": .string("thinking"),
                        "text": .string("The user wants me to use terminal and search_files. I should run a quick command.")
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-terminal"),
                        "name": .string("terminal"),
                        "input": .object(["command": .string("ls -la")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-search"),
                        "name": .string("search_files"),
                        "input": .object(["pattern": .string("config.yaml")])
                    ])
                ],
                reasoning: "Terminal works. Now run search_files to show that works too."
            ),
            ChatMessage(
                role: "user",
                content: nil,
                timestamp: 1_770_000_002,
                messageId: "tool-results",
                contentParts: [
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-terminal"),
                        "content": .string("81 entries")
                    ]),
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-search"),
                        "content": .string("5 matches")
                    ])
                ]
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_003,
                messageId: "assistant-post-tools",
                reasoning: "Terminal works. Now run search_files to show that works too."
            ),
            ChatMessage(
                role: "assistant",
                content: finalAnswer,
                timestamp: 1_770_000_004,
                messageId: "assistant-final",
                reasoning: """
                The user wants me to use terminal and search_files. I should run a quick command.
                Terminal works. Now run search_files to show that works too.
                Both tools worked. I should give a concise summary.

                \(finalAnswer)
                """
            )
        ]

        let reasoningGroups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: [])
        let transcriptMessages = ChatViewModel.transcriptMessages(from: messages)

        XCTAssertEqual(reasoningGroups.map(\.anchorMessageID), [
            "assistant-tools",
            "assistant-post-tools",
            "assistant-final"
        ])
        XCTAssertEqual(reasoningGroups[0].text, "The user wants me to use terminal and search_files. I should run a quick command.")
        XCTAssertEqual(reasoningGroups[1].text, "Terminal works. Now run search_files to show that works too.")
        XCTAssertTrue(reasoningGroups[2].text.contains("Both tools worked. I should give a concise summary."))
        XCTAssertFalse(reasoningGroups[2].text.contains("**Terminal:**"))
        XCTAssertFalse(transcriptMessages.contains { $0.message.id == "tool-results" })
    }

    func testSaveDefaultModelBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/default-model")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "claude-sonnet-4")
            XCTAssertNil(body?["modelId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "model": "claude-sonnet-4"
            }
            """, for: request)
        }

        let response = try await client.saveDefaultModel(model: "claude-sonnet-4")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.model, "claude-sonnet-4")
    }

    func testSaveDefaultModelWithProviderQualifiedID() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/default-model")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "@openai:gpt-5.4")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "model": "@openai:gpt-5.4"
            }
            """, for: request)
        }

        let response = try await client.saveDefaultModel(model: "@openai:gpt-5.4")

        XCTAssertEqual(response.model, "@openai:gpt-5.4")
    }

    func testCommandsBuildsExpectedPathAndDecodesTolerantMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/commands")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "commands": [
                {
                  "name": "browser",
                  "description": "Use browser tools",
                  "category": "tools",
                  "aliases": ["web"],
                  "args_hint": "query",
                  "subcommands": ["open"],
                  "cli_only": "true",
                  "gateway_only": 0,
                  "future_field": "ignored"
                },
                {
                  "name": "status"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.commands()

        XCTAssertEqual(response.commands?.count, 2)
        XCTAssertEqual(response.commands?.first?.name, "browser")
        XCTAssertEqual(response.commands?.first?.argsHint, "query")
        XCTAssertEqual(response.commands?.first?.aliases, ["web"])
        XCTAssertEqual(response.commands?.first?.cliOnly, true)
        XCTAssertEqual(response.commands?.last?.description, nil)
    }

    func testUpdateSessionModelBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/update")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body?["model"] as? String, "@openai:gpt-5.5")
            XCTAssertEqual(body?["model_provider"] as? String, "openai")
            XCTAssertNil(body?["sessionId"])
            XCTAssertNil(body?["modelProvider"])

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "workspace": "/tmp/workspace",
                "model": "@openai:gpt-5.5",
                "model_provider": "openai"
              }
            }
            """, for: request)
        }

        let response = try await client.updateSession(
            id: "session-abc",
            workspace: "/tmp/workspace",
            model: "@openai:gpt-5.5",
            modelProvider: "openai"
        )

        XCTAssertEqual(response.session?.sessionId, "session-abc")
        XCTAssertEqual(response.session?.model, "@openai:gpt-5.5")
        XCTAssertEqual(response.session?.modelProvider, "openai")
    }

    func testReasoningStatusBuildsExpectedPathAndDecodesEffort() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/reasoning")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)

            return apiTestJSONResponse("""
            {
              "show_reasoning": true,
              "reasoning_effort": "high"
            }
            """, for: request)
        }

        let response = try await client.reasoning()

        XCTAssertEqual(response.showReasoning, true)
        XCTAssertEqual(response.reasoningEffort, "high")
        XCTAssertEqual(response.effectiveEffort, "high")
    }

    func testSaveReasoningEffortBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/reasoning")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["effort"] as? String, "xhigh")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "reasoning_effort": "xhigh"
            }
            """, for: request)
        }

        let response = try await client.saveReasoningEffort("xhigh")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.effectiveEffort, "xhigh")
    }

    func testSaveReasoningDisplayBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/reasoning")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["display"] as? String, "hide")
            XCTAssertNil(body?["effort"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "show_reasoning": false,
              "reasoning_effort": "medium"
            }
            """, for: request)
        }

        let response = try await client.saveReasoningDisplay("hide")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.showReasoning, false)
        XCTAssertEqual(response.effectiveEffort, "medium")
    }

    func testPersonalitiesBuildsExpectedPathAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/personalities")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "personalities": [
                {
                  "name": "mentor",
                  "description": "Patient technical coach",
                  "extra": "ignored"
                },
                {
                  "name": "critic"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.personalities()

        XCTAssertEqual(response.personalities?.count, 2)
        XCTAssertEqual(response.personalities?.first?.name, "mentor")
        XCTAssertEqual(response.personalities?.first?.description, "Patient technical coach")
        XCTAssertEqual(response.personalities?.last?.description, nil)
    }

    func testSetPersonalityBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/personality/set")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["name"] as? String, "mentor")
            XCTAssertNil(body?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "personality": "mentor",
              "prompt": "Be direct."
            }
            """, for: request)
        }

        let response = try await client.setPersonality(sessionID: "session-abc", name: "mentor")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.personality, "mentor")
        XCTAssertEqual(response.prompt, "Be direct.")
    }

    func testClearPersonalitySendsEmptyName() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/personality/set")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["name"] as? String, "")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "personality": null
            }
            """, for: request)
        }

        let response = try await client.setPersonality(sessionID: "session-abc", name: "")

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.personality)
    }

    func testRenameSessionBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session/rename")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["title"] as? String, "New Title")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "New Title"
              }
            }
            """, for: request)
        }

        let response = try await client.renameSession(id: "session-abc", title: "New Title")

        XCTAssertEqual(response.session?.sessionId, "session-abc")
        XCTAssertEqual(response.session?.title, "New Title")
    }

    func testProfilesBuildsExpectedPathAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profiles")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "active": "default",
              "profiles": [
                {
                  "name": "default",
                  "path": "/Users/test/.hermes",
                  "is_default": true,
                  "is_active": true,
                  "model": "gpt-5.5",
                  "provider": "openai",
                  "has_env": true,
                  "skill_count": 4
                }
              ],
              "single_profile_mode": true
            }
            """, for: request)
        }

        let response = try await client.profiles()

        XCTAssertEqual(response.active, "default")
        XCTAssertEqual(response.profiles?.first?.name, "default")
        XCTAssertEqual(response.profiles?.first?.isDefault, true)
        XCTAssertEqual(response.profiles?.first?.displayName, "Default")
        XCTAssertEqual(response.singleProfileMode, true)
    }

    func testProfilesResponseToleratesAbsentSingleProfileMode() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            ProfilesResponse.self,
            from: Data(#"{"active": "default", "profiles": []}"#.utf8)
        )

        XCTAssertNil(response.singleProfileMode)
    }

    func testProfilesResponseEffectiveDefaultPrefersActiveName() {
        let response = ProfilesResponse(
            profiles: [
                ProfileSummary(
                    name: "default",
                    path: nil,
                    isDefault: true,
                    isActive: false,
                    gatewayRunning: nil,
                    model: "gpt-5.4",
                    provider: "openai",
                    hasEnv: nil,
                    skillCount: nil
                ),
                ProfileSummary(
                    name: "work",
                    path: nil,
                    isDefault: false,
                    isActive: true,
                    gatewayRunning: nil,
                    model: "gpt-5.5",
                    provider: "anthropic",
                    hasEnv: nil,
                    skillCount: 8
                )
            ],
            active: " work "
        )

        XCTAssertEqual(response.effectiveDefaultProfileName, "work")
        XCTAssertEqual(response.displayName(for: "work"), "work")
    }

    func testProfilesResponseEffectiveDefaultFallsBackToFlags() {
        let activeFlagResponse = ProfilesResponse(
            profiles: [
                ProfileSummary(
                    name: "personal",
                    path: nil,
                    isDefault: false,
                    isActive: true,
                    gatewayRunning: nil,
                    model: nil,
                    provider: nil,
                    hasEnv: nil,
                    skillCount: nil
                )
            ],
            active: nil
        )
        XCTAssertEqual(activeFlagResponse.effectiveDefaultProfileName, "personal")

        let defaultFlagResponse = ProfilesResponse(
            profiles: [
                ProfileSummary(
                    name: "default",
                    path: nil,
                    isDefault: true,
                    isActive: false,
                    gatewayRunning: nil,
                    model: nil,
                    provider: nil,
                    hasEnv: nil,
                    skillCount: nil
                )
            ],
            active: ""
        )
        XCTAssertEqual(defaultFlagResponse.effectiveDefaultProfileName, "default")
        XCTAssertEqual(defaultFlagResponse.displayName(for: "default"), "Default")
    }

    func testSwitchProfileBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profile/switch")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["name"] as? String, "work")

            return apiTestJSONResponse("""
            {
              "active": "work",
              "default_model": "gpt-5.5",
              "default_workspace": "/Users/test/work",
              "profiles": [
                {"name": "default", "is_active": false},
                {"name": "work", "is_active": true}
              ]
            }
            """, for: request)
        }

        let response = try await client.switchProfile(name: "work")

        XCTAssertEqual(response.active, "work")
        XCTAssertEqual(response.defaultModel, "gpt-5.5")
        XCTAssertEqual(response.defaultWorkspace, "/Users/test/work")
        XCTAssertEqual(response.profiles?.last?.isActive, true)
    }

    func testCreateProfileBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profile/create")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["name"] as? String, "research")
            XCTAssertEqual(body?["clone_config"] as? Bool, false)
            // Optional fields must be omitted, not sent as null (the server
            // treats presence as intent).
            XCTAssertEqual(body?.count, 2)

            return apiTestJSONResponse("""
            {
              "ok": true,
              "profile": {
                "name": "research",
                "path": "/Users/test/.hermes/profiles/research",
                "is_default": false
              }
            }
            """, for: request)
        }

        let response = try await client.createProfile(name: "research")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.profile?.name, "research")
        XCTAssertNil(response.error)
    }

    func testCreateProfileSendsOptionalFieldsWithSnakeCaseKeys() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profile/create")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["name"] as? String, "research")
            XCTAssertEqual(body?["clone_config"] as? Bool, true)
            XCTAssertEqual(body?["default_model"] as? String, "claude-sonnet-4-5")
            XCTAssertEqual(body?["model_provider"] as? String, "anthropic")
            XCTAssertEqual(body?["base_url"] as? String, "http://localhost:11434")
            XCTAssertEqual(body?["api_key"] as? String, "sk-test")
            XCTAssertEqual(body?.count, 6)

            return apiTestJSONResponse(#"{"ok": true}"#, for: request)
        }

        let response = try await client.createProfile(
            name: "research",
            cloneConfig: true,
            defaultModel: "claude-sonnet-4-5",
            modelProvider: "anthropic",
            baseUrl: "http://localhost:11434",
            apiKey: "sk-test"
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.profile)
    }

    func testProfileBaseURLRuleMirrorsUpstream() {
        XCTAssertTrue(ProfileNameRules.isValidBaseURL("http://localhost:11434"))
        XCTAssertTrue(ProfileNameRules.isValidBaseURL("https://api.example.com/v1"))
        XCTAssertFalse(ProfileNameRules.isValidBaseURL("localhost:11434"))
        XCTAssertFalse(ProfileNameRules.isValidBaseURL("ftp://example.com"))
        XCTAssertFalse(ProfileNameRules.isValidBaseURL(""))
    }

    func testProfilePickerCancellationErrorDetection() {
        XCTAssertTrue(DefaultProfilePickerView.isCancellationError(CancellationError()))
        XCTAssertTrue(DefaultProfilePickerView.isCancellationError(URLError(.cancelled)))
        XCTAssertTrue(DefaultProfilePickerView.isCancellationError(APIError.network(underlying: URLError(.cancelled))))
        XCTAssertFalse(DefaultProfilePickerView.isCancellationError(URLError(.timedOut)))
        XCTAssertFalse(DefaultProfilePickerView.isCancellationError(APIError.unauthorized))
    }

    func testProfileNameRulesMirrorUpstreamPattern() {
        XCTAssertTrue(ProfileNameRules.isValid("work"))
        XCTAssertTrue(ProfileNameRules.isValid("a"))
        XCTAssertTrue(ProfileNameRules.isValid("9lives"))
        XCTAssertTrue(ProfileNameRules.isValid("team-2_dev"))
        XCTAssertTrue(ProfileNameRules.isValid(String(repeating: "a", count: 64)))

        XCTAssertFalse(ProfileNameRules.isValid(""))
        XCTAssertFalse(ProfileNameRules.isValid("-lead"))
        XCTAssertFalse(ProfileNameRules.isValid("_x"))
        XCTAssertFalse(ProfileNameRules.isValid("Work"))
        XCTAssertFalse(ProfileNameRules.isValid("a b"))
        XCTAssertFalse(ProfileNameRules.isValid("über"))
        XCTAssertFalse(ProfileNameRules.isValid("name!"))
        XCTAssertFalse(ProfileNameRules.isValid(String(repeating: "a", count: 65)))
    }

    func testSettingsBuildsExpectedPathAndDecodesServerVersion() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/settings")

            return apiTestJSONResponse("""
            {
              "bot_name": "Hermes",
              "webui_version": "v0.50.253",
              "theme": "system"
            }
            """, for: request)
        }

        let response = try await client.settings()

        XCTAssertEqual(response.botName, "Hermes")
        XCTAssertEqual(response.webuiVersion, "v0.50.253")
        XCTAssertEqual(response.theme, "system")
    }
}
