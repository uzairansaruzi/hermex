import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for the shared Hermex Button family (`HermexButton.swift`): sizing, emphasis, and
/// Press Feedback resolution are pure contracts; Reduce-Motion safety and glass composition are
/// source contracts, since a SwiftUI `ButtonStyle`'s `makeBody` isn't invokable without a live
/// button-press context.
final class HermexButtonTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    // MARK: - Pure contracts

    func testStandardPressFeedbackIsTheDefault() {
        XCTAssertEqual(HermexButton(content: .label("Go"), action: {}).pressFeedback, .standard)
    }

    func testEveryPressFeedbackCaseHasAScaleLessThanOrEqualToRestingExceptNone() {
        XCTAssertLessThan(HermexButtonPressFeedback.standard.scale, 1)
        XCTAssertLessThan(HermexButtonPressFeedback.emphasized.scale, HermexButtonPressFeedback.standard.scale)
        XCTAssertEqual(HermexButtonPressFeedback.none.scale, 1)
        XCTAssertEqual(HermexButtonPressFeedback.none.opacity, 1)
        XCTAssertEqual(HermexButtonPressFeedback.none.duration, 0)
    }

    func testStandardPressFeedbackReusesTheSharedMotionToken() {
        XCTAssertEqual(HermexButtonPressFeedback.standard.scale, HermesMotion.Properties.scalePress)
        XCTAssertEqual(HermexButtonPressFeedback.standard.duration, HermesMotion.Bundle.feedbackPress.duration)
    }

    func testSizesScaleMonotonicallyFromExtraSmallToLarge() {
        let sizes = HermexButtonSize.allCases
        for (a, b) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThan(a.minHeight, b.minHeight)
            XCTAssertLessThanOrEqual(a.horizontalPadding, b.horizontalPadding)
        }
    }

    // MARK: - Compile contracts

    func testEveryContentConfigurationCompiles() {
        let views: [any View] = [
            HermexButton(content: .label("Go"), action: {}),
            HermexButton(content: .icon("star", accessibilityLabel: "Favorite"), action: {}),
            HermexButton(content: .iconLeading(icon: "star", label: "Favorite"), action: {}),
            HermexButton(content: .iconTrailing(icon: "chevron.right", label: "Next"), action: {}),
            HermexButton(content: .label("Save"), isPending: true, action: {})
        ]
        XCTAssertEqual(views.count, 5)
    }

    func testEveryEmphasisAndSizeProducesAUsableButtonStyle() {
        for size in HermexButtonSize.allCases {
            for emphasis in HermexButtonEmphasis.allCases {
                let style = HermexButtonStyle(size: size, emphasis: emphasis)
                XCTAssertEqual(style.size, size)
                XCTAssertEqual(style.emphasis, emphasis)
            }
        }
    }

    // MARK: - Source contracts

    func testPressFeedbackIsReduceMotionSafe() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertTrue(src.contains("reduceMotion ? 1 : (isPressed ? scale : 1)"))
        XCTAssertTrue(src.contains("scale: pressFeedback.scale"))
        XCTAssertTrue(src.contains("guard !reduceMotion, pressFeedback != .none else { return nil }"))
    }

    func testGlassSurfaceComposesAdaptiveGlassInsteadOfDuplicatingItsFallback() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertTrue(src.contains(".adaptiveGlass("))
    }

    func testFullChromeButtonUsesTheCatalogPillShape() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertTrue(src.contains("let shape = Capsule()"))
        XCTAssertFalse(src.contains("let shape = RoundedRectangle(cornerRadius: HermesRadius.control"))
    }

    func testBrandPrimaryUsesTheHermexGoldRamp() throws {
        XCTAssertTrue(HermexButtonEmphasis.allCases.contains(.brandPrimary))
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertTrue(src.contains("HermesColorRamp.Gold.s500.color"))
        XCTAssertTrue(src.contains("HermesColorRamp.Gold.s600.color"))
    }

    func testHapticsStayOptionalAndSeparateFromPressFeedback() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertTrue(src.contains("var haptic: (() -> Void)?"))
    }

    func testContentUnavailablePatternAdoptsTheSharedButtonStyle() throws {
        let src = try source("HermesMobile/Features/Shared/HermexContentUnavailable.swift")
        XCTAssertTrue(src.contains(".buttonStyle(.hermex("))
    }

    func testPressOnlyStyleLivesUnderTheHermexButtonsFamily() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertTrue(src.contains("struct HermexButtonPressOnlyStyle"))
        XCTAssertTrue(src.contains("static func hermexPressOnly("))
    }

    func testPressOnlyAndFullChromeStylesShareOnePressFeedbackApplicationPoint() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        // One shared helper, called from both HermexButtonStyle and HermexButtonPressOnlyStyle's
        // makeBody, not two hand-rolled scale/opacity/animation chains.
        let occurrences = src.components(separatedBy: "applyingHermexButtonPressFeedback").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 3, "expected a definition plus a call from each style")
    }

    func testPressOnlyStylePreservesEveryExistingChromeVariant() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        for variant in ["icon", "compactControl", "capsule", "card", "thumbnail"] {
            XCTAssertTrue(src.contains("case \(variant)"), "missing preserved chrome variant \(variant)")
        }
    }

    // MARK: - Icon-only content requires an accessibility action label (#974 review)

    func testIconOnlyContentDeclaresARequiredAccessibilityLabel() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertTrue(
            src.contains("case icon(String, accessibilityLabel: String)"),
            "expected the icon-only content case to require an accessibility action label, since a bare " +
                "system image name names nothing VoiceOver can announce"
        )
    }

    func testIconOnlyContentAppliesTheAccessibilityLabelToTheImage() throws {
        let src = try source("HermesMobile/Features/Shared/HermexButton.swift")
        XCTAssertNotNil(
            src.range(
                of: #"case\s+\.icon\(let\s+systemImage,\s*let\s+accessibilityLabel\)\s*:\s*\n\s*Image\(systemName:\s*systemImage\)\s*\n\s*\.accessibilityLabel\(Text\(accessibilityLabel\)\)"#,
                options: .regularExpression
            ),
            "expected the icon-only content case to apply its required accessibility label directly to the Image"
        )
    }
}
