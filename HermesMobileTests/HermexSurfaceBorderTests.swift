import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for the new shared Card/Search border foundation (`HermexSurfaceBorder.swift`, not yet
/// created): the six exact ramp anchors `HermexSurfaceBorderRamp` must expose, and the three
/// adaptive pairs `HermexSurfaceBorderColors` derives from them, so Card and Search can consume
/// shared border roles instead of retaining component-local resting/focus/contrast mappings.
///
/// `HermexSurfaceBorderRamp`/`HermexSurfaceBorderColors` do not exist yet, so — mirroring the
/// existing helper pattern in `HermexCardTests` — these are read as a source contract against the
/// file itself rather than referencing the not-yet-compiling symbols directly, with an explicit
/// failure when the file is missing. Member names below are this batch's own naming choice for the
/// required anchors, not a constraint stated elsewhere; a future implementer may rename them, but
/// must update these tests in the same change if so. The contrast-ratio assertions are computed
/// directly from the ramp's own current hex values via `HermesHexColor.hex` (already-existing
/// production symbols), so RED reaches the intended missing-file/source assertions below rather than
/// a compiler failure.
final class HermexSurfaceBorderTests: XCTestCase {
    private static let sourcePath = "HermesMobile/Features/Shared/HermexSurfaceBorder.swift"

    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func sourceIfExists(_ relativePath: String) -> String? {
        try? String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    private func requiredSource() throws -> String {
        try XCTUnwrap(
            sourceIfExists(Self.sourcePath),
            "expected \(Self.sourcePath) to exist — HermexSurfaceBorderRamp/HermexSurfaceBorderColors are not yet defined"
        )
    }

    // MARK: - Contrast helper (test-only)
    //
    // A minimal WCAG 2.x relative-luminance/contrast-ratio calculator over #RRGGBB hex strings,
    // mirroring the pattern in `HermexCardTests`. Test-only: production never needs to compute a
    // contrast ratio at runtime, only to consume a pre-validated ramp pairing.

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

    // MARK: - Source contract: the foundation file must exist

    func testFoundationFileExistsAtItsNamedSharedPath() {
        XCTAssertNotNil(
            sourceIfExists(Self.sourcePath),
            "expected \(Self.sourcePath) to exist as the shared Card/Search border foundation"
        )
    }

    // MARK: - Source contract: HermexSurfaceBorderRamp's six exact anchors

    func testRampDefinesRestingLightAsNeutralS600() throws {
        let src = try requiredSource()
        XCTAssertTrue(src.contains("enum HermexSurfaceBorderRamp"), "expected a shared HermexSurfaceBorderRamp")
        XCTAssertNotNil(
            src.range(of: #"static let restingLight\b[\s\S]*?HermesColorRamp\.Neutral\.s600\b"#, options: .regularExpression),
            "expected .restingLight == Neutral.s600"
        )
    }

    func testRampDefinesRestingDarkAsNeutralS400() throws {
        let src = try requiredSource()
        XCTAssertNotNil(
            src.range(of: #"static let restingDark\b[\s\S]*?HermesColorRamp\.Neutral\.s400\b"#, options: .regularExpression),
            "expected .restingDark == Neutral.s400"
        )
    }

    func testRampDefinesFocusedLightAsNeutralS700() throws {
        let src = try requiredSource()
        XCTAssertNotNil(
            src.range(of: #"static let focusedLight\b[\s\S]*?HermesColorRamp\.Neutral\.s700\b"#, options: .regularExpression),
            "expected .focusedLight == Neutral.s700"
        )
    }

    func testRampDefinesFocusedDarkAsNeutralS300() throws {
        let src = try requiredSource()
        XCTAssertNotNil(
            src.range(of: #"static let focusedDark\b[\s\S]*?HermesColorRamp\.Neutral\.s300\b"#, options: .regularExpression),
            "expected .focusedDark == Neutral.s300"
        )
    }

    func testRampDefinesIncreasedContrastLightAsNeutralS800() throws {
        let src = try requiredSource()
        XCTAssertNotNil(
            src.range(of: #"static let increasedContrastLight\b[\s\S]*?HermesColorRamp\.Neutral\.s800\b"#, options: .regularExpression),
            "expected .increasedContrastLight == Neutral.s800"
        )
    }

    func testRampDefinesIncreasedContrastDarkAsNeutralS200() throws {
        let src = try requiredSource()
        XCTAssertNotNil(
            src.range(of: #"static let increasedContrastDark\b[\s\S]*?HermesColorRamp\.Neutral\.s200\b"#, options: .regularExpression),
            "expected .increasedContrastDark == Neutral.s200"
        )
    }

    // MARK: - Source contract: HermexSurfaceBorderColors' three adaptive pairs

    func testColorsDefinesRestingAsTheAdaptiveRestingRampPair() throws {
        let src = try requiredSource()
        XCTAssertTrue(src.contains("enum HermexSurfaceBorderColors"), "expected a shared HermexSurfaceBorderColors mapping")
        XCTAssertNotNil(
            src.range(of: #"static let resting\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermexSurfaceBorderRamp\.restingLight,\s*dark:\s*HermexSurfaceBorderRamp\.restingDark\s*\)"#, options: .regularExpression),
            "expected .resting == Neutral.adaptive(light: HermexSurfaceBorderRamp.restingLight, dark: HermexSurfaceBorderRamp.restingDark)"
        )
    }

    func testColorsDefinesFocusedAsTheAdaptiveFocusedRampPair() throws {
        let src = try requiredSource()
        XCTAssertNotNil(
            src.range(of: #"static let focused\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermexSurfaceBorderRamp\.focusedLight,\s*dark:\s*HermexSurfaceBorderRamp\.focusedDark\s*\)"#, options: .regularExpression),
            "expected .focused == Neutral.adaptive(light: HermexSurfaceBorderRamp.focusedLight, dark: HermexSurfaceBorderRamp.focusedDark)"
        )
    }

    func testColorsDefinesIncreasedContrastAsTheAdaptiveIncreasedContrastRampPair() throws {
        let src = try requiredSource()
        XCTAssertNotNil(
            src.range(of: #"static let increasedContrast\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermexSurfaceBorderRamp\.increasedContrastLight,\s*dark:\s*HermexSurfaceBorderRamp\.increasedContrastDark\s*\)"#, options: .regularExpression),
            "expected .increasedContrast == Neutral.adaptive(light: HermexSurfaceBorderRamp.increasedContrastLight, dark: HermexSurfaceBorderRamp.increasedContrastDark)"
        )
    }

    // MARK: - Contrast ratio pins (executable now from current ramp hex values)

    func testRestingLightMeetsThreeToOneAgainstNeutralS100() {
        let ratio = contrastRatio(HermesColorRamp.Neutral.s600.hex, HermesColorRamp.Neutral.s100.hex)
        XCTAssertGreaterThanOrEqual(
            ratio, 3.0,
            "resting light (Neutral.s600) must be >=3:1 against Neutral.s100"
        )
    }

    func testRestingDarkMeetsThreeToOneAgainstNeutralS900() {
        let ratio = contrastRatio(HermesColorRamp.Neutral.s400.hex, HermesColorRamp.Neutral.s900.hex)
        XCTAssertGreaterThanOrEqual(
            ratio, 3.0,
            "resting dark (Neutral.s400) must be >=3:1 against Neutral.s900"
        )
    }
}
