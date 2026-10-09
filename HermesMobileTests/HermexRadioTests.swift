import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexRadio` (`HermexRadio.swift`): one-of-many selected state, disabled state,
/// native Button semantics, and DS sizing, mirroring `HermexCheckbox`'s established architecture with
/// a circular selected/unselected treatment instead of a boolean toggle. A SwiftUI view tree isn't
/// inspectable at runtime without a rendering harness, so this is a compile contract plus pure-value
/// and source contracts for its sizing and accessibility state.
final class HermexRadioTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    // MARK: - Pure contracts: DS sizing

    func testCircleSizeMatchesTheCheckboxBoxSizeForVisualRhythm() {
        XCTAssertEqual(HermexRadioMetrics.circleSize, HermexCheckboxMetrics.boxSize)
    }

    func testMinimumHitTargetMatchesTheEstablishedControlConvention() {
        XCTAssertEqual(HermexRadioMetrics.minimumHitTarget, 44)
    }

    // MARK: - Compile contracts: selected/unselected, enabled/disabled, interactive/indicator-only

    func testSelectedAndUnselectedCompile() {
        let selected = HermexRadio(isSelected: true, label: "Option A", action: {})
        let unselected = HermexRadio(isSelected: false, label: "Option B", action: {})
        XCTAssertFalse(String(describing: type(of: selected)).isEmpty)
        XCTAssertFalse(String(describing: type(of: unselected)).isEmpty)
    }

    func testDisabledAndIndicatorOnlyCompile() {
        let disabled = HermexRadio(isSelected: false, isEnabled: false, label: "Option C", action: {})
        let indicatorOnly = HermexRadio(isSelected: true, label: "Option D")
        XCTAssertFalse(String(describing: type(of: disabled)).isEmpty)
        XCTAssertFalse(String(describing: type(of: indicatorOnly)).isEmpty)
    }

    // MARK: - Source contract: selected accessibility state, native Button semantics

    func testUsesTheSelectedAccessibilityTraitRatherThanAToggleRepresentation() throws {
        let src = try source("HermesMobile/Features/Shared/HermexRadio.swift")
        XCTAssertTrue(src.contains(".isSelected"))
        XCTAssertTrue(src.contains("Button(action:"))
    }

    func testOverlayLabIncludesReachableSelectedAndUnselectedRadioFixtures() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(src.contains("--hermex-overlay-lab-batch-b"))
        XCTAssertTrue(src.contains("--hermex-overlay-lab-batch-b-controls"))
        XCTAssertTrue(src.contains("private struct HermexOverlayLabSelectionControlsFollowup"))
        XCTAssertTrue(src.contains("HermexOverlayLabBatchBSelectionControls.scrollAnchorID"))
        XCTAssertTrue(src.contains("HermexRadio(isSelected: false"))
        XCTAssertTrue(src.contains("HermexRadio(isSelected: true"))
    }

    // MARK: - DSF-08 (Batch B, corrected): HermexSelectionControlColors — replaces the Color.primary
    // contract
    //
    // Approved exact mapping (design-system-follow-up-plan.md, DSF-08/09, corrected per review),
    // shared with Checkbox:
    //   selected                    Neutral.adaptive(light: Neutral.s950, dark: Neutral.s50)
    //   selectedForeground (inverse) Neutral.adaptive(light: Neutral.s50, dark: Neutral.s950)
    //   unselectedBorder            Neutral.adaptive(light: Neutral.s500, dark: Neutral.s600)
    //
    // unselectedBorder's light anchor was originally Neutral.s400 (#AEAEB1); the review measured that
    // pairing at ~2.1:1 against the light primary surface, below the 3:1 non-text boundary threshold
    // (WCAG 1.4.11), and corrected it to Neutral.s500 (#8E8E93), which
    // testUnselectedBorderAndSelectedForegroundMeetTheirContrastThresholds below proves passes.
    //
    // Corrects the previous `Color.primary`-based contract below, which the plan retires in favor of
    // one shared, component-scoped mapping (may live in HermexCheckbox.swift per the plan; this test
    // reads both files so the mapping's actual location doesn't matter).
    func testSelectedRingAndInnerDotUseTheApprovedHermexSelectionControlColorsMappingNotColorPrimary() throws {
        let radioSrc = try source("HermesMobile/Features/Shared/HermexRadio.swift")
        let checkboxSrc = try source("HermesMobile/Features/Shared/HermexCheckbox.swift")
        let combined = radioSrc + "\n" + checkboxSrc

        XCTAssertTrue(combined.contains("enum HermexSelectionControlColors"), "expected a shared, component-scoped HermexSelectionControlColors mapping")
        XCTAssertNotNil(
            combined.range(of: #"static let selected\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s950,\s*dark:\s*HermesColorRamp\.Neutral\.s50\s*\)"#, options: .regularExpression),
            "expected .selected == Neutral.adaptive(light: Neutral.s950, dark: Neutral.s50)"
        )
        XCTAssertNotNil(
            combined.range(of: #"static let selectedForeground\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s50,\s*dark:\s*HermesColorRamp\.Neutral\.s950\s*\)"#, options: .regularExpression),
            "expected .selectedForeground == Neutral.adaptive(light: Neutral.s50, dark: Neutral.s950)"
        )
        XCTAssertNotNil(
            combined.range(of: #"static let unselectedBorder\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s500,\s*dark:\s*HermesColorRamp\.Neutral\.s600\s*\)"#, options: .regularExpression),
            "expected .unselectedBorder == Neutral.adaptive(light: Neutral.s500, dark: Neutral.s600) — corrected from the retired, under-contrast s400 light anchor"
        )

        XCTAssertTrue(
            radioSrc.contains("isSelected ? HermexSelectionControlColors.selected : HermexSelectionControlColors.unselectedBorder"),
            "expected the ring stroke to switch between .selected and .unselectedBorder"
        )
        XCTAssertTrue(radioSrc.contains(".fill(HermexSelectionControlColors.selected)"), "expected the inner dot fill to use .selected")
        XCTAssertFalse(radioSrc.contains("isSelected ? Color.primary : Color(.separator)"), "the retired Color.primary/separator ring contract must be gone")
        XCTAssertFalse(radioSrc.contains(".fill(Color.primary)"), "the retired Color.primary dot fill must be gone")
        XCTAssertFalse(radioSrc.contains("Color.accentColor"), "must not introduce an accent color")
    }

    /// WCAG 2.x contrast ratio computed directly from the ramp's own hex values (a rendered `Color`
    /// can't be inspected without a rendering harness, the same limitation the rest of this file
    /// documents). Measured against the established Neutral.s50/s950 primary-surface pair
    /// (`HermexCardColors.primarySurface`'s own light/dark anchors) since selection controls compose
    /// onto that surface. Proves the corrected unselectedBorder (s500/s600) clears the 3:1 non-text
    /// boundary threshold the retired s400 light anchor missed (~2.1:1), and that
    /// selected/selectedForeground clears 4.5:1 in both appearances.
    func testUnselectedBorderAndSelectedForegroundMeetTheirContrastThresholds() {
        let unselectedBorderLight = HermesColorRamp.Neutral.s500.hex
        let unselectedBorderDark = HermesColorRamp.Neutral.s600.hex
        let primarySurfaceLight = HermesColorRamp.Neutral.s50.hex
        let primarySurfaceDark = HermesColorRamp.Neutral.s950.hex
        let selectedLight = HermesColorRamp.Neutral.s950.hex
        let selectedForegroundLight = HermesColorRamp.Neutral.s50.hex
        let selectedDark = HermesColorRamp.Neutral.s50.hex
        let selectedForegroundDark = HermesColorRamp.Neutral.s950.hex

        XCTAssertGreaterThanOrEqual(contrastRatio(unselectedBorderLight, primarySurfaceLight), 3.0,
                                    "light unselectedBorder (s500) must be >=3:1 against the primary surface (s50)")
        XCTAssertGreaterThanOrEqual(contrastRatio(unselectedBorderDark, primarySurfaceDark), 3.0,
                                    "dark unselectedBorder (s600) must be >=3:1 against the primary surface (s950)")
        XCTAssertGreaterThanOrEqual(contrastRatio(selectedLight, selectedForegroundLight), 4.5,
                                    "light selected/selectedForeground must be >=4.5:1")
        XCTAssertGreaterThanOrEqual(contrastRatio(selectedDark, selectedForegroundDark), 4.5,
                                    "dark selected/selectedForeground must be >=4.5:1")
    }

    // MARK: - Contrast helper (test-only)
    //
    // A minimal WCAG 2.x relative-luminance/contrast-ratio calculator over #RRGGBB hex strings.
    // Test-only: production never needs to compute a contrast ratio at runtime, only to consume a
    // pre-validated ramp pairing.

    private func relativeLuminance(hex: String) -> Double {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let scanner = Scanner(string: digits)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    private func contrastRatio(_ hexA: String, _ hexB: String) -> Double {
        let luminanceA = relativeLuminance(hex: hexA)
        let luminanceB = relativeLuminance(hex: hexB)
        let lighter = max(luminanceA, luminanceB)
        let darker = min(luminanceA, luminanceB)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
