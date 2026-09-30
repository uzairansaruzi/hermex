import XCTest
@testable import HermesMobile

/// The reason a Hermes connection log line gives for an error. It is the one part of the
/// log built from an error, and an error's user info can carry the failing URL, so the host.
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

    /// A WebSocket read that loses its connection throws a POSIX error, not a `URLError`.
    func testASocketErrorIsNamedByItsDomainAndCodeWithoutItsUserInfo() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: [NSURLErrorFailingURLErrorKey: secretURL])
        XCTAssertEqual(HermesConnectionLog.reason(error), "NSPOSIXErrorDomain 57")
    }

    func testABotFailureIsNamedByItsCase() {
        XCTAssertEqual(HermesConnectionLog.reason(BotFailure.rejected(403)), "rejected(403)")
        XCTAssertEqual(HermesConnectionLog.reason(BotFailure.upgradeRefused(403)), "upgradeRefused(403)")
        XCTAssertEqual(HermesConnectionLog.reason(BotFailure.transport), "transport")
    }

    func testADecodingErrorAndACancellationAreNamedByKind() {
        do { _ = try JSONDecoder().decode(BotJSON.self, from: Data("<html>".utf8)); XCTFail("Expected a decoding error") }
        catch { XCTAssertEqual(HermesConnectionLog.reason(error), "DecodingError") }
        XCTAssertEqual(HermesConnectionLog.reason(CancellationError()), "cancelled")
    }

    /// A rejected setting carries the host's own message, which can name anything.
    func testAnErrorCarryingHostTextNeverLogsIt() {
        let reason = HermesConnectionLog.reason(BotSettingFailure.rejected(4001, "secret-host.example refused the model"))
        XCTAssertFalse(reason.contains("secret-host"), reason)
        XCTAssertFalse(reason.contains("refused"), reason)
    }
}
