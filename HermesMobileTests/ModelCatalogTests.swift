import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class ModelCatalogTests: XCTestCase {
    func testModelsResponseBuildsCatalogGroupsFromUpstreamShape() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ModelsResponse.self,
            from: Data("""
            {
              "default_model": "@openai:gpt-5.5",
              "active_provider": "openai",
              "groups": [
                {
                  "name": "OpenAI",
                  "provider_id": "openai",
                  "models": [
                    {"id": "@openai:gpt-5.5", "name": "GPT-5.5"},
                    {"id": "@openai:gpt-5.4", "label": "GPT-5.4"}
                  ]
                }
              ]
            }
            """.utf8)
        )

        let groups = response.catalogGroups

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "OpenAI")
        XCTAssertEqual(groups.first?.providerID, "openai")
        XCTAssertEqual(groups.first?.models.first?.id, "@openai:gpt-5.5")
        XCTAssertEqual(groups.first?.models.first?.displayName, "GPT-5.5")
        XCTAssertEqual(groups.first?.models.first?.providerID, "openai")
        XCTAssertEqual(response.displayName(for: "@openai:gpt-5.4"), "GPT-5.4")
    }

    func testModelsResponseKeepsExtraModelsForSlashAutocompleteOnly() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ModelsResponse.self,
            from: Data("""
            {
              "default_model": "@nous:anthropic/claude-opus-4.7",
              "active_provider": "nous",
              "groups": [
                {
                  "name": "Nous (15 of 397)",
                  "provider_id": "nous",
                  "models": [
                    {"id": "@nous:anthropic/claude-opus-4.7", "label": "Claude Opus 4.7 (via Nous)"}
                  ],
                  "extra_models": [
                    {"id": "@nous:qwen/qwen3-coder", "label": "Qwen3 Coder (via Nous)"}
                  ]
                }
              ]
            }
            """.utf8)
        )

        let group = try XCTUnwrap(response.catalogGroups.first)

        XCTAssertEqual(group.models.map(\.id), ["@nous:anthropic/claude-opus-4.7"])
        XCTAssertEqual(group.extraModels.map(\.id), ["@nous:qwen/qwen3-coder"])
        XCTAssertEqual(
            group.slashAutocompleteModels.map(\.id),
            ["@nous:anthropic/claude-opus-4.7", "@nous:qwen/qwen3-coder"]
        )
        XCTAssertEqual(response.displayName(for: "@nous:qwen/qwen3-coder"), "Qwen3 Coder (via Nous)")
    }

    // MARK: - /api/models/live (issue #236)

    func testModelsLiveResponseDecodesUpstreamShape() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ModelsLiveResponse.self,
            from: Data("""
            {
              "provider": "opencode-go",
              "models": [
                {"id": "kimi-k2.7-code", "label": "Kimi K2.7 Code"}
              ],
              "count": 19
            }
            """.utf8)
        )

        XCTAssertEqual(response.provider, "opencode-go")
        XCTAssertEqual(response.count, 19)

        let options = response.liveOptions
        XCTAssertEqual(options.map(\.id), ["kimi-k2.7-code"])
        XCTAssertEqual(options.first?.displayName, "Kimi K2.7 Code")
        XCTAssertEqual(options.first?.providerID, "opencode-go")
    }

    func testModelsLiveResponseToleratesMissingFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ModelsLiveResponse.self, from: Data("{}".utf8))

        XCTAssertNil(response.provider)
        XCTAssertNil(response.count)
        XCTAssertTrue(response.liveOptions.isEmpty)
    }

    func testMergingLiveModelsReplacesOnlyTheMatchingProviderGroup() {
        let groups = [
            ModelCatalogGroup(
                id: "opencode-go",
                name: "OpenCode Go",
                providerID: "opencode-go",
                models: [
                    ModelCatalogOption(id: "kept-model", displayName: "Kept Model", providerID: "opencode-go"),
                    ModelCatalogOption(id: "stale-model", displayName: "Stale Model", providerID: "opencode-go")
                ],
                extraModels: [
                    ModelCatalogOption(id: "extra-model", displayName: "Extra Model", providerID: "opencode-go")
                ]
            ),
            ModelCatalogGroup(
                id: "openai",
                name: "OpenAI",
                providerID: "openai",
                models: [
                    ModelCatalogOption(id: "@openai:gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
                ]
            )
        ]

        let live = ModelsLiveResponse(
            provider: "opencode-go",
            models: [
                .object(["id": .string("kept-model"), "label": .string("Kept Model")]),
                .object(["id": .string("kimi-k2.7-code"), "label": .string("Kimi K2.7 Code")])
            ],
            count: 2
        )

        let merged = groups.mergingLiveModels(from: live)

        // Live is authoritative for the matched group: addition shows up, stale model drops.
        XCTAssertEqual(merged.first?.models.map(\.id), ["kept-model", "kimi-k2.7-code"])
        XCTAssertEqual(merged.first?.models.last?.displayName, "Kimi K2.7 Code")
        XCTAssertEqual(merged.first?.models.last?.providerID, "opencode-go")
        XCTAssertEqual(merged.first?.id, "opencode-go")
        XCTAssertEqual(merged.first?.name, "OpenCode Go")
        XCTAssertEqual(merged.first?.extraModels.map(\.id), ["extra-model"])
        XCTAssertEqual(merged.last, groups.last)
    }

    func testMergingLiveModelsLeavesGroupsUnchangedWhenNoGroupMatches() {
        let groups = [
            ModelCatalogGroup(
                id: "openai",
                name: "OpenAI",
                providerID: "openai",
                models: [
                    ModelCatalogOption(id: "@openai:gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
                ]
            )
        ]

        let live = ModelsLiveResponse(
            provider: "unknown-provider",
            models: [.object(["id": .string("some-model"), "label": .string("Some Model")])],
            count: 1
        )

        XCTAssertEqual(groups.mergingLiveModels(from: live), groups)
    }

    func testMergingLiveModelsLeavesGroupsUnchangedOnDegenerateResponses() {
        let groups = [
            ModelCatalogGroup(
                id: "opencode-go",
                name: "OpenCode Go",
                providerID: "opencode-go",
                models: [
                    ModelCatalogOption(id: "kept-model", displayName: "Kept Model", providerID: "opencode-go")
                ]
            )
        ]

        // Missing provider.
        XCTAssertEqual(
            groups.mergingLiveModels(from: ModelsLiveResponse(provider: nil, models: [], count: nil)),
            groups
        )

        // Whitespace-only provider.
        XCTAssertEqual(
            groups.mergingLiveModels(from: ModelsLiveResponse(provider: "  ", models: [], count: nil)),
            groups
        )

        // Matching provider but an empty live list must not blank out the cached group.
        XCTAssertEqual(
            groups.mergingLiveModels(from: ModelsLiveResponse(provider: "opencode-go", models: [], count: 0)),
            groups
        )

        // Entries without usable ids parse to nothing and are treated as empty.
        XCTAssertEqual(
            groups.mergingLiveModels(
                from: ModelsLiveResponse(
                    provider: "opencode-go",
                    models: [.object(["label": .string("No ID")])],
                    count: 1
                )
            ),
            groups
        )
    }

    // MARK: - /api/providers (issue #26)

    func testProvidersResponseDecodesLiveStatusShape() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ProvidersResponse.self,
            from: Data("""
            {
              "active_provider": "openai-codex",
              "providers": [
                {
                  "id": "openai-codex",
                  "display_name": "OpenAI Codex",
                  "has_key": true,
                  "configurable": false,
                  "is_plugin_provider": false,
                  "is_self_hosted": false,
                  "base_url": null,
                  "is_oauth": true,
                  "key_source": "oauth",
                  "auth_error": null,
                  "models": [
                    {"id": "gpt-5.5", "label": "GPT 5.5"}
                  ],
                  "models_total": 5
                }
              ]
            }
            """.utf8)
        )

        XCTAssertEqual(response.activeProvider, "openai-codex")
        let provider = try XCTUnwrap(response.providers?.first)
        XCTAssertEqual(provider.id, "openai-codex")
        XCTAssertEqual(provider.displayName, "OpenAI Codex")
        XCTAssertEqual(provider.hasKey, true)
        XCTAssertEqual(provider.configurable, false)
        XCTAssertEqual(provider.isPluginProvider, false)
        XCTAssertEqual(provider.isSelfHosted, false)
        XCTAssertEqual(provider.isOauth, true)
        XCTAssertEqual(provider.keySource, "oauth")
        XCTAssertNil(provider.authError)
        XCTAssertEqual(provider.modelsTotal, 5)
        XCTAssertEqual(provider.models?.first?.id, "gpt-5.5")
        XCTAssertEqual(provider.models?.first?.label, "GPT 5.5")
    }

    func testProvidersResponseToleratesMissingFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ProvidersResponse.self,
            from: Data("""
            {
              "providers": [
                {"id": "bare-provider"},
                {}
              ]
            }
            """.utf8)
        )

        XCTAssertNil(response.activeProvider)
        XCTAssertEqual(response.providers?.count, 2)
        XCTAssertEqual(response.providers?.first?.displayTitle, "bare-provider")
        XCTAssertEqual(response.providers?.last?.displayTitle, "Provider")
    }

    func testProviderPresentationHelpersExposeActiveErrorAndKeyStatus() {
        let keyed = ProviderSummary(
            id: "openrouter",
            displayName: "OpenRouter",
            hasKey: true,
            configurable: true,
            isPluginProvider: false,
            isSelfHosted: false,
            baseUrl: nil,
            isOauth: false,
            keySource: "env_var",
            authError: "token expired",
            models: [ProviderModel(id: "anthropic/claude-sonnet", label: "Claude Sonnet")],
            modelsTotal: 12
        )

        XCTAssertTrue(keyed.isActive(activeProvider: "openrouter"))
        XCTAssertEqual(keyed.displayTitle, "OpenRouter")
        XCTAssertEqual(keyed.keyStatusText, "Has key")
        XCTAssertEqual(keyed.keySourceBadge, "env var")
        XCTAssertEqual(keyed.modelCountText, "1 shown · 12 total")
        XCTAssertEqual(keyed.authErrorText, "token expired")

        let unkeyed = ProviderSummary(
            id: "local",
            displayName: nil,
            hasKey: false,
            configurable: nil,
            isPluginProvider: nil,
            isSelfHosted: true,
            baseUrl: "http://localhost:11434",
            isOauth: nil,
            keySource: "none",
            authError: nil,
            models: nil,
            modelsTotal: nil
        )

        XCTAssertFalse(unkeyed.isActive(activeProvider: "openrouter"))
        XCTAssertEqual(unkeyed.displayTitle, "local")
        XCTAssertEqual(unkeyed.keyStatusText, "No key")
        XCTAssertEqual(unkeyed.keySourceBadge, "self-hosted")
        XCTAssertEqual(unkeyed.modelCountText, "No models listed")
        XCTAssertNil(unkeyed.authErrorText)
    }
}

final class PersonalityAutocompleteTests: XCTestCase {
    func testSlashAutocompleteNamesPrependsNoneAndDeduplicates() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            PersonalitiesResponse.self,
            from: Data("""
            {
              "personalities": [
                {"name": "mentor", "description": "Patient technical coach"},
                {"name": "none", "description": "Should not duplicate the clear option"},
                {"name": "critic"},
                {"name": "   "}
              ]
            }
            """.utf8)
        )

        XCTAssertEqual(response.slashAutocompleteNames, ["none", "mentor", "critic"])
    }
}
