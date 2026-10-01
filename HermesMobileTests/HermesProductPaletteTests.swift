import XCTest
@testable import HermesMobile

final class HermesProductPaletteTests: XCTestCase {
    func testHermesProductPaletteConstantsMatchApprovedValues() {
        XCTAssertEqual(HermesProductPalette.headerAccentYellow, "#FFD700")
        XCTAssertEqual(HermesProductPalette.headerAccentBlue, "#5B7CFF")
        XCTAssertEqual(HermesProductPalette.headerAccentPurple, "#AF52DE")
        XCTAssertEqual(HermesProductPalette.headerAccentRed, "#FF3B30")
        XCTAssertEqual(HermesProductPalette.headerAccentGreen, "#34C759")
        XCTAssertEqual(HermesProductPalette.headerAccentWhite, "#FFFFFF")
        XCTAssertEqual(HermesProductPalette.projectSky, "#7cb9ff")
        XCTAssertEqual(HermesProductPalette.projectGold, "#f5c542")
        XCTAssertEqual(HermesProductPalette.projectRed, "#e94560")
        XCTAssertEqual(HermesProductPalette.projectGreen, "#50c878")
        XCTAssertEqual(HermesProductPalette.projectViolet, "#c084fc")
        XCTAssertEqual(HermesProductPalette.projectOrange, "#fb923c")
        XCTAssertEqual(HermesProductPalette.projectCyan, "#67e8f9")
        XCTAssertEqual(HermesProductPalette.projectPink, "#f472b6")
    }

    func testHeaderRampAliasesEqualRampAnchorsExactly() {
        XCTAssertEqual(HermesProductPalette.headerAccentYellow, HermesColorRamp.Gold.s500.hex)
        XCTAssertEqual(HermesProductPalette.headerAccentBlue, HermesColorRamp.Blue.s500.hex)
        XCTAssertEqual(HermesProductPalette.headerAccentPurple, HermesColorRamp.Purple.s500.hex)
        XCTAssertEqual(HermesProductPalette.headerAccentRed, HermesColorRamp.Red.s500.hex)
        XCTAssertEqual(HermesProductPalette.headerAccentGreen, HermesColorRamp.Green.s500.hex)
    }

    func testProjectRampAliasesMatchRampAnchorsCaseInsensitively() {
        XCTAssertEqual(HermesProductPalette.projectOrange.uppercased(), HermesColorRamp.Orange.s500.hex)
        XCTAssertEqual(HermesProductPalette.projectCyan.uppercased(), HermesColorRamp.Cyan.s500.hex)
        XCTAssertEqual(HermesProductPalette.projectPink.uppercased(), HermesColorRamp.Pink.s500.hex)
    }

    func testHeaderPresetsUnchangedAfterRefactor() {
        let expected = ["#FFD700", "#5B7CFF", "#AF52DE", "#FF3B30", "#34C759", "#FFFFFF"]
        XCTAssertEqual(HeaderLogoColor.presets.map(\.hex), expected)
    }

    func testHeaderDefaultHexUnchangedAfterRefactor() {
        XCTAssertEqual(HeaderLogoColor.defaultHex, "#FFD700")
    }

    func testProjectApprovedColorsUnchangedAfterRefactor() {
        let expected = ["#7cb9ff", "#f5c542", "#e94560", "#50c878", "#c084fc", "#fb923c", "#67e8f9", "#f472b6"]
        XCTAssertEqual(ProjectCreationPalette.approvedColors.map(\.hex), expected)
    }
}
