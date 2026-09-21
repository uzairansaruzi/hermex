import XCTest
@testable import HermesMobile

@MainActor final class BotMessageActionsTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private var connection: BotConnection {
        BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!, username: "user", password: "fixture")
    }
    private var profile: BotProfile { BotProfile(.object(["name": .string("inbox-triage")]))! }

    // MARK: - The menu

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

    // MARK: - Ask Hermex

    func testAskHermexQuotesIntoTheDraftAndSurvivesReopening() async throws {
        let drafts = ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(0))
        let model = make(BotFixtureWire(), drafts: drafts)
        await model.recover()

        model.quotePassage("  The failing line is in the reducer.  ")
        model.editDraft("Why?")
        XCTAssertEqual(model.quotes.map(\.text), ["The failing line is in the reducer."])
        try await drafts.flush()
        model.suspend()

        let stored = await drafts.draft(for: model.draftKey)
        let saved = try XCTUnwrap(stored)
        XCTAssertEqual(saved.quotes.map(\.text), ["The failing line is in the reducer."])
        XCTAssertEqual(saved.text, "Why?")
    }

    func testQuoteShipsAsMarkdownAheadOfTheTypedTextAndClearsOnSend() async throws {
        let wire = BotFixtureWire()
        let model = make(wire)
        await model.recover()

        model.quotePassage("first line\nsecond line")
        model.editDraft("What does this mean?")
        await model.send()

        let sent = try XCTUnwrap(wire.calls.first { $0.0 == "prompt.submit" }?.1["text"]?.text)
        XCTAssertTrue(sent.hasPrefix("> first line\n> second line\n\nWhat does this mean?"), sent)
        XCTAssertTrue(model.quotes.isEmpty)
        XCTAssertEqual(model.draft, "")
        model.suspend()
    }

    func testAQuoteAloneIsSendableAndIsRemovableOneAtATime() async throws {
        let model = make(BotFixtureWire())
        await model.recover()

        XCTAssertFalse(model.hasSendableInput)
        model.quotePassage("keep me")
        model.quotePassage("drop me")
        XCTAssertTrue(model.hasSendableInput)

        model.removeQuote(try XCTUnwrap(model.quotes.last?.id))

        XCTAssertEqual(model.quotes.map(\.text), ["keep me"])
        XCTAssertNotNil(model.preparePrompt(.send))
        model.suspend()
    }

    func testAnEmptySelectionNeverBecomesAQuote() async {
        let model = make(BotFixtureWire())
        await model.recover()

        model.quotePassage("   \n  ")

        XCTAssertTrue(model.quotes.isEmpty)
        XCTAssertFalse(model.hasSendableInput)
        model.suspend()
    }

    private func make(_ wire: BotFixtureWire, drafts: ChatDraftStore? = nil) -> BotConversation {
        BotConversation(server: server, connection: connection, profile: profile, wire: wire,
                        drafts: drafts ?? ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
                        reconnectDelay: { _ in })
    }
}
