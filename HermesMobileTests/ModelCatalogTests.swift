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
    /// The server prefixes every model of a non-active provider with
    /// `@provider:`, so the same model is spelled two different ways depending
    /// on which provider is active. Comparing raw ids left the picker unable to
    /// mark the current default at all. Confirmed against the live
    /// deployment: `openai-codex` is active and its ids are bare, while
    /// `@deepseek:` and `@gemini:` ones carry the prefix.
    func testModelSelectionMatchesAcrossTheProviderPrefix() {
        let prefixed = ModelCatalogOption(
            id: "@gemini:gemini-3.5-flash",
            displayName: "Gemini 3.5 Flash",
            providerID: "gemini"
        )

        XCTAssertTrue(prefixed.matchesSelection(modelID: "@gemini:gemini-3.5-flash", providerID: nil))
        XCTAssertTrue(prefixed.matchesSelection(modelID: "gemini-3.5-flash", providerID: "gemini"))
        XCTAssertFalse(
            prefixed.matchesSelection(modelID: "gemini-3.5-flash", providerID: nil),
            "A bare selection belongs to the active provider, whose models are the unprefixed ones."
        )

        let bare = ModelCatalogOption(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", providerID: "gemini")
        XCTAssertTrue(bare.matchesSelection(modelID: "@gemini:gemini-3.5-flash", providerID: nil))
    }

    /// Normalizing must not merge two providers that offer the same bare id.
    /// The live deployment really does list `@gemini:gemini-2.5-flash` and
    /// `@google:gemini-2.5-flash` side by side, and an earlier version of this
    /// fix ticked both.
    func testModelSelectionStillSeparatesProvidersSharingABareID() {
        let other = ModelCatalogOption(
            id: "@deepseek:gemini-3.5-flash",
            displayName: "Look-alike",
            providerID: "deepseek"
        )

        XCTAssertFalse(other.matchesSelection(modelID: "@gemini:gemini-3.5-flash", providerID: nil))
        XCTAssertFalse(other.matchesSelection(modelID: "gemini-3.5-flash", providerID: "gemini"))

        // A bare selection is the ACTIVE provider's spelling — the prefix is
        // precisely what the server adds to everyone else — so it must not tick
        // a prefixed look-alike.
        let prefixedLookAlike = ModelCatalogOption(
            id: "@google:gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            providerID: "google"
        )
        let activeProviderOption = ModelCatalogOption(
            id: "gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            providerID: "gemini"
        )

        XCTAssertFalse(prefixedLookAlike.matchesSelection(modelID: "gemini-2.5-flash", providerID: nil))

        // The mirror direction: an option carrying no provider at all cannot be
        // shown to belong to a named one either. Guessing "yes" here would be
        // the same bug pointed the other way.
        let providerlessOption = ModelCatalogOption(
            id: "gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            providerID: nil
        )
        XCTAssertFalse(providerlessOption.matchesSelection(modelID: "gemini-2.5-flash", providerID: "gemini"))
        XCTAssertFalse(providerlessOption.matchesSelection(modelID: "@gemini:gemini-2.5-flash", providerID: nil))
        XCTAssertTrue(
            providerlessOption.matchesSelection(modelID: "gemini-2.5-flash", providerID: nil),
            "Neither side naming a provider is still a match."
        )
        XCTAssertTrue(activeProviderOption.matchesSelection(modelID: "gemini-2.5-flash", providerID: nil))
        XCTAssertTrue(
            activeProviderOption.matchesSelection(modelID: "@gemini:gemini-2.5-flash", providerID: nil),
            "Saving through the app leaves the prefixed spelling while the server stores the bare one."
        )
    }

    /// An exact spelling wins over a normalized one so a same-named model from
    /// another provider can never be picked in its place.
    func testFirstMatchingSelectionPrefersTheExactSpelling() {
        let options = [
            ModelCatalogOption(id: "@gemini:flash", displayName: "Prefixed", providerID: "gemini"),
            ModelCatalogOption(id: "flash", displayName: "Bare", providerID: "gemini")
        ]

        XCTAssertEqual(options.firstMatchingSelection(modelID: "flash", providerID: nil)?.displayName, "Bare")
        XCTAssertEqual(
            options.firstMatchingSelection(modelID: "@gemini:flash", providerID: nil)?.displayName,
            "Prefixed"
        )
    }

    func testModelSelectionPreservesNamedCustomProviderIdentity() {
        let beta = ModelCatalogOption(
            id: "@custom:beta:model-a",
            displayName: "Beta Model A",
            providerID: "custom:beta"
        )
        let gamma = ModelCatalogOption(
            id: "@custom:gamma:model-a",
            displayName: "Gamma Model A",
            providerID: "custom:gamma"
        )

        XCTAssertEqual("@custom:beta:model-a".bareModelID, "model-a")
        XCTAssertEqual("@custom:beta:model-a".modelIDProviderPrefix, "custom:beta")
        XCTAssertTrue(beta.matchesSelection(modelID: "@custom:beta:model-a", providerID: nil))
        XCTAssertTrue(beta.matchesSelection(modelID: "model-a", providerID: "custom:beta"))
        XCTAssertFalse(gamma.matchesSelection(modelID: "@custom:beta:model-a", providerID: nil))
        XCTAssertFalse(gamma.matchesSelection(modelID: "model-a", providerID: "custom:beta"))
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
