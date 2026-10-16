import XCTest
@testable import HermesMobile

final class ContextWindowIndicatorTests: XCTestCase {
    func testPresentationBecomesInteractiveWhenPercentageLoads() {
        let snapshot = ContextWindowSnapshot(
            contextLength: 100_000,
            thresholdTokens: nil,
            lastPromptTokens: 25_000,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil
        )
        let presentation = ContextWindowIndicatorPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.percentageLabel, "25")
        XCTAssertTrue(presentation.isInteractive)
        XCTAssertEqual(presentation.percentage, 0.25)
    }

    func testCompactIndicatorWithValidData() {
        let snapshot = ContextWindowSnapshot(
            contextLength: 128_000,
            thresholdTokens: 100_000,
            lastPromptTokens: 57_600,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil
        )

        XCTAssertEqual(ContextWindowFormatter.compactIndicator(from: snapshot), "45% context")
    }

    func testCompactIndicatorWithInputTokensFallback() {
        let snapshot = ContextWindowSnapshot(
            contextLength: 128_000,
            thresholdTokens: nil,
            lastPromptTokens: nil,
            inputTokens: 12_800,
            outputTokens: nil,
            estimatedCost: nil
        )

        XCTAssertEqual(ContextWindowFormatter.compactIndicator(from: snapshot), "10% context")
    }

    func testReplacingTokensUsedUpdatesLastPromptTokensForIndicator() {
        let snapshot = ContextWindowSnapshot(
            contextLength: 128_000,
            thresholdTokens: nil,
            lastPromptTokens: 30_100,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil
        )

        let updated = snapshot.replacingTokensUsed(10_347)

        XCTAssertEqual(updated.lastPromptTokens, 10_347)
        XCTAssertEqual(ContextWindowFormatter.compactIndicator(from: updated), "8% context")
    }

    func testCompactIndicatorReturnsNilWhenContextLengthZero() {
        let snapshot = ContextWindowSnapshot(
            contextLength: 0,
            thresholdTokens: nil,
            lastPromptTokens: 1_000,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil
        )

        XCTAssertNil(ContextWindowFormatter.compactIndicator(from: snapshot))
    }

    func testTokensLabelFormatsK() {
        let snapshot = ContextWindowSnapshot(
            contextLength: 128_000,
            thresholdTokens: nil,
            lastPromptTokens: 12_345,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil
        )

        XCTAssertEqual(ContextWindowFormatter.tokensLabel(from: snapshot), "12.3K / 128.0K")
    }

    func testTokensLabelFormatsM() {
        let snapshot = ContextWindowSnapshot(
            contextLength: 2_000_000,
            thresholdTokens: nil,
            lastPromptTokens: 1_500_000,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil
        )

        XCTAssertEqual(ContextWindowFormatter.tokensLabel(from: snapshot), "1.5M / 2.0M")
    }
}
