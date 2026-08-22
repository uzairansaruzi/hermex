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
    /// another provider can never be picked in its place. The bare row comes
    /// first on purpose: with `[prefixed, exact]` ordering the prefixed row
    /// rejects a bare selection, so deleting the exact-first branch still
    /// returned "Bare" and proved nothing.
    func testFirstMatchingSelectionPrefersTheExactSpelling() {
        let options = [
            ModelCatalogOption(id: "flash", displayName: "Bare", providerID: "gemini"),
            ModelCatalogOption(id: "@gemini:flash", displayName: "Prefixed", providerID: "gemini")
        ]

        XCTAssertEqual(options.firstMatchingSelection(modelID: "flash", providerID: nil)?.displayName, "Bare")
        XCTAssertEqual(
            options.firstMatchingSelection(modelID: "@gemini:flash", providerID: nil)?.displayName,
            "Prefixed"
        )
    }

    /// Ollama and OpenRouter model ids carry their own colons
    /// (`qwen3:32b`, `...:free`). Prefix parsing splits on the FINAL
    /// separator, so an id like `@ollama:qwen3:32b` is genuinely ambiguous —
    /// the row's own `provider_id` anchors the match, and the provider named
    /// on either side must still agree.
    func testModelSelectionHandlesColonBearingModelIDs() {
        // A bare id's trailing colons belong to the model: nothing to strip.
        XCTAssertEqual("deepseek/deepseek-chat-v3:free".bareModelID, "deepseek/deepseek-chat-v3:free")
        XCTAssertNil("deepseek/deepseek-chat-v3:free".modelIDProviderPrefix)

        let ollama = ModelCatalogOption(id: "@ollama:qwen3:32b", displayName: "Qwen3 32B", providerID: "ollama")
        XCTAssertTrue(ollama.matchesSelection(modelID: "@ollama:qwen3:32b", providerID: nil))

        let openrouter = ModelCatalogOption(
            id: "@openrouter:deepseek/deepseek-chat-v3:free",
            displayName: "DeepSeek Chat v3",
            providerID: "openrouter"
        )
        // The exact prefixed spelling matches itself...
        XCTAssertTrue(openrouter.matchesSelection(
            modelID: "@openrouter:deepseek/deepseek-chat-v3:free",
            providerID: nil
        ))
        // ...and an active provider's bare row keeps matching its own bare
        // spelling: both sides normalize through the same final-colon split,
        // so a `:free` tail survives the symmetric comparison.
        let bareOpenRouter = ModelCatalogOption(
            id: "deepseek/deepseek-chat-v3:free",
            displayName: "DeepSeek Chat v3",
            providerID: "openrouter"
        )
        XCTAssertTrue(bareOpenRouter.matchesSelection(modelID: "deepseek/deepseek-chat-v3:free", providerID: "openrouter"))

        // Cross-provider tails stay rejected even when both carry colons.
        XCTAssertFalse(bareOpenRouter.matchesSelection(modelID: "deepseek/deepseek-chat-v3:free", providerID: "ollama"))
        XCTAssertFalse(openrouter.matchesSelection(modelID: "deepseek/deepseek-chat-v3:free", providerID: "ollama"))
        let ollamaLookAlike = ModelCatalogOption(id: "@ollama:deepseek/deepseek-chat-v3:free", displayName: "Look-alike", providerID: "ollama")
        XCTAssertFalse(ollamaLookAlike.matchesSelection(modelID: "@openrouter:deepseek/deepseek-chat-v3:free", providerID: nil))

        // `lastIndex(of: ":")` cannot tell `@provider:model:tag` apart from
        // a named-custom-provider spelling at the string level, so the row's
        // own provider_id anchors the comparison: anchored, both spellings
        // still meet...
        XCTAssertTrue(ollama.matchesSelection(modelID: "qwen3:32b", providerID: "ollama"))
        // ...while a bare selection that names no provider stays the ACTIVE
        // provider's spelling and must not tick a prefixed row.
        XCTAssertFalse(ollama.matchesSelection(modelID: "qwen3:32b", providerID: nil))
    }

    /// Core's catalog dedup can prefix the ACTIVE provider's own rows when an
    /// inactive provider lists the same bare id first, so a stored bare default
    /// matched without naming the active provider ticks the inactive row and
    /// leaves the real default unticked. Matching against `activeProvider`
    /// (the picker now passes it) resolves both directions.
    func testBareDefaultMatchedAgainstActiveProviderRejectsTheInactiveLookAlike() {
        let activeRow = ModelCatalogOption(id: "@gemini:mymodel", displayName: "Prefixed", providerID: "gemini")
        let inactiveRow = ModelCatalogOption(id: "mymodel", displayName: "Bare look-alike", providerID: "deepseek")

        XCTAssertTrue(activeRow.matchesSelection(modelID: "mymodel", providerID: "gemini"))
        XCTAssertFalse(inactiveRow.matchesSelection(modelID: "mymodel", providerID: "gemini"))
        // An embedded @provider: spelling keeps naming its own provider even
        // when another one is active.
        XCTAssertTrue(activeRow.matchesSelection(modelID: "@gemini:mymodel", providerID: nil))
        XCTAssertFalse(inactiveRow.matchesSelection(modelID: "@gemini:mymodel", providerID: nil))
    }

    /// Picker-boundary: decoded `(defaultModel, activeProvider)` must tick the
    /// active provider's dedup-prefixed row and leave the inactive bare
    /// look-alike unchecked. Passing `providerID: nil` (the pre-#284
    /// `isCurrentDefault`) fails this case.
    func testPickerCheckmarkResolvesTheActiveProvidersDedupPrefixedRow() {
        let prefixedActive = ModelCatalogOption(id: "@gemini:mymodel", displayName: "Prefixed", providerID: "gemini")
        let inactiveBare = ModelCatalogOption(id: "mymodel", displayName: "Bare look-alike", providerID: "deepseek")

        XCTAssertTrue(
            DefaultModelPickerView.isChecked(
                prefixedActive,
                selectedModel: nil,
                selectedProvider: nil,
                defaultModel: "mymodel",
                activeProvider: "gemini"
            )
        )
        XCTAssertFalse(
            DefaultModelPickerView.isChecked(
                inactiveBare,
                selectedModel: nil,
                selectedProvider: nil,
                defaultModel: "mymodel",
                activeProvider: "gemini"
            )
        )
    }

    /// An embedded `@provider:` spelling names its own provider and must win
    /// over the currently active one. Passing `activeProvider` blindly
    /// (without consulting the stored spelling) ticks the OpenAI look-alike.
    func testPickerCheckmarkKeepsAnEmbeddedPrefixAuthoritative() {
        let openAIRow = ModelCatalogOption(id: "mymodel", displayName: "OpenAI look-alike", providerID: "openai")
        let geminiRow = ModelCatalogOption(id: "@gemini:mymodel", displayName: "Gemini", providerID: "gemini")

        XCTAssertFalse(
            DefaultModelPickerView.isChecked(
                openAIRow,
                selectedModel: nil,
                selectedProvider: nil,
                defaultModel: "@gemini:mymodel",
                activeProvider: "openai"
            )
        )
        XCTAssertTrue(
            DefaultModelPickerView.isChecked(
                geminiRow,
                selectedModel: nil,
                selectedProvider: nil,
                defaultModel: "@gemini:mymodel",
                activeProvider: "openai"
            )
        )
    }

    /// A tap records the row's provider. The previous stored default must not
    /// stay checkmarked / Selected while the save is in flight.
    func testPickerInFlightSelectionTicksOnlyTheTappedProviderRow() {
        let tapped = ModelCatalogOption(id: "mymodel", displayName: "DeepSeek", providerID: "deepseek")
        let previousDefault = ModelCatalogOption(id: "gpt-5.6-luna", displayName: "Luna", providerID: "openai")

        XCTAssertTrue(
            DefaultModelPickerView.isChecked(
                tapped,
                selectedModel: "mymodel",
                selectedProvider: "deepseek",
                defaultModel: "gpt-5.6-luna",
                activeProvider: "openai"
            )
        )
        XCTAssertFalse(
            DefaultModelPickerView.isChecked(
                previousDefault,
                selectedModel: "mymodel",
                selectedProvider: "deepseek",
                defaultModel: "gpt-5.6-luna",
                activeProvider: "openai"
            )
        )
    }

    /// A stored `@ollama:qwen3:32b` default must tick the Ollama row. Pre-parsing
    /// the stored spelling with `lastIndex(of: ":")` produces provider
    /// `ollama:qwen3` and leaves the row unchecked.
    func testPickerCheckmarkHandlesPrefixedColonBearingDefault() {
        let ollama = ModelCatalogOption(id: "@ollama:qwen3:32b", displayName: "Qwen3 32B", providerID: "ollama")
        let other = ModelCatalogOption(id: "qwen3:32b", displayName: "Look-alike", providerID: "openai")

        XCTAssertTrue(
            DefaultModelPickerView.isChecked(
                ollama,
                selectedModel: nil,
                selectedProvider: nil,
                defaultModel: "@ollama:qwen3:32b",
                activeProvider: "openai"
            )
        )
        XCTAssertFalse(
            DefaultModelPickerView.isChecked(
                other,
                selectedModel: nil,
                selectedProvider: nil,
                defaultModel: "@ollama:qwen3:32b",
                activeProvider: "openai"
            )
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
