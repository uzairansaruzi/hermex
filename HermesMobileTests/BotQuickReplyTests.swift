import XCTest
@testable import HermesMobile

final class BotQuickReplyTests: XCTestCase {
    func testEmptyAndMalformedValuesDecodeToNoReplies() {
        XCTAssertEqual(BotQuickReplyStore.decode(""), [])
        XCTAssertEqual(BotQuickReplyStore.decode("not json"), [])
        XCTAssertEqual(BotQuickReplyStore.decode(#"{"id":"a","text":"Continue"}"#), [], "A lone object is not a list")
    }

    func testBlankWrongTypedAndRepeatedEntriesAreDropped() {
        let raw = #"""
        [{"id":"a","text":"Continue"},
         {"id":"","text":"No id"},
         {"id":"b","text":"  \n"},
         {"id":"c"},
         {"id":7,"text":"Numeric id"},
         "stray",
         {"id":"a","text":"Repeat of a"},
         {"id":"d","text":"Run the tests","pinned":true}]
        """#
        XCTAssertEqual(BotQuickReplyStore.decode(raw), [
            BotQuickReply(id: "a", text: "Continue"),
            BotQuickReply(id: "d", text: "Run the tests"),
        ])
    }

    func testRoundTripKeepsIdsTextAndOrder() {
        let replies = [BotQuickReply(text: "Summarize what changed"), BotQuickReply(text: "Continue")]
        XCTAssertEqual(BotQuickReplyStore.decode(BotQuickReplyStore.encode(replies)), replies)
        XCTAssertNotEqual(replies[0].id, replies[1].id)
    }

    func testRowShowsOnlyWhenNothingElseNeedsTheSlot() {
        let replies = [BotQuickReply(text: "Continue")]
        func shows(replies: [BotQuickReply] = replies, draft: String = "", hasQuotes: Bool = false,
                   hasAttachments: Bool = false, maySend: Bool = true, hasPendingRequest: Bool = false,
                   hasPill: Bool = false) -> Bool {
            BotQuickReplyPolicy.showsRow(replies: replies, draft: draft, hasQuotes: hasQuotes,
                                         hasAttachments: hasAttachments, maySend: maySend,
                                         hasPendingRequest: hasPendingRequest, hasPill: hasPill)
        }
        XCTAssertTrue(shows())
        XCTAssertTrue(shows(draft: " \n"), "A whitespace draft has nothing to send")
        XCTAssertFalse(shows(replies: []), "No saved replies leaves Bot Chat as it was")
        XCTAssertFalse(shows(draft: "c"))
        XCTAssertFalse(shows(hasQuotes: true))
        XCTAssertFalse(shows(hasAttachments: true))
        XCTAssertFalse(shows(maySend: false), "Working, blocked or disconnected")
        XCTAssertFalse(shows(hasPendingRequest: true))
        XCTAssertFalse(shows(hasPill: true))
    }
}
