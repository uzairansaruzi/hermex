import XCTest
@testable import HermesMobile

/// The settled history's normalization must leave a cron run's prompt row
/// recognizable (#1413): an expanded skill row is rewritten to
/// `/skill <instruction>` with whitespace collapsed, and the host's `_CRON_HINT`
/// survives inside that instruction. Feeding a raw expanded row through
/// `HermesTranscriptProjection.project` and the parser proves the card stays
/// reachable, with the hint text from the pin (`cron/scheduler_prompt.py`).
final class HermesTranscriptHistoryTests: XCTestCase {
    private static let hint = """
    [IMPORTANT: You are running as a scheduled cron job. \
    SILENT: If there is genuinely nothing new to report, respond with exactly "[SILENT]" (nothing else) to suppress delivery. \
    FAILURE: If a delegated child fails and this cron run must be recorded as failed, put [CRON_FAILURE] on the first line by itself.]\n\n
    """

    /// An expanded cron skill run: the host's scaffold, then the instruction it
    /// appended — the hint followed by the job's own text, with a runtime note after.
    func testExpandedCronSkillRowStillClassifies() throws {
        let raw = """
        [IMPORTANT: The user has invoked the "research" skill. The full skill content is loaded below.]

        Skill body the history mapper discards.

        The user has provided the following instruction alongside the skill invocation: \(hint)Check the backups

        [Runtime note: The skill content above is reference material.]
        """
        let projected = HermesTranscriptProjection.project(
            [.object(["id": .number(1), "role": .string("user"), "content": .string(raw)])],
            root: "cron_nightly_1"
        )
        let row = try XCTUnwrap(projected.messages.first)
        XCTAssertEqual(row.displayKind, "skill_invocation")
        XCTAssertTrue(row.content?.hasPrefix("/research [IMPORTANT: You are running as a scheduled cron job.") ?? false)

        let prompt = try XCTUnwrap(CronRunPrompt(message: row, isCronRun: true))
        XCTAssertEqual(prompt.skillLabels, "/research")
        XCTAssertEqual(prompt.body, "Check the backups", "the hint is gone from the expanded body")
        XCTAssertEqual(prompt.appVisibleInput, row.content)
        XCTAssertNil(CronRunPrompt(message: row, isCronRun: false), "provenance gates the row")
    }

    /// A cron run without skills stores the hint at the row's start; an ordinary
    /// prompt on the same chat never becomes a card.
    func testPlainCronRowClassifiesAndOrdinaryRowsDoNot() throws {
        let projected = HermesTranscriptProjection.project([
            .object(["id": .number(1), "role": .string("user"), "content": .string(hint + "Check the backups\nand report.")]),
            .object(["id": .number(2), "role": .string("user"), "content": .string("Check the backups\nand report.")])
        ], root: "cron_nightly_1")
        let cron = try XCTUnwrap(projected.messages.first)
        XCTAssertNil(cron.displayKind)
        let prompt = try XCTUnwrap(CronRunPrompt(message: cron, isCronRun: true))
        XCTAssertNil(prompt.skillLabels)
        XCTAssertEqual(prompt.body, "Check the backups\nand report.")
        XCTAssertNil(CronRunPrompt(message: projected.messages.last!, isCronRun: true),
                     "an ordinary user row keeps its bubble")
    }
}
