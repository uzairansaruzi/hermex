import XCTest
import SwiftUI
import UIKit
@testable import HermesMobile

/// Source contracts for `SegmentedControl` (`SegmentedControl.swift`). The fixed variant is a native
/// `HStack`/`Button` composition, not an inspectable rendered tree, so its visual-track geometry is
/// verified as a source contract rather than a hosted-view measurement.
final class SegmentedControlTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    private func segmentedControlSource() throws -> String {
        try source("HermesMobile/Features/Shared/SegmentedControl.swift")
    }

    /// Isolates the `.fixed` case's own body (from its `case .fixed:` line up to the sibling
    /// `case .scrolling:` line), scoped narrowly so an assertion about the fixed track's visual
    /// padding/background never accidentally matches the scrolling branch's own padding.
    private func fixedCaseSource() throws -> String {
        let src = try segmentedControlSource()
        let after = try XCTUnwrap(src.components(separatedBy: "case .fixed:").last,
                                   "expected a `case .fixed:` branch in SegmentedControl's body")
        return try XCTUnwrap(after.components(separatedBy: "case .scrolling:").first,
                              "expected the `.fixed` branch to precede a `case .scrolling:` branch")
    }

    private func scrollingCaseSource() throws -> String {
        let src = try segmentedControlSource()
        let after = try XCTUnwrap(src.components(separatedBy: "case .scrolling:").last,
                                   "expected a `case .scrolling:` branch in SegmentedControl's body")
        return try XCTUnwrap(after.components(separatedBy: "\n    }").first,
                              "expected the `.scrolling` branch to close before body's closing brace")
    }

    /// Isolates the selected-pill construction shared by `optionButton(_:expandsToFill:)` — the `if
    /// isSelected { ... }` block building the capsule both the fixed and scrolling variants render —
    /// scoped narrowly so an assertion about its sizing modifier never accidentally matches an
    /// unrelated part of the file.
    private func selectedPillBlockSource() throws -> String {
        let src = try segmentedControlSource()
        let after = try XCTUnwrap(src.components(separatedBy: "if isSelected {").last,
                                   "expected an `if isSelected` block constructing the selected pill")
        return try XCTUnwrap(
            after.components(separatedBy: "optionLabel(option, isSelected: isSelected, expandsToFill: expandsToFill)").first,
            "expected the selected-pill block to precede the optionLabel(...) call"
        )
    }

    // MARK: - Issue #DSF-04: visible fixed-track density (40pt visual track, 44pt touch target)

    func testFixedTrackNamesAVisualPaddingStepEqualToHermesSpacingS2() throws {
        let src = try segmentedControlSource()
        XCTAssertTrue(
            src.contains("fixedTrackVisualPadding: CGFloat = HermesSpacing.s2"),
            "expected a named fixed-track vertical visual padding constant equal to HermesSpacing.s2"
        )
    }

    func testFixedTrackNamesTokenizedInsetsThatProduce40And36ptVisualLayersAtThe44ptMinimum() throws {
        let src = try segmentedControlSource()
        XCTAssertTrue(
            src.contains("selectedVisualInset: CGFloat = HermesSpacing.s4"),
            "expected the selected pill to use a 4pt tokenized inset, producing 36pt at the 44pt minimum while allowing growth with larger text"
        )
    }

    func testFixedCaseInsetsItsVisualTrackBackgroundInsteadOfFixingItsHeight() throws {
        let fixedCase = try fixedCaseSource()
        XCTAssertTrue(
            fixedCase.contains(".padding(.vertical, SegmentedControlMetrics.fixedTrackVisualPadding)"),
            "expected the fixed track background to inset from the text-bearing row, producing 40pt at normal size and growing with accessibility text"
        )
        XCTAssertFalse(
            fixedCase.contains(".frame(height: SegmentedControlMetrics.fixedTrackVisualHeight)"),
            "the fixed track must not stay locked to 40pt when accessibility text makes the interactive row taller"
        )
    }

    // MARK: - Issue #DSF-04 correction: scrolling's selected pill stays otherwise unchanged
    //
    // The accepted correction requires the fixed variant's selected pill to keep the dynamic inset
    // (so it grows with accessibility-sized labels, matching the fixed track's own accessibility
    // behavior), while the scrolling variant's selected pill reverts to its prior fixed 36pt visual
    // height via a named metric — the review found the two variants had been unintentionally merged
    // onto one shared, always-dynamic sizing when only the fixed variant was supposed to change.

    func testFixedSelectedPillInsetsFromItsTextBearingRowInsteadOfUsingAFixedHeight() throws {
        let block = try selectedPillBlockSource()
        XCTAssertTrue(block.contains("expandsToFill"),
                      "expected the selected pill's own sizing to branch on expandsToFill so fixed and scrolling can diverge")
        XCTAssertTrue(block.contains(".padding(.vertical, SegmentedControlMetrics.selectedVisualInset)"),
                      "expected the fixed variant's selected pill to keep growing with the option label via its 4pt inset")
    }

    func testScrollingSelectedPillKeepsItsPriorFixed36ptVisualHeightInsteadOfGrowingWithAccessibilityText() throws {
        let block = try selectedPillBlockSource()
        XCTAssertTrue(block.contains(".frame(height: SegmentedControlMetrics.scrollingSelectedPillHeight)"),
                      "expected the scrolling variant's selected pill to keep its prior fixed 36pt visual height via a named metric — the accepted correction leaves scrolling otherwise unchanged")
    }

    func testScrollingSelectedPillHeightMetricIsNamedAndEqualsThirtySixPoints() throws {
        let src = try segmentedControlSource()
        XCTAssertTrue(
            src.contains("scrollingSelectedPillHeight: CGFloat = 36"),
            "expected a named 36pt fixed visual-height metric for the scrolling variant's selected pill, restoring its prior geometry exactly"
        )
    }

    func testFixedLabelsIntentionallyUseAtMostTwoCenteredLinesAtAccessibilitySizes() throws {
        let src = try segmentedControlSource()
        XCTAssertTrue(src.contains(".lineLimit(expandsToFill ? 2 : nil)"),
                      "fixed equal-width segment labels must have an explicit two-line accessibility fallback while scrolling labels remain unconstrained")
        XCTAssertTrue(src.contains(".multilineTextAlignment(.center)"),
                      "multi-line fixed segment labels must remain visually centered inside their equal-width segment")
    }

    func testFixedCaseRetainsThe44ptMinimumTouchTarget() throws {
        let fixedCase = try fixedCaseSource()
        XCTAssertTrue(
            fixedCase.contains("SegmentedControlMetrics.minimumTouchHeight"),
            "expected the fixed variant's interactive row to keep the 44pt minimum touch target"
        )
    }

    // MARK: - DSR2-04: fixed track inset moves from HermesSpacing.s4 to HermesSpacing.s2 on all
    // four sides
    //
    // `trackInset` (horizontal) joins `fixedTrackVisualPadding` (vertical, already HermesSpacing.s2)
    // at the same HermesSpacing.s2 step, so the fixed track and selected pill keep the same visual
    // gap on all four sides instead of a larger horizontal-only inset.

    func testTrackInsetMovesFromHermesSpacingS4ToHermesSpacingS2() throws {
        let src = try segmentedControlSource()
        XCTAssertTrue(
            src.contains("trackInset: CGFloat = HermesSpacing.s2"),
            "expected the fixed track's horizontal inset to be HermesSpacing.s2, matching the vertical fixedTrackVisualPadding so all four sides use the same step"
        )
        XCTAssertFalse(
            src.contains("trackInset: CGFloat = HermesSpacing.s4"),
            "the retired 4pt horizontal-only inset must be gone"
        )
    }

    func testFixedTrackVisualPaddingStaysHermesSpacingS2() throws {
        let src = try segmentedControlSource()
        XCTAssertTrue(
            src.contains("fixedTrackVisualPadding: CGFloat = HermesSpacing.s2"),
            "expected the fixed track's vertical visual padding to remain HermesSpacing.s2, unchanged by the trackInset correction"
        )
    }

    func testSelectedVisualInsetStaysHermesSpacingS4() throws {
        let src = try segmentedControlSource()
        XCTAssertTrue(
            src.contains("selectedVisualInset: CGFloat = HermesSpacing.s4"),
            "expected the selected pill's own inset to remain HermesSpacing.s4, unchanged by the trackInset correction"
        )
    }

    func testFixedBackgroundUsesFixedTrackVisualPaddingVerticallyAndTrackInsetHorizontally() throws {
        let fixedCase = try fixedCaseSource()
        XCTAssertTrue(
            fixedCase.contains("SegmentedControlMetrics.trackInset"),
            "expected the fixed track's horizontal inset to keep coming from SegmentedControlMetrics.trackInset"
        )
        XCTAssertTrue(
            fixedCase.contains(".padding(.vertical, SegmentedControlMetrics.fixedTrackVisualPadding)"),
            "expected the fixed track background to keep insetting vertically by SegmentedControlMetrics.fixedTrackVisualPadding"
        )
    }

    func testScrollingCaseStaysStructurallyUnchangedByTheFixedTrackVisualBackground() throws {
        let scrollingCase = try scrollingCaseSource()
        XCTAssertFalse(
            scrollingCase.contains("fixedTrackVisualPadding"),
            "the scrolling branch must not adopt the new fixed-track visual background"
        )
    }

    // MARK: - Hosted regression: the selected pill's Capsule has no height cap (unconstrained)
    //
    // The source contracts above confirm the selected pill insets from its text-bearing row via
    // `.padding(.vertical, SegmentedControlMetrics.selectedVisualInset)`, with no `.frame(height:)`
    // or `.frame(maxHeight:)` anywhere on it. A plain `Capsule()` is a greedy shape that fills
    // whatever height its parent *proposes*, not merely the height its sibling (the text row) needs,
    // so hosting the fixed control in a bounded, non-scrolling container that offers far more
    // vertical room than the row needs reveals the real defect no source-string check can see: the
    // whole control's rendered height balloons toward the host's bound instead of tracking its
    // 44pt-minimum interactive row.
    @MainActor
    private func measuredFixedControlHeight(dynamicTypeSize: DynamicTypeSize, hostHeight: CGFloat) -> CGFloat {
        let control = SegmentedControl(
            "View",
            selection: .constant("one"),
            options: [
                SegmentedControlOption(value: "one", title: "One"),
                SegmentedControlOption(value: "two", title: "Two"),
            ],
            style: .fixed
        )
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        let hosting = UIHostingController(rootView: control)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 360, height: hostHeight)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        return hosting.sizeThatFits(in: CGSize(width: 360, height: hostHeight)).height
    }

    @MainActor
    func testFixedSelectedCapsuleStaysNearTheInteractiveRowHeightAtNormalSizeInAGenerousBoundedHost() {
        let height = measuredFixedControlHeight(dynamicTypeSize: .large, hostHeight: 600)
        XCTAssertLessThan(
            height, 80,
            "expected the fixed track to stay near its 44pt interactive row height at normal text size " +
                "even when hosted with generous extra vertical room — the selected pill's Capsule has no " +
                "height cap, so it greedily fills whatever height is proposed instead of tracking the row"
        )
    }

    @MainActor
    func testFixedSelectedCapsuleStaysNearTheInteractiveRowHeightAtAccessibility5InAGenerousBoundedHost() {
        let height = measuredFixedControlHeight(dynamicTypeSize: .accessibility5, hostHeight: 600)
        XCTAssertLessThan(
            height, 160,
            "expected the fixed track to grow only with its accessibility-sized label even when hosted " +
                "with generous extra vertical room — the selected pill's Capsule has no height cap, so it " +
                "greedily fills whatever height is proposed instead of tracking the row"
        )
    }

    func testOverlayLabIncludesReachableFixedAndScrollingFollowupFixtures() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(src.contains("--hermex-overlay-lab-followup"))
        XCTAssertTrue(src.contains("private struct HermexOverlayLabSegmentedControlFollowup"))
        XCTAssertTrue(src.contains("style: .fixed"))
        XCTAssertTrue(src.contains("style: .scrolling"))
        XCTAssertTrue(src.contains("overlay-lab-followup-segmented-fixed"))
    }
}
