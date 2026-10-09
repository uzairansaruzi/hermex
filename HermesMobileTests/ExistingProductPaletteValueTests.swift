import XCTest
@testable import HermesMobile

final class ExistingProductPaletteValueTests: XCTestCase {
    func testHeaderPresetsCurrentValues() {
        let expected = ["#FFD700", "#5B7CFF", "#AF52DE", "#FF3B30", "#34C759", "#FFFFFF"]
        XCTAssertEqual(HeaderLogoColor.presets.map(\.hex), expected)
    }

    func testHeaderDefaultHexCurrentValue() {
        XCTAssertEqual(HeaderLogoColor.defaultHex, "#FFD700")
    }

    func testProjectApprovedColorsCurrentValues() {
        let expected = ["#7cb9ff", "#f5c542", "#e94560", "#50c878", "#c084fc", "#fb923c", "#67e8f9", "#f472b6"]
        XCTAssertEqual(ProjectCreationPalette.approvedColors.map(\.hex), expected)
    }
}
