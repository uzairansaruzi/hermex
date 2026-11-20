import SwiftUI
import XCTest
@testable import HermesMobile

final class ModelPickerSheetTests: XCTestCase {
    private func option(_ id: String, provider: String?) -> ModelCatalogOption {
        ModelCatalogOption(id: id, displayName: id, providerID: provider)
    }

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

    private var codexGroup: ModelCatalogGroup {
        ModelCatalogGroup(
            id: "openai-codex",
            name: "OpenAI Codex",
            providerID: "openai-codex",
            models: [option("gpt-5", provider: "openai-codex"), option("o3", provider: "openai-codex")]
        )
    }

    func testSearchingAGroupsDisplayNameKeepsAllOfItsModels() {
        let filtered = ModelPickerSheet.filteredGroups([codexGroup], query: "OpenAI Codex")

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.allModels.count, 2)
    }

    func testSearchingAModelNameKeepsOnlyThatModel() {
        let filtered = ModelPickerSheet.filteredGroups([codexGroup], query: "o3")

        XCTAssertEqual(filtered.first?.allModels.map(\.id), ["o3"])
    }

    func testSearchFindsAModelByTheNameItsRowShows() {
        let model = option("zai/glm-5.3-flash:local", provider: "zai")
        let group = ModelCatalogGroup(id: "zai", name: "ZAI", providerID: "zai", models: [model])

        XCTAssertEqual(ModelPickerSheet.filteredGroups([group], query: "GLM 5.3").first?.allModels, [model])
        XCTAssertTrue(ModelPickerSheet.matches(model, query: "glm-5.3-flash"))
    }

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

    @MainActor
    func testExpandedGroupGivesEachModelItsOwnLazyListRow() async throws {
        let models = (1...400).map { option("m\($0)", provider: "openrouter") }
        let group = ModelCatalogGroup(id: "openrouter", name: "OpenRouter", providerID: "openrouter", models: models)
        let host = UIHostingController(
            rootView: ModelPickerSheet(
                configuration: .composer,
                modelGroups: [group],
                selectedModelID: "m1",
                selectedModelProviderID: "openrouter",
                isSelected: { $0.id == "m1" },
                onSelect: { _ in }
            )
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()

        let list = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UICollectionView }.first)
        list.layoutIfNeeded()
        let rowCount = (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }

        XCTAssertGreaterThanOrEqual(rowCount, 400, "every model is a List row of its own")
        XCTAssertLessThan(list.visibleCells.count, 50, "only the rows on screen are built")
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
