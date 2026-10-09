import XCTest
@testable import HermesMobile

final class HermesSpacingTests: XCTestCase {
    func testScaleMatchesApprovedValues() {
        XCTAssertEqual(HermesSpacing.s0, 0)
        XCTAssertEqual(HermesSpacing.s2, 2)
        XCTAssertEqual(HermesSpacing.s4, 4)
        XCTAssertEqual(HermesSpacing.s8, 8)
        XCTAssertEqual(HermesSpacing.s12, 12)
        XCTAssertEqual(HermesSpacing.s16, 16)
        XCTAssertEqual(HermesSpacing.s20, 20)
        XCTAssertEqual(HermesSpacing.s24, 24)
        XCTAssertEqual(HermesSpacing.s32, 32)
        XCTAssertEqual(HermesSpacing.s40, 40)
        XCTAssertEqual(HermesSpacing.s48, 48)
        XCTAssertEqual(HermesSpacing.s64, 64)
        XCTAssertEqual(HermesSpacing.screenHorizontal, 16)
    }

    func testIconSizeScaleMatchesApprovedValues() {
        XCTAssertEqual(HermesIconSize.xs, 12)
        XCTAssertEqual(HermesIconSize.small, 16)
        XCTAssertEqual(HermesIconSize.medium, 20)
        XCTAssertEqual(HermesIconSize.large, 24)
        XCTAssertEqual(HermesIconSize.extraLarge, 32)
    }

    func testIconSizeTypographyPairingAliasesMatchApprovedMapping() {
        XCTAssertEqual(HermesIconSize.Typography.compact, HermesIconSize.xs)
        XCTAssertEqual(HermesIconSize.Typography.standard, HermesIconSize.small)
        XCTAssertEqual(HermesIconSize.Typography.prominent, HermesIconSize.medium)
        XCTAssertEqual(HermesIconSize.Typography.title, HermesIconSize.large)
        XCTAssertEqual(HermesIconSize.Typography.feature, HermesIconSize.extraLarge)
    }

    func testIconSizeAvatarPairingAliasesMatchTheApprovedPairingTable() {
        XCTAssertEqual(HermesIconSize.Avatar.small, HermesIconSize.medium)
        XCTAssertEqual(HermesIconSize.Avatar.small, 20)
        XCTAssertEqual(HermesIconSize.Avatar.medium, HermesIconSize.large)
        XCTAssertEqual(HermesIconSize.Avatar.medium, 24)
        XCTAssertEqual(HermesIconSize.Avatar.large, HermesIconSize.extraLarge)
        XCTAssertEqual(HermesIconSize.Avatar.large, 32)
    }

    func testAttachmentSizeScaleMatchesApprovedValues() {
        XCTAssertEqual(HermesAttachmentSize.compactPreview, 30)
        XCTAssertEqual(HermesAttachmentSize.messageGridCell, 118)
        XCTAssertEqual(HermesAttachmentSize.composerImage, 96)
        XCTAssertEqual(HermesAttachmentSize.composerImageAccessibility, 108)
        XCTAssertEqual(HermesAttachmentSize.fileIconPanelWidth, 58)
        XCTAssertEqual(HermesAttachmentSize.fileIconPanelHeight, 68)
        XCTAssertEqual(HermesAttachmentSize.fileIconPanelWidthAccessibility, 76)
        XCTAssertEqual(HermesAttachmentSize.fileIconPanelHeightAccessibility, 84)
        XCTAssertEqual(HermesAttachmentSize.composerFileTextWidth, 128)
        XCTAssertEqual(HermesAttachmentSize.composerFileTextWidthAccessibility, 160)
        XCTAssertEqual(HermesAttachmentSize.composerFileTileWidth, 222)
        XCTAssertEqual(HermesAttachmentSize.composerFileTileWidthAccessibility, 280)
        XCTAssertEqual(HermesAttachmentSize.composerFileTileMinHeight, 92)
        XCTAssertEqual(HermesAttachmentSize.composerFileTileMinHeightAccessibility, 112)
        XCTAssertEqual(HermesAttachmentSize.composerStripHeight, 108)
        XCTAssertEqual(HermesAttachmentSize.composerStripHeightAccessibility, 132)
        XCTAssertEqual(HermesAttachmentSize.messageFileTextInset, 18)
        XCTAssertEqual(HermesAttachmentSize.removeControl, 24)
        XCTAssertEqual(HermesAttachmentSize.removeOverlap, 6)
        XCTAssertEqual(HermesAttachmentSize.accessibilityVerticalPadding, 10)
    }

    func testUsageSizeScaleMatchesApprovedValues() {
        XCTAssertEqual(HermesUsageSize.chartHeight, 180)
        XCTAssertEqual(HermesUsageSize.legendIndicator, 7)
        XCTAssertEqual(HermesUsageSize.balanceBarHeight, 8)
        XCTAssertEqual(HermesUsageSize.minimumBalanceFill, 8)
    }
}
