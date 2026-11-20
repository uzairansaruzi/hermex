import XCTest
@testable import HermesMobile

final class SettingsAcknowledgementsTests: XCTestCase {
    func testListsEveryBundledNoticeSortedAndReadable() throws {
        let notices = AcknowledgementNotice.loadAll(bundle: .main)

        XCTAssertEqual(Set(notices.map(\.url.lastPathComponent)), [
            "DMSans-LICENSE.txt", "Highlightr-LICENSE.txt", "KeychainAccess-LICENSE.txt", "LDSwiftEventSource-LICENSE.txt",
            "Lora-LICENSE.txt", "LucideIcons-LICENSE.txt", "MarkdownUI-LICENSE.txt", "NetworkImage-LICENSE.txt", "OpenBotAvatar-LICENSE.txt",
            "Pele-LICENSE.txt", "Splash-LICENSE.txt", "SwiftMath-LICENSE.txt", "swift-cmark-COPYING.txt",
        ])
        XCTAssertEqual(notices.map(\.name), notices.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        for notice in notices {
            XCTAssertFalse(try String(contentsOf: notice.url, encoding: .utf8).isEmpty, notice.name)
        }
    }
}
