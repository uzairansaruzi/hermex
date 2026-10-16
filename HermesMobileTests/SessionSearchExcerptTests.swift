import XCTest
@testable import HermesMobile

final class SessionSearchExcerptTests: XCTestCase {
    /// Every bolded run of the excerpt, in order.
    private func boldRuns(_ excerpt: SessionSearchExcerpt) -> [String] {
        excerpt.highlighted.runs.compactMap { run in
            guard run.inlinePresentationIntent == .stronglyEmphasized else { return nil }
            return String(excerpt.highlighted[run.range].characters)
        }
    }

    private func plainText(_ excerpt: SessionSearchExcerpt) -> String {
        String(excerpt.highlighted.characters)
    }

    func testHighlightsEveryOccurrenceRegardlessOfCase() {
        let excerpt = SessionSearchExcerpt(
            text: "...Billing failed, so retry the billing job...",
            query: "billing"
        )

        XCTAssertEqual(boldRuns(excerpt), ["Billing", "billing"])
        XCTAssertEqual(plainText(excerpt), excerpt.text)
    }

    /// The server sends whatever the transcript held, which may be decomposed
    /// while the typed query is composed (or the reverse). Bolding the text's
    /// own range keeps the combining marks attached to their base character.
    func testHighlightsAcrossComposedAndDecomposedSpellings() {
        let decomposedText = "meet at the cafe\u{0301} tonight"
        let excerpt = SessionSearchExcerpt(text: decomposedText, query: "café")

        XCTAssertEqual(boldRuns(excerpt), ["cafe\u{0301}"])
        XCTAssertEqual(plainText(excerpt), decomposedText)
    }

    /// Diacritics are not folded: the server matched the query literally, so
    /// bolding "café" for a query of "cafe" would claim a hit that never was.
    func testDoesNotFoldDiacritics() {
        let excerpt = SessionSearchExcerpt(text: "meet at the café tonight", query: "cafe")

        XCTAssertTrue(boldRuns(excerpt).isEmpty)
    }

    func testEmptyQueryHighlightsNothing() {
        let excerpt = SessionSearchExcerpt(text: "...deploy the worker...", query: "")

        XCTAssertTrue(boldRuns(excerpt).isEmpty)
        XCTAssertEqual(plainText(excerpt), excerpt.text)
    }

    /// Excerpts windowed out of a serialized tool result arrive with that
    /// JSON's escapes still in them; the row must not print them.
    func testTurnsEscapedWhitespaceIntoSpaces() {
        let excerpt = SessionSearchExcerpt(
            text: #"...459k 419M 0% /\n---\nRAM: 8.0 GB", "exit_code": 0,..."#,
            query: "RAM"
        )

        XCTAssertEqual(excerpt.text, #"...459k 419M 0% / --- RAM: 8.0 GB", "exit_code": 0,..."#)
        XCTAssertEqual(boldRuns(excerpt), ["RAM"])
    }

    func testCollapsesRunsOfWhitespaceAndTrims() {
        let excerpt = SessionSearchExcerpt(text: "  deploy\tthe\t\tworker  ", query: "deploy")

        XCTAssertEqual(excerpt.text, "deploy the worker")
    }

    // MARK: Hermes snippets (#1053)

    /// The host marks each match with `>>>` and `<<<`: those spans are bolded, the marks
    /// never show, and the plain text VoiceOver reads has none.
    func testAHermesSnippetBoldsItsMarkedMatchesWithoutTheMarks() {
        let excerpt = SessionSearchExcerpt(
            hermesSnippet: "...the >>>Nimbus<<< rollout and the >>>nimbus<<<-2 cluster...", query: "nimb"
        )

        XCTAssertEqual(boldRuns(excerpt), ["Nimbus", "nimbus"])
        XCTAssertEqual(excerpt.text, "...the Nimbus rollout and the nimbus-2 cluster...")
        XCTAssertEqual(plainText(excerpt), excerpt.text)
    }

    /// A stray mark, such as a `>>>` the message itself held, is dropped too; it only starts or
    /// ends the bolding. Escaped whitespace still becomes spaces.
    func testAHermesSnippetNeverShowsAStrayMark() {
        let excerpt = SessionSearchExcerpt(hermesSnippet: #"<<<print >>>deploy<<<\n done>>>"#, query: "deploy")

        XCTAssertEqual(excerpt.text, "print deploy done")
        XCTAssertEqual(boldRuns(excerpt), ["deploy"])
        XCTAssertFalse(plainText(excerpt).contains(">>>") || plainText(excerpt).contains("<<<"))
    }

    /// The host's substring search (for text FTS can't split) marks nothing, so the query is
    /// bolded as in a webui excerpt.
    func testAnUnmarkedHermesSnippetBoldsTheQuery() {
        let excerpt = SessionSearchExcerpt(hermesSnippet: "会议记录：部署计划", query: "部署")

        XCTAssertEqual(boldRuns(excerpt), ["部署"])
        XCTAssertEqual(excerpt.text, "会议记录：部署计划")
    }
}
