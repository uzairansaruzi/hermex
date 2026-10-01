import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexTooltip` (`HermexTooltip.swift`): an explicit-trigger, `.popover`-anchored
/// explanatory control — no hover-only dependency, Dynamic Type-safe content, and the native
/// dismiss/recovery path a `.popover` already provides. A SwiftUI view tree isn't inspectable at
/// runtime without a rendering harness, so this is a compile contract plus a source contract for the
/// native presentation path.
final class HermexTooltipTests: XCTestCase {
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

    @MainActor
    func testDefaultTriggerCompiles() {
        let tooltip = HermexTooltip.info {
            Text("Explanatory content")
        }
        XCTAssertFalse(String(describing: type(of: tooltip)).isEmpty)
    }

    @MainActor
    func testCustomTriggerCompiles() {
        let tooltip = HermexTooltip {
            Image(systemName: "questionmark.circle")
        } content: {
            Text("Explanatory content")
        }
        XCTAssertFalse(String(describing: type(of: tooltip)).isEmpty)
    }

    // MARK: - Source contracts: the native popover presentation path, no hover-only dependency

    func testUsesTheNativePopoverPresentationPath() throws {
        let src = try source("HermesMobile/Features/Shared/HermexTooltip.swift")
        XCTAssertTrue(src.contains(".popover("))
        XCTAssertFalse(src.contains(".onHover"), "Tooltip must not depend on hover as its only trigger")
    }

    func testTriggerIsAnExplicitTappableButton() throws {
        let src = try source("HermesMobile/Features/Shared/HermexTooltip.swift")
        XCTAssertTrue(src.contains("Button"))
    }

    func testContentIsDynamicTypeSafe() throws {
        let src = try source("HermesMobile/Features/Shared/HermexTooltip.swift")
        XCTAssertTrue(src.contains("fixedSize(horizontal: false, vertical: true)"))
    }

    // MARK: - Source contract: a 44x44pt minimum trigger tap target

    func testTriggerReservesA44x44MinimumTapTarget() throws {
        let src = try source("HermesMobile/Features/Shared/HermexTooltip.swift")
        XCTAssertTrue(
            src.contains("minWidth: 44, minHeight: 44"),
            "the tap trigger must reserve a 44x44pt minimum hit target, independent of the glyph's own visual size"
        )
    }

    func testInfoTriggerGlyphKeepsTheApprovedIconSizeScale() throws {
        let src = try source("HermesMobile/Features/Shared/HermexTooltip.swift")
        XCTAssertTrue(
            src.contains("HermesIconSize.small"),
            "the info trigger glyph must stay on the approved icon size scale, not grow to fill the 44pt tap target"
        )
    }
}
