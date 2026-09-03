import XCTest
@testable import HermesMobile

/// Pins the two rules the shared picker gained when Settings > Default Model
/// started using it: which row spins during a server save, and what the custom
/// entry commits under each configuration.
final class ModelPickerSheetTests: XCTestCase {
    private func option(_ id: String, provider: String?) -> ModelCatalogOption {
        ModelCatalogOption(id: id, displayName: id, providerID: provider)
    }

    // MARK: In-flight row

    func testInFlightRowMatchesTheSavingModelAndProvider() {
        let key = ModelFavoriteKey(modelID: "gpt-5", providerID: "openai")

        XCTAssertTrue(
            ModelPickerSheet.isInFlight(option("gpt-5", provider: "openai"), inFlightKey: key)
        )
    }

    func testInFlightRowIgnoresTheSameModelIDUnderAnotherProvider() {
        let key = ModelFavoriteKey(modelID: "gpt-5", providerID: "openai")

        XCTAssertFalse(
            ModelPickerSheet.isInFlight(option("gpt-5", provider: "azure"), inFlightKey: key)
        )
        XCTAssertFalse(
            ModelPickerSheet.isInFlight(option("gpt-5", provider: nil), inFlightKey: key)
        )
    }

    func testNoRowIsInFlightWithoutAKey() {
        XCTAssertFalse(
            ModelPickerSheet.isInFlight(option("gpt-5", provider: "openai"), inFlightKey: nil)
        )
    }

    // MARK: Search

    private var codexGroup: ModelCatalogGroup {
        ModelCatalogGroup(
            id: "openai-codex",
            name: "OpenAI Codex",
            providerID: "openai-codex",
            models: [option("gpt-5", provider: "openai-codex"), option("o3", provider: "openai-codex")]
        )
    }

    func testSearchingAGroupsDisplayNameKeepsAllOfItsModels() {
        // The header reads "OpenAI Codex" while the id is "openai-codex", so
        // matching ids alone would answer "no models" to the visible name.
        let filtered = ModelPickerSheet.filteredGroups([codexGroup], query: "OpenAI Codex")

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.allModels.count, 2)
    }

    func testSearchingAModelNameKeepsOnlyThatModel() {
        let filtered = ModelPickerSheet.filteredGroups([codexGroup], query: "o3")

        XCTAssertEqual(filtered.first?.allModels.map(\.id), ["o3"])
    }

    func testSearchingSomethingAbsentDropsTheGroup() {
        XCTAssertTrue(ModelPickerSheet.filteredGroups([codexGroup], query: "claude").isEmpty)
    }

    func testAnEmptyQueryKeepsEveryGroupUntouched() {
        XCTAssertEqual(ModelPickerSheet.filteredGroups([codexGroup], query: "   ").count, 1)
    }

    // MARK: Custom entry

    func testServerDefaultCommitsABareModelIDWithNoProvider() {
        let built = ModelPickerSheet.customOption(
            modelID: "  my-model  ",
            providerID: "  ",
            configuration: .serverDefault
        )

        XCTAssertEqual(built?.id, "my-model")
        XCTAssertNil(built?.providerID)
    }

    func testComposerRequiresAProviderForACustomModel() {
        XCTAssertNil(
            ModelPickerSheet.customOption(
                modelID: "my-model",
                providerID: "",
                configuration: .composer
            )
        )
    }

    func testCustomProviderIsLowercasedWhenSupplied() {
        let built = ModelPickerSheet.customOption(
            modelID: "my-model",
            providerID: "OpenAI",
            configuration: .serverDefault
        )

        XCTAssertEqual(built?.providerID, "openai")
    }

    func testEmptyModelIDNeverCommits() {
        for configuration in [ModelPickerConfiguration.composer, .serverDefault] {
            XCTAssertNil(
                ModelPickerSheet.customOption(
                    modelID: "   ",
                    providerID: "openai",
                    configuration: configuration
                )
            )
        }
    }
}
