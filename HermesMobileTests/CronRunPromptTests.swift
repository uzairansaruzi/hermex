import XCTest
@testable import HermesMobile

/// A scheduled task's stored prompt row (#1413). The fixture carries the pinned
/// `_CRON_HINT` (`cron/scheduler_prompt.py` at `ca67828`), whose bracketed
/// runbook nests the `[SILENT]` / `[CRON_FAILURE]` tokens, in both shapes the
/// display projection produces: the no-skills row that opens with it, and the
/// skill run's `/skill <hint> <instruction>` rewrite.
final class CronRunPromptTests: XCTestCase {
    /// The verified hint text, byte for what the host prepends (`_CRON_HINT + prompt`),
    /// including its trailing blank line.
    private static let hint = """
    [IMPORTANT: You are running as a scheduled cron job. \
    DELIVERY: Your final response will be automatically delivered to the user — do NOT use send_message or try to deliver the output yourself. \
    Just produce your report/output as your final response and the system handles the rest. \
    SILENT: If there is genuinely nothing new to report, respond with exactly "[SILENT]" (nothing else) to suppress delivery. \
    [SILENT] is a literal ASCII control token — never translate or rephrase it, whatever language the rest of your answer uses. \
    Never combine [SILENT] with content — either report your findings normally, or say [SILENT] and nothing more. \
    FAILURE: If a delegated child fails and this cron run must be recorded as failed, put [CRON_FAILURE] on the first line by itself, \
    then explain the child failure on following lines. \
    RECURSION: This is a run of an EXISTING scheduled job — execute the task now. \
    NEVER create or update a cron job because of recurring or future-schedule language in the task prompt below; \
    treat phrasing like "each Monday" or "every day at 9" as context for this run, not as a request to schedule another job.]\n\n
    """

    func testHintOpeningTheRowBecomesACard() throws {
        let content = Self.hint + "Check the backups\nand report."
        let prompt = try XCTUnwrap(CronRunPrompt(content: content))
        XCTAssertNil(prompt.skillLabels)
        XCTAssertEqual(prompt.body, "Check the backups\nand report.")
        XCTAssertEqual(prompt.appVisibleInput, content, "Copy keeps the exact input, hint included")
        XCTAssertTrue(prompt.summary.contains("Check the backups"))
        XCTAssertFalse(prompt.summary.contains("SILENT"), "the runbook never previews")
    }

    func testNestedTokensStayInsideTheHint() throws {
        let prompt = try XCTUnwrap(CronRunPrompt(content: Self.hint + "Summarize the logs."))
        XCTAssertEqual(prompt.body, "Summarize the logs.")
    }

    func testSkillRewriteYieldsLabelsAndTaskText() throws {
        let content = "/research \(Self.hint)Check the backups\nand report."
        let prompt = try XCTUnwrap(CronRunPrompt(content: content))
        XCTAssertEqual(prompt.skillLabels, "/research")
        XCTAssertEqual(prompt.body, "Check the backups\nand report.")
        XCTAssertEqual(prompt.appVisibleInput, content)
    }

    func testStackedBundleLabelsStayWhole() throws {
        let content = "/clean /work [IMPORTANT: You are running as a scheduled cron job. Do the sweep.] Sweep the kitchen"
        let prompt = try XCTUnwrap(CronRunPrompt(content: content))
        XCTAssertEqual(prompt.skillLabels, "/clean /work")
        XCTAssertEqual(prompt.body, "Sweep the kitchen")
    }

    // MARK: - Fallbacks

    func testOrdinaryMessageIsNeverACard() {
        XCTAssertNil(CronRunPrompt(content: "Check the backups this morning, please."))
    }

    func testHintQuotedMidMessageIsNeverACard() {
        let content = "What does this mean?\n\(Self.hint)Check the backups"
        XCTAssertNil(CronRunPrompt(content: content))
    }

    func testSlashCommandWithoutTheHintIsNeverACard() {
        XCTAssertNil(CronRunPrompt(content: "/research check the backups"))
    }

    func testUnbalancedHintFallsBack() {
        var unbalanced = Self.hint
        unbalanced.removeLast(3) // drops "]\n\n"
        XCTAssertNil(CronRunPrompt(content: unbalanced + "Check the backups"))
        XCTAssertNil(CronRunPrompt(content: "[IMPORTANT: You are running as a scheduled cron job."))
    }

    func testHintWithoutTaskTextFallsBack() {
        XCTAssertNil(CronRunPrompt(content: Self.hint))
    }

    // MARK: - Provenance

    /// A `.session` target with a `cron_` key is a scheduled task's run even though
    /// the chat's `SessionSummary` placeholder carries no source markers.
    func testCronSessionKeySuppliesProvenance() {
        XCTAssertTrue(CronRunPrompt.isCronRun(
            target: .session(profile: "default", key: "cron_nightly_20261030T0900"),
            storedKey: "cron_nightly_20261030T0900", root: "cron_nightly_20261030T0900"
        ))
        XCTAssertTrue(CronRunPrompt.isCronRun(target: .session(profile: "default", key: "cr-1"), storedKey: nil, root: "CRON_other"))
        XCTAssertFalse(CronRunPrompt.isCronRun(
            target: .session(profile: "default", key: "session-123"), storedKey: "session-123", root: "session-123"
        ))
        XCTAssertFalse(CronRunPrompt.isCronRun(target: .canonicalChat(profile: "default"), storedKey: nil, root: "bot-root"))
        XCTAssertFalse(CronRunPrompt.isCronRun(target: .new(profile: "default"), storedKey: nil, root: nil))
    }

    /// Provenance gates the row, and only the run's own first user row routes.
    func testMessageGating() {
        let content = Self.hint + "Check the backups"
        XCTAssertNil(CronRunPrompt(message: ChatMessage(role: "user", content: content, timestamp: nil, messageId: "r1"),
                                   isCronRun: false))
        XCTAssertNil(CronRunPrompt(message: ChatMessage(role: "assistant", content: content, timestamp: nil, messageId: "r2"),
                                   isCronRun: true))
        XCTAssertNotNil(CronRunPrompt(message: ChatMessage(role: "user", content: content, timestamp: nil, messageId: "r3"),
                                      isCronRun: true))
    }
}
