import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for the Content Unavailable pattern (`HermexContentUnavailable.swift`): its loading,
/// empty, error, unavailable, custom, and no-results variants, and the two-action vertical stack
/// ordering. A SwiftUI view tree isn't inspectable at runtime without a rendering harness, so the
/// stack ordering is a source contract read from `HermexContentUnavailable.swift` itself; every
/// variant builds without error as a compile contract.
final class HermexContentUnavailableTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    // MARK: - Compile contracts

    func testEveryVariantCompiles() {
        let loading = HermexContentUnavailable(variant: .loading, description: Text("Loading models..."))
        let empty = HermexContentUnavailable(variant: .empty, title: "No skills available", systemImage: "wand.and.stars")
        let error = HermexContentUnavailable(
            variant: .error,
            title: "Could Not Load Profiles",
            description: Text("network error"),
            primaryAction: .init(title: "Try Again", handler: {})
        )
        let unavailable = HermexContentUnavailable(variant: .unavailable, title: "Unavailable")
        let custom = HermexContentUnavailable(variant: .custom, title: "Custom", description: Text("detail"))
        let noResults = HermexContentUnavailable(
            variant: .noResults,
            title: "No matching Cards",
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text("Change or clear the filters to see more Cards.")
        )

        for view in [
            String(describing: type(of: loading)),
            String(describing: type(of: empty)),
            String(describing: type(of: error)),
            String(describing: type(of: unavailable)),
            String(describing: type(of: custom)),
            String(describing: type(of: noResults))
        ] {
            XCTAssertFalse(view.isEmpty)
        }
    }

    // MARK: - Two-action vertical stack, primary first

    func testOnlyOneActionPreservesTheEstablishedSecondaryEmphasis() {
        XCTAssertEqual(
            HermexContentUnavailable.primaryActionEmphasis(hasSecondaryAction: false),
            .secondary
        )
    }

    func testBothActionsGiveThePrimaryActionTheEstablishedPrimaryHierarchy() {
        XCTAssertEqual(
            HermexContentUnavailable.primaryActionEmphasis(hasSecondaryAction: true),
            .primary
        )
    }

    func testBothActionsCompile() {
        let view = HermexContentUnavailable(
            variant: .error,
            title: "Could Not Load",
            description: Text("network error"),
            primaryAction: .init(title: "Try Again", handler: {}),
            secondaryAction: .init(title: "Cancel", handler: {})
        )
        XCTAssertFalse(String(describing: type(of: view)).isEmpty)
    }

    func testBothActionsRenderAsAVerticalStackWithThePrimaryActionFirst() throws {
        let src = try source("HermesMobile/Features/Shared/HermexContentUnavailable.swift")
        guard let vstackRange = src.range(of: "VStack"),
              let primaryRange = src.range(of: "primaryAction.title, action: primaryAction.handler"),
              let secondaryRange = src.range(of: "secondaryAction.title, action: secondaryAction.handler") else {
            return XCTFail("Expected a VStack wrapping the primary action ahead of the secondary action")
        }
        XCTAssertTrue(vstackRange.lowerBound < primaryRange.lowerBound)
        XCTAssertTrue(primaryRange.lowerBound < secondaryRange.lowerBound)
    }

    // MARK: - Explicit full-screen placement (Layout)

    /// Every existing caller (this file's own `testEveryVariantCompiles`, and every production/catalog
    /// call site) constructs `HermexContentUnavailable` with no `layout:` argument at all — the new
    /// property must default to `.intrinsic` so none of them change behavior.
    func testDefaultLayoutIsIntrinsicPreservingEveryExistingCaller() {
        let view = HermexContentUnavailable(variant: .empty, title: "Empty")
        XCTAssertEqual(view.layout, .intrinsic)
    }

    func testFullScreenLayoutIsExplicitlySelectable() {
        let view = HermexContentUnavailable(variant: .unavailable, title: "Unavailable", layout: .fullScreen)
        XCTAssertEqual(view.layout, .fullScreen)
    }

    /// A SwiftUI view tree isn't inspectable at runtime without a rendering harness (see this file's
    /// own header note), so — same convention as `testBothActionsRenderAsAVerticalStackWithThePrimaryActionFirst`
    /// above — the one-third-of-container-height placement is a source contract: `.fullScreen` reads
    /// the available height via `GeometryReader` and offsets content by a `/ 3` fraction of it, rather
    /// than falling through to `ContentUnavailableView`'s own default centering.
    func testFullScreenLayoutPositionsContentAtOneThirdOfContainerHeightInsteadOfCentering() throws {
        let src = try source("HermesMobile/Features/Shared/HermexContentUnavailable.swift")
        guard let fullScreenCaseRange = src.range(of: "case .fullScreen"),
              let geometryRange = src.range(of: "GeometryReader"),
              let thirdRange = src.range(of: "/ 3") else {
            return XCTFail("Expected the .fullScreen layout to read the container height via GeometryReader and offset content by roughly one third of it")
        }
        XCTAssertTrue(fullScreenCaseRange.lowerBound < geometryRange.lowerBound)
        XCTAssertTrue(geometryRange.lowerBound < thirdRange.lowerBound)
    }

    /// Dynamic Type and long content must stay readable rather than being clipped by a fixed offset —
    /// `.fullScreen` wraps its content in a `ScrollView` so it can grow downward instead.
    func testFullScreenLayoutScrollsInsteadOfClippingLongContent() throws {
        let src = try source("HermesMobile/Features/Shared/HermexContentUnavailable.swift")
        XCTAssertTrue(src.contains("ScrollView"), "Expected the .fullScreen layout to wrap its content in a ScrollView so long content/Dynamic Type can scroll instead of being clipped")
    }
}
