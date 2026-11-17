import XCTest
@testable import HermesMobile

/// `set_theme`'s `theme.apply` values as Hermex applies them (#1727).
final class HermesThemeRequestTests: XCTestCase {
    /// Each accent the tool may send lands on Hermex's swatch of that colour, the theme's own
    /// accent, the hex in uppercase, or a refusal that lists what Hermex has; the answer reports it.
    func testAccentsMapToHermexsSwatches() throws {
        let cases: [(sent: String, stored: HermesThemeRequest.Change.Accent?, reported: BotJSON?)] = [
            ("green", .hex("#4CC96B"), .string("green")),
            ("cyan", .hex("#30B8C4"), .string("cyan")),
            ("violet", .hex("#7D7AFF"), .string("violet")),
            ("pink", .hex("#FF6FAE"), .string("pink")),
            ("red", .hex("#FF5C5C"), .string("red")),
            ("orange", .hex("#FF9F3C"), .string("orange")),
            ("nous", .themeOwn, .null),
            ("theme", .themeOwn, .null),
            ("#12abEF", .hex("#12ABEF"), .string("custom:#12ABEF")),
            ("mono", nil, nil)
        ]
        for (sent, stored, reported) in cases {
            let change = HermesThemeRequest.apply(.object(["session_id": .string("runtime"), "accent": .string(sent)]))
            let answer = try JSONDecoder().decode(BotJSON.self, from: Data(change.answer.utf8))
            XCTAssertEqual(change.accent, stored, sent)
            XCTAssertNil(change.theme, sent)
            if let reported {
                XCTAssertEqual(answer["success"], .bool(true), sent)
                XCTAssertEqual(answer["applied"].fields?["accent"], reported, sent)
            } else {
                XCTAssertEqual(answer["success"], .bool(false), sent)
                XCTAssertEqual(answer["available"].list?.compactMap(\.text).contains("mono"), false, sent)
                XCTAssertEqual(answer["available"].list?.compactMap(\.text).contains("green"), true, sent)
            }
        }
    }
}
