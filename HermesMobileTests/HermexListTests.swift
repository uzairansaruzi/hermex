import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexList` (`HermexList.swift`): a default 12pt vertical scroll-content margin
/// using the existing `HermesSpacing.s12` token, while native SwiftUI List semantics (selection,
/// refresh, row insets, separators, swipe/context menus, keyboard/accessibility) stay untouched. A
/// SwiftUI view tree isn't inspectable at runtime without a rendering harness, so this is a
/// source-contract suite, matching the convention used by ListItemTests/HermexContentUnavailableTests.
final class HermexListTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    func testDefaultVerticalContentMarginUsesTheExistingS12Token() throws {
        let src = try source("HermesMobile/Features/Shared/HermexList.swift")
        XCTAssertTrue(
            src.contains(".contentMargins(.vertical, HermesSpacing.s12, for: .scrollContent)"),
            "expected HermexList to apply a default 12pt vertical scroll-content margin using HermesSpacing.s12"
        )
    }

    func testHermesSpacingS12Is12Points() {
        XCTAssertEqual(HermesSpacing.s12, 12)
    }

    func testCompiles() {
        let list = HermexList {
            Text("Row")
        }
        XCTAssertFalse(String(describing: type(of: list)).isEmpty)
    }

    // MARK: - `.compactOverlay` style (source contracts)
    //
    // `HermexPopoverMenu` composes `HermexList(style: .compactOverlay)`. These contracts pin the
    // `Style` API — a default `.standard` case that preserves current behavior, plus an explicit
    // `.compactOverlay` case with plain/transparent chrome, hidden separators, and a minimum
    // accessible row height — matching the source-contract convention above.

    func testDefaultInitializerRetainsStandardStyle() throws {
        let src = try source("HermesMobile/Features/Shared/HermexList.swift")
        XCTAssertTrue(
            src.contains("enum Style"),
            "expected HermexList to expose a Style enum"
        )
        XCTAssertTrue(
            src.contains("style: Style = .standard"),
            "expected the initializer to default to .standard so existing callers are unaffected"
        )
    }

    func testCompactOverlayStyleIsExplicitlyAvailable() throws {
        let src = try source("HermesMobile/Features/Shared/HermexList.swift")
        XCTAssertTrue(
            src.contains("case compactOverlay"),
            "expected an explicit .compactOverlay case for overlay-hosted lists such as HermexPopoverMenu"
        )
    }

    func testCompactOverlayUsesPlainTransparentContainerAndHiddenSeparators() throws {
        let src = try source("HermesMobile/Features/Shared/HermexList.swift")
        XCTAssertTrue(src.contains(".listStyle(.plain)"), "expected the compact overlay branch to use a plain list style")
        XCTAssertTrue(src.contains(".scrollContentBackground(.hidden)"), "expected the compact overlay branch to hide native list chrome so the overlay's own material shows through")
        XCTAssertTrue(src.contains(".listRowSeparator(.hidden)"), "expected the compact overlay branch to hide row separators")
    }

    func testCompactOverlayKeepsMinimumAccessibleRowHeight() throws {
        let src = try source("HermesMobile/Features/Shared/HermexList.swift")
        XCTAssertTrue(
            src.contains("44"),
            "expected the compact overlay branch to preserve at least a 44pt minimum accessible row height"
        )
    }

    func testCompactOverlayRowsDoNotCoverTheOwningGlassSurface() throws {
        let src = try source("HermesMobile/Features/Shared/HermexList.swift")
        let compactBranch = try XCTUnwrap(src.components(separatedBy: "case .compactOverlay:").last)
        XCTAssertTrue(compactBranch.contains(".listRowBackground(Color.clear)"),
                      "native row backgrounds must not cover the menu's adaptive glass or opaque fallback")
    }

    func testStandardStyleSourceContractIsUnchanged() throws {
        let src = try source("HermesMobile/Features/Shared/HermexList.swift")
        XCTAssertTrue(src.contains("case .standard:"), "expected an explicit .standard branch once the Style enum is introduced")
        let standardBranch = src.components(separatedBy: "case .standard:").last ?? ""
        XCTAssertTrue(
            standardBranch.contains(".contentMargins(.vertical, HermesSpacing.s12, for: .scrollContent)"),
            "expected the .standard branch to preserve the existing 12pt vertical scroll-content margin byte-for-byte"
        )
    }

    // MARK: - `.compactOverlay` insets go to zero (Issue #607, Round 3, Task 3)
    //
    // `HermexPopoverMenu` now owns its own shell padding around the list content (see
    // `HermexPopoverMenuTests`), so `.compactOverlay`'s own row horizontal inset and scroll-content
    // margin collapse to zero. The vertical row inset and the 44pt minimum accessible row height are
    // unrelated to that shell padding and stay exactly as they are.

    func testCompactOverlayRowHorizontalInsetBecomesZero() {
        XCTAssertEqual(HermexListCompactOverlayMetrics.rowHorizontalInset, HermesSpacing.s0)
    }

    func testCompactOverlayScrollContentMarginBecomesZero() {
        XCTAssertEqual(HermexListCompactOverlayMetrics.scrollContentMargin, HermesSpacing.s0)
    }

    func testCompactOverlayVerticalRowInsetAndMinimumRowHeightStayUnchanged() {
        XCTAssertEqual(HermexListCompactOverlayMetrics.rowVerticalInset, HermesSpacing.s4)
        XCTAssertEqual(HermexListCompactOverlayMetrics.minimumRowHeight, 44)
    }
}
