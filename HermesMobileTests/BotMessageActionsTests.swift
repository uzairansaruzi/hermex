import XCTest
@testable import HermesMobile

/// A room message's long-press menu.
@MainActor final class BotMessageActionsTests: XCTestCase {
    func testBotMessageOffersCopyAndNothingElse() {
        let items = BotMessageActions.items(copyText: "A reply", isHapticsEnabled: false, copy: { _ in })

        XCTAssertEqual(items.map(\.kind), [.copy])
        XCTAssertEqual(items.map(\.title), ["Copy"])
        XCTAssertTrue(items.allSatisfy(\.isEnabled))
        XCTAssertEqual(items.uiMenu().children.compactMap { ($0 as? UIAction)?.title }, ["Copy"])
    }

    func testCopyCarriesTheMarkdownSourceNotTheRenderedText() {
        let markdown = "Here is the fix:\n\n```swift\nlet x = 1\n```\n\n- **bold** item"
        var copied: String?
        let items = BotMessageActions.items(copyText: markdown, isHapticsEnabled: false, copy: { copied = $0 })

        items.first?.perform()

        XCTAssertEqual(copied, markdown)
    }

    func testMessageWithNothingToCopyHasNoMenu() {
        XCTAssertTrue(BotMessageActions.items(copyText: nil, isHapticsEnabled: false, copy: { _ in }).isEmpty)
        XCTAssertTrue(BotMessageActions.items(copyText: "  \n ", isHapticsEnabled: false, copy: { _ in }).isEmpty)
    }
}
