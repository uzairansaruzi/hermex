import XCTest
@testable import HermesMobile

final class TranscriptLogRowBodyWindowTests: XCTestCase {
    private let cap = TranscriptLogRowMetrics.bodyWindowHeight

    func testUnmeasuredContentStartsClosed() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: nil, cap: cap)

        XCTAssertEqual(layout.frameHeight, 0)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentBelowTheCapTakesItsNaturalHeightWithoutScrolling() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: 96, cap: cap)

        XCTAssertEqual(layout.frameHeight, 96)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentAtTheCapFillsTheWindowWithoutScrolling() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: cap, cap: cap)

        XCTAssertEqual(layout.frameHeight, cap)
        XCTAssertFalse(layout.scrolls)
    }

    func testContentAboveTheCapClipsToTheWindowAndScrolls() {
        let layout = TranscriptLogRowBodyWindowLayout.resolve(contentHeight: 1_800, cap: cap)

        XCTAssertEqual(layout.frameHeight, cap)
        XCTAssertTrue(layout.scrolls)
    }

    func testTheCapIsTwoHundredFortyPoints() {
        XCTAssertEqual(cap, 240)
    }

    func testTheMinimumRowHeightIsThirtyTwoPoints() {
        XCTAssertEqual(TranscriptLogRowMetrics.minimumHeight, 32)
    }

    // MARK: - DSR2-11 source contracts

    /// Repository root, derived from this file's own location rather than an
    /// assumed working directory, so the loader survives being run from any
    /// path.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let transcriptLogRowViewURL = repositoryRoot
        .appendingPathComponent("HermesMobile/Features/Chat/TranscriptLogRowView.swift")

    private static let disclosureRowSourceURL = repositoryRoot
        .appendingPathComponent("HermesMobile/Features/Chat/DisclosureRow.swift")

    private static let disclosureRowTestsURL = repositoryRoot
        .appendingPathComponent("HermesMobileTests/DisclosureRowBodyWindowTests.swift")

    private static let projectFileURL = repositoryRoot
        .appendingPathComponent("HermesMobile.xcodeproj/project.pbxproj")

    private func transcriptLogRowViewSource() throws -> String {
        try String(contentsOf: Self.transcriptLogRowViewURL, encoding: .utf8)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testOuterAndNestedStacksUseZeroSpacingToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertEqual(occurrenceCount(of: "spacing: HermesSpacing.s0", in: source), 2)
    }

    func testRowLineUsesRowSpacingToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(
            source.contains(
                "HStack(alignment: usesStackedLabel ? .top : .center, spacing: HermesSpacing.s8)"
            )
        )
    }

    func testExpandedBodyUsesSpacingTokensForLeadingTopAndBottom() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains(".padding(.leading, HermesSpacing.s12)"))
        XCTAssertTrue(source.contains(".padding(.top, HermesSpacing.s2)"))
        XCTAssertTrue(source.contains(".padding(.bottom, HermesSpacing.s8)"))
    }

    func testTrailingStatusStackUsesSpacingToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("HStack(spacing: HermesSpacing.s2)"))
    }

    func testCopiedLabelUsesTrailingSpacingToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains(".padding(.trailing, HermesSpacing.s4)"))
    }

    func testRowUsesHorizontalPaddingToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains(".padding(.horizontal, HermesSpacing.s2)"))
    }

    func testAccessibilityStackedLabelUsesSpacingToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("VStack(alignment: .leading, spacing: HermesSpacing.s2)"))
    }

    func testPressedBackgroundUsesRadiusToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("RoundedRectangle(cornerRadius: HermesRadius.r8, style: .continuous)"))
    }

    func testChevronIsAlwaysTheDownGlyphWithNoUpBranch() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("Image(systemName: \"chevron.down\")"))
        XCTAssertFalse(source.contains("chevron.up"))
    }

    func testChevronUsesIconSizeTokens() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("HermesIconSize.xs"))
        XCTAssertTrue(source.contains("HermesIconSize.small"))
    }

    func testChevronRotatesWithReduceMotionAwareAnimation() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains(".rotationEffect(.degrees(isExpanded ? 180 : 0))"))
        XCTAssertTrue(
            source.contains("reduceMotion ? nil : .easeInOut(duration: HermesMotion.Duration.d150)")
        )
    }

    func testAccessibilityValueReflectsExpansionState() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(
            source.contains("accessibilityValue(isExpanded ? Text(\"Expanded\") : Text(\"Collapsed\"))")
        )
    }

    func testSummaryAndDetailUseAppFontTokens() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains(".appFont(.captionSemibold, dynamicTypeSize: dynamicTypeSize)"))
        XCTAssertTrue(source.contains(".appFont(.caption, dynamicTypeSize: dynamicTypeSize)"))
    }

    func testStatusFrameUsesIconSizeToken() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains(".frame(width: HermesIconSize.small, height: HermesIconSize.small)"))
    }

    func testIconSlotRetainsNamedTwentyPointWidthAndEighteenPointHeight() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("iconWidth: CGFloat = 20"))
        XCTAssertTrue(source.contains("iconHeight: CGFloat = 18"))
        XCTAssertTrue(
            source.contains(
                ".frame(width: TranscriptLogRowMetrics.iconWidth, height: TranscriptLogRowMetrics.iconHeight)"
            )
        )
    }

    func testBodyIndentDerivesFromIconWidthAndRowSpacingRatherThanAnUnrelatedLiteral() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("rowSpacing: CGFloat = HermesSpacing.s8"))
        XCTAssertTrue(source.contains("iconWidth + rowSpacing"))
    }

    func testExpandedBodyRemainsOwnedByTranscriptLogRowBodyWindow() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("TranscriptLogRowBodyWindow(content: expandedBody)"))
    }

    func testBodyWindowRetainsScrollAndMotionBehavior() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains(".scrollDisabled(!layout.scrolls)"))
        XCTAssertTrue(source.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertTrue(source.contains("ChatMotion.disclosure(reduceMotion: reduceMotion)"))
        XCTAssertTrue(source.contains("ChatMotion.disclosureTransition(reduceMotion: reduceMotion)"))
        XCTAssertTrue(source.contains("ChatMotion.quickState(reduceMotion: reduceMotion)"))
    }

    func testCopyRetainsPasteboardHapticAndCopiedBadge() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("UIPasteboard.general.string = copyText()"))
        XCTAssertTrue(source.contains("ChatHaptics.copied(isEnabled: isHapticsEnabled)"))
        XCTAssertTrue(source.contains("Text(\"Copied\")"))
    }

    func testAccessibilityActionsAndHintsRemain() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("accessibilityAction(named: Text(\"Copy\")) { copy() }"))
        XCTAssertTrue(source.contains("Double tap to hide details. Long press to copy."))
        XCTAssertTrue(source.contains("Double tap to show details. Long press to copy."))
    }

    func testToggleRetainsTranscriptScrollAnchorCallback() throws {
        let source = try transcriptLogRowViewSource()

        XCTAssertTrue(source.contains("chatDisclosureToggled()"))
    }

    func testDisclosureRowProductionFileNoLongerExists() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.disclosureRowSourceURL.path))
    }

    func testDisclosureRowBodyWindowTestsFileNoLongerExists() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.disclosureRowTestsURL.path))
    }

    func testProjectFileNoLongerReferencesDisclosureRowFiles() throws {
        let pbxproj = try String(contentsOf: Self.projectFileURL, encoding: .utf8)

        XCTAssertFalse(pbxproj.contains("DisclosureRow.swift"))
        XCTAssertFalse(pbxproj.contains("DisclosureRowBodyWindowTests.swift"))
    }
}
