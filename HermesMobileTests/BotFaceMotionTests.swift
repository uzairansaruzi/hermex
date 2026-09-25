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

    func testStartingInsideABlinkStillEmitsThatBlinksOpenEdge() {
        let schedule = BotBlinkSchedule(seed: "inbox-triage")
        let shut = Date(timeIntervalSinceReferenceDate: schedule.phase + schedule.period * 3)
        let start = shut.addingTimeInterval(0.05)
        XCTAssertTrue(schedule.isShut(at: start))
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(4))

        XCTAssertEqual(entries[0], start)
        XCTAssertEqual(entries[1].timeIntervalSince(shut), BotBlinkSchedule.shutDuration, accuracy: 0.0001)
        XCTAssertFalse(schedule.isShut(at: entries[1]), "the eyes reopen at the end of the current blink")
        XCTAssertEqual(entries[2].timeIntervalSince(shut), schedule.period, accuracy: 0.0001)
        XCTAssertTrue(schedule.isShut(at: entries[2]))
    }

    func testEveryBitStartsAndEndsAtRestSoItCutsCleanlyIntoTheBlinkSchedule() {
        for bit in BotFaceBit.allCases {
            XCTAssertEqual(bit.pose(at: 0), .rest, "\(bit) starts at rest")
            XCTAssertEqual(bit.pose(at: 1), .rest, "\(bit) ends at rest")
            XCTAssertNotEqual(bit.pose(at: 0.5), .rest, "\(bit) does something in the middle")
            XCTAssertTrue((0.4...1.6).contains(bit.duration), "\(bit) is a short burst")
        }
        XCTAssertEqual(BotFaceBit.hop.pose(at: 0.5).lift, 0.16, accuracy: 0.001)
        XCTAssertEqual(BotFaceBit.hop.pose(at: 0.05).scaleY, 1 - 0.12 * sin(0.05 / 0.15 * .pi), accuracy: 0.001)
        XCTAssertEqual(BotFaceBit.doubleBlink.pose(at: 0.1).lid, 0.06)
        XCTAssertEqual(BotFaceBit.doubleBlink.pose(at: 0.35).lid, 1)
        XCTAssertEqual(BotFaceBit.doubleBlink.pose(at: 0.6).lid, 0.06)
        XCTAssertEqual(BotFaceBit.spin.pose(at: 0.999).roll, 360, accuracy: 0.01, "a full turn lands where it started")
    }

    func testPlayfulScheduleIsSparseSeededAndRarelySpins() {
        let schedule = BotPlayfulSchedule(seed: "inbox-triage")
        let entries = (0..<60).map(schedule.entry)
        for entry in entries { XCTAssertTrue((4...9).contains(entry.delay)) }
        XCTAssertEqual(entries.map(\.bit), (0..<60).map(schedule.entry).map(\.bit), "the same bot repeats its repertoire")
        XCTAssertNotEqual(entries.map(\.bit), (0..<60).map(BotPlayfulSchedule(seed: "researcher").entry).map(\.bit))
        let spins = entries.enumerated().filter { $0.element.bit == .spin }.map(\.offset)
        XCTAssertEqual(spins, [10, 20, 30, 40, 50], "a spin only every tenth slot, so at least 40 seconds apart")
        XCTAssertFalse(entries.contains { $0.bit == .glanceDown }, "looking down is for typing, not idling")
        XCTAssertGreaterThan(Set(entries.map(\.bit)).count, 3)
    }

    func testBlinkPhaseIsSeededPerBot() {
        let a = BotBlinkSchedule(seed: "inbox-triage"), b = BotBlinkSchedule(seed: "researcher")
        XCTAssertNotEqual(a.phase, b.phase)
        XCTAssertEqual(a, BotBlinkSchedule(seed: "inbox-triage"), "the same bot keeps its rhythm across renders")
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
        let schedule = BotWorkingSchedule(start: BotWorkingSchedule.notStarted, blink: blink)
        let now = Date(timeIntervalSinceReferenceDate: 1000)

        XCTAssertEqual(Array(schedule.entries(from: now, mode: .normal).prefix(6)),
                       Array(blink.entries(from: now, mode: .normal).prefix(6)),
                       "a chat opened onto a pending approval never runs the 15 fps beat")
        XCTAssertEqual(schedule.pose(at: now).gazeX, BotFacePose.settledWorking.gazeX)
    }

    func testWorkingScheduleSettlesIntoALeanThatOnlyBlinks() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let blink = BotBlinkSchedule(seed: "inbox-triage")
        let schedule = BotWorkingSchedule(start: start, blink: blink)
        let inside = start.addingTimeInterval(10)

        XCTAssertEqual(schedule.pose(at: inside), .working(at: inside.timeIntervalSinceReferenceDate))
        let settled = BotFacePose.settledWorking
        XCTAssertNotEqual(settled, .rest)
        XCTAssertEqual(settled.gazeX, -0.0275, accuracy: 0.0001)
        XCTAssertEqual(settled.gazeY, 0)
        XCTAssertEqual(settled.roll, 0)

        let after = start.addingTimeInterval(31)
        let shut = blink.entries(from: after, mode: .normal).dropFirst().first { blink.isShut(at: $0) }!
        let open = shut.addingTimeInterval(BotBlinkSchedule.shutDuration + 0.5)
        var shutPose = settled
        shutPose.lid = BotFacePose.blink.lid
        XCTAssertEqual(schedule.pose(at: shut), shutPose)
        XCTAssertEqual(schedule.pose(at: open), settled)
        for date in [after, shut, open] {
            XCTAssertEqual(schedule.pose(at: date).lid, blink.isShut(at: date) ? BotFacePose.blink.lid : 1)
        }
    }

    func testWorkingPoseLeansAndBlinksAndRestIsNeutral() {
        let pose = BotFacePose.working(at: 0)
        XCTAssertNotEqual(pose, .rest)
        XCTAssertEqual(pose.lid, 1)
        XCTAssertEqual(BotFacePose.working(at: 1.3).lid, 0.06, "Desktop shuts the eyes in the last fifth of each 1.45 s beat")
        XCTAssertLessThanOrEqual(abs(pose.gazeX), 0.06)
        XCTAssertLessThanOrEqual(abs(pose.roll), 4.2)
        XCTAssertEqual(BotFacePose.rest.lid, 1)
        XCTAssertEqual(BotFacePose.blink.lid, 0.06)
    }
}
