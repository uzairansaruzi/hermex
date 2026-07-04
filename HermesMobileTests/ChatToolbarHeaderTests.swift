import CoreGraphics
import XCTest
@testable import HermesMobile

final class ChatToolbarHeaderTests: XCTestCase {
    func testSubtitleUsesWorkspaceBasenameBeforeProfile() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: "/Users/example/hermes-mobile",
                profileTitle: "Default"
            ),
            "hermes-mobile"
        )
    }

    func testSubtitleFallsBackToStableProfileTitle() {
        XCTAssertEqual(
            ChatToolbarSubtitleResolver.subtitle(
                workspacePath: nil,
                profileTitle: "Work"
            ),
            "Work"
        )
    }

    func testSubtitleOmitsGenericOrBlankContext() {
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileTitle: "Profile"))
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: "   ", profileTitle: "   "))
    }

    func testHeaderGradientSolidRegionCoversHeaderBarBottom() {
        let topSafeAreaInset: CGFloat = 59
        let headerBarBottom = topSafeAreaInset + ChatHeaderBackgroundGradientLayout.inlineHeaderBarHeight

        XCTAssertGreaterThanOrEqual(
            ChatHeaderBackgroundGradientLayout.solidHeight(topSafeAreaInset: topSafeAreaInset),
            headerBarBottom + ChatHeaderBackgroundGradientLayout.solidExtensionBelowHeader
        )
    }

    func testHeaderGradientKeepsFadeTailToVeryTopOfTranscript() {
        let topSafeAreaInset: CGFloat = 59
        let visibleHeight = ChatHeaderBackgroundGradientLayout.visibleHeight(topSafeAreaInset: topSafeAreaInset)
        let solidHeight = ChatHeaderBackgroundGradientLayout.solidHeight(topSafeAreaInset: topSafeAreaInset)

        XCTAssertEqual(visibleHeight - solidHeight, ChatHeaderBackgroundGradientLayout.fadeTailHeight)
        XCTAssertLessThanOrEqual(ChatHeaderBackgroundGradientLayout.fadeTailHeight, 18)
        XCTAssertLessThan(ChatHeaderBackgroundGradientLayout.solidStop(topSafeAreaInset: topSafeAreaInset), 1)
        XCTAssertLessThan(
            ChatHeaderBackgroundGradientLayout.solidStop(topSafeAreaInset: topSafeAreaInset),
            ChatHeaderBackgroundGradientLayout.fadeKneeStop(topSafeAreaInset: topSafeAreaInset)
        )
        XCTAssertLessThan(ChatHeaderBackgroundGradientLayout.fadeKneeStop(topSafeAreaInset: topSafeAreaInset), 1)
    }

    func testHeaderGradientUsesMinimumHeightForCompactTopInsets() {
        XCTAssertEqual(
            ChatHeaderBackgroundGradientLayout.visibleHeight(topSafeAreaInset: 0),
            ChatHeaderBackgroundGradientLayout.minimumVisibleHeight
        )
        XCTAssertLessThanOrEqual(
            ChatHeaderBackgroundGradientLayout.minimumVisibleHeight,
            ChatHeaderBackgroundGradientLayout.inlineHeaderBarHeight
                + ChatHeaderBackgroundGradientLayout.solidExtensionBelowHeader
                + ChatHeaderBackgroundGradientLayout.fadeTailHeight
        )
    }

    func testHeaderGradientClampsNegativeTopInsets() {
        XCTAssertEqual(
            ChatHeaderBackgroundGradientLayout.solidHeight(topSafeAreaInset: -24),
            ChatHeaderBackgroundGradientLayout.inlineHeaderBarHeight
                + ChatHeaderBackgroundGradientLayout.solidExtensionBelowHeader
        )
    }

    func testHeaderGradientStopsRemainOrderedAcrossCommonSafeAreaInsets() {
        let topSafeAreaInsets: [CGFloat] = [0, 24, 47, 59, 102]

        for topSafeAreaInset in topSafeAreaInsets {
            let solidStop = ChatHeaderBackgroundGradientLayout.solidStop(topSafeAreaInset: topSafeAreaInset)
            let fadeKneeStop = ChatHeaderBackgroundGradientLayout.fadeKneeStop(topSafeAreaInset: topSafeAreaInset)

            XCTAssertGreaterThanOrEqual(solidStop, 0, "solidStop for \(topSafeAreaInset)")
            XCTAssertLessThan(solidStop, 1, "solidStop for \(topSafeAreaInset)")
            XCTAssertGreaterThan(fadeKneeStop, solidStop, "fadeKneeStop for \(topSafeAreaInset)")
            XCTAssertLessThan(fadeKneeStop, 1, "fadeKneeStop for \(topSafeAreaInset)")
        }
    }
}
