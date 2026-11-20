import XCTest
@testable import HermesMobile

@MainActor
final class DelayedStatusTests: XCTestCase {
    private let start = ContinuousClock.now
    private let policy = DelayedStatusPolicy()

    func testBriefStatusNeverShows() {
        var status = DelayedStatus<ActiveStreamRecoveryState>()

        let deadline = status.update(target: .checking, now: at(0), policy: policy, immediately: false)
        XCTAssertEqual(deadline, at(400))
        XCTAssertNil(status.shown)

        XCTAssertNil(status.update(target: nil, now: at(300), policy: policy, immediately: false))
        XCTAssertNil(status.shown)
    }

    func testShownStatusHoldsBeforeHiding() {
        var status = DelayedStatus<ActiveStreamRecoveryState>()
        _ = status.update(target: .checking, now: at(0), policy: policy, immediately: false)
        _ = status.update(target: .checking, now: at(400), policy: policy, immediately: false)
        XCTAssertEqual(status.shown, .checking)

        XCTAssertEqual(status.update(target: nil, now: at(450), policy: policy, immediately: false), at(800))
        XCTAssertEqual(status.shown, .checking)

        XCTAssertNil(status.update(target: nil, now: at(800), policy: policy, immediately: false))
        XCTAssertNil(status.shown)
    }

    func testShownStatusSwapsAtOnce() {
        var status = DelayedStatus<ActiveStreamRecoveryState>()
        _ = status.update(target: .checking, now: at(0), policy: policy, immediately: false)
        _ = status.update(target: .checking, now: at(400), policy: policy, immediately: false)

        _ = status.update(target: .reconnecting, now: at(600), policy: policy, immediately: false)
        XCTAssertEqual(status.shown, .reconnecting)

        XCTAssertEqual(status.update(target: nil, now: at(700), policy: policy, immediately: false), at(1000))
    }

    func testImmediateValueSkipsTheDelay() {
        var status = DelayedStatus<ActiveStreamRecoveryState>()

        _ = status.update(target: .waitingForNetwork, now: at(0), policy: policy, immediately: true)

        XCTAssertEqual(status.shown, .waitingForNetwork)
    }

    func testNewStatusDuringHoldReplacesTheHeldOne() {
        var status = DelayedStatus<ActiveStreamRecoveryState>()
        _ = status.update(target: .checking, now: at(0), policy: policy, immediately: false)
        _ = status.update(target: .checking, now: at(400), policy: policy, immediately: false)
        _ = status.update(target: nil, now: at(450), policy: policy, immediately: false)

        _ = status.update(target: .reconnecting, now: at(500), policy: policy, immediately: false)
        XCTAssertEqual(status.shown, .reconnecting)
    }

    func testCancelledRunNeverPublishes() async {
        var now = at(0)
        let sleeper = DeadlineSleeper()
        let parked = expectation(description: "run waiting for the show deadline")
        sleeper.didPark = { parked.fulfill() }
        let driver = DelayedStatusDriver<ActiveStreamRecoveryState>(now: { now }, sleep: sleeper.sleep(until:))

        let cancelledFirst = Task { await driver.run(target: .waitingForNetwork, immediately: true) }
        cancelledFirst.cancel()
        await cancelledFirst.value
        XCTAssertNil(driver.shown)

        let run = Task { await driver.run(target: .checking) }
        await fulfillment(of: [parked], timeout: 5)

        run.cancel()
        now = at(400)
        sleeper.resume()
        await run.value

        XCTAssertNil(driver.shown)
    }

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(milliseconds))
    }
}

@MainActor
private final class DeadlineSleeper {
    private var parked: CheckedContinuation<Void, Never>?
    var didPark: (() -> Void)?

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        await withCheckedContinuation { continuation in
            parked = continuation
            didPark?()
        }
    }

    func resume() {
        parked?.resume()
        parked = nil
    }
}
