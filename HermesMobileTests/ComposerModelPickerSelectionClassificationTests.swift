import XCTest
@testable import HermesMobile

final class ComposerModelPickerSelectionClassificationTests: XCTestCase {
    private let visibleModel = ModelCatalogOption(
        id: "anthropic/claude-fable-5",
        displayName: "Claude Fable 5",
        providerID: "openrouter"
    )
    private let overflowModel = ModelCatalogOption(
        id: "deepseek/deepseek-v4-pro",
        displayName: "deepseek/deepseek-v4-pro",
        providerID: "openrouter"
    )

    private var groups: [ModelCatalogGroup] {
        [
            ModelCatalogGroup(
                id: "openrouter",
                name: "OpenRouter",
                providerID: "openrouter",
                models: [visibleModel],
                extraModels: [overflowModel]
            )
        ]
    }

    func testOverflowSelectionWithEmptyQueryIsNotRendered() {
        let rendered = ModelPickerSheet.isRenderedByCurrentPicker(
            option: overflowModel,
            modelGroups: groups,
            searchQuery: ""
        )

        XCTAssertFalse(
            rendered,
            "overflow model is invisible in the trimmed empty-query view; the Current Custom row must represent it"
        )
    }

    func testVisibleModelWithEmptyQueryIsRendered() {
        let rendered = ModelPickerSheet.isRenderedByCurrentPicker(
            option: visibleModel,
            modelGroups: groups,
            searchQuery: ""
        )

        XCTAssertTrue(rendered)
    }

    func testOverflowSelectionWithExpandedGroupIsRendered() {
        var overflowExpansion = ModelPickerOverflowExpansionState()
        overflowExpansion.setExpanded(true, groupID: "openrouter")

        let rendered = ModelPickerSheet.isRenderedByCurrentPicker(
            option: overflowModel,
            modelGroups: groups,
            searchQuery: "",
            overflowExpansion: overflowExpansion
        )

        XCTAssertTrue(rendered)
    }

    func testOverflowMatchWhileSearchingIsRendered() {
        let rendered = ModelPickerSheet.isRenderedByCurrentPicker(
            option: overflowModel,
            modelGroups: groups,
            searchQuery: "deepseek"
        )

        XCTAssertTrue(rendered)
    }

    func testSameIDUnderDifferentProviderIsNotRendered() {
        let otherProvider = ModelCatalogOption(
            id: overflowModel.id,
            displayName: overflowModel.displayName,
            providerID: "nous"
        )

        let rendered = ModelPickerSheet.isRenderedByCurrentPicker(
            option: otherProvider,
            modelGroups: groups,
            searchQuery: ""
        )

        XCTAssertFalse(rendered)
    }

    func testSingleEffortBecomesStaticAndIsCommitted() {
        let selection = ComposerModelEffortSelection(
            model: ModelCatalogOption(id: "o4-mini", displayName: "o4-mini", providerID: "openai"),
            effort: "xhigh",
            supportedEfforts: ["high"],
            supportsEffort: true
        )

        XCTAssertEqual(selection.staticEffort?.id, "high")
        XCTAssertEqual(selection.committedEffort, "high")
    }
}
