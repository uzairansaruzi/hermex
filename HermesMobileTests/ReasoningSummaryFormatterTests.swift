import XCTest
@testable import HermesMobile

final class ReasoningSummaryFormatterTests: XCTestCase {
    func testCollapsesNewlineRunsToOneSpace() {
        XCTAssertEqual(
            ReasoningSummaryFormatter.summary(for: "First line\n\nSecond line\r\nThird"),
            "First line Second line Third"
        )
    }

    func testCutsTextPastTheLimitWithAnEllipsis() {
        let text = String(repeating: "b", count: ReasoningSummaryFormatter.characterLimit + 1)
        XCTAssertEqual(
            ReasoningSummaryFormatter.summary(for: text),
            String(repeating: "b", count: ReasoningSummaryFormatter.characterLimit) + "..."
        )
    }

    func testStopsReadingAtTheScanLimitEvenAcrossNewlines() {
        let text = "a" + String(repeating: "\n", count: ReasoningSummaryFormatter.scanLimit) + "b"
        XCTAssertEqual(ReasoningSummaryFormatter.summary(for: text), "a")
    }

    func testLatestThoughtPrefersTheNewestCompletedHeading() {
        let text = """
        **Planning**

        **Checking the retry policy**

        The cron client maps 502 to rejected.

        **Writing the fi
        """
        XCTAssertEqual(ReasoningSummaryFormatter.latestThought(in: text), "Checking the retry policy")
    }

    func testLatestThoughtFallsBackToTheNewestParagraphsFirstSentence() {
        let text = """
        Opening paragraph.

        The cron client maps 502 to rejected, so the list never retries. Then it stops.
        """
        XCTAssertEqual(
            ReasoningSummaryFormatter.latestThought(in: text),
            "The cron client maps 502 to rejected, so the list never retries."
        )
        XCTAssertEqual(
            ReasoningSummaryFormatter.latestThought(in: "最初の段落。\n\n再試行ポリシーを確認する。次に"),
            "再試行ポリシーを確認する。"
        )
    }

    func testLatestThoughtReadsOnlyTheTail() {
        let filler = String(repeating: "Reading more files. ", count: ReasoningSummaryFormatter.tailLimit / 10)
        let text = "**Old heading**\n\n\(filler)\n\nNewest paragraph here. Rest"
        XCTAssertEqual(ReasoningSummaryFormatter.latestThought(in: text), "Newest paragraph here.")

        // A tail that starts exactly on a line keeps that line.
        let heading = "**Current phase**\n\n"
        let tail = heading + String(repeating: "x", count: ReasoningSummaryFormatter.tailLimit - heading.count)
        XCTAssertEqual(ReasoningSummaryFormatter.latestThought(in: "Older text.\n" + tail), "Current phase")
    }

    func testPreviewsStripCommonMarkupButKeepIdentifiers() {
        let text = "## Plan\n- Check `retry_policy` in [the docs](https://example.com/a_(b)) and **bold** *em*, `2*3`, 4*5, `**kwargs` and ``**opts``"
        let expected = "Plan Check retry_policy in the docs and bold em, 2*3, 4*5, **kwargs and **opts"
        XCTAssertEqual(ReasoningSummaryFormatter.summary(for: text), expected)
        XCTAssertEqual(ReasoningSummaryFormatter.latestThought(in: text), expected)
    }
}
