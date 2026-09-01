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

final class StreamingReasoningTextStateTests: XCTestCase {
    func testReasoningBlockDisplayTextPreservesExistingBoundaryTrimming() {
        XCTAssertEqual(
            ReasoningBlockContent.displayText(from: " \nReasoning stays complete.\n "),
            "Reasoning stays complete."
        )
        XCTAssertNil(ReasoningBlockContent.displayText(from: " \n\t "))
    }

    func testLargePrefixStreamReconstructsExactlyAndPreservesStableChunks() {
        let paragraph = "Hermes inspects the workspace before choosing the next step.\n\n"
        let fullText = String(String(repeating: paragraph, count: 1_500).prefix(80_000))
        var state = StreamingReasoningTextState()
        var previousChunks: [StreamingReasoningChunk] = []

        for characterCount in stride(from: 2_000, through: 80_000, by: 2_000) {
            let end = fullText.index(fullText.startIndex, offsetBy: characterCount)
            state.update(with: String(fullText[..<end]))

            XCTAssertEqual(Array(state.stableChunks.prefix(previousChunks.count)), previousChunks)
            XCTAssertLessThanOrEqual(
                state.activeTail.count,
                StreamingReasoningTextState.maximumActiveTailCharacterCount
            )
            previousChunks = state.stableChunks
        }

        XCTAssertEqual(Array(state.reconstructedText.utf8), Array(fullText.utf8))
        XCTAssertFalse(state.stableChunks.isEmpty)
    }

    func testBlankLineBecomesAStableChunkBoundary() {
        let firstParagraph = String(repeating: "A", count: 900) + "\n\n"
        let text = firstParagraph + String(repeating: "B", count: 1_000)
        let state = StreamingReasoningTextState(text: text)

        XCTAssertEqual(state.stableChunks.first?.text, firstParagraph)
        XCTAssertEqual(state.reconstructedText, text)
    }

    func testLongUnbrokenTextUsesBoundedGraphemeSafeChunks() {
        let text = String(repeating: "x", count: 5_000)
        let state = StreamingReasoningTextState(text: text)

        XCTAssertTrue(state.stableChunks.allSatisfy {
            $0.text.count == StreamingReasoningTextState.targetChunkCharacterCount
        })
        XCTAssertLessThanOrEqual(
            state.activeTail.count,
            StreamingReasoningTextState.maximumActiveTailCharacterCount
        )
        XCTAssertEqual(state.reconstructedText, text)
    }

    func testEmojiAndMultiScalarGraphemesStayIntact() {
        let graphemes = ["👨🏽‍💻", "e\u{301}", "🇺🇸", "🫶🏻"]
        let text = String(repeating: graphemes.joined(), count: 800)
        let state = StreamingReasoningTextState(text: text)

        XCTAssertEqual(Array(state.reconstructedText.utf8), Array(text.utf8))
        XCTAssertTrue(state.stableChunks.allSatisfy { chunk in
            chunk.text.allSatisfy { graphemes.contains(String($0)) }
        })
    }

    func testPrefixAppendCanExtendTheFinalGrapheme() {
        let initialText = String(repeating: "x", count: 2_000) + "e"
        let extendedText = initialText + "\u{301}"
        var state = StreamingReasoningTextState(text: initialText)

        state.update(with: extendedText)

        XCTAssertEqual(Array(state.reconstructedText.utf8), Array(extendedText.utf8))
        XCTAssertTrue(state.activeTail.hasSuffix("e\u{301}"))
    }

    func testNonPrefixReplacementDropsPreviousChunks() {
        let original = String(repeating: "Original paragraph.\n\n", count: 200)
        let replacement = String(repeating: "Replacement paragraph.\n\n", count: 200)
        var state = StreamingReasoningTextState(text: original)

        state.update(with: replacement)

        XCTAssertEqual(state.stableChunks.first?.id, 0)
        XCTAssertTrue(state.stableChunks.first?.text.hasPrefix("Replacement") == true)
        XCTAssertFalse(state.reconstructedText.contains("Original"))
        XCTAssertEqual(state.reconstructedText, replacement)
    }

    func testExplicitNewStreamResetRestartsChunkIdentity() {
        let firstStream = String(repeating: "First stream.\n\n", count: 200)
        let secondStream = String(repeating: "Second stream.\n\n", count: 200)
        var state = StreamingReasoningTextState(text: firstStream)

        state.reset(with: secondStream)

        XCTAssertEqual(state.stableChunks.first?.id, 0)
        XCTAssertEqual(state.reconstructedText, secondStream)
    }

    func testTextStorageUpdateAppendsOnlyNewSuffix() {
        let rendered = String(repeating: "Long paragraph without breaks. ", count: 100)
        let newText = rendered + "Still streaming."

        XCTAssertEqual(
            StreamingReasoningTextStorageUpdate.make(
                renderedText: rendered,
                newText: newText
            ),
            .append("Still streaming.")
        )
    }

    func testTextStorageUpdateReplacesNonPrefixContent() {
        XCTAssertEqual(
            StreamingReasoningTextStorageUpdate.make(
                renderedText: "Old stream",
                newText: "Replacement stream"
            ),
            .replace("Replacement stream")
        )
    }

    func testTextStorageUpdatePreservesCrossUpdateGraphemeBytes() {
        let rendered = "Planning e"
        let newText = rendered + "\u{301}"

        XCTAssertEqual(
            StreamingReasoningTextStorageUpdate.make(
                renderedText: rendered,
                newText: newText
            ),
            .append("\u{301}")
        )
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
