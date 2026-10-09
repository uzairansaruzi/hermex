import XCTest
import SwiftUI
@testable import HermesMobile

/// Contracts for `AccordionList` (`AccordionList.swift`): its pure expansion/separator resolvers,
/// compile contracts for controlled/local single/multiple expansion, and source contracts for
/// SwiftUI structure the pure tests above cannot inspect (ListItem-rooted rows, shared tokens,
/// accessibility state, and the absence of nested scrolling).
final class AccordionListTests: XCTestCase {
    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
    }

    private func resourceURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: resourceURL(relativePath), encoding: .utf8)
    }

    func testSingleExpansionTogglesToZeroOrOneItem() {
        XCTAssertEqual(
            AccordionListExpansionResolver.toggledSingle(current: nil, id: "one"),
            "one"
        )
        XCTAssertNil(
            AccordionListExpansionResolver.toggledSingle(current: "one", id: "one")
        )
        XCTAssertEqual(
            AccordionListExpansionResolver.toggledSingle(current: "one", id: "two"),
            "two"
        )
    }

    func testMultipleExpansionTogglesOnlyTheRequestedItem() {
        XCTAssertEqual(
            AccordionListExpansionResolver.toggledMultiple(current: ["one"], id: "two"),
            Set(["one", "two"])
        )
        XCTAssertEqual(
            AccordionListExpansionResolver.toggledMultiple(current: ["one", "two"], id: "one"),
            Set(["two"])
        )
    }

    func testLocalExpansionPrunesRemovedIdentifiers() {
        XCTAssertNil(
            AccordionListExpansionResolver.prunedSingle(current: "removed", validIDs: ["kept"])
        )
        XCTAssertEqual(
            AccordionListExpansionResolver.prunedMultiple(
                current: ["kept", "removed"],
                validIDs: ["kept"]
            ),
            Set(["kept"])
        )
    }

    func testSeparatorStylesExposeTheAcceptedBoundarySemantics() {
        XCTAssertFalse(AccordionListSeparatorStyle.none.showsInternalDividers)
        XCTAssertFalse(AccordionListSeparatorStyle.none.showsOuterDividers)
        XCTAssertTrue(AccordionListSeparatorStyle.betweenRows.showsInternalDividers)
        XCTAssertFalse(AccordionListSeparatorStyle.betweenRows.showsOuterDividers)
        XCTAssertFalse(AccordionListSeparatorStyle.topAndBottom.showsInternalDividers)
        XCTAssertTrue(AccordionListSeparatorStyle.topAndBottom.showsOuterDividers)
        XCTAssertTrue(AccordionListSeparatorStyle.all.showsInternalDividers)
        XCTAssertTrue(AccordionListSeparatorStyle.all.showsOuterDividers)
    }

    func testComponentCompilesWithExplicitAppearanceSeparatorsAndLocalExpansion() {
        let sections = [
            Section(id: "hermex", title: "Hermex", rows: [Row(id: "session", title: "Session")])
        ]
        let view = AccordionList(
            items: sections,
            appearance: .card,
            separatorStyle: .betweenRows,
            expansion: .localSingle(initiallyExpanded: nil),
            bodyItems: { $0.rows },
            headerTitle: { Text($0.title) },
            headerSubtitle: { Text("\($0.rows.count) sessions") },
            headerAccessibilityLabel: { Text($0.title) },
            headerIsDisabled: { _ in false },
            headerLeading: { _ in HermexAvatar(systemImage: "folder", size: .small) },
            headerTitleAccessory: { _ in EmptyView() },
            bodyItem: { _, row in ListItem(title: Text(row.title), action: {}) }
        )
        XCTAssertFalse(String(describing: type(of: view)).isEmpty)
    }

    func testExpansionDescriptorSupportsControlledAndLocalSingleAndMultipleForms() {
        let controlledSingle = AccordionListExpansion<String>.single(.constant(nil))
        let controlledMultiple = AccordionListExpansion<String>.multiple(.constant(["hermex"]))
        let localSingle = AccordionListExpansion<String>.localSingle(initiallyExpanded: nil)
        let localMultiple = AccordionListExpansion<String>.localMultiple(initiallyExpanded: ["hermex"])

        for expansion in [controlledSingle, controlledMultiple, localSingle, localMultiple] {
            XCTAssertFalse(String(describing: expansion).isEmpty)
        }
    }

    func testSourceUsesListItemTokensAccessibilityAndNoNestedScroll() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(src.contains("ListItem("))
        XCTAssertTrue(src.contains("titleRole: .label"))
        XCTAssertTrue(src.contains("rowIndicatorSystemImage:"))
        XCTAssertTrue(src.contains("HermesAvatarSize.small.rawValue + HermesSpacing.s12"))
        XCTAssertTrue(src.contains(".hermexCardSurface(.outlined"))
        XCTAssertTrue(src.contains("HermexDivider()"))
        XCTAssertTrue(src.contains("HermesMotion.animation(for: HermesMotion.Bundle.contentReposition)"))
        XCTAssertTrue(src.contains("expanded ? Text(\"Expanded\") : Text(\"Collapsed\")"))
        XCTAssertTrue(src.contains("guard !headerIsDisabled(item) else { return }"))
        XCTAssertTrue(src.contains("binding.wrappedValue"))
        XCTAssertTrue(src.contains("State(initialValue: initiallyExpanded)"))
        XCTAssertFalse(src.contains("ScrollView"))
        XCTAssertFalse(src.contains("ProjectSummary"))
        XCTAssertFalse(src.contains("SessionSummary"))
        XCTAssertFalse(src.contains("@AppStorage"))
    }

    // MARK: - Card padding, chevron size, and divider alignment (issue #607 follow-up)

    func testCardAppearanceAppliesTheSharedCardContentPaddingToken() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(
            src.contains(".padding(.horizontal, HermexCardMetrics.contentPadding)"),
            "card appearance must use the shared Card content padding token, not a new literal"
        )
    }

    func testCardlessAppearanceAddsNoAccordionLevelHorizontalPadding() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        guard let range = src.range(of: "private func cardlessGroup") else {
            return XCTFail("expected a cardlessGroup function")
        }
        let bodyStart = src[range.upperBound...]
        guard let bodyEnd = bodyStart.range(of: "\n    @ViewBuilder\n    private func groupRows") else {
            return XCTFail("expected cardlessGroup to be followed by groupRows")
        }
        let cardlessGroupBody = bodyStart[..<bodyEnd.lowerBound]
        XCTAssertFalse(
            cardlessGroupBody.contains(".padding(.horizontal"),
            "cardless must not introduce an Accordion-level horizontal outer padding"
        )
    }

    func testAccordionHeaderChevronUsesTheMediumIconSizeStep() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(
            src.contains("rowIndicatorSize: HermesIconSize.medium"),
            "the accordion header chevron must opt into the 20pt icon step via ListItem's configurable seam"
        )
    }

    // MARK: - DSR2-02: header text-column, body-row alignment, and divider alignment derive from one
    // named source
    //
    // `headerTextLeadingInset` — the header row's own text-column start (avatar width + header/body
    // gap) — is the one named source both a body row's leading alignment and the internal body-row
    // divider's leading alignment derive from, rather than each reconstructing its own inset.

    // MARK: - DSR3-08: headers without a leading element

    /// `AccordionList` doesn't yet expose a compile-safe path for callers with no header leading
    /// content, so this pins the required source shape as an explicit XCTest assertion — matching
    /// `AccordionListMetrics.headerTextLeadingInset` above — rather than a `headerLeading`-omitting
    /// compile fixture, which would fail the whole test target to compile before the overload exists.
    func testSourceDefinesANoLeadingInitializerOverloadWhereHeaderLeadingIsEmptyView() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(
            src.contains("extension AccordionList where HeaderLeading == EmptyView"),
            "expected a compile-safe initializer path for callers with no header leading content, " +
                "so they never pass an empty placeholder frame manually"
        )
        XCTAssertTrue(
            src.contains("headerLeading: { _ in EmptyView() }"),
            "expected the no-leading initializer overload to forward an EmptyView headerLeading closure to the designated initializer"
        )
    }

    func testBodyLeadingInsetIsZeroWithoutHeaderLeadingAndTheExistingHeaderTextLeadingInsetWhenItExists() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(
            src.contains("hasHeaderLeading ? AccordionListMetrics.headerTextLeadingInset : HermesSpacing.s0"),
            "expected no-leading mode to use zero Accordion-owned body inset while leading-present mode " +
                "retains the existing avatar-derived headerTextLeadingInset"
        )
    }

    func testHeaderTextLeadingInsetIsOneNamedSourceReplacingTheOldPerRowReconstruction() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(
            src.contains("static let headerTextLeadingInset = HermesAvatarSize.small.rawValue + HermesSpacing.s12"),
            "expected one named headerTextLeadingInset metric — the header row's own text-column start — instead of a metric that only body rows referenced"
        )
        XCTAssertFalse(
            src.contains("static let bodyLeadingInset"),
            "bodyLeadingInset is retired in favor of the single named headerTextLeadingInset source"
        )
    }

    func testBodyRowLeadingAlignmentDerivesFromTheNamedHeaderTextLeadingInset() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(
            src.contains(".padding(.leading, bodyLeadingInset)"),
            "expected body rows to align to the effective bodyLeadingInset — zero without header leading, " +
                "the named headerTextLeadingInset when header leading exists"
        )
    }

    func testBodyRowDividersAlignToTheSameNamedHeaderTextLeadingInset() throws {
        let src = try source("HermesMobile/Features/Shared/AccordionList.swift")
        XCTAssertTrue(
            src.contains("bodyDividerLeadingInset = bodyLeadingInset + HermesSpacing.s12"),
            "the body-row divider inset must derive from the effective bodyLeadingInset plus ListItem's " +
                "own 12pt horizontal inset — equal to ListItem's standard content column when there is no header leading"
        )
        XCTAssertTrue(
            src.contains("HermexDivider(leadingInset: bodyDividerLeadingInset)"),
            "dividers between body rows must begin at the body row's actual text-content alignment"
        )
    }
}
