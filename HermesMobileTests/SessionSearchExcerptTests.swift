import XCTest
@testable import HermesMobile

final class SessionSearchExcerptTests: XCTestCase {
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

    func testHighlightsAcrossComposedAndDecomposedSpellings() {
        let decomposedText = "meet at the cafe\u{0301} tonight"
        let excerpt = SessionSearchExcerpt(text: decomposedText, query: "café")

        XCTAssertEqual(boldRuns(excerpt), ["cafe\u{0301}"])
        XCTAssertEqual(plainText(excerpt), decomposedText)
    }

    func testDoesNotFoldDiacritics() {
        let excerpt = SessionSearchExcerpt(text: "meet at the café tonight", query: "cafe")

        XCTAssertTrue(boldRuns(excerpt).isEmpty)
    }

    func testEmptyQueryHighlightsNothing() {
        let excerpt = SessionSearchExcerpt(text: "...deploy the worker...", query: "")

        XCTAssertTrue(boldRuns(excerpt).isEmpty)
        XCTAssertEqual(plainText(excerpt), excerpt.text)
    }

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

    func testAHermesSnippetBoldsItsMarkedMatchesWithoutTheMarks() {
        let excerpt = SessionSearchExcerpt(
            hermesSnippet: "...the >>>Nimbus<<< rollout and the >>>nimbus<<<-2 cluster...", query: "nimb"
        )

        XCTAssertEqual(boldRuns(excerpt), ["Nimbus", "nimbus"])
        XCTAssertEqual(excerpt.text, "...the Nimbus rollout and the nimbus-2 cluster...")
        XCTAssertEqual(plainText(excerpt), excerpt.text)
    }

    func testAHermesSnippetNeverShowsAStrayMark() {
        let excerpt = SessionSearchExcerpt(hermesSnippet: #"<<<print >>>deploy<<<\n done>>>"#, query: "deploy")

        XCTAssertEqual(excerpt.text, "print deploy done")
        XCTAssertEqual(boldRuns(excerpt), ["deploy"])
        XCTAssertFalse(plainText(excerpt).contains(">>>") || plainText(excerpt).contains("<<<"))
    }

    func testAnUnmarkedHermesSnippetBoldsTheQuery() {
        let excerpt = SessionSearchExcerpt(hermesSnippet: "会议记录：部署计划", query: "部署")

        XCTAssertEqual(boldRuns(excerpt), ["部署"])
        XCTAssertEqual(excerpt.text, "会议记录：部署计划")
    }
}
