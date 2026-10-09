import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexBottomSheet` (`HermexBottomSheet.swift`): a content scaffold supplied to
/// native `.sheet`, never a replacement for it. A SwiftUI view tree isn't inspectable at runtime
/// without a rendering harness, so this is a compile contract (the body slot genuinely accepts both
/// native `List` and arbitrary content, the footer slot accepts either axis, and the whole thing
/// composes inside a real `.sheet`) plus a source contract pinning the native composition — a
/// `NavigationStack`, this file's own `TopNav`, `.safeAreaInset` for the footer, and the explicit
/// absence of any custom presentation, transition, drag, or dimming behavior the caller's `.sheet`
/// already owns.
final class HermexBottomSheetTests: XCTestCase {
    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    private func hermesBottomSheetSource() throws -> String {
        try source("HermesMobile/Features/Shared/HermexBottomSheet.swift")
    }

    private func overlayLabSource() throws -> String {
        try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
    }

    // MARK: - Compile contracts

    @MainActor
    func testCompilesWithArbitraryBodyContentAndNoFooter() {
        struct Host: View {
            var body: some View {
                HermexBottomSheet("Add Attachment") {
                    VStack {
                        Text("Attach a file from Workspace.")
                    }
                }
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    /// The footer is documented as optional, so a caller must be able to omit it entirely using the
    /// explicit `content:` label form (not just trailing-closure syntax) with no other footer-shaped
    /// argument supplied.
    @MainActor
    func testCompilesWithNoFooterArgumentUsingTheLabeledContentForm() {
        struct Host: View {
            var body: some View {
                HermexBottomSheet("Information", content: { Text("Body") })
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testCompilesWithANativeListBody() {
        struct Host: View {
            var body: some View {
                HermexBottomSheet("Choose a Source") {
                    List {
                        Text("Workspace file")
                        Text("Photo Library")
                    }
                }
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testCompilesWithLeadingAndTrailingTopNavActions() {
        struct Host: View {
            var body: some View {
                HermexBottomSheet(
                    "New Task",
                    content: { Text("Body") },
                    leadingPrimary: { Button("Cancel") {} },
                    trailingPrimary: { Button("Save") {} }
                )
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testCompilesWithAHorizontalFooterButtonStack() {
        struct Host: View {
            var body: some View {
                HermexBottomSheet(
                    "Add Attachment",
                    footerAxis: .horizontal,
                    content: { Text("Body") },
                    footer: {
                        Button("Cancel") {}
                        Button("Attach") {}
                    }
                )
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testCompilesWithAVerticalFooterButtonStack() {
        struct Host: View {
            var body: some View {
                HermexBottomSheet(
                    "Choose a Source",
                    footerAxis: .vertical,
                    content: { Text("Body") },
                    footer: {
                        Button("Continue") {}
                        Button("Cancel") {}
                    }
                )
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testFooterAxisDefaultsToHorizontalWhenOmitted() {
        struct Host: View {
            var body: some View {
                HermexBottomSheet("Add Attachment", content: { Text("Body") }, footer: {
                    Button("Cancel") {}
                })
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    /// The caller keeps owning `.sheet` itself — detents, drag indicator, interactive-dismiss
    /// policy, and dismissal — this only proves `HermexBottomSheet` is valid content for it.
    @MainActor
    func testComposesAsContentInsideANativeSheetPresentation() {
        struct Host: View {
            @State var isPresented = false
            var body: some View {
                Text("Screen")
                    .sheet(isPresented: $isPresented) {
                        HermexBottomSheet("Add Attachment") {
                            Text("Body")
                        }
                    }
                    .presentationDetents([.medium, .large])
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    // MARK: - Source contracts: native composition, no invented presentation behavior

    func testOwnsANavigationStackWithAnInlineNavigationTitle() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(src.contains("NavigationStack"), "expected the scaffold to own a NavigationStack")
        XCTAssertTrue(src.contains(".navigationTitle(title)"), "expected an inline native navigation title")
        XCTAssertTrue(src.contains(".navigationBarTitleDisplayMode(.inline)"))
    }

    func testComposesTheSharedTopNavRatherThanAHandRolledBar() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(src.contains("TopNav("), "expected composition of the shared TopNav, not a hand-rolled bar")
        XCTAssertTrue(src.contains(".toolbar"), "expected TopNav to be composed through native .toolbar")
    }

    func testUsesModalAppropriateTopNavPlacements() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(src.contains(".cancellationAction"), "expected the leading slot to use modal-appropriate placement")
        XCTAssertTrue(src.contains(".confirmationAction"), "expected the trailing slot to use modal-appropriate placement")
    }

    func testBodySlotIsAnUnconstrainedViewBuilderWithNoImposedChrome() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(src.contains("@ViewBuilder"), "expected the body slot to be a ViewBuilder")
        XCTAssertFalse(src.contains("ScrollView"), "must not impose its own scroll view around the body slot")
        XCTAssertFalse(src.contains("HermexCard"), "must not impose card chrome around the body slot")
    }

    func testFooterIsPinnedWithNativeSafeAreaInsetNotAFixedHeight() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(src.contains(".safeAreaInset(edge: .bottom)"), "expected the footer to be pinned via native safeAreaInset")
        XCTAssertFalse(src.contains(".frame(height:"), "must not hard-code a sheet or footer height")
        XCTAssertFalse(src.contains(".presentationDetents("), "detents stay owned by the caller's .sheet")
    }

    func testFooterSurfaceSpansTheSheetWidthForEitherAxis() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(
            src.contains(".frame(maxWidth: .infinity)\n            .background(.bar)"),
            "the footer's bar surface must span the sheet instead of shrinking to horizontal actions"
        )
    }

    func testFooterAxisSupportsHorizontalAndVerticalStacksUsingExistingSpacingTokens() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(src.contains("enum FooterAxis"))
        XCTAssertTrue(src.contains("case horizontal"))
        XCTAssertTrue(src.contains("case vertical"))
        XCTAssertTrue(src.contains("HStack"))
        XCTAssertTrue(src.contains("VStack"))
        XCTAssertTrue(src.contains("HermesSpacing."), "expected footer spacing to use an existing Hermex spacing token")
    }

    func testFooterAxisDefaultsToHorizontal() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertTrue(src.contains("footerAxis: FooterAxis = .horizontal"))
    }

    func testDoesNotWrapOrReplaceTheNativeSheetPresentationModifierItself() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertFalse(src.contains(".sheet("), "must not wrap or replace the caller's own .sheet presentation")
        XCTAssertFalse(src.contains("interactiveDismissDisabled"), "dismiss policy stays with the caller")
    }

    func testIntroducesNoCustomPresentationMotionDragOrDimmingLayer() throws {
        let src = try hermesBottomSheetSource()
        XCTAssertFalse(src.contains("DragGesture"), "must not add a custom drag gesture")
        XCTAssertFalse(src.contains(".transition("), "must not add a custom transition")
        XCTAssertFalse(src.contains(".animation("), "must not add a custom animation — native .sheet owns presentation motion")
        XCTAssertFalse(src.contains("reduceMotion"), "must not add a home-grown Reduce Motion branch — native .sheet owns it")
        XCTAssertFalse(src.contains("Color.black.opacity"), "must not add a custom dimming/backdrop layer")
    }

    // MARK: - Issue #DSF-02: default XS/neutral/adaptive-glass TopNav slot styling
    //
    // TopNav decides whether a slot reaches the toolbar at all purely from its own generic type
    // (`slotIsEmpty<V>(_:)` compares `ObjectIdentifier(V.self)` against `ObjectIdentifier(EmptyView
    // .self)`). Wrapping a slot in a closure that calls `.buttonStyle(...)` on its result — e.g.
    // `{ leadingPrimary().buttonStyle(...) }` — returns an opaque `ModifiedContent`, never
    // `EmptyView`, so `slotIsEmpty` becomes unconditionally false for that slot no matter what the
    // caller actually passed in. Every `HermexBottomSheet`, including one with no toolbar actions at
    // all, would then mount a zero-content `ToolbarItemGroup` — exactly what TopNav's own elision
    // exists to prevent. `ToolbarContent` is not a `View`, so the style cannot be attached outside
    // `TopNav(...)`; instead TopNav exposes an opt-in action style that it applies inside each
    // non-empty ToolbarItemGroup only after the unchanged generic-type elision check succeeds.

    func testTopNavSlotsReceiveTheOriginalClosuresDirectlyPreservingTopNavsEmptySlotElision() throws {
        let src = try hermesBottomSheetSource()
        let toolbarBlock = try XCTUnwrap(src.components(separatedBy: ".toolbar {").last,
                                          "expected a .toolbar composing TopNav")
        for slot in ["leadingPrimary", "leadingSecondary", "trailingPrimary", "trailingSecondary"] {
            XCTAssertTrue(toolbarBlock.contains("\(slot): \(slot)"),
                          "expected \(slot) to be passed to TopNav directly (e.g. `\(slot): \(slot)`) so TopNav's own EmptyView-default slot type is preserved instead of being replaced by an opaque ModifiedContent")
            XCTAssertFalse(toolbarBlock.contains("\(slot)().buttonStyle"),
                           "wrapping \(slot) in a closure that calls .buttonStyle on its invoked result defeats TopNav.slotIsEmpty for every caller, including one that supplies no toolbar actions at all")
        }
    }

    func testBottomSheetOptsIntoCompactAdaptiveGlassTopNavActionsWithoutWrappingItsSlots() throws {
        let src = try hermesBottomSheetSource()
        let toolbarBlock = try XCTUnwrap(src.components(separatedBy: ".toolbar {").last,
                                          "expected a .toolbar composing TopNav")
        XCTAssertTrue(toolbarBlock.contains("actionStyle: .compactAdaptiveGlass"),
                      "expected Bottom Sheet alone to opt into TopNav's compact XS neutral adaptive-glass action style")
        XCTAssertFalse(toolbarBlock.contains(".buttonStyle(.hermex("),
                       "Bottom Sheet must not apply the style by wrapping each slot or by pretending ToolbarContent is a View")
    }

    /// Guards the other half of the requirement: TopNav may provide an opt-in action-style seam, but
    /// its global default remains native so every existing caller outside Bottom Sheet is unchanged.
    func testScopingTheDefaultButtonStyleLeavesTopNavsOwnGlobalDefaultsUnchanged() throws {
        let topNavSrc = try source("HermesMobile/Features/Shared/TopNav.swift")
        XCTAssertTrue(topNavSrc.contains("actionStyle: TopNavActionStyle = .native"),
                      "TopNav's action style must default to native so Bottom Sheet's opt-in does not restyle unrelated callers")
        XCTAssertTrue(topNavSrc.contains("if !Self.slotIsEmpty(LeadingPrimary.self)"),
                      "TopNav must keep checking the original generic slot type before creating a toolbar group")
        XCTAssertTrue(topNavSrc.contains("actionStyle.apply(to: leadingPrimary())"),
                      "TopNav applies the opt-in style only inside a toolbar group that survived empty-slot elision")
    }

    func testOverlayLabIncludesAReachableBottomSheetFollowupFixture() throws {
        let src = try overlayLabSource()
        XCTAssertTrue(src.contains("private struct HermexOverlayLabBottomSheetFollowup"))
        XCTAssertTrue(src.contains("HermexBottomSheet("))
        XCTAssertTrue(src.contains(".sheet(isPresented:"))
        XCTAssertTrue(src.contains("overlay-lab-followup-bottom-sheet-trigger"))
    }
}
