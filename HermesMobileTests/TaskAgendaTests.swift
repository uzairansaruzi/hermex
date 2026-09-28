import XCTest
@testable import HermesMobile

/// Covers the three pieces the Tasks agenda list is built on: humanising cron
/// expressions, assigning each job to exactly one group, and stripping the
/// terminal escapes out of server run text.
final class TaskAgendaTests: XCTestCase {

    // MARK: - Fixtures

    /// Eastern time, matching the reference server the eleven real expressions
    /// came from, so rendered clock times are the ones cron fires at.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private static let locale = Locale(identifier: "en_US")

    private func makeJob(
        id: String? = "job-1",
        name: String = "Task",
        schedule: String? = "0 7 * * *",
        enabled: Bool = true,
        state: String = "scheduled",
        nextRunAt: Date? = nil,
        lastStatus: String? = "ok",
        lastError: String? = nil,
        lastDeliveryError: String? = nil
    ) throws -> CronJob {
        var payload: [String: Any] = [
            "name": name,
            "enabled": enabled,
            "state": state,
            "toast_notifications": true
        ]
        if let id { payload["id"] = id }
        if let schedule { payload["schedule"] = ["kind": "cron", "expr": schedule, "display": schedule] }
        if let nextRunAt { payload["next_run_at"] = ISO8601DateFormatter().string(from: nextRunAt) }
        if let lastStatus { payload["last_status"] = lastStatus }
        if let lastError { payload["last_error"] = lastError }
        if let lastDeliveryError { payload["last_delivery_error"] = lastDeliveryError }

        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CronJob.self, from: data)
    }

    private func describe(_ expression: String) -> CronScheduleDescription? {
        CronScheduleHumanizer.describe(expression, locale: Self.locale, calendar: Self.calendar)
    }

    /// `Date.FormatStyle` separates the time from AM/PM with a narrow no-break
    /// space (U+202F). Fold it back to a plain space so the expectations below
    /// stay readable and the assertions are about the words, not the spacing.
    private func sentence(_ expression: String) -> String? {
        describe(expression)?.sentence.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - Humanising

    func testHumanisesEveryExpressionOnTheReferenceServer() {
        let expectations: [String: String] = [
            "*/15 * * * *": "Every 15 minutes",
            "0 4 * * *": "Daily at 4:00 AM",
            "0 7 * * *": "Daily at 7:00 AM",
            "0 8 * * *": "Daily at 8:00 AM",
            "0 9 * * *": "Daily at 9:00 AM",
            "0 16 1 * *": "Monthly on the 1st at 4:00 PM",
            "0 18 * * 5": "Weekly on Friday at 6:00 PM",
            "0 20 * * 0": "Weekly on Sunday at 8:00 PM",
            "25 9 * * 1-5": "Weekdays at 9:25 AM",
            "5 16 * * 1-5": "Weekdays at 4:05 PM",
            "30 16 * * 1-5": "Weekdays at 4:30 PM"
        ]

        for (expression, expected) in expectations {
            XCTAssertEqual(sentence(expression), expected, expression)
        }
    }

    func testRecurrenceDropsTheTimeOfDayForRowsThatShowTheNextRun() {
        XCTAssertEqual(describe("0 7 * * *")?.recurrence, "Daily")
        XCTAssertEqual(describe("25 9 * * 1-5")?.recurrence, "Weekdays")
        XCTAssertEqual(describe("0 16 1 * *")?.recurrence, "Monthly on the 1st")
        XCTAssertEqual(describe("0 20 * * 0")?.recurrence, "Weekly on Sunday")
        // An interval has no time of day, so both forms are the same string.
        XCTAssertEqual(describe("*/15 * * * *")?.recurrence, "Every 15 minutes")
    }

    func testHumanisesTheRemainingRecognisedShapes() {
        XCTAssertEqual(sentence("* * * * *"), "Every minute")
        XCTAssertEqual(sentence("*/1 * * * *"), "Every minute")
        XCTAssertEqual(sentence("0 */2 * * *"), "Every 2 hours")
        XCTAssertEqual(sentence("0 12 * * 0,6"), "Weekends at 12:00 PM")
        // Cron's day 7 is Sunday.
        XCTAssertEqual(sentence("0 20 * * 7"), "Weekly on Sunday at 8:00 PM")
    }

    func testUnrecognisedExpressionsFallThroughInsteadOfGuessing() {
        let unrecognised = [
            "",
            "not a cron",
            "*/15 * * *",          // too few fields
            "*/15 * * * * *",      // too many fields
            "0 7 * * 9",           // day of week out of range
            "0 99 * * *",          // hour out of range
            "*/0 * * * *",         // zero step
            "0 7 1 * 1",           // day-of-month and day-of-week together
            "0 7 * 3 *",           // month restricted
            "0 7 * * 2-4",         // a weekday range we do not name
            "0,30 7 * * *"         // a minute list
        ]

        for expression in unrecognised {
            XCTAssertNil(describe(expression), expression)
        }
    }

    func testHumaniserIsNilForAMissingExpression() {
        XCTAssertNil(CronScheduleHumanizer.describe(nil, locale: Self.locale, calendar: Self.calendar))
    }

    // MARK: - Grouping

    private func group(
        _ job: CronJob,
        isRunning: Bool = false,
        now: Date
    ) -> TaskAgendaGroup {
        TaskAgenda.group(for: job, isRunning: isRunning, now: now, calendar: Self.calendar)
    }

    func testGroupsByWhenTheJobRunsNext() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let startOfToday = Self.calendar.startOfDay(for: now)

        func job(offsetDays: Int, hour: Int) throws -> CronJob {
            let day = try XCTUnwrap(Self.calendar.date(byAdding: .day, value: offsetDays, to: startOfToday))
            let next = try XCTUnwrap(Self.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day))
            return try makeJob(nextRunAt: next)
        }

        XCTAssertEqual(group(try job(offsetDays: 0, hour: 23), now: now), .laterToday)
        XCTAssertEqual(group(try job(offsetDays: 1, hour: 7), now: now), .tomorrow)
        XCTAssertEqual(group(try job(offsetDays: 3, hour: 7), now: now), .thisWeek)
        XCTAssertEqual(group(try job(offsetDays: 6, hour: 23), now: now), .thisWeek)
        XCTAssertEqual(group(try job(offsetDays: 7, hour: 1), now: now), .later)
        XCTAssertEqual(group(try job(offsetDays: 30, hour: 7), now: now), .later)
        XCTAssertEqual(group(try makeJob(nextRunAt: nil), now: now), .later)
    }

    func testAnOverdueNextRunStaysTodaysBusiness() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let overdue = try XCTUnwrap(Self.calendar.date(byAdding: .hour, value: -3, to: now))

        XCTAssertEqual(group(try makeJob(nextRunAt: overdue), now: now), .laterToday)
    }

    func testRunningWinsOverEveryOtherGroup() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let job = try makeJob(
            enabled: false,
            state: "paused",
            lastStatus: "error",
            lastError: "Script exited with code 1"
        )

        XCTAssertEqual(group(job, isRunning: true, now: now), .now)
    }

    func testAFailedLastRunNeedsAttentionWhateverTheEnabledState() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)

        let pausedFailure = try makeJob(
            enabled: false,
            state: "paused",
            lastStatus: "error",
            lastError: "Script exited with code 1"
        )
        XCTAssertEqual(group(pausedFailure, now: now), .needsAttention)

        let liveFailure = try makeJob(
            nextRunAt: now.addingTimeInterval(3600),
            lastStatus: "error"
        )
        XCTAssertEqual(group(liveFailure, now: now), .needsAttention)

        let deliveryFailure = try makeJob(lastDeliveryError: "discord: 403")
        XCTAssertEqual(group(deliveryFailure, now: now), .needsAttention)
    }

    func testAPausedJobWithoutAFailureIsPaused() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let job = try makeJob(enabled: false, state: "paused", nextRunAt: now.addingTimeInterval(-86_400))

        XCTAssertEqual(group(job, now: now), .paused)
    }

    func testEveryJobLandsInExactlyOneGroup() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let jobs = try referenceServerJobs(now: now)
        let running: Set<String> = ["job-2"]

        let sections = TaskAgenda.sections(
            jobs: jobs,
            runningJobIDs: running,
            filter: .all,
            now: now,
            calendar: Self.calendar
        )

        let placed = sections.flatMap(\.jobs).map(\.id)
        XCTAssertEqual(placed.count, jobs.count, "A job was dropped or duplicated by the grouping.")
        XCTAssertEqual(Set(placed), Set(jobs.map(\.id)))
        XCTAssertTrue(sections.allSatisfy { !$0.jobs.isEmpty }, "Empty groups must not be rendered.")
        XCTAssertEqual(
            sections.map(\.group),
            sections.map(\.group).sorted { $0.rawValue < $1.rawValue },
            "Groups must keep their declared screen order."
        )
    }

    func testJobsSortByNextRunThenName() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let soon = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(7200)

        let jobs = [
            try makeJob(id: "c", name: "Beta", nextRunAt: later),
            try makeJob(id: "b", name: "Zulu", nextRunAt: soon),
            try makeJob(id: "a", name: "Alpha", nextRunAt: soon)
        ]

        let sections = TaskAgenda.sections(
            jobs: jobs,
            runningJobIDs: [],
            filter: .all,
            now: now,
            calendar: Self.calendar
        )

        XCTAssertEqual(sections.flatMap(\.jobs).map(\.name), ["Alpha", "Zulu", "Beta"])
    }

    // MARK: - Filters

    func testFilterCountsMatchTheReferenceServer() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let jobs = try referenceServerJobs(now: now)

        XCTAssertEqual(TaskAgenda.count(of: .all, in: jobs, runningJobIDs: []), 11)
        XCTAssertEqual(TaskAgenda.count(of: .live, in: jobs, runningJobIDs: []), 3)
        XCTAssertEqual(TaskAgenda.count(of: .paused, in: jobs, runningJobIDs: []), 8)
        XCTAssertEqual(TaskAgenda.count(of: .errors, in: jobs, runningJobIDs: []), 1)
    }

    func testTheErrorsFilterSelectsTheFailingJob() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let jobs = try referenceServerJobs(now: now)

        let sections = TaskAgenda.sections(
            jobs: jobs,
            runningJobIDs: [],
            filter: .errors,
            now: now,
            calendar: Self.calendar
        )

        XCTAssertEqual(sections.flatMap(\.jobs).map(\.name), ["trading-bot-start-weekdays-0925"])
    }

    func testARunningPausedJobStillCountsAsLive() throws {
        let job = try makeJob(id: "job-1", enabled: false, state: "paused")

        XCTAssertEqual(TaskAgenda.count(of: .live, in: [job], runningJobIDs: ["job-1"]), 1)
        XCTAssertEqual(TaskAgenda.count(of: .paused, in: [job], runningJobIDs: ["job-1"]), 0)
    }

    /// The shape of the maintainer's server: eleven jobs, three scheduled,
    /// eight paused, one of the paused ones carrying a failed run.
    private func referenceServerJobs(now: Date) throws -> [CronJob] {
        var jobs: [CronJob] = [
            try makeJob(
                id: "job-0",
                name: "trading-bot-start-weekdays-0925",
                schedule: "25 9 * * 1-5",
                enabled: false,
                state: "paused",
                nextRunAt: now.addingTimeInterval(-86_400 * 40),
                lastStatus: "error",
                lastError: "Script exited with code 1\nstdout:\nFAIL — trading bot did not verify cleanly."
            )
        ]

        for index in 1...7 {
            jobs.append(
                try makeJob(
                    id: "paused-\(index)",
                    name: "Paused \(index)",
                    enabled: false,
                    state: "paused",
                    nextRunAt: now.addingTimeInterval(-86_400 * Double(index))
                )
            )
        }

        for index in 1...3 {
            jobs.append(
                try makeJob(
                    id: "job-\(index)",
                    name: "Live \(index)",
                    nextRunAt: now.addingTimeInterval(3600 * Double(index))
                )
            )
        }

        return jobs
    }

    // MARK: - ANSI stripping

    func testStripsColourCodesFromRunOutput() {
        let raw = "\u{1B}[0;32m[BOT START]\u{1B}[0m Starting Trading Bot"

        XCTAssertEqual(raw.strippingANSIEscapes(), "[BOT START] Starting Trading Bot")
    }

    func testLeavesTextWithoutEscapesUntouched() {
        let plain = "Script exited with code 1"

        XCTAssertEqual(plain.strippingANSIEscapes(), plain)
    }

    func testDropsASequenceSplitAcrossATruncationBoundary() {
        // A transcript clipped mid-escape must not leak its bytes into the UI.
        XCTAssertEqual("done \u{1B}[0;3".strippingANSIEscapes(), "done ")
        XCTAssertEqual("done \u{1B}".strippingANSIEscapes(), "done ")
        XCTAssertEqual("done \u{1B}]0;title".strippingANSIEscapes(), "done ")
    }

    func testStripsOperatingSystemCommandsAndTwoCharacterEscapes() {
        XCTAssertEqual("\u{1B}]0;window title\u{07}ready".strippingANSIEscapes(), "ready")
        XCTAssertEqual("\u{1B}]0;window title\u{1B}\\ready".strippingANSIEscapes(), "ready")
        XCTAssertEqual("\u{1B}creset".strippingANSIEscapes(), "reset")
    }

    func testFirstLineSummaryTakesOneReadableLine() {
        let raw = "\n\n\u{1B}[0;31mScript exited with code 1\u{1B}[0m\nstdout:\nFAIL"

        XCTAssertEqual(raw.firstLineSummary(), "Script exited with code 1")
        XCTAssertNil("   \n\n".firstLineSummary())
    }

    func testFirstLineSummaryClipsALongLine() {
        let raw = String(repeating: "a", count: 200)

        let summary = raw.firstLineSummary(limit: 20)

        XCTAssertEqual(summary, String(repeating: "a", count: 20) + "…")
    }

    func testFailureSummaryPrefersTheRunErrorAndIsEscapeFree() throws {
        let job = try makeJob(
            lastStatus: "error",
            lastError: "\u{1B}[0;31mScript exited with code 1\u{1B}[0m\nstdout: noise"
        )

        XCTAssertEqual(job.failureSummary, "Script exited with code 1")
        XCTAssertTrue(job.hasFailedRun)
    }
}
