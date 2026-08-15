import XCTest
@testable import HermesMobile

final class StreamingMarkdownBlockSplitterTests: XCTestCase {
    func testShortTextStaysInActiveMarkdown() {
        let text = "Hello from Hermes."
        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertTrue(segments.stableChunks.isEmpty)
        XCTAssertEqual(segments.activeMarkdown, text)
    }

    func testCompletedFenceSealsStableChunk() {
        let stableBody = String(repeating: "A", count: 6_100)
        let text = """
        \(stableBody)
        ```swift
        let answer = 42
        ```
        Still streaming
        """

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertEqual(segments.stableChunks.count, 1)
        XCTAssertTrue(segments.stableChunks[0].text.contains(stableBody))
        XCTAssertTrue(segments.activeMarkdown.contains("Still streaming"))
    }

    func testHeadingBoundaryCanSealWithoutFence() {
        let prose = String(repeating: "Line of prose.\n", count: 500)
        let text = prose + "## Next section\nMore text"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertFalse(segments.stableChunks.isEmpty)
        XCTAssertTrue(segments.activeMarkdown.contains("More text"))
    }

    func testTabSeparatedHeadingCountsAsStableBoundary() {
        let prose = String(repeating: "Line of prose.\n", count: 500)
        let text = prose + "##\tTab heading\nMore text"

        let segments = StreamingMarkdownBlockSplitter.split(text)

        XCTAssertFalse(segments.stableChunks.isEmpty)
        XCTAssertTrue(segments.activeMarkdown.contains("More text"))
    }
}

final class ReasoningMarkdownPresentationTests: XCTestCase {
    func testFormatsProviderBoldLedgerAsRowsWithSectionRules() {
        let source = """
        **Inspecting source**
        **Comparing results**

        The result is ready.

        **Planning follow-up**
        **Verifying output**
        """

        XCTAssertEqual(
            ReasoningMarkdownPresentation.formatted(source),
            [
                "**Inspecting source**  ",
                "**Comparing results**",
                "",
                "---",
                "",
                "The result is ready.",
                "",
                "---",
                "",
                "**Planning follow-up**  ",
                "**Verifying output**"
            ].joined(separator: "\n")
        )
    }

    func testLeavesOrdinaryMarkdownAndSingleBoldParagraphUntouched() {
        let source = """
        ## Real heading

        A paragraph with **inline emphasis**.

        **One bold paragraph**
        """

        XCTAssertEqual(ReasoningMarkdownPresentation.formatted(source), source)
    }

    func testLeavesBoldLookingLinesInsideFenceUntouched() {
        let source = """
        ```markdown
        **First example**
        **Second example**
        ```
        """

        XCTAssertEqual(ReasoningMarkdownPresentation.formatted(source), source)
    }

    func testMixedFenceMarkerInsideFenceDoesNotHideFollowingLedger() {
        let source = """
        ```markdown
        ~~~
        ```

        **Inspecting source**
        **Verifying result**
        """

        XCTAssertEqual(
            ReasoningMarkdownPresentation.formatted(source),
            [
                "```markdown",
                "~~~",
                "```",
                "",
                "---",
                "",
                "**Inspecting source**  ",
                "**Verifying result**"
            ].joined(separator: "\n")
        )
    }

    func testLeavesStandaloneBoldItalicLinesUntouched() {
        let source = """
        ***Inspecting source***
        ***Verifying result***
        """

        XCTAssertEqual(ReasoningMarkdownPresentation.formatted(source), source)
    }
}

/// Width resolution for chat markdown table cells (issue #233). The layout
/// itself needs a render pass to verify; this covers the pure clamp that
/// decides the wrap width the cell height is measured at.
final class TableCellWidthCapTests: XCTestCase {
    private let minWidth: CGFloat = 96
    private let maxWidth: CGFloat = 260

    func testIdealWidthBelowMinClampsToMin() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 40, proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, minWidth)
    }

    func testIdealWidthWithinBoundsIsUsedAsIs() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 150, proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, 150)
    }

    func testIdealWidthAboveMaxClampsToMax() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 1_200, proposedWidth: nil, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, maxWidth)
    }

    func testProposedColumnWidthOverridesIdealWidth() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 40, proposedWidth: 200, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, 200)
    }

    func testProposedColumnWidthIsStillClamped() {
        let width = TableCellWidthCap.resolvedWidth(
            idealWidth: 40, proposedWidth: 999, minWidth: minWidth, maxWidth: maxWidth
        )
        XCTAssertEqual(width, maxWidth)
    }
}
