#if DEBUG
import QuartzCore
import XCTest
@testable import HermesMobile

final class HitchMeterTests: XCTestCase {
    private let sixtyHertz: CFTimeInterval = 1.0 / 60
    private let oneTwentyHertz: CFTimeInterval = 1.0 / 120

    func testFiftyMillisecondGapAtSixtyHertzCountsOneThirtyThreeMillisecondHitch() {
        var accumulator = HitchAccumulator()
        let last = feed(&accumulator, from: 10, frames: 30, every: sixtyHertz)
        record(&accumulator, at: last + 0.050, every: sixtyHertz)

        let reading = accumulator.reading
        XCTAssertEqual(reading.hitchCount, 1)
        XCTAssertEqual(reading.hitchMillisecondsPerSecond, 33.33, accuracy: 0.01)
    }

    func testHitchesOlderThanOneSecondFallOutOfTheWindow() {
        var accumulator = HitchAccumulator()
        let beforeGap = feed(&accumulator, from: 10, frames: 12, every: sixtyHertz)
        record(&accumulator, at: beforeGap + 0.050, every: sixtyHertz)
        XCTAssertEqual(accumulator.reading.hitchCount, 1)

        feed(&accumulator, from: beforeGap + 0.050 + sixtyHertz, frames: 70, every: sixtyHertz)

        let reading = accumulator.reading
        XCTAssertEqual(reading.hitchCount, 0)
        XCTAssertEqual(reading.hitchMillisecondsPerSecond, 0)
    }

    func testOneTwentyHertzTargetUsesItsOwnThreshold() {
        var accumulator = HitchAccumulator()
        let last = feed(&accumulator, from: 10, frames: 60, every: oneTwentyHertz)
        record(&accumulator, at: last + 0.012, every: oneTwentyHertz)
        record(&accumulator, at: last + 0.012 + sixtyHertz, every: oneTwentyHertz)

        let reading = accumulator.reading
        XCTAssertEqual(reading.hitchCount, 1)
        XCTAssertEqual(reading.hitchMillisecondsPerSecond, 8.33, accuracy: 0.01)
        XCTAssertEqual(reading.hertz, 120, accuracy: 0.01)
    }

    @discardableResult
    private func feed(
        _ accumulator: inout HitchAccumulator,
        from start: CFTimeInterval,
        frames: Int,
        every interval: CFTimeInterval
    ) -> CFTimeInterval {
        var timestamp = start
        for index in 0..<frames {
            timestamp = start + CFTimeInterval(index) * interval
            record(&accumulator, at: timestamp, every: interval)
        }
        return timestamp
    }

    private func record(
        _ accumulator: inout HitchAccumulator,
        at timestamp: CFTimeInterval,
        every interval: CFTimeInterval
    ) {
        accumulator.record(timestamp: timestamp, targetTimestamp: timestamp + interval)
    }
}
#endif
