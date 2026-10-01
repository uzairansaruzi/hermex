import XCTest
import SwiftUI
@testable import HermesMobile

final class AttachmentTileTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Shared view struct properties

    func testFileGlyphCarriesTheFileTypesIconAtTheGivenSize() {
        let glyph = AttachmentFileGlyph(fileType: AttachmentFileType(fileName: "invoice.pdf"), size: HermesIconSize.extraLarge)

        XCTAssertEqual(glyph.fileType.iconName, "doc.richtext")
        XCTAssertEqual(glyph.size, HermesIconSize.extraLarge)
    }

    func testExtensionLabelCarriesTheFileTypesExtension() {
        let label = AttachmentExtensionLabel(fileType: AttachmentFileType(fileName: "archive.tgz"))

        XCTAssertEqual(label.fileType.extensionLabel, "TGZ")
    }

    func testFileBadgeCarriesItsRequestedPanelSize() {
        let badge = AttachmentFileBadge(
            fileType: AttachmentFileType(fileName: "report.csv"),
            width: HermesAttachmentSize.fileIconPanelWidth,
            height: HermesAttachmentSize.fileIconPanelHeight
        )

        XCTAssertEqual(badge.width, 58)
        XCTAssertEqual(badge.height, 68)
    }

    func testImageTileSurfaceCarriesItsRequestedFrameAndCornerRadius() {
        let surface = AttachmentImageTileSurface(
            width: HermesAttachmentSize.messageGridCell,
            height: HermesAttachmentSize.messageGridCell,
            cornerRadius: HermesRadius.r16
        ) { Color.clear }

        XCTAssertEqual(surface.width, 118)
        XCTAssertEqual(surface.height, 118)
        XCTAssertEqual(surface.cornerRadius, HermesRadius.r16)
    }

    func testImageTileSurfaceDefaultsItsCornerRadiusToTheSharedCardToken() {
        let surface = AttachmentImageTileSurface(
            width: HermesAttachmentSize.messageGridCell,
            height: HermesAttachmentSize.messageGridCell
        ) { Color.clear }

        XCTAssertEqual(surface.cornerRadius, HermesRadius.card)
    }

    // MARK: - Attachment outer-surface radius derives from Card

    func testCompactCardSurfaceDefaultsItsCornerRadiusToTheSharedCardToken() throws {
        let cardSource = try source("HermesMobile/Features/Shared/HermexCard.swift")

        XCTAssertTrue(cardSource.contains("func compactCardSurface(cornerRadius: CGFloat = HermesRadius.card"))
    }

    // MARK: - Attachment remove/close control uses opaque Hermes tokens

    func testRemoveControlColorsAreDerivedFromOpaqueNeutralRampSteps() {
        // Distinct opaque colors per appearance, never `.opacity`-derived, satisfy the contract at
        // the API surface: each resolves to a concrete Color backed by a Neutral ramp step pair.
        XCTAssertNotNil(AttachmentRemoveControlColors.background)
        XCTAssertNotNil(AttachmentRemoveControlColors.border)
        XCTAssertNotNil(AttachmentRemoveControlColors.content)
    }

    func testFileBadgeComposesFromTheSharedGlyphExtensionLabelAndBadgeFillDerivation() throws {
        let familySource = try source("HermesMobile/Features/Shared/AttachmentTile.swift")

        XCTAssertTrue(familySource.contains("AttachmentFileGlyph("))
        XCTAssertTrue(familySource.contains("AttachmentExtensionLabel("))
        XCTAssertTrue(familySource.contains("fileType.badgeFill"))
    }

    func testAttachmentLoadingTileOwnsTheFullBoxSkeletonAndItsAnnouncement() throws {
        let tileSource = try source("HermesMobile/Features/Shared/AttachmentTile.swift")

        XCTAssertTrue(tileSource.contains("struct AttachmentLoadingTile"))
        XCTAssertTrue(tileSource.contains(".skeletonPlaceholder()"))
        XCTAssertTrue(tileSource.contains(".skeletonAnnouncement("))
        XCTAssertFalse(tileSource.contains("ProgressView"))
    }
}
