import XCTest
@testable import HermesMobile

final class StreamingRevealGateTests: XCTestCase {
    func testCutsAtTheLastWhitespaceAndHoldsThePartialWord() {
        let (shown, held) = StreamingRevealGate.cut("alpha beta gam", heldPreviousTick: false)
        XCTAssertEqual(shown, "alpha beta ")
        XCTAssertEqual(held, "gam")
    }

    func testTrailingWhitespaceShowsEverything() {
        let (shown, held) = StreamingRevealGate.cut("alpha beta\n", heldPreviousTick: false)
        XCTAssertEqual(shown, "alpha beta\n")
        XCTAssertEqual(held, "")
    }

    func testAFragmentHeldLastTickIsReleasedWithoutNewWhitespace() {
        let (shown, held) = StreamingRevealGate.cut("gamma", heldPreviousTick: true)
        XCTAssertEqual(shown, "gamma")
        XCTAssertEqual(held, "")
    }

    func testAHeldFragmentFinishedByWhitespaceShowsWithTheCut() {
        // "gam" was held; "ma delt" arrived since.
        let (shown, held) = StreamingRevealGate.cut("gamma delt", heldPreviousTick: true)
        XCTAssertEqual(shown, "gamma ")
        XCTAssertEqual(held, "delt")
    }

    func testCJKWithoutWhitespaceIsHeldOneTickThenReleased() {
        let first = StreamingRevealGate.cut("你好世界", heldPreviousTick: false)
        XCTAssertEqual(first.shown, "")
        XCTAssertEqual(first.held, "你好世界")

        let second = StreamingRevealGate.cut("你好世界，再见", heldPreviousTick: true)
        XCTAssertEqual(second.shown, "你好世界，再见")
        XCTAssertEqual(second.held, "")
    }

    func testABurstShowsInOneCut() {
        let words = (0..<100).map { "w\($0) " }.joined()
        let (shown, held) = StreamingRevealGate.cut(words + "tail", heldPreviousTick: false)
        XCTAssertEqual(shown, words)
        XCTAssertEqual(held, "tail")
    }

    func testAnEmptyBufferShowsAndHoldsNothing() {
        for heldPreviousTick in [false, true] {
            let (shown, held) = StreamingRevealGate.cut("", heldPreviousTick: heldPreviousTick)
            XCTAssertEqual(shown, "")
            XCTAssertEqual(held, "")
        }
    }

    func testNeverSplitsAGraphemeCluster() {
        // The combining accent and the ZWJ family stay whole on either side.
        let text = "café 👩‍👩‍👧‍👦"
        let (shown, held) = StreamingRevealGate.cut(text, heldPreviousTick: false)
        XCTAssertEqual(shown, "café ")
        XCTAssertEqual(held, "👩‍👩‍👧‍👦")
        XCTAssertEqual(Array((shown + held).utf8), Array(text.utf8))
    }
}
