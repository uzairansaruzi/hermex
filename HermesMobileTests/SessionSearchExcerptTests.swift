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

    /// Redaction can replace the matched span, leaving an excerpt the query is
    /// no longer in. The excerpt still reads; nothing is bolded.
    func testShowsPlainExcerptWhenTheQueryIsAbsent() {
        let excerpt = SessionSearchExcerpt(text: "...the token is [redacted]...", query: "sk-live")

        XCTAssertTrue(boldRuns(excerpt).isEmpty)
        XCTAssertEqual(plainText(excerpt), excerpt.text)
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

    func testLeavesAnOrdinaryExcerptAlone() {
        let text = "...decided to move the billing plan tiers behind a flag..."
        let excerpt = SessionSearchExcerpt(text: text, query: "billing")

        XCTAssertEqual(excerpt.text, text)
    }

    func testHighlightsAMatchAtEitherEdge() {
        let excerpt = SessionSearchExcerpt(text: "deploy the deploy", query: "deploy")

        XCTAssertEqual(boldRuns(excerpt), ["deploy", "deploy"])
        XCTAssertEqual(plainText(excerpt), excerpt.text)
    }
}
