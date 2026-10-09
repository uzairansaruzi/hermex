import XCTest
import SwiftUI
@testable import HermesMobile

final class TopNavTests: XCTestCase {
    /// Compiling this file at all is the contract: `TopNav` must satisfy `ToolbarContentBuilder`'s
    /// `buildExpression` as a first-class `ToolbarContent` value, exactly like `ToolbarItem` and
    /// `ToolbarItemGroup`, with distinct leading/center/trailing builder slots.
    func testTopNavComposesIntoAToolbarContentBuilderWithLeadingCenterAndTrailingSlots() {
        struct Host: View {
            var body: some View {
                Text("Screen")
                    .toolbar {
                        TopNav(
                            leadingPrimary: { Button("Back") {} },
                            leadingSecondary: { Button("More") {} },
                            center: { Text("Title") },
                            trailingPrimary: { Button("Done") {} },
                            trailingSecondary: { Button("Info") {} }
                        )
                    }
            }
        }
        _ = Host()
        XCTAssertTrue(true)
    }

    // `ToolbarItemPlacement` does not conform to `Equatable`, so these compare its
    // `CustomStringConvertible` description rather than the value directly.
    func testDefaultPlacementsAreTopBarLeadingAndTopBarTrailing() {
        let nav = TopNav(trailingPrimary: { Text("Done") })

        XCTAssertEqual(String(describing: nav.leadingPlacement), String(describing: ToolbarItemPlacement.topBarLeading))
        XCTAssertEqual(String(describing: nav.trailingPlacement), String(describing: ToolbarItemPlacement.topBarTrailing))
    }

    func testPlacementsAreOverridableForModalAndEditorSemantics() {
        let nav = TopNav(
            leadingPlacement: .cancellationAction,
            trailingPlacement: .confirmationAction,
            leadingPrimary: { Text("Cancel") },
            trailingPrimary: { Text("Save") }
        )

        XCTAssertEqual(String(describing: nav.leadingPlacement), String(describing: ToolbarItemPlacement.cancellationAction))
        XCTAssertEqual(String(describing: nav.trailingPlacement), String(describing: ToolbarItemPlacement.confirmationAction))
    }

    func testPlacementAcceptsADynamicToolbarItemPlacementValue() {
        let dynamicPlacement: ToolbarItemPlacement = .cancellationAction
        let nav = TopNav(trailingPlacement: dynamicPlacement, trailingPrimary: { Text("Done") })

        XCTAssertEqual(String(describing: nav.trailingPlacement), String(describing: ToolbarItemPlacement.cancellationAction))
    }

    func testTrailingSpacerFlagDefaultsToFalseAndIsStoredWhenSet() {
        let defaultNav = TopNav(trailingPrimary: { Text("A") })
        XCTAssertFalse(defaultNav.trailingSpacer)

        let spacedNav = TopNav(
            trailingSpacer: true,
            trailingPrimary: { Text("A") },
            trailingSecondary: { Text("B") }
        )
        XCTAssertTrue(spacedNav.trailingSpacer)
    }

    // MARK: - Migration closure (issue #607)

    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testTopNavSourceDocumentsTheFiveSlotContract() throws {
        let topNavSource = try source("HermesMobile/Features/Shared/TopNav.swift")

        XCTAssertTrue(topNavSource.contains("leadingPrimary"))
        XCTAssertTrue(topNavSource.contains("leadingSecondary"))
        XCTAssertTrue(topNavSource.contains("var center"))
        XCTAssertTrue(topNavSource.contains("trailingPrimary"))
        XCTAssertTrue(topNavSource.contains("trailingSecondary"))
        XCTAssertTrue(topNavSource.contains(": ToolbarContent"))
    }

    func testActionStyleIsAppliedOnlyInsideGroupsAfterEmptySlotChecks() throws {
        let topNavSource = try source("HermesMobile/Features/Shared/TopNav.swift")
        XCTAssertTrue(topNavSource.contains("enum TopNavActionStyle"))
        XCTAssertTrue(topNavSource.contains("actionStyle: TopNavActionStyle = .native"))
        for slot in ["leadingPrimary", "leadingSecondary", "trailingPrimary", "trailingSecondary"] {
            XCTAssertTrue(topNavSource.contains("actionStyle.apply(to: \(slot)())"),
                          "expected the opt-in style to wrap \(slot) only inside its non-empty toolbar group")
        }
    }

    func testCompactAdaptiveGlassActionsPreserveTextLabelsIntrinsicWidth() throws {
        let topNavSource = try source("HermesMobile/Features/Shared/TopNav.swift")
        XCTAssertTrue(
            topNavSource.contains(".fixedSize(horizontal: true, vertical: false)"),
            "compact glass text actions such as Cancel and Done must not collapse into the toolbar overflow ellipsis"
        )
    }
}
