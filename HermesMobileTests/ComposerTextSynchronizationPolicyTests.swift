import XCTest
@testable import HermesMobile

final class ComposerTextSynchronizationPolicyTests: XCTestCase {
    func testMatchingBoundTextDoesNotClobberActiveComposition() {
        XCTAssertFalse(
            ComposerTextSynchronizationPolicy.shouldApplyBoundText(
                viewText: "자",
                boundText: "자",
                markedRange: NSRange(location: 0, length: 1)
            )
        )
    }

    func testCommittedBindingDoesNotClobberActiveComposition() {
        XCTAssertFalse(
            ComposerTextSynchronizationPolicy.shouldApplyBoundText(
                viewText: "draft자",
                boundText: "draft",
                markedRange: NSRange(location: 5, length: 1)
            )
        )
    }

    func testExternalReplacementAppliesDuringActiveComposition() {
        XCTAssertTrue(
            ComposerTextSynchronizationPolicy.shouldApplyBoundText(
                viewText: "draft자",
                boundText: "replacement",
                markedRange: NSRange(location: 5, length: 1)
            )
        )
    }

    func testExternalClearAppliesDuringActiveComposition() {
        XCTAssertTrue(
            ComposerTextSynchronizationPolicy.shouldApplyBoundText(
                viewText: "draft자",
                boundText: "",
                markedRange: NSRange(location: 5, length: 1)
            )
        )
    }
}
