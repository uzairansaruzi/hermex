import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `HermexSelectionSheet` (`HermexSelectionSheet.swift`, Issue #607, DSF-06): the
/// caller-presented content that retires the unused `HermexDropdown` foundation and replaces its
/// intended fixed-option-selection role. Selection Sheet composes the existing `HermexBottomSheet`,
/// `TopNav`, `HermexList`/`ListItem`, row-owned `HermexRadio`/`HermexCheckbox` indicators, and an
/// optional `HermexSearchField` — never a second, competing overlay/presentation mechanism. It
/// supports immediate single-selection commit and staged multi-selection with explicit Done/Cancel.
///
/// This test is written before `HermexSelectionSheet.swift` exists, so every test that needs the
/// future source fails through one explicit, readable XCTest assertion (`selectionSheetSource()`)
/// rather than a raw file-not-found error — see the approved design spec
/// (`2026-09-29-selection-sheet-design.md`, `DSF-06-selection-sheet-r1`) and flow-state brief
/// (`2026-09-29-selection-sheet-flow-state.md`, `DSF-06-flow-r1`) this pins.
final class HermexSelectionSheetTests: XCTestCase {
    // MARK: - Source helpers

    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    /// Counts non-overlapping regular-expression matches in `text` — used by the content-inset
    /// source contracts below, where "exactly once"/"exactly two" is the assertion, not mere
    /// presence.
    private func matches(of pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))
            .map { $0.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) } ?? 0
    }

    /// A bounded window of `src` starting right after `marker`, used by the DSR3-09 footer-axis
    /// ordering contracts below to scope a "which comes first" check to one switch-case branch
    /// without depending on the exact closing-brace shape the branch ends up with.
    private func boundedRegion(startingAt marker: String, in src: String, maxLength: Int) -> String? {
        guard let start = src.range(of: marker) else { return nil }
        let remainder = src[start.upperBound...]
        let end = remainder.index(remainder.startIndex, offsetBy: maxLength, limitedBy: remainder.endIndex)
            ?? remainder.endIndex
        return String(remainder[remainder.startIndex..<end])
    }

    /// Loads the future `HermexSelectionSheet.swift` source if it exists, or records one clear,
    /// explicit XCTest failure and returns `nil` so the caller can bail out safely — never a raw
    /// "file doesn't exist" error that would mask the intended contract being pinned.
    private func selectionSheetSource(file: StaticString = #filePath, line: UInt = #line) -> String? {
        let url = resourceURL("HermesMobile/Features/Shared/HermexSelectionSheet.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail(
                "HermesMobile/Features/Shared/HermexSelectionSheet.swift does not exist yet — "
                    + "Task 3 of the Selection Sheet implementation plan adds it",
                file: file,
                line: line
            )
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Public type contracts

    func testDefinesTheOptionModel() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("struct HermexSelectionSheetOption<Value: Hashable>: Identifiable"),
            "expected the approved option model's exact declaration"
        )
    }

    func testDefinesTheSearchConfigurationModel() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("struct HermexSelectionSheetSearch"), "expected the optional Search configuration model")
    }

    func testDefinesTheMultiSelectionDraftModel() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("struct HermexSelectionSheetDraft<Value: Hashable>"),
            "expected the pure multi-selection draft model"
        )
    }

    func testDefinesTheSelectionSheetViewWithExactlyOneGenericParameter() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("struct HermexSelectionSheet<Value: Hashable>: View"),
            "expected the component to declare exactly one generic parameter (Value) — no second " +
                "generic row-content parameter, which would imply an arbitrary public row closure"
        )
    }

    func testDeclaresExplicitSingleAndMultiSelectionBindingPaths() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("Binding<Value?>"), "expected an explicit single-selection Binding<Value?> initializer path")
        XCTAssertTrue(src.contains("Binding<Set<Value>>"), "expected an explicit multi-selection Binding<Set<Value>> initializer path")
    }

    func testNoArbitraryPublicRowContentClosureExists() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertFalse(src.contains("Row: View"), "expected no second generic row-content type parameter")
        XCTAssertFalse(src.contains("@escaping () -> Row"), "expected no caller-supplied arbitrary row builder")
        XCTAssertFalse(src.contains("@ViewBuilder row"), "expected no public @ViewBuilder row slot")
    }

    // MARK: - Composition contracts (existing foundations only, never a new overlay mechanism)

    func testComposesTheExistingBottomSheetScaffold() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("HermexBottomSheet("), "expected Selection Sheet to compose the existing HermexBottomSheet scaffold")
    }

    func testComposesTheExistingSearchFieldWhenSearchIsProvided() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("HermexSearchField("), "expected the optional Search slot to render the real HermexSearchField")
    }

    func testComposesTheExistingListContainer() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("HermexList {"), "expected the option list to compose the shared HermexList container")
    }

    func testComposesListItemForRows() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("ListItem("), "expected every option row to compose the shared ListItem anatomy")
    }

    func testUsesVisualOnlyRadioAndCheckboxIndicators() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("HermexRadio(isSelected:"),
            "expected the single-selection row indicator to be a visual-only HermexRadio(isSelected:)"
        )
        XCTAssertTrue(
            src.contains("HermexCheckbox(isChecked:"),
            "expected the multi-selection row indicator to be a visual-only HermexCheckbox(isChecked:)"
        )
    }

    func testUsesTheIndicatorOnlyListItemSelectionChrome() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains(".indicatorOnly"),
            "expected rows to opt into ListItem's additive .indicatorOnly selected chrome, so the row-owned " +
                "Radio/Checkbox visual never duplicates ListItem's own selected pill/checkmark"
        )
    }

    func testUsesTheEnvironmentDismissActionRatherThanASecondSheetModifier() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("@Environment(\\.dismiss)"),
            "expected row commit, Done, and Cancel to all dismiss through the environment dismiss action"
        )
    }

    func testNeverCallsANativeSheetModifierItself() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertFalse(src.contains(".sheet("), "the caller owns .sheet — Selection Sheet must never wrap itself in a second one")
    }

    func testHasNoDependencyOnThePopoverOrSameWindowOverlayMechanism() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertFalse(src.contains("HermexPopoverMenu"), "Selection Sheet must not depend on Popover Menu")
        XCTAssertFalse(src.contains("HermexSameWindowOverlay"), "Selection Sheet must not depend on the same-window overlay host — native .sheet already owns presentation")
        XCTAssertFalse(src.contains("HermexOverlayLifecycle"), "Selection Sheet must not depend on the overlay lifecycle state machine — native .sheet already owns exactly-once dismissal")
    }

    // MARK: - Row state, focus, and content contracts

    func testRowsOwnSelectedAndDisabledState() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("state.isSelected") || src.contains("isSelected:"), "expected rows to express selected state")
        XCTAssertTrue(src.contains("state.isDisabled") || src.contains("isEnabled") || src.contains("isDisabled"), "expected rows to express disabled state for a disabled option")
    }

    func testAllowsUpToThreeTitleLinesAtAccessibilityTextSizes() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("titleLineLimit: 3"), "expected rows to permit up to three title lines rather than clipping at accessibility Dynamic Type sizes")
    }

    func testOwnsAccessibilityFocusForInitialRowFocus() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("@AccessibilityFocusState"),
            "expected Selection Sheet to own accessibility focus state so it can move initial VoiceOver focus to the selected enabled option, or the first enabled option otherwise"
        )
    }

    /// Regression for a PR #974 bot finding: the initial-focus task used to sleep 400ms before
    /// unconditionally assigning `focusedOptionValue`, so a VoiceOver user who had already moved to
    /// another row, Search, Cancel, or Done — or who was mid-dismissal on a single-selection commit
    /// — could have focus stolen back out from under them. Initial focus must instead be requested
    /// on the next task cycle via `Task.yield()`, with cancellation checked immediately before the
    /// assignment so a since-cancelled task can never perform a later overwrite.
    func testInitialFocusTaskYieldsOnceInsteadOfSleepingThenChecksCancellationBeforeAssigning() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertFalse(
            src.contains("Task.sleep"),
            "expected the initial-focus task to never sleep an arbitrary delay before assigning focus"
        )
        guard let region = boundedRegion(startingAt: ".task {", in: src, maxLength: 200) else {
            XCTFail("expected a locatable sheetContent .task block to scope this contract to")
            return
        }
        XCTAssertTrue(
            region.contains("await Task.yield()"),
            "expected initial focus to be scheduled on the next task cycle via Task.yield(), not an arbitrary delay"
        )
        XCTAssertTrue(
            region.range(
                of: #"Task\.yield\(\)[\s\S]*?Task\.isCancelled[\s\S]*?focusedOptionValue\s*=\s*initialFocusOptionValue"#,
                options: .regularExpression
            ) != nil,
            "expected cancellation to be checked after yielding and immediately before assigning the focus target"
        )
    }

    func testGenericAndQueriedEmptyCopyAreDistinct() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("No options available"), "expected the generic empty-without-query copy")
        XCTAssertTrue(src.contains("No results"), "expected the distinct empty-with-query (no-results) copy")
    }

    // MARK: - Single-selection lifecycle (no overfitting one exact formatting shape)

    func testEnabledSingleActivationOnlyMutatesWhenValueDiffersThenDismisses() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("option.isEnabled"),
            "expected single-selection row activation to check the option's enabled state before doing anything"
        )
        XCTAssertTrue(
            src.range(of: #"selection\.wrappedValue\s*!=\s*option\.value"#, options: .regularExpression) != nil,
            "expected the caller binding to be mutated only when the tapped value differs from the current selection"
        )
        XCTAssertTrue(
            src.range(of: #"selection\.wrappedValue\s*=\s*option\.value"#, options: .regularExpression) != nil,
            "expected the single-selection caller binding to be written with the tapped option's value"
        )
        XCTAssertTrue(src.contains("dismiss()"), "expected activation to dismiss the sheet")
    }

    func testDisabledSingleRowsCannotMutateOrDismiss() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.range(of: #"guard\s+option\.isEnabled\s+else\s*\{\s*return\s*\}"#, options: .regularExpression) != nil,
            "expected a disabled option's row activation to guard-return before any mutation or dismissal"
        )
    }

    // MARK: - Multi-selection lifecycle (no overfitting one exact formatting shape)

    func testMultiInitializationSnapshotsCallerSelectionsIntoBaselineAndDraft() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains("baseline"), "expected multi-selection to seed a baseline from the caller's current set")
        XCTAssertTrue(
            src.contains("selections.wrappedValue") || src.contains("HermexSelectionSheetDraft("),
            "expected multi-selection to seed its local draft from the caller's current Set<Value> binding"
        )
    }

    func testMultiInitializerSeedsDraftSynchronouslyBeforeTheFirstRowCanBeActivated() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("_draft = State(initialValue: HermexSelectionSheetDraft(baseline: selections.wrappedValue))"),
            "expected the multi initializer to snapshot the caller set synchronously, before the sheet becomes interactive"
        )
        XCTAssertFalse(
            src.contains("seedDraftIfNeeded()"),
            "draft seeding must not wait for an asynchronous view task, where an immediate first tap could see nil state"
        )
    }

    func testMultiSelectionResetsDraftFromCallerBindingOnEveryPresentation() {
        guard let src = selectionSheetSource() else { return }
        guard let region = boundedRegion(
            startingAt: "private func multiSelectionSheet(selections: Binding<Set<Value>>) -> some View {",
            in: src,
            maxLength: 900
        ) else {
            XCTFail("expected a locatable multiSelectionSheet(selections:) composition to scope this contract to")
            return
        }
        XCTAssertTrue(
            region.range(
                of: #"\.onAppear\s*\{\s*draft\s*=\s*HermexSelectionSheetDraft\(baseline:\s*selections\.wrappedValue\)\s*\}"#,
                options: .regularExpression
            ) != nil,
            "expected the multi-selection composition to reset the draft from the caller's current binding on " +
                "every presentation, so a cancelled draft from a prior presentation of the same sheet content " +
                "can never persist into the next one"
        )
    }

    func testRowTogglesMutateOnlyTheLocalDraft() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(src.contains(".toggle("), "expected an enabled multi-selection row tap to toggle the local draft, never the caller binding directly")
    }

    func testDoneAssignsTheCompleteDraftExactlyOnceThenDismisses() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.range(of: #"selections\.wrappedValue\s*=\s*draft\.values"#, options: .regularExpression) != nil
                || src.range(of: #"selections\.wrappedValue\s*=\s*\w*[Dd]raft\.values"#, options: .regularExpression) != nil,
            "expected Done to write the complete current draft to the caller binding exactly once"
        )
    }

    func testCancelAndDismissPathsNeverWriteTheCallerSelectionBinding() {
        guard let src = selectionSheetSource() else { return }
        // Cancel must dismiss without ever assigning to either caller binding — approximate by
        // scoping to the Cancel action's own trailing closure text, not the whole file (Done's own
        // closure elsewhere legitimately assigns the multi-selection binding).
        guard let cancelRange = src.range(of: #"Cancel[\s\S]{0,20}\{[\s\S]{0,200}?\}"#, options: .regularExpression) else {
            XCTFail("expected a locatable Cancel action closure to scope this contract to")
            return
        }
        let cancelBody = String(src[cancelRange])
        XCTAssertFalse(cancelBody.contains("selection.wrappedValue ="), "Cancel must never write the single-selection caller binding")
        XCTAssertFalse(cancelBody.contains("selections.wrappedValue ="), "Cancel must never write the multi-selection caller binding")
        XCTAssertTrue(cancelBody.contains("dismiss()"), "expected Cancel to dismiss")
    }

    func testFilteringNeverIntersectsHiddenSelectedValuesOutOfTheDraft() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertFalse(
            src.contains(".intersection("),
            "expected no intersection with the caller's currently-visible option array — a value temporarily " +
                "hidden by Search filtering must remain in the draft"
        )
        XCTAssertFalse(
            src.contains("selections.wrappedValue.filter") || src.contains("draft.values = draft.values.filter"),
            "expected no filtering operation that could drop a hidden selected value from the draft"
        )
    }

    // MARK: - Content inset contracts (DSR2-07): a caller-selected outer horizontal inset that
    // replaces Search's own screenHorizontal padding, applied exactly once to the shared
    // Search/list/empty-state container.

    func testContentInsetStandardUsesTheScreenHorizontalSpacingToken() {
        XCTAssertEqual(HermexSelectionSheetContentInset.standard.horizontalPadding, HermesSpacing.s16)
    }

    func testContentInsetNoneUsesZeroPadding() {
        XCTAssertEqual(HermexSelectionSheetContentInset.none.horizontalPadding, HermesSpacing.s0)
    }

    @MainActor
    func testSingleSelectionSheetCompilesOmittingContentInsetDefaultsToStandard() {
        enum Option: Hashable { case first, second }
        struct Host: View {
            @State var selection: Option?
            var body: some View {
                HermexSelectionSheet(
                    "Pick one",
                    selection: $selection,
                    options: [
                        HermexSelectionSheetOption(value: Option.first, title: "First"),
                        HermexSelectionSheetOption(value: Option.second, title: "Second"),
                    ]
                )
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testMultiSelectionSheetCompilesWithContentInsetNone() {
        enum Option: Hashable { case first, second }
        struct Host: View {
            @State var selections: Set<Option> = []
            var body: some View {
                HermexSelectionSheet(
                    "Pick many",
                    selections: $selections,
                    options: [
                        HermexSelectionSheetOption(value: Option.first, title: "First"),
                        HermexSelectionSheetOption(value: Option.second, title: "Second"),
                    ],
                    contentInset: .none
                )
            }
        }
        let host = Host()
        XCTAssertFalse(String(describing: type(of: host)).isEmpty)
    }

    @MainActor
    func testSearchCompilesOnEitherSelectionPathWithoutChangingContentInsetOwnership() {
        enum Option: Hashable { case first }
        struct SingleHost: View {
            @State var selection: Option?
            @State var query = ""
            var body: some View {
                HermexSelectionSheet(
                    "Pick one",
                    selection: $selection,
                    options: [HermexSelectionSheetOption(value: Option.first, title: "First")],
                    search: HermexSelectionSheetSearch(title: "Search", text: $query)
                )
            }
        }
        struct MultiHost: View {
            @State var selections: Set<Option> = []
            @State var query = ""
            var body: some View {
                HermexSelectionSheet(
                    "Pick many",
                    selections: $selections,
                    options: [HermexSelectionSheetOption(value: Option.first, title: "First")],
                    search: HermexSelectionSheetSearch(title: "Search", text: $query),
                    contentInset: .none
                )
            }
        }
        let singleHost = SingleHost()
        let multiHost = MultiHost()
        XCTAssertFalse(String(describing: type(of: singleHost)).isEmpty)
        XCTAssertFalse(String(describing: type(of: multiHost)).isEmpty)
    }

    func testDefinesTheContentInsetEnumWithStandardAndNoneCases() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("enum HermexSelectionSheetContentInset: Equatable"),
            "expected the content inset enum's exact declaration"
        )
        XCTAssertTrue(src.contains("case standard"), "expected the .standard case")
        XCTAssertTrue(src.contains("case none"), "expected the .none case")
    }

    func testBothPublicInitializersDefaultContentInsetToStandard() {
        guard let src = selectionSheetSource() else { return }
        let count = matches(of: #"contentInset:\s*HermexSelectionSheetContentInset\s*=\s*\.standard"#, in: src)
        XCTAssertEqual(count, 2, "expected both the single- and multi-selection initializers to default contentInset to .standard")
    }

    func testNoArbitraryCGFloatContentInsetAPIExists() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertFalse(src.contains("contentInset: CGFloat"), "expected no arbitrary CGFloat contentInset API")
    }

    func testStoresExactlyOneContentInsetValue() {
        guard let src = selectionSheetSource() else { return }
        let count = matches(of: #"\blet contentInset: HermexSelectionSheetContentInset\b"#, in: src)
        XCTAssertEqual(count, 1, "expected exactly one stored contentInset value")
    }

    func testOuterContentAppliesContentInsetPaddingExactlyOnceToTheSharedContainer() {
        guard let src = selectionSheetSource() else { return }
        let count = matches(of: #"\.padding\(\.horizontal,\s*contentInset\.horizontalPadding\)"#, in: src)
        XCTAssertEqual(
            count, 1,
            "expected the outer Search/list/empty-state container to apply the content inset's horizontal padding exactly once"
        )
    }

    func testSearchNoLongerOwnsItsOwnScreenHorizontalPadding() {
        guard let src = selectionSheetSource() else { return }
        XCTAssertFalse(
            src.contains(".padding(.horizontal, HermesSpacing.screenHorizontal)"),
            "expected Search to no longer own its own screenHorizontal padding — the outer container " +
                "now applies the content inset's horizontal padding exactly once"
        )
    }

    // MARK: - DSR3-09: multi-select Bottom Sheet footer axis, TopNav restructuring, and button styles

    func testDefinesMultiSelectFooterAxis() throws {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("enum HermexSelectionSheetFooterAxis"),
            "expected the approved footer-axis enum's exact declaration"
        )
        XCTAssertTrue(src.contains("case horizontal"), "expected a .horizontal case")
        XCTAssertTrue(src.contains("case vertical"), "expected a .vertical case")
    }

    func testMultiInitializerDefaultsFooterAxisToHorizontal() throws {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains("footerAxis: HermexSelectionSheetFooterAxis = .horizontal"),
            "expected the multi-selection initializer to default its footer axis to horizontal"
        )
    }

    func testBodyBuildsTwoModeSpecificBottomSheetCompositions() throws {
        guard let src = selectionSheetSource() else { return }
        XCTAssertEqual(
            matches(of: #"HermexBottomSheet\("#, in: src), 2,
            "expected body to branch into two explicit single/multi HermexBottomSheet compositions " +
                "rather than one unified call shared by both modes"
        )
    }

    func testLeadingAndTrailingPrimaryAreUsedOnlyByTheSingleSelectionComposition() throws {
        guard let src = selectionSheetSource() else { return }
        XCTAssertEqual(
            matches(of: #"leadingPrimary:\s*\{"#, in: src), 1,
            "expected exactly one TopNav leadingPrimary Cancel — kept only for the single-selection composition"
        )
        XCTAssertFalse(
            src.contains("trailingPrimary:"),
            "expected Done to move out of TopNav trailingPrimary — multi-selection now uses the Bottom Sheet footer instead"
        )
    }

    func testMultiModeUsesExactlyOneBottomSheetFooterAndSingleModeUsesNone() throws {
        guard let src = selectionSheetSource() else { return }
        XCTAssertEqual(
            matches(of: #"footer:\s*\{"#, in: src), 1,
            "expected the Bottom Sheet footer parameter to be used exactly once — by multi-selection only; single mode must render no footer"
        )
    }

    func testFooterCancelUsesTheHermexSecondaryButtonStyle() throws {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains(".buttonStyle(.hermex(.medium, emphasis: .secondary))"),
            "expected the multi-select footer Cancel action to use the Hermex secondary Button style"
        )
    }

    func testFooterDoneUsesTheHermexPrimaryButtonStyle() throws {
        guard let src = selectionSheetSource() else { return }
        XCTAssertTrue(
            src.contains(".buttonStyle(.hermex(.medium, emphasis: .primary))"),
            "expected the multi-select footer Done action to use the Hermex primary Button style"
        )
    }

    func testHorizontalFooterOrdersCancelThenDone() throws {
        guard let src = selectionSheetSource() else { return }
        guard let region = boundedRegion(startingAt: "case .horizontal:", in: src, maxLength: 300) else {
            XCTFail("expected a `case .horizontal:` multi-select footer-axis branch")
            return
        }
        guard let cancelRange = region.range(of: "Cancel"), let doneRange = region.range(of: "Done") else {
            XCTFail("expected the horizontal footer branch to render both Cancel and Done")
            return
        }
        XCTAssertTrue(
            cancelRange.lowerBound < doneRange.lowerBound,
            "expected horizontal multi-select footer order: Cancel then Done"
        )
    }

    func testVerticalFooterOrdersDoneThenCancelBothFullWidth() throws {
        guard let src = selectionSheetSource() else { return }
        guard let region = boundedRegion(startingAt: "case .vertical:", in: src, maxLength: 700) else {
            XCTFail("expected a `case .vertical:` multi-select footer-axis branch")
            return
        }
        guard let doneRange = region.range(of: "Done"), let cancelRange = region.range(of: "Cancel") else {
            XCTFail("expected the vertical footer branch to render both Done and Cancel")
            return
        }
        XCTAssertTrue(
            doneRange.lowerBound < cancelRange.lowerBound,
            "expected vertical multi-select footer order: Done then Cancel"
        )
        XCTAssertNotNil(
            region.range(
                of: #"Button\s*\{\s*commitMultiSelection\(selections:\s*selections\)\s*\}\s*label:\s*\{\s*Text\(\"Done\"\)\s*\.frame\(maxWidth:\s*\.infinity\)\s*\}\s*\.buttonStyle\(\.hermex\(\.medium,\s*emphasis:\s*\.primary\)\)"#,
                options: .regularExpression
            ),
            "expected the Done label to stretch before Hermex Button chrome is applied"
        )
        XCTAssertNotNil(
            region.range(
                of: #"Button\s*\{\s*dismiss\(\)\s*\}\s*label:\s*\{\s*Text\(\"Cancel\"\)\s*\.frame\(maxWidth:\s*\.infinity\)\s*\}\s*\.buttonStyle\(\.hermex\(\.medium,\s*emphasis:\s*\.secondary\)\)"#,
                options: .regularExpression
            ),
            "expected the Cancel label to stretch before Hermex Button chrome is applied"
        )
    }

    // MARK: - Retirement contracts: HermexDropdown is fully removed, Popover Menu stays action-only

    func testHermexDropdownProductionSourceIsRemoved() {
        let url = resourceURL("HermesMobile/Features/Shared/HermexDropdown.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "expected HermexDropdown.swift to be deleted once Selection Sheet replaces its role — no shim or deprecation wrapper retained"
        )
    }

    func testHermexDropdownTestsAreRemoved() {
        let url = resourceURL("HermesMobileTests/HermexDropdownTests.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "expected HermexDropdownTests.swift to be deleted alongside the retired HermexDropdown.swift"
        )
    }

    func testHermexPopoverMenuRemainsActionOnlyWithNoSelectionAPI() throws {
        let src = try source("HermesMobile/Features/Shared/HermexPopoverMenu.swift")
        XCTAssertFalse(src.contains("Selection"), "expected HermexPopoverMenu to remain action-only — no selection API of its own; persistent selection belongs to Selection Sheet")
        XCTAssertTrue(src.contains("struct HermexPopoverMenuAction"), "expected Popover Menu's existing action-only model to be unchanged")
    }

    // MARK: - DEBUG lab reachability

    func testRemainsReachableFromTheDebugOverlayLab() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(
            src.contains("--hermex-overlay-lab-selection-sheet"),
            "expected a deterministic launch flag scrolling straight to the Selection Sheet fixtures"
        )
        XCTAssertTrue(
            src.contains("overlay-lab-selection-sheet-section"),
            "expected a deterministic scroll anchor for the Selection Sheet section"
        )
    }

    func testDebugLabExposesStableSingleMultiSearchAndLongListFixtureIdentifiers() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(src.contains("overlay-lab-selection-sheet-single"), "expected a stable identifier for the single-selection fixture")
        XCTAssertTrue(src.contains("overlay-lab-selection-sheet-multi"), "expected a stable identifier for the staged multi-selection fixture")
        XCTAssertTrue(src.contains("overlay-lab-selection-sheet-search"), "expected a stable identifier for the optional Search fixture")
        XCTAssertTrue(src.contains("overlay-lab-selection-sheet-long-list"), "expected a stable identifier for the long (20+ option) scrolling-list fixture")
    }

    // MARK: - DEBUG lab reachability (DSR2-07): a no-inset specimen composed inside a pre-padded
    // Card, alongside the existing default-inset specimens.

    func testDebugLabExposesANoInsetSpecimenComposedInsideAPrePaddedCard() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(
            src.contains("overlay-lab-selection-sheet-no-inset"),
            "expected a stable identifier for the contentInset: .none specimen"
        )
        XCTAssertTrue(
            src.contains("contentInset: .none"),
            "expected the no-inset specimen to actually pass contentInset: .none"
        )
        XCTAssertTrue(
            src.contains("HermexCard") || src.contains("Card("),
            "expected the no-inset specimen to be composed inside a pre-padded Card, demonstrating why contentInset: .none is needed"
        )
    }

    func testDebugLabCanAutoPresentSingleAndMultiSheetsForHeadlessRenderedVerification() throws {
        let src = try source("HermesMobile/Features/Shared/HermexOverlayLab.swift")
        XCTAssertTrue(
            src.contains("--hermex-overlay-lab-auto-selection-sheet-single"),
            "expected a DEBUG-only launch seam for rendering the single-selection sheet without host pointer automation"
        )
        XCTAssertTrue(
            src.contains("--hermex-overlay-lab-auto-selection-sheet-multi"),
            "expected a DEBUG-only launch seam for rendering the multi-selection sheet and its Done/Cancel actions without host pointer automation"
        )
    }
}
