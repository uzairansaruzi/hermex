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

    func testBlinkPhaseIsSeededPerBot() {
        let a = BotBlinkSchedule(seed: "inbox-triage"), b = BotBlinkSchedule(seed: "researcher")
        XCTAssertNotEqual(a.phase, b.phase)
        XCTAssertEqual(a, BotBlinkSchedule(seed: "inbox-triage"), "the same bot keeps its rhythm across renders")
    }

    func testReduceMotionStillsEveryMode() {
        XCTAssertEqual(BotFaceMotion.idle.honoring(reduceMotion: true), .still)
        XCTAssertEqual(BotFaceMotion.working.honoring(reduceMotion: true), .still)
        XCTAssertEqual(BotFaceMotion.working.honoring(reduceMotion: false), .working)
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
