import Observation
import XCTest
import SwiftUI
import UIKit
@testable import HermesMobile

/// Contracts for `HermexPopoverMenu` (`HermexPopoverMenu.swift`): a fully custom, trigger-anchored
/// floating menu mounted through `HermexSameWindowOverlay`, never a native `Menu`/`.contextMenu`/
/// `.popover`. Public API, row composition, and non-directly-observable behavior (exact lifecycle
/// wiring, motion bundle reuse, first-enabled-focus selection logic) stay source-contract checks —
/// the same established pattern as `HermexDialogTests`/`HermexListTests` — via `popoverMenuSource()`,
/// which fails the calling test explicitly through `XCTFail`, attributed to that test's own
/// file/line. `HermexPopoverPlacement.resolve` and `HermexPopoverMenuContentSizing` are pure and
/// get real unit coverage. Mount/unmount, modal isolation, Escape dismissal, and touch containment
/// get real hosted-window coverage, matching `HermexDialogTests`'s "Rendered behavior" section;
/// per-row action activation inside a real SwiftUI `List` is left to the DEBUG Overlay Lab's
/// manual/rendered pass rather than a hosted XCTest, since `List` virtualizes its rows and there is
/// no reliable, non-sleeping way to force cell materialization in a headless test window.
@MainActor final class HermexPopoverMenuTests: XCTestCase {
    private static let popoverMenuRelativePath = "HermesMobile/Features/Shared/HermexPopoverMenu.swift"

    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func popoverMenuSource(file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        let url = resourceURL(Self.popoverMenuRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("expected \(Self.popoverMenuRelativePath) to exist", file: file, line: line)
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Public API

    func testExposesTheApprovedPublicModifierAndActionTypes() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("func hermexPopoverMenu("), "expected the approved hermexPopoverMenu(...) presentation modifier")
        XCTAssertTrue(src.contains("struct HermexPopoverMenuAction"), "expected the approved HermexPopoverMenuAction row model")
        XCTAssertTrue(src.contains("enum HermexPopoverMenuActionRole"), "expected the approved standard/destructive role enum")
    }

    func testRequiresACallerSuppliedAccessibilityLabel() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("accessibilityLabel: Text"),
            "the caller must always name the trigger's context; there is no generic hidden default such as \"Actions\""
        )
    }

    func testActionModelExposesStableIdentityOptionalSymbolEnabledRoleAndOneClosure() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("let id: AnyHashable"), "expected a stable, caller-supplied row identity")
        XCTAssertTrue(src.contains("let title:"), "expected a required row title")
        XCTAssertTrue(src.contains("let systemImage: String?"), "expected an optional row symbol")
        XCTAssertTrue(src.contains("let isEnabled: Bool"), "expected an enabled/disabled row flag")
        XCTAssertTrue(src.contains("let role: HermexPopoverMenuActionRole"), "expected a standard/destructive row role")
        XCTAssertTrue(src.contains("let action:"), "expected exactly one action closure per row — no nested rows or arbitrary content")
    }

    // MARK: - Same-window host and lifecycle reuse, not a rewrite

    func testUsesTheExistingRootSameWindowHostInsteadOfNativeMenuOrPopover() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("HermexSameWindowOverlay("), "must reuse the existing shared same-window host, not a bespoke one")
        XCTAssertTrue(src.contains(".root"), "the menu mounts at root bounds, like HermexDialog")
        XCTAssertFalse(src.contains("Menu {"), "must never present a native SwiftUI Menu")
        XCTAssertFalse(src.contains(".contextMenu"), "must never present a native .contextMenu")
        XCTAssertFalse(src.contains(".popover("), "must never present a native .popover")
        XCTAssertFalse(src.contains(".sheet("), "must never adapt into a sheet")
        XCTAssertFalse(src.contains("fullScreenCover"), "must never adapt into a full-screen cover")
        XCTAssertFalse(src.contains(".alert("), "must never present as a native alert")
    }

    func testUsesTheExistingSharedOverlayLifecycleInsteadOfANewOne() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("HermexOverlayLifecycle()"), "must reuse the existing shared generation-based lifecycle, not a bespoke one")
        XCTAssertTrue(src.contains("lifecycle.beginPresentation()"))
        XCTAssertTrue(src.contains("lifecycle.completePresentation(generation:"))
        XCTAssertTrue(src.contains("lifecycle.beginDismissal(after:"), "an enabled action must be deferred through the shared lifecycle, run only after exit completes")
        XCTAssertTrue(src.contains("lifecycle.completeDismissal(generation:"))
        XCTAssertTrue(src.contains("lifecycle.cancelOwner()"), "owner teardown must cancel the lifecycle so a stale completion can never act")
    }

    // MARK: - Row composition

    func testComposesHermexListCompactOverlayAndListItemForEachRow() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("HermexList(style: .compactOverlay)"),
            "must compose HermexList's compact-overlay style (see HermexListTests), not a bespoke list container"
        )
        XCTAssertTrue(src.contains("ListItem("), "must render each action through the shared ListItem row anatomy")
    }

    func testDisabledActionsMapToListItemDisabledStateAndStayVisible() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("isDisabled:") && src.contains("action.isEnabled"),
            "a disabled action must map onto ListItem's disabled row state — disabled rows remain visible and announced but never act or dismiss"
        )
    }

    func testDestructiveActionsExposeTextualSemanticsNotJustColor() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("Destructive action"), "destructive rows must carry a textual accessibility hint, not rely on color alone")
        XCTAssertTrue(src.contains(".destructive"), "expected the destructive role to be handled explicitly")
    }

    // MARK: - Accessibility, focus, and dismissal ownership

    func testFirstEnabledActionReceivesInitialAccessibilityFocus() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("AccessibilityFocusState"),
            "expected an accessibility focus binding so initial VoiceOver focus reaches the first enabled row"
        )
    }

    func testMenuSurfaceIsAModalAccessibilityContainerNamedByTheCaller() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains(".accessibilityAddTraits(.isModal)"),
            "the underlying screen must be isolated from touch and accessibility interaction while the menu is presented"
        )
        XCTAssertTrue(
            src.contains(".accessibilityElement(children:"),
            "expected the menu surface to be a named accessibility container, not a loose collection of rows"
        )
    }

    func testAccessibilityEscapeIsWired() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains(".accessibilityAction(.escape)"), "expected VoiceOver Escape to dismiss the menu without running an action")
    }

    func testInputIsDisabledOutsidePresented() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains(".allowsHitTesting(lifecycle.phase == .presented)"),
            "actions must be accepted only while fully presented, matching HermexDialog's established pattern"
        )
    }

    /// `HermexOverlayLifecycleTests` proves the exactly-once/fresh-generation/cancellation semantics
    /// of a queued reopen at the lifecycle level; this is the smallest contract proving
    /// `HermexPopoverMenu` actually reads and acts on that result, matching `HermexDialogTests`.
    func testFinishExitRunsTheDeferredActionThenResumesAFreshEntryOnAQueuedReopenInsteadOfUnmounting() throws {
        guard let src = try popoverMenuSource() else { return }
        let finishExitBody = try XCTUnwrap(
            src.components(separatedBy: "private func finishExit(generation: Int) {").last,
            "expected a finishExit(generation:) function"
        )
        XCTAssertTrue(
            finishExitBody.contains("case .completed(let action, let reopened):"),
            "finishExit must read both the deferred action and any queued reopen generation from completeDismissal"
        )
        guard let reopenedRange = finishExitBody.range(of: "guard let reopened else {") else {
            return XCTFail("expected finishExit to branch on whether a reopen was queued")
        }
        guard let onExitRange = finishExitBody.range(of: "onExitCompleted(action)") else {
            return XCTFail("expected the no-reopen branch to still hand off through onExitCompleted")
        }
        guard let beginEntryRange = finishExitBody.range(of: "beginEntry(generation: reopened)") else {
            return XCTFail("expected a queued reopen to resume the same mounted surface via beginEntry, never onExitCompleted")
        }
        XCTAssertLessThan(reopenedRange.lowerBound, onExitRange.lowerBound,
                          "onExitCompleted must only run inside the no-reopen branch")
        XCTAssertLessThan(onExitRange.upperBound, beginEntryRange.lowerBound,
                          "the queued-reopen path must come after, and be distinct from, the onExitCompleted branch")
    }

    // MARK: - Motion reuse (no new tokens)

    func testUsesExistingMotionBundlesAndReduceMotionFallback() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("HermesMotion.Bundle.overlayEnter"))
        XCTAssertTrue(src.contains("HermesMotion.Bundle.overlayExit"))
        XCTAssertTrue(src.contains("reduceMotion"), "Reduce Motion must remove translation and keep an opacity-only state change")
    }

    func testDirectionalEntryOffsetIsFourPointsPerImplementationPlan() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("motionOffset"), "expected a named local motion-offset constant, not a bare literal")
        XCTAssertEqual(HermexPopoverMenuMetrics.motionOffset, 4, "below enters from y = -4 and above enters from y = +4 per the implementation plan")
    }

    func testEntryWaitsForMeasuredContainerAndDoesNotRepositionFromZeroGeometry() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("guard containerBounds.width > 0, containerBounds.height > 0"),
            "entry must not start until the same-window container has real geometry"
        )
        XCTAssertFalse(
            src.contains(".onAppear(perform: present)"),
            "starting entry directly on appear lets the zero-sized initial placement animate across the screen"
        )
        XCTAssertTrue(
            src.contains("lifecycle.phase == .presented ? HermesMotion.animation(for: HermesMotion.Bundle.contentReposition) : nil"),
            "placement changes may animate only after entry completes, never from zero geometry during entry"
        )
    }

    // MARK: - Outside tap and hardware Escape (source contracts; not hosted — see class doc)

    func testOutsideTapRequestsDismissalWithoutRunningAnAction() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains(".onTapGesture { requestDismissal(after: nil) }"),
            "an outside tap must request a plain dismissal — it must never run an action"
        )
    }

    func testOutsideTapLayerIsClearNotDimmedUnlikeDialog() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("Color.clear"), "expected a clear, non-dimming outside-tap hit layer")
        XCTAssertFalse(src.contains("Color.black.opacity"), "the popover's outside-tap layer must never dim, unlike HermexDialog's scrim")
    }

    func testHardwareEscapeUsesTheEstablishedCancelShortcutPattern() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains(".keyboardShortcut(.cancelAction)"), "expected hardware Escape via the established cancel-shortcut pattern")
    }

    func testAnchorDisappearanceDismissesWithoutAnAction() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("frame == nil, isMounted"),
            "expected the trigger anchor reader to drop straight to hidden, without an action, once its anchor disappears"
        )
    }

    // MARK: - Anchor and container geometry (source contracts; pure math is covered under Placement)

    func testTriggerAnchorReaderUsesLayoutSubviewsAndDidMoveToWindowWithoutPolling() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("override func layoutSubviews()"))
        XCTAssertTrue(src.contains("override func didMoveToWindow()"))
        XCTAssertFalse(src.contains("Timer("), "must not poll on a timer for anchor or container geometry")
        XCTAssertFalse(src.contains("DispatchQueue.main.asyncAfter"), "must not poll on a delayed dispatch for anchor or container geometry")
    }

    func testRecomputesPlacementFromLiveContainerGeometryAndSafeAreaInsets() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(src.contains("safeAreaInsets"))
        XCTAssertTrue(src.contains("containerBounds"))
        XCTAssertTrue(src.contains("HermexPopoverPlacement.resolve("))
    }

    func testInitialFocusLogicSelectsTheFirstEnabledActionSpecifically() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("actions.first(where: { $0.isEnabled })"),
            "initial focus must specifically select the first ENABLED action, not merely actions.first"
        )
    }

    // MARK: - Placement resolver (pure; real unit coverage, not source contracts)

    private func metrics() -> (margin: CGFloat, gap: CGFloat, width: CGFloat, minRow: CGFloat) {
        (
            HermexPopoverMenuMetrics.safeAreaMargin,
            HermexPopoverMenuMetrics.anchorGap,
            HermexPopoverMenuMetrics.preferredWidth,
            HermexPopoverMenuMetrics.minimumRowHeight
        )
    }

    func testPlacementPrefersBelowWhenMenuFits() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 844)
        let anchor = CGRect(x: 20, y: 100, width: 60, height: 40)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let placement = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )

        XCTAssertEqual(placement.edge, .below)
        XCTAssertEqual(placement.frame, CGRect(x: 20, y: 148, width: 280, height: 132))
    }

    func testPlacementFlipsAboveWhenBelowDoesNotFit() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 844)
        let anchor = CGRect(x: 20, y: 780, width: 60, height: 40)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let placement = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )

        XCTAssertEqual(placement.edge, .above)
        XCTAssertEqual(placement.frame, CGRect(x: 20, y: 640, width: 280, height: 132))
    }

    func testPlacementClampsLeadingAndTrailingEdgesToSafeArea() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 844)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let leading = HermexPopoverPlacement.resolve(
            anchor: CGRect(x: 2, y: 100, width: 40, height: 40),
            preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )
        XCTAssertEqual(leading.frame.minX, 12, "must clamp inside the 12pt safe-area margin, not sit flush with the screen edge")

        let trailing = HermexPopoverPlacement.resolve(
            anchor: CGRect(x: 370, y: 100, width: 40, height: 40),
            preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )
        XCTAssertEqual(trailing.frame.maxX, 378, "must clamp so the trailing edge stays inside the 12pt safe-area margin")
    }

    func testPlacementChoosesLargerSideAndReturnsBoundedHeightWhenNeitherFits() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 300)
        let anchor = CGRect(x: 20, y: 145, width: 60, height: 20)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let placement = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )

        XCTAssertLessThan(placement.frame.height, preferred.height, "neither side fits the full preferred height, so it must be bounded")
        XCTAssertGreaterThanOrEqual(placement.frame.height, metrics().minRow, "the bounded height must never drop below the minimum row height")
    }

    func testPlacementRecomputesForRotationOrSafeAreaChange() {
        let anchor = CGRect(x: 20, y: 100, width: 60, height: 40)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let portrait = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred,
            containerBounds: CGRect(x: 0, y: 0, width: 390, height: 844), safeAreaInsets: .zero
        )
        let landscapeWithSafeArea = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred,
            containerBounds: CGRect(x: 0, y: 0, width: 844, height: 390),
            safeAreaInsets: UIEdgeInsets(top: 0, left: 47, bottom: 21, right: 47)
        )

        XCTAssertNotEqual(portrait, landscapeWithSafeArea, "changed container bounds and safe-area insets must recompute a different placement")
    }

    func testPlacementPreservesAnchorGapAfterClamp() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 844)
        let anchor = CGRect(x: 2, y: 100, width: 40, height: 40)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let placement = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )

        XCTAssertEqual(placement.edge, .below)
        XCTAssertEqual(placement.frame.minY, anchor.maxY + metrics().gap, "horizontal clamping must never change the vertical anchor gap")
    }

    func testPlacementNeverInflatesHeightAboveAvailableSafeAreaSpace() {
        // Regression for a real rendering defect (reproduced live: the resolved menu overflowed
        // past the container, clipping the last action). When neither side has room for even one
        // `HermexPopoverMenuMetrics.minimumRowHeight`, the resolver must still return a frame that
        // fits inside the safe area, not a height inflated up to that per-row floor. `HermexList`
        // already guarantees the *row* floor via `defaultMinListRowHeight`; the *viewport* can be
        // smaller than one row and simply scroll to reach the rest.
        let container = CGRect(x: 0, y: 0, width: 390, height: 100)
        let anchor = CGRect(x: 20, y: 40, width: 60, height: 20)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let placement = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )

        let safeTop = container.minY + metrics().margin
        let safeBottom = container.maxY - metrics().margin
        XCTAssertLessThanOrEqual(placement.frame.maxY, safeBottom, "the resolved frame must never overflow past the safe-area bottom")
        XCTAssertGreaterThanOrEqual(placement.frame.minY, safeTop, "the resolved frame must never overflow past the safe-area top")
        XCTAssertLessThan(
            placement.frame.height, metrics().minRow,
            "when neither side has 44pt of room, the bounded height must reflect the real available space, not an inflated 44pt floor"
        )
    }

    func testPlacementHandlesNonzeroContainerOrigin() {
        // The same-window host's root need not sit at window origin (0, 0) — the container
        // geometry reader reports the host's own bounds converted into window coordinates, which
        // can be offset. The resolver must clamp relative to that origin, not assume (0, 0).
        let container = CGRect(x: 100, y: 50, width: 390, height: 844)
        let anchor = CGRect(x: 120, y: 150, width: 60, height: 40)
        let preferred = CGSize(width: metrics().width, height: 3 * metrics().minRow)

        let placement = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )

        XCTAssertEqual(placement.edge, .below)
        XCTAssertEqual(
            placement.frame, CGRect(x: 120, y: 198, width: 280, height: 132),
            "must clamp relative to the container's own origin, not assume it sits at window (0, 0)"
        )
    }

    func testResolverMetricsMatchApprovedConstants() {
        XCTAssertEqual(HermexPopoverMenuMetrics.safeAreaMargin, 12)
        XCTAssertEqual(HermexPopoverMenuMetrics.anchorGap, 8)
        XCTAssertEqual(HermexPopoverMenuMetrics.preferredWidth, 280)
        XCTAssertEqual(HermexPopoverMenuMetrics.minimumRowHeight, 44)
    }

    // MARK: - Content sizing (pure; real per-row height, not actions.count * minimumRowHeight)

    func testEstimatedContentHeightAccountsForRealListItemHeightNotBareMinimumRowHeight() {
        let naive = CGFloat(3) * HermexPopoverMenuMetrics.minimumRowHeight
        let real = HermexPopoverMenuContentSizing.preferredContentHeight(actionCount: 3, dynamicTypeSize: .large)
        XCTAssertGreaterThan(
            real, naive,
            "the real per-row height (48pt ListItem content plus compact-overlay row insets) is taller than the bare 44pt minimum-row floor"
        )
    }

    func testEstimatedContentHeightGrowsMeaningfullyAtAccessibilityDynamicTypeSizes() {
        let standard = HermexPopoverMenuContentSizing.preferredContentHeight(actionCount: 3, dynamicTypeSize: .large)
        let accessibility = HermexPopoverMenuContentSizing.preferredContentHeight(actionCount: 3, dynamicTypeSize: .accessibility5)
        XCTAssertGreaterThan(
            accessibility, standard * 1.5,
            "the largest accessibility Dynamic Type size must ask for meaningfully more room, not the same estimate every size gets"
        )
    }

    func testShortMenuFitsFullyWithoutClampingWhenTheContainerHasRoom() {
        let preferred = CGSize(
            width: metrics().width,
            height: HermexPopoverMenuContentSizing.preferredContentHeight(actionCount: 3, dynamicTypeSize: .large)
        )
        let placement = HermexPopoverPlacement.resolve(
            anchor: CGRect(x: 20, y: 100, width: 60, height: 40),
            preferredSize: preferred,
            containerBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            safeAreaInsets: .zero
        )
        XCTAssertEqual(
            placement.frame.height, preferred.height,
            "a short menu with ample room must render at its full estimated height, never clamped into scrolling"
        )
    }

    func testLongMenuClampsToAvailableSpaceAndScrollsInsteadOfOverflowing() {
        let preferred = CGSize(
            width: metrics().width,
            height: HermexPopoverMenuContentSizing.preferredContentHeight(actionCount: 12, dynamicTypeSize: .large)
        )
        let container = CGRect(x: 0, y: 0, width: 390, height: 500)
        let anchor = CGRect(x: 20, y: 420, width: 60, height: 20)
        let placement = HermexPopoverPlacement.resolve(
            anchor: anchor, preferredSize: preferred, containerBounds: container, safeAreaInsets: .zero
        )
        XCTAssertLessThan(
            placement.frame.height, preferred.height,
            "a 12-row menu must clamp to the available space rather than overflow — HermexList scrolls internally to reach the rest"
        )
    }

    // MARK: - Component-local shell padding (Issue #607, Round 3, Task 4)
    //
    // `HermexList.Style.compactOverlay`'s own row horizontal inset and scroll-content margin
    // collapse to zero (see `HermexListTests`), so the popover now owns its own shell padding around
    // the list content instead. `HermexPopoverMenuMetrics.contentPadding` does not exist yet — a
    // source-only contract, matching the established pattern above.

    func testDefinesAComponentLocalContentPaddingOfSixteenPoints() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("static let contentPadding: CGFloat = HermesSpacing.s16"),
            "expected a component-local contentPadding of HermesSpacing.s16, replacing the spacing HermexList.Style.compactOverlay used to own"
        )
    }

    func testPreferredContentHeightIncludesTwoShellPaddings() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("HermexPopoverMenuMetrics.contentPadding * 2"),
            "expected the preferred content height estimate to budget for the shell padding on both the top and bottom edge"
        )
    }

    func testMenuSurfaceAppliesTheShellPaddingExactlyOnce() throws {
        guard let src = try popoverMenuSource() else { return }
        let menuSurfaceBody = try XCTUnwrap(
            src.components(separatedBy: "private var menuSurface: some View {").last,
            "expected a menuSurface computed property"
        )
        let occurrences = menuSurfaceBody.components(separatedBy: ".padding(HermexPopoverMenuMetrics.contentPadding)").count - 1
        XCTAssertEqual(
            occurrences, 1,
            "expected menuSurface to apply the shell padding exactly once, not per-row and not doubled with any remaining HermexList spacing"
        )
    }

    func testPopoverListItemsRequestNoContentInset() throws {
        guard let src = try popoverMenuSource() else { return }
        XCTAssertTrue(
            src.contains("contentInset: .none"),
            "expected popover rows to opt into ListItemContentInset.none now that the shell owns the surrounding padding"
        )
    }

    // MARK: - Public construction

    func testPublicAPICompilesWithRealActionsAndAccessibilityLabel() {
        struct Host: View {
            @State var isPresented = false
            var body: some View {
                Text("Trigger").hermexPopoverMenu(
                    isPresented: $isPresented,
                    accessibilityLabel: Text("Row actions"),
                    actions: [
                        HermexPopoverMenuAction(id: "pin", title: "Pin", systemImage: "pin", action: {}),
                        HermexPopoverMenuAction(id: "delete", title: "Delete", role: .destructive, action: {})
                    ]
                )
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    // MARK: - Rendered behavior
    // Reduce Motion is forced on the harness so present/dismiss complete synchronously within one
    // MainActor turn — deterministic, with no sleep or polling — matching HermexDialogTests.

    func testMountsAnchoredModalHostAndUnmountsOnEscape() async throws {
        let model = HermexPopoverMenuHarnessModel()
        let window = try show(HermexPopoverMenuHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        model.isPresented = true
        await settle(window)

        let overlayHost = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier
        })
        XCTAssertTrue(overlayHost.accessibilityViewIsModal, "the mounted host must isolate the underlying screen")

        // VoiceOver starts on the first enabled action. The List's UIKit collection view also
        // inherits the surface identifier, but is not the focused accessibility element.
        let focusedAction = try XCTUnwrap(accessibilityNode(
            withIdentifier: "hermex-popover-menu-action-first", in: window
        ))
        XCTAssertTrue(focusedAction.accessibilityPerformEscape())
        await settle(window)

        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier })
        XCTAssertEqual(model.actionRunCount, 0, "Escape must never run an action")
    }

    func testInitiallyPresentedBindingMountsTheMenu() async throws {
        let model = HermexPopoverMenuHarnessModel()
        model.isPresented = true
        let window = try show(HermexPopoverMenuHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        XCTAssertTrue(descendants(window).contains {
            $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier
        })
    }

    func testExternalBindingFalseRunsExitBeforeUnmount() async throws {
        let model = HermexPopoverMenuHarnessModel()
        let window = try show(HermexPopoverMenuHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier })

        model.isPresented = false
        // No run-loop turn has occurred yet — the host must still be mounted immediately after the
        // caller's own state write, proving unmount is never synchronous with it.
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier },
                      "unmounting must not happen synchronously with the caller's own binding write")

        await settle(window)
        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier },
                        "the host must eventually unmount once exit completes")
    }

    func testMenuSurfaceClaimsTouchesOverItsOwnBoundsInsteadOfTheOutsideDismissLayer() async throws {
        // A real, observable hit-test — not a source assertion — mirroring
        // `HermexDialogTests.testBackdropInterceptsTouchesWithoutDismissing`: a touch over the
        // menu's own rendered bounds must be claimed inside its host, never fall through to the
        // full-screen clear outside-tap layer sitting behind it in the same ZStack.
        let model = HermexPopoverMenuHarnessModel()
        let window = try show(HermexPopoverMenuHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)

        let surface = try XCTUnwrap(accessibilityNode(
            withIdentifier: HermexPopoverMenuPresentation.surfaceAccessibilityIdentifier, in: window
        ))
        let surfaceFrame = surface.accessibilityFrame
        XCTAssertFalse(surfaceFrame.isEmpty, "expected the presented surface to report a real on-screen frame")

        let overlayHost = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier
        })
        let hit = try XCTUnwrap(window.hitTest(CGPoint(x: surfaceFrame.midX, y: surfaceFrame.midY), with: nil))
        XCTAssertTrue(
            hit === overlayHost || hit.isDescendant(of: overlayHost),
            "a touch over the menu surface's own bounds must be claimed within its host, never fall through to the outside dismiss layer"
        )
        XCTAssertTrue(
            descendants(window).contains { $0.accessibilityIdentifier == HermexPopoverMenuPresentation.overlayHostAccessibilityIdentifier },
            "the menu must remain presented — a touch over its own surface must not have triggered an outside dismissal"
        )
        XCTAssertEqual(model.actionRunCount, 0)
    }

    func testMenuUsesTheTriggersCurrentPositionAfterItsParentScrolls() async throws {
        let model = HermexPopoverMenuHarnessModel()
        let window = try show(ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 400)
                HermexPopoverMenuHarnessView(model: model)
                Color.clear.frame(height: 1000)
            }
        })
        defer { close(window) }
        await settle(window)
        let scroller = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first)
        scroller.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        await settle(window)

        model.isPresented = true
        await settle(window)

        let trigger = try XCTUnwrap(accessibilityNode(withIdentifier: "popover-harness-trigger", in: window))
        let menu = try XCTUnwrap(accessibilityNode(
            withIdentifier: HermexPopoverMenuPresentation.surfaceAccessibilityIdentifier, in: window
        ))
        let readerFrames = descendants(window).filter {
            String(describing: type(of: $0)).contains("AnchorView")
                || String(describing: type(of: $0)).contains("GeometryView")
        }.map { "\(type(of: $0)): \($0.convert($0.bounds, to: window))" }
        // `.accessibilityElement(children: .contain)` reports the union of the action rows, not the
        // decorative shell padding around them. Expand that content frame back to the card's visual
        // frame before asserting the resolver's trigger gap.
        let menuCardFrame = menu.accessibilityFrame.insetBy(
            dx: -HermexPopoverMenuMetrics.contentPadding,
            dy: -HermexPopoverMenuMetrics.contentPadding
        )
        XCTAssertEqual(menuCardFrame.minY - trigger.accessibilityFrame.maxY,
                       HermexPopoverMenuMetrics.anchorGap, accuracy: 1,
                       "the menu must use the trigger's scrolled position, not a cached screen coordinate; trigger=\(trigger.accessibilityFrame), menuContent=\(menu.accessibilityFrame), menuCard=\(menuCardFrame), offset=\(scroller.contentOffset), readers=\(readerFrames)")
    }

    // MARK: - Test harness

    private func show<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// Finds the accessibility element (a real `UIView`, or one of SwiftUI's own non-view
    /// accessibility nodes) carrying `identifier`, anywhere under `root`, so a test can activate it
    /// the way VoiceOver would — the same helper `HermexDialogTests` uses to reach
    /// `.accessibilityAction(.escape)` without synthesizing raw touch events.
    private func accessibilityNode(withIdentifier identifier: String, in root: UIView) -> NSObject? {
        var queue: [Any] = [root]
        var seenViews: Set<ObjectIdentifier> = []
        while let current = queue.popLast() {
            if let view = current as? UIView {
                guard seenViews.insert(ObjectIdentifier(view)).inserted else { continue }
                if view.accessibilityIdentifier == identifier { return view }
                for element in view.accessibilityElements ?? [] { queue.append(element) }
                let count = view.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = view.accessibilityElement(at: index) { queue.append(element) }
                    }
                }
                queue += view.subviews
            } else if let object = current as? NSObject {
                if (object.value(forKey: "accessibilityIdentifier") as? String) == identifier {
                    return object
                }
            }
        }
        return nil
    }

    // MARK: - Adoption boundary

    func testNoProductionScreenAdoptsHermexPopoverMenuYet() throws {
        let root = resourceURL("HermesMobile")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var adoptionSites: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard !url.path.contains("/Features/Shared/") else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if contents.contains("hermexPopoverMenu(") {
                adoptionSites.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(
            adoptionSites.isEmpty,
            "expected zero production adoption of hermexPopoverMenu( outside HermesMobile/Features/Shared (foundation + DEBUG Overlay Lab), found: \(adoptionSites)"
        )
    }
}

@MainActor @Observable
private final class HermexPopoverMenuHarnessModel {
    var isPresented = false
    var actionRunCount = 0
}

private struct HermexPopoverMenuHarnessView: View {
    @Bindable var model: HermexPopoverMenuHarnessModel

    var body: some View {
        Button("Trigger") { model.isPresented = true }
            .accessibilityIdentifier("popover-harness-trigger")
            .hermexPopoverMenu(
                isPresented: $model.isPresented,
                accessibilityLabel: Text("Row actions"),
                actions: [
                    HermexPopoverMenuAction(id: "first", title: "First", action: { model.actionRunCount += 1 }),
                    HermexPopoverMenuAction(id: "disabled", title: "Disabled", isEnabled: false, action: { model.actionRunCount += 1 }),
                    HermexPopoverMenuAction(id: "destructive", title: "Delete", role: .destructive, action: { model.actionRunCount += 1 })
                ]
            )
            // Forces the synchronous present/dismiss path so rendered tests never depend on real
            // wall-clock animation timing, matching HermexDialogTests's harness.
            .environment(\._accessibilityReduceMotion, true)
    }
}
