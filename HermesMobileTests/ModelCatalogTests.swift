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

    func testAllModelsMergesModelsAndExtraModelsDeduplicatedByID() {
        let group = ModelCatalogGroup(
            id: "nous",
            name: "Nous",
            providerID: "nous",
            models: [
                ModelCatalogOption(id: "@nous:alpha", displayName: "Alpha", providerID: "nous"),
                ModelCatalogOption(id: "@nous:shared", displayName: "Shared (featured)", providerID: "nous")
            ],
            extraModels: [
                ModelCatalogOption(id: "@nous:shared", displayName: "Shared (extra)", providerID: "nous"),
                ModelCatalogOption(id: "@nous:beta", displayName: "Beta", providerID: "nous")
            ]
        )

        // Deduplicated by id, order preserved (models first); the featured copy
        // wins when an id appears in both lists.
        XCTAssertEqual(
            group.allModels.map(\.id),
            ["@nous:alpha", "@nous:shared", "@nous:beta"]
        )
        XCTAssertEqual(
            group.allModels.first { $0.id == "@nous:shared" }?.displayName,
            "Shared (featured)"
        )
        XCTAssertEqual(group.allModels.count, 3)
        XCTAssertEqual(group.slashAutocompleteModels, group.allModels)
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
