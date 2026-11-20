import XCTest

extension XCTestCase {
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
