import XCTest
@testable import HermesMobile

/// About's support details and the prefilled Report a Problem link (#1396).
@MainActor final class SupportReportTests: XCTestCase {
    /// Hermes servers name the tested Hermes release; a webui server never does, and a release it
    /// never cached reads unknown. No address or name reaches the text.
    func testReportNamesTheTestedReleaseOnlyForHermes() {
        let hermes = SupportReport(server: Self.account(kind: .hermes, serverVersion: "0.21.4"))
        let hermesLines = hermes.text.components(separatedBy: "\n")
        XCTAssertEqual(hermesLines.first, "Hermex support details")
        XCTAssertTrue(hermesLines.contains("Server kind: Hermes"))
        XCTAssertTrue(hermesLines.contains("Server release: 0.21.4"))
        XCTAssertTrue(hermesLines.contains("Tested Hermes release: \(HermesCompatibility.testedVersion)"))

        let webui = SupportReport(server: Self.account(kind: .webui, serverVersion: nil))
        let webuiLines = webui.text.components(separatedBy: "\n")
        XCTAssertTrue(webuiLines.contains("Server kind: webui"))
        XCTAssertTrue(webuiLines.contains("Server release: unknown"))
        XCTAssertFalse(webui.text.contains("Tested"), webui.text)

        for text in [hermes.text, webui.text] {
            XCTAssertFalse(text.contains("example.com"), text)
            XCTAssertFalse(text.contains("Studio Mac"), text)
        }
    }

    /// The link opens the bug form with its three version inputs filled in, decoded the way
    /// GitHub reads a query (`+` is a space), and carries nothing else from the report. Without the
    /// install's version it opens the template chooser instead.
    func testIssueURLPrefillsTheThreeVersionInputs() throws {
        let report = SupportReport(appVersion: "2.0.1", build: "412 & co", channel: .release, iOSVersion: "27.0",
                                   device: "iPhone", serverKind: .hermes, serverRelease: "0.21.4+canary.ü")
        let query = try XCTUnwrap(URLComponents(url: report.issueURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let fields = Dictionary(uniqueKeysWithValues: query.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        })
        XCTAssertEqual(fields, [
            "template": "bug_report.yml",
            "app-version": "2.0.1 (412 & co)",
            "ios-version": "iOS 27.0 on iPhone",
            "server-version": "Hermes 0.21.4+canary.ü",
        ])

        var unversioned = report
        unversioned.build = nil
        XCTAssertEqual(unversioned.issueURL, AppConfig.reportProblemURL)
    }

    private static func account(kind: ServerKind, serverVersion: String?) -> ServerAccount {
        ServerAccount(id: "https://hermes.example.com", urlString: "https://hermes.example.com",
                      displayName: "Studio Mac", initials: "SM", headerLogoColorHex: "#000000",
                      createdAt: .distantPast, updatedAt: .distantPast, kind: kind, serverVersion: serverVersion)
    }
}
