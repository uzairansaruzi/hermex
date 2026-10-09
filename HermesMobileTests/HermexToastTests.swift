import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexToast` (`HermexToast.swift`): semantic tint/icon mapping is a pure contract;
/// visibility stays caller-owned through the `hermexToast(isPresented:toast:)` presentation modifier,
/// so a SwiftUI view tree isn't inspectable at runtime without a rendering harness and that adoption
/// surface is a compile contract.
final class HermexToastTests: XCTestCase {
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

    func testEverySemanticHasADefaultIcon() {
        XCTAssertEqual(HermexToast.Semantic.success.defaultIcon, "checkmark.circle")
    }

    // MARK: - Issue #DSR2-08: exact background color-family anchors, replacing the raw Semantic.tint
    // mapping (whose SwiftUI system colors — including .yellow for warning — no longer match the
    // approved ramp, which maps warning to Orange).

    func testEverySemanticMapsToItsApprovedToastBackgroundColor() {
        XCTAssertEqual(HermexToastColors.information.hex, HermesColorRamp.Blue.s700.hex)
        XCTAssertEqual(HermexToastColors.success.hex, HermesColorRamp.Green.s800.hex)
        XCTAssertEqual(HermexToastColors.warning.hex, HermesColorRamp.Orange.s800.hex)
        XCTAssertEqual(HermexToastColors.error.hex, HermesColorRamp.Red.s700.hex)
    }

    // MARK: - Contrast helper (test-only)
    //
    // A minimal WCAG 2.x relative-luminance/contrast-ratio calculator over #RRGGBB hex strings,
    // mirroring the pattern in `HermexSurfaceBorderTests`. Test-only: production never needs to
    // compute a contrast ratio at runtime, only to consume a pre-validated color mapping.

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

    func testEveryApprovedToastBackgroundClearsFourPointFiveToOneAgainstWhiteForegroundContent() {
        for hex in [
            HermesColorRamp.Blue.s700.hex,
            HermesColorRamp.Green.s800.hex,
            HermesColorRamp.Orange.s800.hex,
            HermesColorRamp.Red.s700.hex,
        ] {
            let ratio = contrastRatio(hex, "#FFFFFF")
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(hex) must be >=4.5:1 against white foreground content")
        }
    }

    func testExplicitIconOverridesTheSemanticDefault() {
        let toast = HermexToast(.information, message: Text("Synced"), icon: "checkmark.circle")
        XCTAssertEqual(toast.icon, "checkmark.circle")
    }

    // MARK: - Compile contracts: caller-owned visibility, optional icon/action

    func testEverySemanticCompilesWithAndWithoutAnAction() {
        for semantic in [HermexToast.Semantic.information, .success, .warning, .error] {
            let plain = HermexToast(semantic, message: Text("Status"))
            let withAction = HermexToast(semantic, message: Text("Status"), action: .init(title: "Undo", handler: {}))
            XCTAssertFalse(String(describing: type(of: plain)).isEmpty)
            XCTAssertFalse(String(describing: type(of: withAction)).isEmpty)
        }
    }

    @MainActor
    func testHermexToastPresentationModifierCompilesOverAnyView() {
        struct Host: View {
            @State var isPresented = true
            var body: some View {
                Color.clear
                    .hermexToast(isPresented: $isPresented, toast: HermexToast(.success, message: Text("Saved")))
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    // MARK: - Source contract: default top-edge motion, caller-owned lifecycle preserved

    func testDefaultTransitionMovesFromTheTopEdgeReusingTheOverlayEnterAndExitMotionBundles() throws {
        let src = try source("HermesMobile/Features/Shared/HermexToast.swift")
        XCTAssertTrue(src.contains(".move(edge: .top)"))
        XCTAssertTrue(src.contains(".combined(with: .opacity)"))
        XCTAssertTrue(src.contains("HermesMotion.Bundle.overlayEnter"))
        XCTAssertTrue(src.contains("HermesMotion.Bundle.overlayExit"))
        XCTAssertTrue(src.contains(".asymmetric("))
    }

    func testReduceMotionFallsBackToAnOpacityOnlyStateChange() throws {
        let src = try source("HermesMobile/Features/Shared/HermexToast.swift")
        XCTAssertTrue(src.contains("reduceMotion"))
        XCTAssertTrue(src.contains("return .opacity"))
    }

    func testPresentationStaysCallerOwnedWithNoInternalTimer() throws {
        let src = try source("HermesMobile/Features/Shared/HermexToast.swift")
        XCTAssertFalse(src.contains("Timer"))
        XCTAssertFalse(src.contains("DispatchQueue.main.asyncAfter"))
        XCTAssertTrue(src.contains("@Binding var isPresented: Bool"))
    }

    // MARK: - Issue #DSR2-08: white-label trailing action on the colored surface, using the shared
    // hermexPressOnly(.compactControl) style rather than a neutral filled HermexButton

    /// Isolates the `if let action { ... }` block's own source so an assertion about the trailing
    /// action's chrome never accidentally matches the icon's own, still-status-tinted, foreground
    /// modifier a few lines above it.
    private func trailingActionSource() throws -> String {
        let src = try source("HermesMobile/Features/Shared/HermexToast.swift")
        let after = try XCTUnwrap(src.components(separatedBy: "if let action {").last,
                                   "expected an `if let action` trailing-action block")
        return try XCTUnwrap(after.components(separatedBy: "\n            }").first,
                              "expected the action block to close before the closing HStack brace")
    }

    // MARK: - Issue #DSR2-08: the toast surface itself now carries the semantic color (via
    // HermexToastColors.background(for:)), so icon, message, and the trailing action all read as
    // white content on that colored surface — none of them carries its own separate semantic tint
    // or a neutral filled HermexButton chrome anymore.

    func testTrailingActionComposesANativeButtonWithWhiteLabelAndTheSharedHermexPressOnlyCompactControlStyle() throws {
        let block = try trailingActionSource()
        XCTAssertTrue(block.contains("Button("), "expected the trailing action to compose a native Button")
        XCTAssertTrue(
            block.contains(".buttonStyle(.hermexPressOnly(.compactControl))"),
            "expected the trailing action to use the shared hermexPressOnly(.compactControl) button style"
        )
        XCTAssertTrue(block.contains(".white"), "expected the trailing action's label content to use white foreground")
    }

    func testTrailingActionNoLongerComposesHermexButtonOrANeutralFilledCapsuleOrSemanticTint() throws {
        let block = try trailingActionSource()
        XCTAssertFalse(block.contains("HermexButton("), "the trailing action must no longer compose the shared HermexButton")
        XCTAssertFalse(block.contains("emphasis: .neutral"), "the trailing action must no longer use HermexButton's neutral emphasis")
        XCTAssertFalse(block.contains("size: .extraSmall"), "the trailing action must no longer use HermexButton's extraSmall size")
        XCTAssertFalse(block.contains("capsule"), "the trailing action must not compose a neutral filled capsule")
        XCTAssertFalse(
            block.contains("semantic.tint"),
            "the trailing action must not carry its own semantic tint — the colored surface itself now carries the semantic"
        )
    }

    func testIconAndMessageUseWhiteForegroundRatherThanTheirOwnSemanticTint() throws {
        let src = try source("HermesMobile/Features/Shared/HermexToast.swift")
        let iconBlock = try XCTUnwrap(src.components(separatedBy: "if let icon {").last?
            .components(separatedBy: "\n\n").first,
            "expected an `if let icon` block")
        XCTAssertFalse(iconBlock.contains("semantic.tint"), "the icon must use white foreground, not its own semantic tint")
        XCTAssertTrue(iconBlock.contains(".foregroundStyle(.white)"), "expected the icon's foreground to be white")

        XCTAssertNotNil(
            src.range(of: #"message\s*\n\s*\.appFont\([\s\S]{0,120}?\.foregroundStyle\(\.white\)"#, options: .regularExpression),
            "expected the message to use white foreground"
        )
    }

    func testToastSurfaceOwnsTheSemanticBackgroundWithNoRegularMaterialOrRawSemanticTintMapping() throws {
        let src = try source("HermesMobile/Features/Shared/HermexToast.swift")
        XCTAssertTrue(
            src.contains("HermexToastColors.background(for:"),
            "expected the rounded Toast surface to use HermexToastColors.background(for:)"
        )
        XCTAssertFalse(src.contains(".regularMaterial"), "expected no .regularMaterial Toast background")
        XCTAssertFalse(src.contains("semantic.tint"), "expected no raw Semantic.tint mapping left anywhere in production")
    }

    func testOverlayLabIncludesToastFollowupFixturesWithAndWithoutAnAction() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(src.contains("private struct HermexOverlayLabToastFollowup"))
        XCTAssertTrue(src.contains("HermexToast(.success"))
        XCTAssertTrue(src.contains("action: .init(title: \"Undo\""))
        XCTAssertTrue(src.contains("overlay-lab-followup-toast"))
    }

    // MARK: - DEBUG lab reachability (DSR2-08): all four real semantic surfaces, stably identified,
    // alongside the existing follow-up fixture's action specimen.

    func testOverlayLabExposesAllFourSemanticToastSurfacesWithStableIdentifiers() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        for identifier in [
            "overlay-lab-toast-information",
            "overlay-lab-toast-success",
            "overlay-lab-toast-warning",
            "overlay-lab-toast-error",
        ] {
            XCTAssertTrue(src.contains(identifier), "expected a stable identifier for \(identifier)")
        }
        for semantic in [".information", ".success", ".warning", ".error"] {
            XCTAssertTrue(src.contains("HermexToast(\(semantic)"), "expected a real HermexToast(\(semantic) specimen")
        }
    }
}
