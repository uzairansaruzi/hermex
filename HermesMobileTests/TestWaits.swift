import XCTest

// How a test waits for something to happen: on a signal, never on the clock
// (`ci/check_test_waits.py` flags sleeps and polling loops in this target).

extension XCTestCase {
    /// Waits on observation, never a clock, until `condition` holds: it is checked again
    /// whenever an `@Observable` value it read changes. `timeout` only ends a broken test: the
    /// wait fails once nothing the condition reads changes for that long. Observation can't see
    /// an actor's state, so a double kept in an actor signals its calls with `CallCount`.
    @MainActor
    func waitUntil(_ description: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
                   line: UInt = #line, _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            let changed = XCTestExpectation(description: description)
            withObservationTracking { _ = condition() } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: timeout) == .completed else {
                return XCTFail("Nothing changed while waiting for: \(description)", file: file, line: line)
            }
        }
    }
}

/// A test double's call count that a test can wait on. A double kept in an actor calls
/// `record()` for each call, and `expectation(reaching:)` hands the test an expectation that is
/// fulfilled once the count reaches a target, so the test waits for the Nth call instead of
/// polling the double:
///
///     await fulfillment(of: [client.boardCalls(reaching: 2)], timeout: 5)
struct CallCount {
    private(set) var value = 0
    private var waiters: [(target: Int, expectation: XCTestExpectation)] = []

    mutating func record() {
        value += 1
        waiters.removeAll { waiter in
            guard value >= waiter.target else { return false }
            waiter.expectation.fulfill()
            return true
        }
    }

    mutating func expectation(reaching target: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "call \(target)")
        if value >= target {
            expectation.fulfill()
        } else {
            waiters.append((target, expectation))
        }
        return expectation
    }
}
