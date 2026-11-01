import XCTest
import SwiftUI
@testable import HermesMobile

final class TagTests: XCTestCase {
    func testRetainedSizePaddingMatchesApprovedMetrics() {
        XCTAssertEqual(Tag.Size.compact.horizontalPadding, HermesSpacing.s8)
        XCTAssertEqual(Tag.Size.compact.verticalPadding, HermesSpacing.s2)

        XCTAssertEqual(Tag.Size.regular.horizontalPadding, HermesSpacing.s8)
        XCTAssertEqual(Tag.Size.regular.verticalPadding, HermesSpacing.s4)

        XCTAssertEqual(Tag.Size.prominent.horizontalPadding, HermesSpacing.s12)
        XCTAssertEqual(Tag.Size.prominent.verticalPadding, HermesSpacing.s8)
    }

    func testTintConvenienceInitializerDerivesForegroundAndFillFromOneTint() {
        let tag = Tag(label: "Cached", tint: .orange)

        XCTAssertEqual(tag.foreground, .orange)
        XCTAssertEqual(tag.fill, Color.orange.opacity(0.12))
    }

    func testTintConvenienceInitializerHonorsACustomFillOpacity() {
        let tag = Tag(label: "Modified", tint: .yellow, fillOpacity: 0.18)

        XCTAssertEqual(tag.fill, Color.yellow.opacity(0.18))
    }

    func testExplicitForegroundFillInitializerKeepsThemIndependent() {
        let tag = Tag(label: "Selected", foreground: .red, fill: .blue)

        XCTAssertEqual(tag.foreground, .red)
        XCTAssertEqual(tag.fill, .blue)
    }

    func testDefaultsMatchTheMostCommonExistingCallSite() {
        let tag = Tag(label: "Selected", tint: .accentColor)

        XCTAssertEqual(tag.size, .regular)
        XCTAssertEqual(tag.minimumScaleFactor, 1)
        XCTAssertNil(tag.icon)
        XCTAssertFalse(tag.isDecorative)
        if case .captionSemibold = tag.font {
            // expected
        } else {
            XCTFail("expected the default font role to be .captionSemibold, preserving the shared semibold tag treatment")
        }
    }

    func testIconIsOptionalAndCarriedThroughEitherInitializer() {
        let withTint = Tag(label: "Skill", tint: .purple, icon: "wand.and.stars")
        let withExplicitColors = Tag(label: "Skill", foreground: .purple, fill: .clear, icon: "wand.and.stars")

        XCTAssertEqual(withTint.icon, "wand.and.stars")
        XCTAssertEqual(withExplicitColors.icon, "wand.and.stars")
    }

    // MARK: - Source contract: Tag never exposes an action closure or gesture

    func testTagSourceExposesNoActionClosure() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("HermesMobile/Features/Shared/Tag.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(src.contains("action:"), "Tag must stay display-only: no action closure")
        XCTAssertFalse(src.contains("onTapGesture"), "Tag must stay display-only: no tap gesture")
        XCTAssertFalse(src.contains("case micro"), "Tag no longer supports a micro size")
    }
}
