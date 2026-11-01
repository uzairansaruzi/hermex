import XCTest
@testable import HermesMobile

/// About → Acknowledgements (#1411) lists the license notices bundled in the app.
final class SettingsAcknowledgementsTests: XCTestCase {
    /// Every bundled notice is listed, sorted, and readable; the folder's `NOTICE.txt` index is not.
    func testListsEveryBundledNoticeSortedAndReadable() throws {
        let notices = AcknowledgementNotice.loadAll(bundle: .main)

        XCTAssertEqual(Set(notices.map(\.url.lastPathComponent)), [
            "Highlightr-LICENSE.txt", "KeychainAccess-LICENSE.txt", "LDSwiftEventSource-LICENSE.txt",
            "LucideIcons-LICENSE.txt", "MarkdownUI-LICENSE.txt", "NetworkImage-LICENSE.txt",
            "Splash-LICENSE.txt", "SwiftMath-LICENSE.txt", "swift-cmark-COPYING.txt",
        ])
        XCTAssertEqual(notices.map(\.name), notices.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        for notice in notices {
            XCTAssertFalse(try String(contentsOf: notice.url, encoding: .utf8).isEmpty, notice.name)
        }
    }
}
