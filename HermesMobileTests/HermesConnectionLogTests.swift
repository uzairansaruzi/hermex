import XCTest
@testable import HermesMobile

final class HermesConnectionLogTests: XCTestCase {
    private let secretURL = URL(string: "https://secret-host.example/api/ws")!

    func testAURLErrorIsNamedByItsCodeWithoutTheFailingURL() {
        let error = URLError(.networkConnectionLost, userInfo: [
            NSURLErrorFailingURLErrorKey: secretURL,
            NSURLErrorFailingURLStringErrorKey: secretURL.absoluteString
        ])
        let reason = HermesConnectionLog.reason(error)
        XCTAssertEqual(reason, "URLError -1005")
        XCTAssertFalse(reason.contains("secret-host"))
    }

    func testASocketErrorIsNamedByItsDomainAndCodeWithoutItsUserInfo() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: [NSURLErrorFailingURLErrorKey: secretURL])
        XCTAssertEqual(HermesConnectionLog.reason(error), "NSPOSIXErrorDomain 57")
    }

    func testAnErrorCarryingHostTextNeverLogsIt() {
        let reason = HermesConnectionLog.reason(BotSettingFailure.rejected(4001, "secret-host.example refused the model"))
        XCTAssertFalse(reason.contains("secret-host"), reason)
        XCTAssertFalse(reason.contains("refused"), reason)
        XCTAssertFalse(HermesConnectionLog.reason(BotFailure.resumeRefused("secret-host.example")).contains("secret-host"))
    }
}
