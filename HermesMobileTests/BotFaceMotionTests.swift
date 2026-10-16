import XCTest
@testable import HermesMobile

final class BotFaceMotionTests: XCTestCase {
    func testBlinkScheduleFiresOnlyAtShutAndOpenEdges() {
        let schedule = BotBlinkSchedule(seed: "inbox-triage")
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(5))

        XCTAssertEqual(entries[0], start, "the first entry paints the current state")
        XCTAssertGreaterThan(entries[1], start)
        XCTAssertEqual(entries[2].timeIntervalSince(entries[1]), BotBlinkSchedule.shutDuration, accuracy: 0.0001)
        XCTAssertEqual(entries[3].timeIntervalSince(entries[1]), schedule.period, accuracy: 0.0001)
        XCTAssertTrue(schedule.isShut(at: entries[1]))
        XCTAssertTrue(schedule.isShut(at: entries[1].addingTimeInterval(0.1)))
        XCTAssertFalse(schedule.isShut(at: entries[2]))
        XCTAssertFalse(schedule.isShut(at: entries[2].addingTimeInterval(1)))
        XCTAssertTrue((3...5).contains(schedule.period))
    }

    func testReduceMotionStillsEveryMode() {
        let working = BotFaceMotion.working(since: Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(BotFaceMotion.idle.honoring(reduceMotion: true), .still)
        XCTAssertEqual(working.honoring(reduceMotion: true), .still)
        XCTAssertEqual(working.honoring(reduceMotion: false), working)
    }

    func testWorkingScheduleRunsAtFifteenFramesPerSecondOnlyForTheBeat() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let blink = BotBlinkSchedule(seed: "inbox-triage")
        let schedule = BotWorkingSchedule(start: start, blink: blink)
        let end = start.addingTimeInterval(BotWorkingSchedule.beat)
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(600))
        let frames = entries.prefix { $0 < end }

        XCTAssertEqual(BotWorkingSchedule.beat, 30)
        XCTAssertEqual(frames.first, start)
        XCTAssertEqual(frames.count, 450, "30 s at 15 fps")
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(later.timeIntervalSince(earlier), 1.0 / 15, accuracy: 0.0001)
        }
        let settled = Array(entries.dropFirst(frames.count).prefix(5))
        XCTAssertEqual(settled, Array(blink.entries(from: end, mode: .normal).prefix(5)),
                       "after the beat only the blink schedule's edges fire")
        XCTAssertEqual(settled.first, end, "the first settled entry paints the lean")
    }

    func testWorkingSchedulePastTheBeatGivesOnlyBlinkEdges() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let blink = BotBlinkSchedule(seed: "inbox-triage")
        let later = start.addingTimeInterval(3600)
        let entries = Array(BotWorkingSchedule(start: start, blink: blink).entries(from: later, mode: .normal).prefix(6))

        XCTAssertEqual(entries, Array(blink.entries(from: later, mode: .normal).prefix(6)))
        for (earlier, next) in zip(entries.dropFirst(), entries.dropFirst(2)) {
            XCTAssertGreaterThanOrEqual(next.timeIntervalSince(earlier), BotBlinkSchedule.shutDuration - 0.0001,
                                        "no 15 fps entries once the beat is over")
        }
    }

    func testUnstartedBeatHoldsTheSettledLean() {
        let blink = BotBlinkSchedule(seed: "inbox-triage")
        let schedule = BotWorkingSchedule(start: BotWorkingBeat().start, blink: blink)
        let now = Date(timeIntervalSinceReferenceDate: 1000)

        XCTAssertEqual(Array(schedule.entries(from: now, mode: .normal).prefix(6)),
                       Array(blink.entries(from: now, mode: .normal).prefix(6)),
                       "a chat opened onto a pending approval never runs the 15 fps beat")
        XCTAssertEqual(schedule.pose(at: now).gazeX, BotFacePose.settledWorking.gazeX)
    }

    func testWorkingBeatStartsOnlyWhenWorkStartsOrTheChatReturns() {
        var beat = BotWorkingBeat()
        let t = { Date(timeIntervalSinceReferenceDate: $0) }

        // Opened onto a pending approval: nothing sways until the answer resumes work.
        beat.observe(.unknown, at: t(1)); beat.observe(.needsAttention, at: t(2))
        XCTAssertEqual(beat.start, .distantPast)
        beat.observe(.unknown, at: t(3)); beat.observe(.running, at: t(4))
        XCTAssertEqual(beat.start, t(4), "an answered approval resumes work")

        // A same-turn reconnect doesn't restart it.
        beat.observe(.unknown, at: t(10)); beat.observe(.running, at: t(11))
        XCTAssertEqual(beat.start, t(4))

        // A new prompt from idle starts one; so does returning to the foreground mid-turn.
        beat.observe(.idle, at: t(20)); beat.observe(.unknown, at: t(21)); beat.observe(.running, at: t(22))
        XCTAssertEqual(beat.start, t(22))
        beat.observe(.unknown, at: t(30)); beat.rearm(); beat.observe(.running, at: t(31))
        XCTAssertEqual(beat.start, t(31))
    }
}
