import Observation
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

/// Contracts for `HermexDialog` (`HermexDialog.swift`): a fully custom, always-centered modal
/// mounted through `HermexSameWindowOverlay`, never a native presentation. Some claims (generic
/// header/body/footer construction, the exact prohibited/required APIs a source scan can pin) are
/// compile/source contracts, the same established pattern as `HermexBottomSheetTests`. The
/// exactly-once/cancellation/staleness guarantees of the shared lifecycle itself are proven at the
/// unit level in `HermexOverlayLifecycleTests`; the rendered tests below forward Reduce Motion so
/// present/dismiss complete synchronously and deterministically, without any sleep or polling.
@MainActor final class HermexDialogTests: XCTestCase {
    // MARK: - Compile contracts

    func testDialogPublicAPICompilesWithGenericHeaderBodyAndFooter() {
        struct Host: View {
            @State var isPresented = false
            var body: some View {
                Text("Trigger").hermexDialog(isPresented: $isPresented) {
                    HStack { Image(systemName: "bell"); Text("Heading") }
                } content: {
                    VStack { Text("Line one"); Text("Line two") }
                } footer: { context in
                    Button("Cancel") { context.dismiss() }
                    Button("Continue") { context.dismissAfter {} }
                }
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    func testCompilesWithVerticalFooterAxis() {
        struct Host: View {
            @State var isPresented = false
            var body: some View {
                Text("Trigger").hermexDialog(isPresented: $isPresented, footerAxis: .vertical) {
                    Text("Heading")
                } content: {
                    Text("Body")
                } footer: { context in
                    Button("Primary") { context.dismissAfter {} }
                    Button("Secondary") { context.dismiss() }
                }
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    func testFooterAxisDefaultsToHorizontalWhenOmitted() {
        struct Host: View {
            @State var isPresented = false
            var body: some View {
                Text("Trigger").hermexDialog(isPresented: $isPresented) {
                    Text("Heading")
                } content: {
                    Text("Body")
                } footer: { context in
                    Button("OK") { context.dismiss() }
                }
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    // MARK: - Source contracts

    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    private func hermexDialogSource() throws -> String {
        try source("HermesMobile/Features/Shared/HermexDialog.swift")
    }

    private func overlayLabSource() throws -> String {
        try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
    }

    func testDialogAlwaysExposesCloseDialogControl() throws {
        XCTAssertEqual(HermexDialogPresentation.closeButtonAccessibilityLabel, "Close dialog")
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains("closeButton"), "expected an unconditional close control")
        XCTAssertFalse(src.contains("showsCloseButton"), "the close control is never caller-optional")
    }

    /// `closeButtonAccessibilityLabel` is a plain `String` constant, and its only consumers
    /// (`.icon(_:accessibilityLabel:)` and `.accessibilityLabel(_:)`) take the value as a `String`, not
    /// a `Text`/`LocalizedStringKey` literal at the call site. `ci/check_string_catalog.py` only ever
    /// sees `Localizable` keys the compiler extracts from a `LocalizedStringKey` use — a plain `String`
    /// constant threaded through a `String`-typed accessibility API never produces one, so this
    /// component-owned, always-visible VoiceOver label is permanently invisible to that checker. It
    /// must route through `String(localized:)` instead so the checker (and translators) can see it.
    func testCloseButtonAccessibilityLabelIsLocalizedNotAPlainLiteralInvisibleToTheStringCatalogChecker() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(
            src.contains(#"static let closeButtonAccessibilityLabel = String(localized:"#),
            "expected closeButtonAccessibilityLabel to be built with String(localized:), since a plain " +
                "String literal here is invisible to ci/check_string_catalog.py's compiler-extraction scan"
        )
    }

    func testBackdropTapGestureIsANoOp() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains(".onTapGesture {}"),
                       "the dimmed backdrop must consume touches without requesting dismissal")
    }

    func testDialogUsesRootSameWindowHostInsteadOfNativePresentation() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains("HermexSameWindowOverlay("))
        XCTAssertTrue(src.contains(".root"))
        XCTAssertFalse(src.contains(".alert("))
        XCTAssertFalse(src.contains(".sheet("))
        XCTAssertFalse(src.contains("fullScreenCover"))
        XCTAssertFalse(src.contains("Menu {"))
        XCTAssertFalse(src.contains(".popover("))
    }

    func testDialogHasNoScrollOrTextInputPresentationAPI() throws {
        let src = try hermexDialogSource()
        XCTAssertFalse(src.contains("ScrollView"))
        XCTAssertFalse(src.contains("List("))
        XCTAssertFalse(src.contains("TextField"))
        XCTAssertFalse(src.contains("SecureField"))
        XCTAssertFalse(src.contains("TextEditor"))
    }

    func testCallerBindingIsWrittenBackOnlyWhenExitCompletes() throws {
        let src = try hermexDialogSource()
        let occurrences = src.components(separatedBy: "isPresented = false").count - 1
        XCTAssertEqual(occurrences, 1,
                        "the caller's isPresented binding must be written back in exactly one place: onExitCompleted, not at exit start")
    }

    func testCloseAndEscapeShareTheSameDismissalPath() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains(".keyboardShortcut(.cancelAction)"),
                       "expected hardware Escape via the established cancel-shortcut pattern")
        XCTAssertTrue(src.contains(".accessibilityAction(.escape)"), "expected VoiceOver Escape to be wired")
        XCTAssertEqual(src.components(separatedBy: "requestDismissal(after: nil)").count - 1, 3,
                        "close, escape, and owner-driven dismissal must all route through the same plain-dismiss path")
    }

    func testUsesTheSharedOverlayLifecycleForExactlyOnceCompletion() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains("lifecycle.beginPresentation()"))
        XCTAssertTrue(src.contains("lifecycle.completePresentation(generation:"))
        XCTAssertTrue(src.contains("lifecycle.beginDismissal(after:"))
        XCTAssertTrue(src.contains("lifecycle.completeDismissal(generation:"))
        XCTAssertTrue(src.contains("lifecycle.cancelOwner()"), "owner teardown must cancel the lifecycle")
        XCTAssertTrue(src.contains(".onDisappear"), "owner cancellation must be wired to view disappearance")
    }

    func testUsesExistingMotionBundlesAndReduceMotionFallback() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains("HermesMotion.Bundle.overlayEnter"))
        XCTAssertTrue(src.contains("HermesMotion.Bundle.overlayExit"))
        XCTAssertTrue(src.contains("reduceMotion"))
    }

    func testUsesExistingCardSurfaceRadiusAndShadowTokens() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains(".hermexCardSurface(.glass"))
        XCTAssertTrue(src.contains("HermesRadius."))
        XCTAssertTrue(src.contains(".hermesShadow(.overlay)"))
    }

    func testInputIsDisabledOutsidePresented() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains(".allowsHitTesting(lifecycle.phase == .presented)"))
    }

    func testHeadingIsMarkedAsAnAccessibilityHeader() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains(".accessibilityAddTraits(.isHeader)"))
    }

    func testOwnerCanSupersedeAnInFlightDismissal() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains("else if lifecycle.phase == .dismissing"))
        XCTAssertTrue(src.contains("transitionTask?.cancel()"))
    }

    /// `HermexOverlayLifecycleTests` proves the exactly-once/fresh-generation/cancellation semantics
    /// of a queued reopen at the lifecycle level; this is the smallest contract proving `HermexDialog`
    /// actually reads and acts on that result, instead of discarding it.
    func testFinishExitRunsTheDeferredActionThenResumesAFreshEntryOnAQueuedReopenInsteadOfUnmounting() throws {
        let src = try hermexDialogSource()
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

    func testAccessibilityLabSpecimenUsesVerticalActions() throws {
        let src = try overlayLabSource()
        let accessibilitySection = try XCTUnwrap(
            src.components(separatedBy: "private struct HermexOverlayLabAccessibilitySize").last?
                .components(separatedBy: "// ─── 5/6.").first
        )
        XCTAssertTrue(accessibilitySection.contains("footerAxis: .vertical"),
                      "the accessibility5 specimen must use the approved vertical action layout")
    }

    func testAccessibilityLabSpecimenAppliesDynamicTypeToTheDialogModifier() throws {
        let src = try overlayLabSource()
        let accessibilitySection = try XCTUnwrap(
            src.components(separatedBy: "private struct HermexOverlayLabAccessibilitySize").last?
                .components(separatedBy: "// ─── 5/6.").first
        )
        let dialogOffset = try XCTUnwrap(accessibilitySection.range(of: ".hermexDialog")?.lowerBound)
        let dynamicTypeOffset = try XCTUnwrap(accessibilitySection.range(of: ".dynamicTypeSize(.accessibility5)")?.lowerBound)
        XCTAssertLessThan(dialogOffset, dynamicTypeOffset,
                          "Dynamic Type must wrap the modifier so its forwarded overlay environment receives accessibility5")
    }

    // MARK: - Issue #DSF-01: header/close centering, XS adaptive-glass close, trailing footer

    /// Isolates the `closeButton` computed property's own source, the same bounded-slice pattern
    /// `testAccessibilityLabSpecimenAppliesDynamicTypeToTheDialogModifier` uses for a named region
    /// of `HermexOverlayLab.swift` — scoping assertions to just this control instead of the whole
    /// file, so the icon's own status/emphasis text never bleeds into other proximate `HermexButton`
    /// call sites this file may later grow.
    private func closeButtonSource() throws -> String {
        let src = try hermexDialogSource()
        let after = try XCTUnwrap(src.components(separatedBy: "private var closeButton: some View {").last,
                                   "expected a closeButton computed property")
        return try XCTUnwrap(after.components(separatedBy: "\n\n    private func present()").first,
                              "expected closeButton to be immediately followed by present()")
    }

    func testHeaderRowVerticallyCentersHeadingAndCloseControl() throws {
        let src = try hermexDialogSource()
        XCTAssertTrue(src.contains("HStack(alignment: .center, spacing: HermexDialogMetrics.headerSpacing)"),
                      "expected the header row to vertically center the heading and close control")
        XCTAssertFalse(src.contains("HStack(alignment: .top, spacing: HermexDialogMetrics.headerSpacing)"),
                       "the header row must no longer use top alignment now that header/close are centered")
    }

    func testCloseControlComposesTheSharedHermexButtonAtExtraSmallNeutralAdaptiveGlass() throws {
        let block = try closeButtonSource()
        XCTAssertTrue(block.contains("HermexButton("), "expected the close control to compose the shared HermexButton")
        XCTAssertTrue(block.contains("content: .icon(\"xmark\""), "expected the close control to keep its xmark glyph")
        XCTAssertTrue(
            block.contains("accessibilityLabel: HermexDialogPresentation.closeButtonAccessibilityLabel)"),
            "expected the close control to supply its accessibility action name through the HermexButton " +
                "content contract, not only an external modifier"
        )
        XCTAssertTrue(block.contains("size: .extraSmall"), "expected the close control's compact visual to be HermexButtonSize.extraSmall")
        XCTAssertTrue(block.contains("emphasis: .neutral"), "expected the close control to use neutral emphasis")
        XCTAssertTrue(block.contains("isGlass: true"), "expected the close control to compose adaptive glass")
        XCTAssertFalse(block.contains("in: Circle()"),
                       "the bespoke circular background must be replaced by the shared HermexButton chrome")
    }

    /// A min-only outer `.frame(minWidth:minHeight:)` clamps its own size up to 44pt and centers its
    /// XS child without proposing anything the child must fill and without adding a content shape —
    /// SwiftUI's default content shape for a composite view stays sized to the child's own layout
    /// (the ~24pt `HermexButtonSize.extraSmall` chrome), so the surrounding ~10pt of padding on each
    /// side is not actually tappable even though the frame reports 44x44. There is no distinct,
    /// individually hit-testable UIView for this control inside the hosted window hierarchy — the
    /// whole dialog surface renders through one SwiftUI-owned hit-testing path — so a windowed
    /// `hitTest(_:)` at the frame's edge cannot deterministically distinguish "claimed by the close
    /// button's enlarged shape" from "claimed by whatever sits behind/around it" without inventing a
    /// new rendering harness. This stays a source contract instead, narrowly scoped to the exact fix:
    /// the outer frame must be followed immediately by `.contentShape(Rectangle())`, which is what
    /// actually enlarges the hit-testable region to match the reported frame, before the control's
    /// other (keyboard/disabled/accessibility) modifiers apply.
    func testCloseControlExpandsItsActualHitTestShapeToThe44ptFrameItReports() throws {
        let block = try closeButtonSource()
        XCTAssertTrue(block.contains("HermexDialogMetrics.closeButtonDimension"),
                      "expected the close control to still reserve its 44pt minimum hit target even though its visual chrome shrinks to XS")

        let frameModifier = ".frame(minWidth: HermexDialogMetrics.closeButtonDimension, minHeight: HermexDialogMetrics.closeButtonDimension)"
        guard let frameRange = block.range(of: frameModifier) else {
            XCTFail("expected the 44pt outer frame to size the composite HermexButton")
            return
        }

        let afterFrame = block[frameRange.upperBound...]
        guard let contentShapeRange = afterFrame.range(of: ".contentShape(Rectangle())") else {
            XCTFail("""
                a min-only outer .frame() clamps its own size up to 44pt and centers its XS child \
                without proposing anything the child must fill and without adding a content shape, \
                so the surrounding padding stays untappable even though the frame reports 44x44; the \
                outer frame must be followed by .contentShape(Rectangle()) so the enlarged frame \
                itself becomes the hit-testable region
                """)
            return
        }

        let betweenFrameAndContentShape = afterFrame[afterFrame.startIndex..<contentShapeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(betweenFrameAndContentShape.isEmpty,
                      ".contentShape(Rectangle()) must directly follow the 44pt frame, with no modifier in between")

        for laterModifier in [".keyboardShortcut(.cancelAction)", ".disabled(", ".accessibilityLabel(", ".accessibilityIdentifier("] {
            guard let modifierRange = block.range(of: laterModifier) else {
                XCTFail("expected \(laterModifier) to remain on the composite close control")
                continue
            }
            XCTAssertLessThan(contentShapeRange.upperBound, modifierRange.lowerBound,
                              "\(laterModifier) must come after the enlarged .contentShape(Rectangle()), not before it")
        }
    }

    func testHorizontalFooterAlignsCallerSuppliedActionsToTheSemanticTrailingEdge() throws {
        let src = try hermexDialogSource()
        let afterHorizontal = try XCTUnwrap(src.components(separatedBy: "case .horizontal:").last,
                                             "expected a .horizontal case in footerLayout's switch")
        let horizontalCase = try XCTUnwrap(afterHorizontal.components(separatedBy: "case .vertical:").first,
                                            "expected a .vertical case immediately following .horizontal")
        XCTAssertTrue(horizontalCase.contains("Spacer(") || horizontalCase.contains("alignment: .trailing"),
                      "expected the horizontal footer to push caller-supplied actions to the semantic trailing edge via a leading Spacer or a trailing frame alignment, never a guessed reordering of the caller's own content")
    }

    // MARK: - Rendered behavior
    // Reduce Motion is forced on the harness so present/dismiss complete synchronously within one
    // MainActor turn — deterministic, with no sleep or polling, per the async-testing rule in
    // AGENTS.md — while still exercising the real modifier, `HermexDialog`, and
    // `HermexSameWindowOverlay` together.

    func testMountsCenteredSurfaceWithCloseControlAndUnmountsOnDismiss() async throws {
        let model = HermexDialogHarnessModel()
        let window = try show(HermexDialogHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        model.isPresented = true
        await settle(window)

        let overlayHost = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier
        })
        XCTAssertTrue(overlayHost.accessibilityViewIsModal, "the mounted host must isolate the underlying screen")
        let actionContext = try XCTUnwrap(model.actionContext)
        actionContext.dismiss()
        await settle(window)

        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier },
                        "the host must unmount once dismissal completes")
    }

    func testInitiallyPresentedBindingMountsTheDialog() async throws {
        let model = HermexDialogHarnessModel()
        model.isPresented = true
        let window = try show(HermexDialogHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        XCTAssertTrue(descendants(window).contains {
            $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier
        })
    }

    func testAccessibilityEscapeRequestsDismissal() async throws {
        let model = HermexDialogHarnessModel()
        let window = try show(HermexDialogHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)

        guard let surface = accessibilityNode(
            withIdentifier: HermexDialogPresentation.surfaceAccessibilityIdentifier, in: window
        ) else {
            try XCTSkipUnless(
                accessibilityTreeIsPublished(in: window, knownNodeIdentifier: "dialog-harness-trigger"),
                "No accessibility tree is published in-process on this toolchain."
            )
            XCTFail("expected the dialog surface's own accessibility node even though other accessibility nodes are published")
            return
        }
        XCTAssertTrue(surface.accessibilityPerformEscape())
        await settle(window)

        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier })
    }

    func testBackdropInterceptsTouchesWithoutDismissing() async throws {
        let model = HermexDialogHarnessModel()
        let window = try show(HermexDialogHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)

        let overlayHost = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier
        })
        let point = CGPoint(x: window.bounds.midX, y: window.bounds.minY + 40)
        let hit = try XCTUnwrap(window.hitTest(point, with: nil))
        XCTAssertTrue(hit === overlayHost || hit.isDescendant(of: overlayHost),
                      "a touch anywhere over the dialog's bounds must be claimed by its own host, never pass through")
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier },
                      "the dialog must remain presented — nothing dismissed it")
    }

    func testFooterDismissThenRunDefersActionUntilExitCompletes() async throws {
        let model = HermexDialogHarnessModel()
        let window = try show(HermexDialogHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)
        XCTAssertEqual(model.actionRunCount, 0)

        let actionContext = try XCTUnwrap(model.actionContext)
        actionContext.dismissAfter { model.actionRunCount += 1 }
        await settle(window)

        XCTAssertEqual(model.actionRunCount, 1, "the deferred action must run exactly once, after the dialog closes")
        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier })
    }

    func testRepeatedCloseOrActionCannotRunTwice() async throws {
        let model = HermexDialogHarnessModel()
        let window = try show(HermexDialogHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)

        let actionContext = try XCTUnwrap(model.actionContext)
        actionContext.dismissAfter { model.actionRunCount += 1 }
        actionContext.dismissAfter { model.actionRunCount += 1 }
        await settle(window)

        XCTAssertEqual(model.actionRunCount, 1, "a second activation after the first is accepted must never run the action again")
    }

    func testExternalBindingFalseRunsExitBeforeUnmount() async throws {
        let model = HermexDialogHarnessModel()
        let window = try show(HermexDialogHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier })

        model.isPresented = false
        // No run-loop turn has occurred yet — the host must still be mounted immediately after the
        // caller's own state write, proving unmount is never synchronous with it.
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier },
                      "unmounting must not happen synchronously with the caller's own binding write")

        await settle(window)
        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == HermexDialogPresentation.overlayHostAccessibilityIdentifier },
                        "the host must eventually unmount once exit completes")
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

    /// Distinguishes "no accessibility tree is published in-process on this toolchain" (the gap
    /// `BotChatPresentationTests` already documents for some build SDKs) from "this overlay's own
    /// node specifically never mounted" — a real regression. Probes a plain, always-present node
    /// outside the overlay (the harness's own trigger, hosted the ordinary way as the window's root
    /// view) rather than the identifier a caller is actually asserting on, so a true toolchain gap
    /// and a real missing-node bug are never confused with each other.
    private func accessibilityTreeIsPublished(in window: UIWindow, knownNodeIdentifier: String) -> Bool {
        accessibilityNode(withIdentifier: knownNodeIdentifier, in: window) != nil
    }

    /// Every accessibility label exposed under a view — hosted view labels plus explicit
    /// accessibility elements, which need not be views (the same walk `BotChatPresentationTests`
    /// uses).
    private func accessibilityLabels(in root: UIView) -> [String] {
        var labels: [String] = []
        var queue = [root]
        var seen: Set<ObjectIdentifier> = []
        while let view = queue.popLast() {
            guard seen.insert(ObjectIdentifier(view)).inserted else { continue }
            if let label = view.accessibilityLabel { labels.append(label) }
            for element in view.accessibilityElements ?? [] {
                if let elementView = element as? UIView {
                    queue.append(elementView)
                } else if let object = element as? NSObject, let label = object.value(forKey: "accessibilityLabel") as? String {
                    labels.append(label)
                }
            }
            let count = view.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let elementView = view.accessibilityElement(at: index) as? UIView {
                        queue.append(elementView)
                    } else if let object = view.accessibilityElement(at: index) as? NSObject,
                              let label = object.value(forKey: "accessibilityLabel") as? String {
                        labels.append(label)
                    }
                }
            }
            queue += view.subviews
        }
        return labels
    }

    /// Finds the accessibility element (a real `UIView`, or one of SwiftUI's own non-view
    /// accessibility nodes) carrying `identifier`, anywhere under `root`, so a test can activate it
    /// the way VoiceOver would — the standard way to exercise a SwiftUI `Button`'s action or an
    /// `.accessibilityAction(.escape)` closure without synthesizing raw touch events.
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
}

@MainActor @Observable
private final class HermexDialogHarnessModel {
    var isPresented = false
    var actionRunCount = 0
    var actionContext: HermexOverlayActionContext?
}

private struct HermexDialogHarnessView: View {
    @Bindable var model: HermexDialogHarnessModel

    var body: some View {
        Button("Trigger") { model.isPresented = true }
            .accessibilityIdentifier("dialog-harness-trigger")
            .hermexDialog(isPresented: $model.isPresented) {
                Text(verbatim: "Heading").font(.headline)
            } content: {
                Text(verbatim: "Body")
            } footer: { context in
                Color.clear
                    .frame(width: 0, height: 0)
                    .onAppear { model.actionContext = context }
                Button("Dismiss") { context.dismiss() }
                    .accessibilityIdentifier("dialog-harness-dismiss")
                Button("Action") { context.dismissAfter { model.actionRunCount += 1 } }
                    .accessibilityIdentifier("dialog-harness-action")
            }
            // Forces the synchronous present/dismiss path so rendered tests never depend on real
            // wall-clock animation timing.
            .environment(\._accessibilityReduceMotion, true)
    }
}
