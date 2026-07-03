import XCTest
@testable import HermesMobile

/// Decoding contract for `GET /api/providers` (#26). The primary fixture mirrors
/// the live server shape captured 2026-07-02 plus upstream
/// `api/providers.py::get_providers()` @ `312d3fab`, including a
/// `custom_providers`-derived entry that omits most fields.
final class APIClientProvidersTests: APIClientTestCase {
    func testProvidersRequestDecodesLiveShape() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/providers")

            return apiTestJSONResponse("""
            {
              "active_provider": "openai-codex",
              "providers": [
                {
                  "id": "openai-codex",
                  "display_name": "OpenAI Codex",
                  "has_key": true,
                  "configurable": false,
                  "is_self_hosted": false,
                  "base_url": null,
                  "is_plugin_provider": false,
                  "is_oauth": true,
                  "key_source": "oauth",
                  "auth_error": null,
                  "models": [
                    { "id": "gpt-5.5", "label": "GPT 5.5" },
                    { "id": "gpt-5.5-codex", "label": "GPT 5.5 Codex" }
                  ],
                  "models_total": 5
                },
                {
                  "id": "anthropic",
                  "display_name": "Anthropic",
                  "has_key": false,
                  "configurable": true,
                  "is_self_hosted": false,
                  "base_url": null,
                  "is_plugin_provider": false,
                  "is_oauth": true,
                  "key_source": "oauth",
                  "auth_error": "OAuth token expired — run hermes auth login anthropic",
                  "models": [],
                  "models_total": 0
                },
                {
                  "id": "custom:glmcode",
                  "display_name": "glmcode",
                  "has_key": true,
                  "configurable": false,
                  "is_custom": true,
                  "key_source": "config_yaml",
                  "models": [ "glm-4.7" ],
                  "models_total": 1
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.providers()

        XCTAssertEqual(response.activeProvider, "openai-codex")
        let providers = try XCTUnwrap(response.providers)
        XCTAssertEqual(providers.count, 3)

        let codex = providers[0]
        XCTAssertEqual(codex.id, "openai-codex")
        XCTAssertEqual(codex.displayName, "OpenAI Codex")
        XCTAssertEqual(codex.hasKey, true)
        XCTAssertEqual(codex.configurable, false)
        XCTAssertEqual(codex.isSelfHosted, false)
        XCTAssertNil(codex.baseUrl)
        XCTAssertEqual(codex.isPluginProvider, false)
        XCTAssertEqual(codex.isOauth, true)
        XCTAssertEqual(codex.keySource, "oauth")
        XCTAssertNil(codex.authError)
        XCTAssertEqual(codex.models?.count, 2)
        XCTAssertEqual(codex.models?.first?.id, "gpt-5.5")
        XCTAssertEqual(codex.models?.first?.label, "GPT 5.5")
        XCTAssertEqual(codex.modelsTotal, 5)

        let anthropic = providers[1]
        XCTAssertEqual(anthropic.hasKey, false)
        XCTAssertEqual(anthropic.authError, "OAuth token expired — run hermes auth login anthropic")
        XCTAssertEqual(anthropic.models, [])

        // Custom-provider entries omit is_oauth / auth_error / is_self_hosted /
        // base_url / is_plugin_provider, and may carry bare-string model IDs.
        let custom = providers[2]
        XCTAssertEqual(custom.id, "custom:glmcode")
        XCTAssertEqual(custom.isCustom, true)
        XCTAssertNil(custom.isOauth)
        XCTAssertNil(custom.authError)
        XCTAssertEqual(custom.keySource, "config_yaml")
        XCTAssertEqual(custom.models?.first?.id, "glm-4.7")
        XCTAssertEqual(custom.models?.first?.label, "glm-4.7")
    }

    func testProvidersDecodingToleratesAbsentAndUnknownFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let empty = try decoder.decode(ProvidersResponse.self, from: Data("{}".utf8))
        XCTAssertNil(empty.providers)
        XCTAssertNil(empty.activeProvider)

        let sparse = try decoder.decode(ProvidersResponse.self, from: Data("""
        {
          "active_provider": null,
          "providers": [
            {},
            {
              "id": "mystery",
              "key_source": "keychain",
              "future_field": { "nested": true },
              "models": [ { "id": "m-1" }, "m-2" ],
              "models_total": "7"
            }
          ]
        }
        """.utf8))

        XCTAssertNil(sparse.activeProvider)
        let providers = try XCTUnwrap(sparse.providers)
        XCTAssertEqual(providers.count, 2)
        XCTAssertNil(providers[0].id)
        XCTAssertNil(providers[0].hasKey)
        XCTAssertNil(providers[0].models)

        let mystery = providers[1]
        XCTAssertEqual(mystery.id, "mystery")
        XCTAssertEqual(mystery.keySource, "keychain")
        XCTAssertEqual(mystery.models?.count, 2)
        XCTAssertEqual(mystery.models?[0].id, "m-1")
        XCTAssertNil(mystery.models?[0].label)
        XCTAssertEqual(mystery.models?[1].id, "m-2")
        XCTAssertEqual(mystery.models?[1].label, "m-2")
        XCTAssertEqual(mystery.modelsTotal, 7)
    }

    func testProvidersDecodingSurvivesUnexpectedProvidersShape() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(ProvidersResponse.self, from: Data("""
        { "providers": "unexpected", "active_provider": 7 }
        """.utf8))

        XCTAssertNil(response.providers)
        XCTAssertEqual(response.activeProvider, "7")
    }
}
