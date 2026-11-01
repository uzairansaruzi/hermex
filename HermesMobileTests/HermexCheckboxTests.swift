import XCTest
@testable import HermesMobile

final class HermexCheckboxTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testMetricsMeetVisualAndAccessibilityContracts() {
        XCTAssertEqual(HermexCheckboxMetrics.boxSize, 20)
        XCTAssertEqual(HermexCheckboxMetrics.borderWidth, 2)
        XCTAssertEqual(HermexCheckboxMetrics.minimumHitTarget, 44)
    }

    func testInteractiveCheckboxUsesNativeToggleAccessibilityRepresentation() throws {
        let component = try source("HermesMobile/Features/Shared/HermexCheckbox.swift")
        XCTAssertTrue(component.contains(".accessibilityRepresentation"))
        XCTAssertTrue(component.contains("Toggle("))
        XCTAssertTrue(component.contains(".accessibilityHidden(true)"))
    }

    func testOverlayLabIncludesReachableCheckedUncheckedAndRowOwnedCheckboxFixtures() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(src.contains("--hermex-overlay-lab-batch-b"))
        XCTAssertTrue(src.contains("--hermex-overlay-lab-batch-b-controls"))
        XCTAssertTrue(src.contains("private struct HermexOverlayLabSelectionControlsFollowup"))
        XCTAssertTrue(src.contains("HermexOverlayLabBatchBSelectionControls.scrollAnchorID"))
        XCTAssertTrue(src.contains("HermexCheckbox(isChecked: false"))
        XCTAssertTrue(src.contains("HermexCheckbox(isChecked: true"))
        XCTAssertTrue(src.contains("action: nil"))
        XCTAssertNotNil(
            src.range(
                of: #"HermexCheckbox\(isChecked:\s*rowOwnedIsChecked,\s*action:\s*nil\)[\s\S]*?\.buttonStyle\(\.plain\)"#,
                options: .regularExpression
            ),
            "expected the row-owned fixture to preserve neutral label styling instead of inheriting Button tint"
        )
    }

    // MARK: - DSF-09 (Batch B, corrected): HermexSelectionControlColors — replaces the Color.primary
    // contract
    //
    // Approved exact mapping (design-system-follow-up-plan.md, DSF-08/09, corrected per review),
    // shared with Radio:
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
    // one shared, component-scoped mapping. The plan allows this mapping to live in
    // HermexCheckbox.swift and be consumed by Radio, so this test owns the mapping's own definition
    // contract (HermexRadioTests reads it too, since Radio consumes it from here or wherever it lands).
    func testCheckedFillBorderAndCheckmarkUseTheApprovedHermexSelectionControlColorsMappingNotColorPrimary() throws {
        let component = try source("HermesMobile/Features/Shared/HermexCheckbox.swift")

        XCTAssertTrue(component.contains("enum HermexSelectionControlColors"), "expected the shared, component-scoped HermexSelectionControlColors mapping")
        XCTAssertNotNil(
            component.range(of: #"static let selected\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s950,\s*dark:\s*HermesColorRamp\.Neutral\.s50\s*\)"#, options: .regularExpression),
            "expected .selected == Neutral.adaptive(light: Neutral.s950, dark: Neutral.s50)"
        )
        XCTAssertNotNil(
            component.range(of: #"static let selectedForeground\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s50,\s*dark:\s*HermesColorRamp\.Neutral\.s950\s*\)"#, options: .regularExpression),
            "expected .selectedForeground == Neutral.adaptive(light: Neutral.s50, dark: Neutral.s950)"
        )
        XCTAssertNotNil(
            component.range(of: #"static let unselectedBorder\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s500,\s*dark:\s*HermesColorRamp\.Neutral\.s600\s*\)"#, options: .regularExpression),
            "expected .unselectedBorder == Neutral.adaptive(light: Neutral.s500, dark: Neutral.s600) — corrected from the retired, under-contrast s400 light anchor"
        )

        XCTAssertTrue(component.contains("isChecked ? HermexSelectionControlColors.selected : Color.clear"), "expected the checked fill to use .selected")
        XCTAssertTrue(
            component.contains("isChecked ? HermexSelectionControlColors.selected : HermexSelectionControlColors.unselectedBorder"),
            "expected the border to switch between .selected and .unselectedBorder"
        )
        XCTAssertTrue(
            component.contains(".foregroundStyle(HermexSelectionControlColors.selectedForeground)"),
            "expected the checkmark to use .selectedForeground instead of the inverse system background"
        )

        XCTAssertFalse(component.contains("isChecked ? Color.primary : Color.clear"), "the retired Color.primary fill contract must be gone")
        XCTAssertFalse(component.contains("isChecked ? Color.primary : Color(.separator)"), "the retired Color.primary/separator border contract must be gone")
        XCTAssertFalse(component.contains("Color(.systemBackground)"), "the checkmark must no longer use the inverse system background")
        XCTAssertFalse(component.contains("Color.accentColor"), "must not introduce an accent color")
    }

    /// WCAG 2.x contrast ratio computed directly from the ramp's own hex values (a rendered `Color`
    /// can't be inspected without a rendering harness). Measured against the established
    /// Neutral.s50/s950 primary-surface pair (`HermexCardColors.primarySurface`'s own light/dark
    /// anchors) since selection controls compose onto that surface. Proves the corrected
    /// unselectedBorder (s500/s600) clears the 3:1 non-text boundary threshold the retired s400 light
    /// anchor missed (~2.1:1), and that selected/selectedForeground clears 4.5:1 in both appearances.
    /// Mirrors HermexRadioTests' own identically-named test — Radio and Checkbox share the exact same
    /// HermexSelectionControlColors mapping, so both files pin the same contract independently.
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
