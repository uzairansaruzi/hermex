import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for the Card family's shared defaults (`HermexCard.swift`): the exact 16-point content
/// padding available for Card-composing surfaces, the Compact Card surface's compile contract, and
/// the Request Card surface factory. A SwiftUI view tree isn't inspectable at runtime without a
/// rendering harness, so the factory's presence is a source contract read from `HermexCard.swift`
/// itself; the padding value is a pure contract.
final class HermexCardTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    // MARK: - Pure contract

    func testCardContentPaddingIsExactlySixteenPointsOnEveryEdge() {
        XCTAssertEqual(HermexCardMetrics.contentPadding, HermesSpacing.s16)
        XCTAssertEqual(HermexCardMetrics.contentPadding, 16)
    }

    // MARK: - Compile contract

    func testCompactCardSurfaceCompilesWithDefaultAndClearFill() {
        let filled = Color.clear.frame(width: 1, height: 1).compactCardSurface(cornerRadius: HermesRadius.r16)
        let bordered = Color.clear.frame(width: 1, height: 1).compactCardSurface(cornerRadius: HermesRadius.r16, fill: .clear)
        XCTAssertFalse(String(describing: type(of: filled)).isEmpty)
        XCTAssertFalse(String(describing: type(of: bordered)).isEmpty)
    }

    // MARK: - Request Card lives in the Card family

    func testRequestCardSurfaceIsDefinedInTheCardFamilyFile() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        XCTAssertTrue(src.contains("func requestCardSurface(cornerRadius:"))
    }

    func testOverlayLabIncludesAReachableBatchBCardFixtureForEverySurfaceVariant() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(src.contains("--hermex-overlay-lab-batch-b"))
        XCTAssertTrue(src.contains("private struct HermexOverlayLabCardFollowup"))
        XCTAssertTrue(src.contains(".hermexCardSurface(.glass)"))
        XCTAssertTrue(src.contains(".hermexCardSurface(.outlined)"))
        XCTAssertTrue(src.contains(".compactCardSurface()"))
        XCTAssertTrue(src.contains(".requestCardSurface("))
        XCTAssertTrue(src.contains("material: .opaque"))
        XCTAssertTrue(src.contains("material: .translucentOverScrim"))
    }

    // MARK: - DSR2-01: Card consumes shared border roles instead of retaining component-local
    // resting/focus/contrast mappings
    //
    // `HermexCardColors` retains only its two surface roles (primary/secondary); the standard and
    // Increased Contrast border roles move to the shared `HermexSurfaceBorderColors.resting` /
    // `.increasedContrast` foundation (contracted in `HermexSurfaceBorderTests`) so Card and Search
    // stop each owning their own border mapping. A rendered `Color` value can't be inspected without
    // a rendering harness, so these stay source contracts, mirroring every other test in this file.

    func testHermexCardColorsRetainsOnlyItsTwoSurfaceRolesWithNoBorderDeclarations() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        XCTAssertTrue(src.contains("enum HermexCardColors"), "expected HermexCardColors to remain, holding only surface roles")
        XCTAssertNotNil(
            src.range(of: #"static let primarySurface\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s50,\s*dark:\s*HermesColorRamp\.Neutral\.s950\s*\)"#, options: .regularExpression),
            "expected .primarySurface == Neutral.adaptive(light: Neutral.s50, dark: Neutral.s950)"
        )
        XCTAssertNotNil(
            src.range(of: #"static let secondarySurface\b[\s\S]*?HermesColorRamp\.Neutral\.adaptive\(\s*light:\s*HermesColorRamp\.Neutral\.s100,\s*dark:\s*HermesColorRamp\.Neutral\.s900\s*\)"#, options: .regularExpression),
            "expected .secondarySurface == Neutral.adaptive(light: Neutral.s100, dark: Neutral.s900)"
        )
        XCTAssertFalse(
            src.contains("static let standardBorder"),
            "border roles move to the shared HermexSurfaceBorderColors foundation; HermexCardColors must retain only surface roles"
        )
        XCTAssertFalse(
            src.contains("static let increasedContrastBorder"),
            "border roles move to the shared HermexSurfaceBorderColors foundation; HermexCardColors must retain only surface roles"
        )
    }

    func testGlassSurfaceUsesTheTokenizedPrimaryUnderlayAndSharedRestingOrIncreasedContrastBorderWhilePreservingAdaptiveGlassBehavior() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        guard let caseRange = src.range(of: #"case \.glass:[\s\S]*?case \.outlined:"#, options: .regularExpression) else {
            return XCTFail("expected a `case .glass:` branch in HermexCardSurfaceModifier")
        }
        let glassCase = String(src[caseRange])
        XCTAssertTrue(glassCase.contains("HermexCardColors.primarySurface"), "expected the glass underlay/fallback fill to use HermexCardColors.primarySurface")
        XCTAssertTrue(glassCase.contains("HermexSurfaceBorderColors.resting"), "expected the resting-contrast stroke to use the shared HermexSurfaceBorderColors.resting role")
        XCTAssertTrue(glassCase.contains("HermexSurfaceBorderColors.increasedContrast"), "expected the Increased Contrast stroke to use the shared HermexSurfaceBorderColors.increasedContrast role")
        XCTAssertFalse(glassCase.contains("HermexCardColors.standardBorder"), "the retired component-local standardBorder must be gone from the glass case")
        XCTAssertFalse(glassCase.contains("HermexCardColors.increasedContrastBorder"), "the retired component-local increasedContrastBorder must be gone from the glass case")
        XCTAssertTrue(glassCase.contains(".adaptiveGlass("), "must preserve Adaptive Glass/material behavior")
        XCTAssertTrue(glassCase.contains("reduceTransparency"), "must preserve the Reduce Transparency solid fallback")
        XCTAssertFalse(glassCase.contains("secondarySystemBackground"), "the retired platform color must be gone from the glass case")
        XCTAssertFalse(glassCase.contains("Color.primary.opacity"), "the retired Color.primary.opacity border recipe must be gone from the glass case")
    }

    func testOutlinedSurfaceUsesTheTokenizedPrimaryBackgroundAndASharedRestingOrIncreasedContrastBorder() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        guard let caseRange = src.range(of: #"case \.outlined:[\s\S]*?\n    \}"#, options: .regularExpression) else {
            return XCTFail("expected a `case .outlined:` branch in HermexCardSurfaceModifier")
        }
        let outlinedCase = String(src[caseRange])
        XCTAssertTrue(outlinedCase.contains("HermexCardColors.primarySurface"), "expected the outlined background to use HermexCardColors.primarySurface")
        XCTAssertTrue(
            outlinedCase.contains("HermexSurfaceBorderColors.resting") || outlinedCase.contains("HermexSurfaceBorderColors.increasedContrast"),
            "expected the outlined border to use a shared HermexSurfaceBorderColors role"
        )
        XCTAssertFalse(outlinedCase.contains("HermexCardColors.standardBorder"), "the retired component-local standardBorder must be gone from the outlined case")
        XCTAssertFalse(outlinedCase.contains("HermexCardColors.increasedContrastBorder"), "the retired component-local increasedContrastBorder must be gone from the outlined case")
        XCTAssertFalse(outlinedCase.contains("Color(.systemBackground)"), "the retired platform background must be gone from the outlined case")
        XCTAssertFalse(outlinedCase.contains("Color(.separator)"), "the retired platform border must be gone from the outlined case")
    }

    func testCompactCardSurfaceDefaultsToTheTokenizedSecondaryBackgroundAndTheSharedRestingBorderWithoutTheRetiredBorderOpacityRecipe() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        XCTAssertTrue(
            src.contains("fill: Color = HermexCardColors.secondarySurface"),
            "expected compactCardSurface's default fill to be the tokenized secondary surface — caller-supplied .clear remains supported per the existing compile contract above"
        )
        XCTAssertFalse(src.contains("fill: Color = Color(.secondarySystemBackground)"), "the retired platform default fill must be gone")

        guard let funcRange = src.range(of: #"func compactCardSurface[\s\S]*?\n\}"#, options: .regularExpression) else {
            return XCTFail("expected the compactCardSurface function body")
        }
        let body = String(src[funcRange])
        XCTAssertTrue(body.contains(".modifier(HermexCompactCardBorderModifier"),
                      "expected compactCardSurface to delegate border rendering to a file-scope environment-reading modifier; Swift forbids nesting that type inside this generic View extension method")
        XCTAssertFalse(body.contains("Color(.separator)"), "the retired platform border must be gone from compactCardSurface")

        guard let modifierStart = src.range(of: "private struct HermexCompactCardBorderModifier")?.lowerBound,
              let requestStart = src.range(of: "enum RequestCardMaterial")?.lowerBound else {
            return XCTFail("expected a file-scope HermexCompactCardBorderModifier before RequestCardMaterial")
        }
        let modifier = String(src[modifierStart..<requestStart])
        XCTAssertTrue(modifier.contains("@Environment(\\.colorSchemeContrast) private var colorSchemeContrast"))
        XCTAssertTrue(modifier.contains("HermexSurfaceBorderColors.resting"), "expected the compact hairline border to use the shared HermexSurfaceBorderColors.resting role at normal contrast")
        XCTAssertTrue(modifier.contains("HermexSurfaceBorderColors.increasedContrast"), "expected the compact hairline border to use the shared HermexSurfaceBorderColors.increasedContrast role under Increased Contrast")
        XCTAssertFalse(modifier.contains("HermexCardColors.standardBorder"), "the retired component-local standardBorder must be gone from the compact modifier")
        XCTAssertFalse(modifier.contains("HermexCardColors.increasedContrastBorder"), "the retired component-local increasedContrastBorder must be gone from the compact modifier")
        XCTAssertFalse(
            modifier.contains(".opacity(colorSchemeContrast == .increased ? 1 : HermexCompactCardMetrics.borderOpacity)"),
            "Compact Card must not apply the retired normal borderOpacity recipe now that both states resolve to fully opaque shared border roles"
        )
        XCTAssertFalse(modifier.contains("Color(.separator)"), "the retired platform border must be absent from the compact modifier")
    }

    /// DSR2-01 requires every bordered Card variant — not just `.glass`/`.outlined` — to select the
    /// shared border roles: `compactCardSurface`, Request Card `.opaque`, and Request Card
    /// `.translucentOverScrim` must all select `HermexSurfaceBorderColors.increasedContrast` under
    /// Increased Contrast and `.resting` otherwise, using the same ternary `HermexCardSurfaceModifier`
    /// already applies for `.glass`/`.outlined`. A file-wide count is deliberately structure-agnostic
    /// about *where* each variant's border lives (a `ViewModifier`, a free function, or an
    /// environment-reading seam `compactCardSurface` delegates to) — only that the same conditional
    /// selection of the shared roles is applied consistently everywhere a Card variant draws a border.
    func testEveryCardVariantSelectsTheSharedIncreasedContrastRoleUnderIncreasedContrastAndTheSharedRestingRoleOtherwise() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        let ternary = "colorSchemeContrast == .increased ? HermexSurfaceBorderColors.increasedContrast : HermexSurfaceBorderColors.resting"
        let occurrences = src.components(separatedBy: ternary).count - 1
        XCTAssertEqual(occurrences, 5,
                       "expected all five Card variants (.glass, .outlined, compact default, opaque Request Card, translucent-over-scrim Request Card) to select the shared HermexSurfaceBorderColors.increasedContrast role under Increased Contrast and .resting otherwise via this exact ternary — found \(occurrences)")
        XCTAssertFalse(
            src.contains("colorSchemeContrast == .increased ? HermexCardColors.increasedContrastBorder : HermexCardColors.standardBorder"),
            "the retired component-local border ternary must be gone entirely"
        )
    }

    /// Reading `colorSchemeContrast` requires an environment-reading seam — `compactCardSurface` is
    /// today a plain `View` extension with no environment access, so it must move its border behind a
    /// `ViewModifier` (or equivalent) to gain one. `HermexCardSurfaceModifier` (the existing seam for
    /// `.glass`/`.outlined`) already declares one `@Environment(\.colorSchemeContrast)`; this requires
    /// at least two more — compact's new seam and `RequestCardSurfaceModifier` — while leaving
    /// `compactCardSurface`'s own public call signature (and its documented `.clear` fill support)
    /// completely unchanged.
    func testAtLeastTwoMoreEnvironmentReadingSeamsExistForCompactAndRequestCardBorders() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        let declaration = "@Environment(\\.colorSchemeContrast) private var colorSchemeContrast"
        let occurrences = src.components(separatedBy: declaration).count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 3,
                                    "expected at least 3 declarations of @Environment(\\.colorSchemeContrast): the existing HermexCardSurfaceModifier, plus a new seam each for compactCardSurface and RequestCardSurfaceModifier — found \(occurrences)")
    }

    func testCompactCardSurfacesPublicSignatureStaysUnchangedWhileItGainsIncreasedContrastSupport() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        XCTAssertTrue(
            src.contains("func compactCardSurface(cornerRadius: CGFloat = HermesRadius.card, fill: Color = HermexCardColors.secondarySurface) -> some View {"),
            "compactCardSurface's public call signature — including its cornerRadius/fill defaults — must stay exactly as callers already depend on while its border gains Increased Contrast support behind a new environment-reading seam"
        )
    }

    func testRequestCardOpaqueUsesTheTokenizedPrimaryBackgroundAndTranslucentOverScrimKeepsMaterialBehaviorWithATokenizedBorder() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        guard let structIdx = src.range(of: "private struct RequestCardSurfaceModifier") else {
            return XCTFail("expected RequestCardSurfaceModifier")
        }
        let tail = String(src[structIdx.lowerBound...])
        guard let bodyRange = tail.range(of: #"func body\(content: Content\) -> some View \{[\s\S]*?\n    \}\n\}"#, options: .regularExpression) else {
            return XCTFail("expected RequestCardSurfaceModifier.body")
        }
        let body = String(tail[bodyRange])
        XCTAssertTrue(body.contains(".background(HermexCardColors.primarySurface, in: shape)"), "expected the opaque case to use HermexCardColors.primarySurface")
        XCTAssertTrue(body.contains(".regularMaterial, in: shape"), "translucent-over-scrim must keep material behavior")
        XCTAssertTrue(body.contains("HermexSurfaceBorderColors.resting"), "expected the Request Card surface to use the shared HermexSurfaceBorderColors.resting role")
        XCTAssertFalse(body.contains("HermexCardColors.standardBorder"), "the retired component-local standardBorder must be gone from Request Card")
        XCTAssertFalse(body.contains("secondarySystemBackground"), "the retired platform background must be gone from Request Card")
        XCTAssertFalse(body.contains(".primary.opacity(0.10)"), "the retired Color.primary.opacity border recipe must be gone from Request Card")
    }

    /// DSR2-01 requires `RequestCardSurfaceModifier` itself to read `colorSchemeContrast` (it is
    /// already a `ViewModifier`, unlike the free-function `compactCardSurface`) and for both its
    /// `.opaque` and `.translucentOverScrim` branches to select the shared
    /// `HermexSurfaceBorderColors.increasedContrast`/`.resting` roles via the same ternary the other
    /// three variants use.
    func testRequestCardSurfaceModifierReadsColorSchemeContrastAndBothMaterialsSelectTheSharedIncreasedContrastRole() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        guard let structIdx = src.range(of: "private struct RequestCardSurfaceModifier") else {
            return XCTFail("expected RequestCardSurfaceModifier")
        }
        let tail = String(src[structIdx.lowerBound...])
        XCTAssertTrue(tail.contains("@Environment(\\.colorSchemeContrast)"),
                      "expected RequestCardSurfaceModifier to declare @Environment(\\.colorSchemeContrast) so both materials can select the shared Increased Contrast role")

        guard let bodyRange = tail.range(of: #"func body\(content: Content\) -> some View \{[\s\S]*?\n    \}\n\}"#, options: .regularExpression) else {
            return XCTFail("expected RequestCardSurfaceModifier.body")
        }
        let body = String(tail[bodyRange])
        let ternary = "colorSchemeContrast == .increased ? HermexSurfaceBorderColors.increasedContrast : HermexSurfaceBorderColors.resting"
        let occurrences = body.components(separatedBy: ternary).count - 1
        XCTAssertEqual(occurrences, 2,
                       "expected both the .opaque and .translucentOverScrim branches to select the shared HermexSurfaceBorderColors.increasedContrast role under Increased Contrast and .resting otherwise — found \(occurrences)")
    }

    func testRetiredPlatformColorExpressionsAreAbsentFromHermexCardSwift() throws {
        let src = try source("HermesMobile/Features/Shared/HermexCard.swift")
        XCTAssertFalse(src.contains("Color(.secondarySystemBackground)"), "retired: direct secondarySystemBackground surface recipe")
        XCTAssertFalse(src.contains("Color(.systemBackground)"), "retired: direct systemBackground surface recipe")
        XCTAssertFalse(src.contains("Color(.separator)"), "retired: direct separator border recipe")
        XCTAssertFalse(src.contains(".primary.opacity"), "retired: Color.primary.opacity border recipe")
        XCTAssertFalse(src.contains("HermexCardColors.standardBorder"), "retired: component-local standardBorder must be gone everywhere, declaration and usage alike")
        XCTAssertFalse(src.contains("HermexCardColors.increasedContrastBorder"), "retired: component-local increasedContrastBorder must be gone everywhere, declaration and usage alike")
    }
}
