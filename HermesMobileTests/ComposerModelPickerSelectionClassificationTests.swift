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

    // PR #293 review: selecting an overflow model through search, then reopening
    // the picker with an empty query, must still classify it as NOT rendered so
    // the "Current Custom" row appears and shows the active selection.
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

    func testOverflowExpansionRevealsAndCollapsesExtraModels() {
        guard let group = groups.first else {
            return XCTFail("Expected an OpenRouter group")
        }
        var overflowExpansion = ModelPickerOverflowExpansionState()

        XCTAssertEqual(overflowExpansion.displayedModels(in: group), [visibleModel])

        overflowExpansion.setExpanded(true, groupID: group.id)
        XCTAssertEqual(
            overflowExpansion.displayedModels(in: group),
            [visibleModel, overflowModel]
        )

        overflowExpansion.setExpanded(false, groupID: group.id)
        XCTAssertEqual(overflowExpansion.displayedModels(in: group), [visibleModel])
    }

    // While searching, allModels are rendered — an overflow match found by that
    // search IS represented and must not duplicate a Current Custom row.
    func testOverflowMatchWhileSearchingIsRendered() {
        let rendered = ModelPickerSheet.isRenderedByCurrentPicker(
            option: overflowModel,
            modelGroups: groups,
            searchQuery: "deepseek"
        )

        XCTAssertTrue(rendered)
    }

    func testVisibleMatchWhileSearchingIsRendered() {
        let rendered = ModelPickerSheet.isRenderedByCurrentPicker(
            option: visibleModel,
            modelGroups: groups,
            searchQuery: "claude"
        )

        XCTAssertTrue(rendered)
    }

    // Provider-aware: same bare ID under another provider is not the same row.
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
}
