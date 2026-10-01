import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `ListItem` (`ListItem.swift`): its shared metrics, default state, and the
/// defaulted-initializer/haptic-feedback compile contracts.
final class ListItemTests: XCTestCase {
    // MARK: - Pure contracts

    func testMetricsMatchTheExistingPickerRowGeometry() {
        XCTAssertEqual(ListItemMetrics.minHeight, 48)
        XCTAssertEqual(ListItemMetrics.cornerRadius, HermesRadius.field)
    }

    func testStateDefaultsToNormal() {
        let state = ListItemState()
        XCTAssertFalse(state.isSelected)
        XCTAssertFalse(state.isPending)
        XCTAssertFalse(state.isDisabled)
    }

    // MARK: - Compile contract

    func testEveryDefaultedInitializerCompiles() {
        let plain = ListItem(title: Text("Server default"), action: {})
        let withLeading = ListItem(title: Text("Row"), action: {}, leading: { Image(systemName: "circle") })
        let withTrailing = ListItem(title: Text("Row"), action: {}, trailingAccessory: { Image(systemName: "star") })
        let full = ListItem(
            title: Text("Row"),
            subtitle: Text("Detail"),
            action: {},
            leading: { Image(systemName: "circle") },
            titleAccessory: { Tag(label: "Selected", tint: .accentColor) },
            trailingAccessory: { Image(systemName: "star") }
        )
        XCTAssertFalse(String(describing: type(of: plain)).isEmpty)
        XCTAssertFalse(String(describing: type(of: withLeading)).isEmpty)
        XCTAssertFalse(String(describing: type(of: withTrailing)).isEmpty)
        XCTAssertFalse(String(describing: type(of: full)).isEmpty)
    }

    // MARK: - Haptic feedback option

    func testHapticFeedbackStyleOptionDefaultsToNilAndCanBeSetExplicitly() {
        let withoutHaptic = ListItem(title: Text("Row"), action: {}, leading: { Image(systemName: "circle") })
        let withHaptic = ListItem(
            title: Text("Row"),
            hapticFeedbackStyle: .light,
            action: {},
            leading: { Image(systemName: "circle") }
        )
        XCTAssertNil(withoutHaptic.hapticFeedbackStyle, "the default must remain a plain native Button")
        XCTAssertEqual(withHaptic.hapticFeedbackStyle, .light)
    }

    // MARK: - Accordion header seams

    func testSemanticTitleRoleAndInRowIndicatorCanBeConfigured() {
        let header = ListItem(
            title: Text("Hermex"),
            titleRole: .label,
            rowIndicatorSystemImage: "chevron.down",
            action: {},
            leading: { Image(systemName: "folder") }
        )

        switch header.titleRole {
        case .label:
            break
        default:
            XCTFail("Accordion headers must be able to request the semantic label role")
        }
        XCTAssertEqual(header.rowIndicatorSystemImage, "chevron.down")
    }

    func testSemanticTitleRoleAndInRowIndicatorKeepExistingDefaults() {
        let row = ListItem(title: Text("Session"), action: {})

        switch row.titleRole {
        case .body:
            break
        default:
            XCTFail("Existing ListItem callers must keep the body role")
        }
        XCTAssertNil(row.rowIndicatorSystemImage)
        XCTAssertEqual(
            row.rowIndicatorSize,
            HermesIconSize.small,
            "existing ListItem callers must keep the current 16pt indicator size"
        )
    }

    func testRowIndicatorSizeCanBeConfiguredForAnAccordionHeaderChevron() {
        let header = ListItem(
            title: Text("Hermex"),
            rowIndicatorSystemImage: "chevron.down",
            rowIndicatorSize: HermesIconSize.medium,
            action: {},
            leading: { Image(systemName: "folder") }
        )
        XCTAssertEqual(header.rowIndicatorSize, HermesIconSize.medium)
    }

    func testRowIndicatorLivesInsideTheRowButtonAndIsAccessibilityHidden() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(src.contains("rowIndicatorSystemImage"))
        XCTAssertTrue(src.contains("Image(systemName: rowIndicatorSystemImage)"))
        XCTAssertTrue(src.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(src.contains(".appFont(titleRole)"))
        XCTAssertTrue(
            src.contains(".font(.system(size: rowIndicatorSize, weight: .semibold))"),
            "the indicator's rendered size must come from the configurable rowIndicatorSize seam, not a hardcoded token"
        )
    }

    // MARK: - Selection Sheet seam: additive, default-preserving selectionChrome (Issue #607)
    //
    // `ListItemSelectionChrome` does not exist yet — Task 2 of the Selection Sheet implementation
    // plan adds it. Before that lands, these are source-only contracts (no compile reference to the
    // missing enum), so the test target itself keeps building while pinning the approved seam: a
    // `.standard` default that preserves every existing caller's current selected pill/checkmark and
    // accessibility behavior unchanged, plus an additive `.indicatorOnly` mode Selection Sheet opts
    // into so a row-owned Radio/Checkbox visual never duplicates the built-in selected mark.

    func testDefinesAnAdditiveSelectionChromeEnumDefaultingToStandard() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(src.contains("enum ListItemSelectionChrome"), "expected a ListItemSelectionChrome enum")
        XCTAssertTrue(src.contains("case standard"), "expected a .standard case")
        XCTAssertTrue(src.contains("case indicatorOnly"), "expected an additive .indicatorOnly case")
        XCTAssertTrue(
            src.contains("var selectionChrome: ListItemSelectionChrome = .standard"),
            "expected a stored selectionChrome property defaulting to .standard"
        )
    }

    func testSelectedAccessibilityTraitStaysDrivenByStateIsSelectedRegardlessOfChrome() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains(".accessibilityAddTraits(state.isSelected ? .isSelected : [])"),
            "expected the selected accessibility trait to remain driven by state.isSelected, unconditioned on selectionChrome, for both .standard and .indicatorOnly rows"
        )
    }

    func testSelectionPillAndBuiltInCheckmarkAreGatedToStandardChromeOnly() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains(
                "listItemSelectionPill(isSelected: state.isSelected && selectionChrome == .standard, contentInset: contentInset)"
            ),
            "expected the selected pill treatment to render only under .standard chrome, with contentInset passed explicitly rather than read back from an environment value the same view just wrote, so .indicatorOnly rows can pair with a Radio/Checkbox visual without a duplicate selection mark"
        )
        XCTAssertTrue(
            src.contains("state.isSelected && selectionChrome == .standard"),
            "expected the built-in trailing selected checkmark to be gated the same way, only under .standard chrome"
        )
    }

    func testIndicatorOnlySelectedSubtitleDoesNotUseTheStandardPillInverseColor() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains("state.isSelected && selectionChrome == .standard"),
            "expected every inverse selected foreground to require the standard filled pill"
        )
        XCTAssertTrue(
            src.contains("private var subtitleForeground")
                && src.contains("state.isSelected && selectionChrome == .standard ? Color(.systemBackground).opacity(0.7) : Color.secondary"),
            "an indicator-only selected row has no dark pill, so its subtitle must remain secondary rather than becoming an unreadable inverse color"
        )
    }

    func testEveryConvenienceInitializerForwardsSelectionChromeWithAStandardDefault() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        // Count declared `init(` headers only, excluding the forwarding `self.init(` calls each
        // convenience initializer's body makes to the designated one.
        let declaredInitializerCount = src.components(separatedBy: "init(").count - 1
            - (src.components(separatedBy: "self.init(").count - 1)
        // The stored property's own declaration ("var selectionChrome: ListItemSelectionChrome =
        // .standard") also contains this substring, so it must be excluded to count only
        // initializer-parameter declarations.
        let selectionChromeParameterCount = src.components(
            separatedBy: "selectionChrome: ListItemSelectionChrome = .standard"
        ).count - 1 - (src.contains("var selectionChrome: ListItemSelectionChrome = .standard") ? 1 : 0)
        XCTAssertGreaterThan(declaredInitializerCount, 1, "expected ListItem to keep its multiple defaulted convenience initializers")
        XCTAssertEqual(
            selectionChromeParameterCount,
            declaredInitializerCount,
            "expected every declared ListItem convenience initializer to forward selectionChrome with a .standard default, so no existing call site must change"
        )
    }

    // MARK: - Interaction Foundation seam: additive, default-preserving contentInset (Issue #607,
    // Round 3, Task 1)
    //
    // `ListItemContentInset` does not exist yet — Round 3's Interaction Foundation implementation
    // plan (Tasks 1-2) adds it. Before that lands, these are source-only contracts (no compile
    // reference to the missing enum), matching the established `ListItemSelectionChrome` pattern
    // above: a `.standard` default that preserves every existing caller's current row padding
    // unchanged, plus an additive `.none` case `HermexPopoverMenu`'s rows can later request once the
    // popover shell owns its own padding instead (see `HermexPopoverMenuTests`).

    func testDefinesAnAdditiveListItemContentInsetEnumDefaultingToStandard() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(src.contains("enum ListItemContentInset"), "expected a ListItemContentInset enum")
        XCTAssertTrue(src.contains("case standard"), "expected a .standard case")
        XCTAssertTrue(src.contains("case none"), "expected an additive .none case")
        XCTAssertTrue(
            src.contains("var contentInset: ListItemContentInset = .standard"),
            "expected a stored contentInset property defaulting to .standard"
        )
    }

    func testEveryConvenienceInitializerForwardsContentInsetWithAStandardDefault() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        // Same counting approach as selectionChrome above: count declared `init(` headers, excluding
        // the forwarding `self.init(` calls, and require every one to forward contentInset.
        let declaredInitializerCount = src.components(separatedBy: "init(").count - 1
            - (src.components(separatedBy: "self.init(").count - 1)
        let contentInsetParameterCount = src.components(
            separatedBy: "contentInset: ListItemContentInset = .standard"
        ).count - 1 - (src.contains("var contentInset: ListItemContentInset = .standard") ? 1 : 0)
        XCTAssertGreaterThan(declaredInitializerCount, 1, "expected ListItem to keep its multiple defaulted convenience initializers")
        XCTAssertEqual(
            contentInsetParameterCount,
            declaredInitializerCount,
            "expected every declared ListItem convenience initializer to forward contentInset with a .standard default, so no existing call site must change"
        )
    }

    // MARK: - Interaction Foundation: explicit contentInset plumbing, not environment (Issue #607,
    // Round 3, modifier-order correction)
    //
    // `ListItem.body` applies `.environment(\.listItemContentInset, contentInset)` to the inner
    // HStack, then applies the outer `.listItemSelectionPill(...)` modifier. SwiftUI environment
    // writes only flow to a modifier's own content, never back out to a modifier applied after it on
    // the same view chain, so the outer `.listItemSelectionPill` cannot safely rely on an environment
    // value written by its own inner content: Popover `.none` can silently resolve to the default
    // `.standard`. The fix is for `contentInset` to reach `listItemSelectionPill` as an explicit
    // parameter, not an environment read.

    func testSelectionPillModifierReceivesContentInsetAsAnExplicitParameterNotAnEnvironmentRead() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains("func listItemSelectionPill(isSelected: Bool, contentInset: ListItemContentInset) -> some View"),
            "expected listItemSelectionPill to receive contentInset as an explicit parameter: the outer modifier applied after ListItem's inner HStack cannot safely rely on an environment value that same inner content just wrote"
        )
    }

    func testListItemContentInsetIsNeverPlumbedThroughTheEnvironment() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertFalse(
            src.contains("ListItemContentInsetKey"),
            "expected contentInset to be threaded as an explicit parameter, not stored behind an EnvironmentKey"
        )
        XCTAssertFalse(
            src.contains("listItemContentInset"),
            "expected no EnvironmentValues.listItemContentInset accessor: an outer modifier applied after the inner HStack cannot safely read an environment value that same inner content just wrote"
        )
        XCTAssertFalse(
            src.contains(".environment(\\.listItemContentInset, contentInset)"),
            "expected ListItem.body to stop writing contentInset onto the environment for its own outer modifier to read back"
        )
    }

    // MARK: - Interaction Foundation: ButtonStyle-owned pressed state (Issue #607, Round 3, Task 2)
    //
    // `ListItemButtonStyle` does not exist yet — source-only contracts, matching the pattern above:
    // one ButtonStyle-owned rounded pressed surface using `ListItemMetrics.cornerRadius` and
    // `HermesMotion.Bundle.stateChange`, with no scale feedback (contrasting the existing
    // `HermesMotion.Bundle.feedbackPress`/scale-based tactile pattern used elsewhere in the app),
    // while leaving the disabled/pending row-disable, the optional haptic path, the independently
    // interactive trailing accessory, and the standard/indicator-only selection chrome distinction
    // all unchanged.

    /// Isolates the declaration region that starts right after `marker` and runs up to (but not
    /// including) the next top-level declaration, or the end of the file if `marker` introduces the
    /// last one. Unlike `components(separatedBy:).last`, this fails explicitly when `marker` is
    /// absent instead of silently returning the whole source, so assertions scoped to this region
    /// can't pass by matching unrelated text elsewhere in the file.
    private func region(after marker: String, in src: String) throws -> String {
        let markerRange = try XCTUnwrap(
            src.range(of: marker),
            "expected to find \"\(marker)\" in source"
        )
        let remainder = src[markerRange.upperBound...]
        let topLevelDeclarationPattern = #"(?m)^(?:(?:public|private|internal|fileprivate|open|final)\s+)*(?:struct|enum|class|extension|protocol)\s"#
        let regex = try NSRegularExpression(pattern: topLevelDeclarationPattern)
        let nsRange = NSRange(remainder.startIndex..<remainder.endIndex, in: remainder)
        guard
            let match = regex.firstMatch(in: String(remainder), range: nsRange),
            let nextDeclarationRange = Range(match.range, in: remainder)
        else {
            return String(remainder)
        }
        return String(remainder[..<nextDeclarationRange.lowerBound])
    }

    func testDefinesADedicatedButtonStyleForThePressedSurface() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains("struct ListItemButtonStyle: ButtonStyle"),
            "expected a dedicated ListItemButtonStyle owning the pressed surface"
        )
    }

    func testPressedSurfaceUsesTheSharedCornerRadiusAndStateChangeMotion() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        let body = try region(after: "struct ListItemButtonStyle: ButtonStyle", in: src)
        XCTAssertTrue(
            body.contains("RoundedRectangle(cornerRadius: ListItemMetrics.cornerRadius"),
            "expected the pressed surface to share ListItem's own corner radius, not a new literal"
        )
        XCTAssertTrue(
            body.contains("HermesMotion.Bundle.stateChange"),
            "expected the pressed surface's transition to use the shared stateChange motion bundle"
        )
    }

    func testPressedSurfaceHasNoScaleFeedback() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        let body = try region(after: "struct ListItemButtonStyle: ButtonStyle", in: src)
        XCTAssertFalse(
            body.contains("scaleEffect"),
            "the row's pressed surface must be a color/opacity change only — no scale feedback, unlike HermesMotion.Bundle.feedbackPress elsewhere"
        )
        XCTAssertFalse(body.contains("HermesMotion.Bundle.feedbackPress"))
    }

    func testRowButtonUsesTheDedicatedButtonStyleInsteadOfPlain() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains(".buttonStyle(ListItemButtonStyle("),
            "expected rowButton to adopt the dedicated pressed-surface ButtonStyle in place of .buttonStyle(.plain)"
        )
        XCTAssertFalse(
            src.contains(".buttonStyle(.plain)"),
            "expected the plain button style to be fully replaced, not left alongside the new one"
        )
    }

    func testDisabledAndPendingRowsStayDisabledUnderTheNewButtonStyle() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains(".disabled(state.isDisabled || state.isPending)"),
            "expected the row action to remain disabled while pending or explicitly disabled after adopting the new ButtonStyle"
        )
    }

    func testHapticPathAndTrailingAccessoryRemainIntactUnderTheNewButtonStyle() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        XCTAssertTrue(
            src.contains("HapticButton(feedbackStyle: hapticFeedbackStyle, action: action)"),
            "expected the optional haptic feedback path to remain available alongside the new pressed-surface ButtonStyle"
        )
        XCTAssertTrue(
            src.contains("trailingAccessory()"),
            "expected the trailing accessory to remain independently interactive, outside the row's own button"
        )
    }

    func testButtonStyleApplicationReceivesExplicitSelectedStateToDistinguishStandardFromIndicatorOnly() throws {
        let src = try source("HermesMobile/Features/Shared/ListItem.swift")
        let callPrefix = ".buttonStyle(ListItemButtonStyle("
        guard let prefixRange = src.range(of: callPrefix) else {
            XCTFail("expected the row to apply the pressed-surface style via \"\(callPrefix)\"")
            return
        }

        // Walk the call's argument list with paren balance tracking (rather than the first `)`),
        // since a real argument — `state.isSelected && selectionChrome == .standard`, for instance —
        // may itself contain no parens but a future one could.
        var depth = 1
        var index = prefixRange.upperBound
        var argumentsEndIndex = index
        while index < src.endIndex {
            switch src[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    argumentsEndIndex = index
                }
            default:
                break
            }
            if depth == 0 { break }
            index = src.index(after: index)
        }

        let arguments = src[prefixRange.upperBound..<argumentsEndIndex]
        XCTAssertTrue(
            arguments.contains("selectionChrome") || arguments.contains("isSelected"),
            "expected the ListItemButtonStyle application call to receive an explicit selected-state input — selectionChrome, an equivalent boolean, or another explicit selected-surface argument — so standard selected rows can keep their filled selected pill with a contrast-safe pressed adjustment, while indicator-only/unselected rows use the normal pressed fill"
        )
    }

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
}
