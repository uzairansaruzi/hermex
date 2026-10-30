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

    /// The active server's current Hermes connection adds its latest attempt (#1395): when it
    /// started and each stage's outcome, with no host or account. Another server's report, and
    /// this one's once the connection is retired, has none.
    func testReportCarriesOnlyTheActiveServersCurrentAttempt() async throws {
        defer { HermesHostFixture.reset() }
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration { request in
            request.url?.path == "/auth/password-login" ? .json(401, .object(["error": .string("invalid_credentials")])) : nil
        } })
        let server = URL(string: "https://hermes.example.com")!
        let saved = BotConnection(id: UUID(), name: "Studio Mac", address: server, username: "operator", password: "secret")
        let http = connections.connection(for: saved, server: server)
        do { try await http.signIn(); XCTFail("The login was refused") } catch {}

        let text = SupportReport(server: Self.account(kind: .hermes, serverVersion: "0.21.5"), connections: connections).text
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Last connection attempt: ") && $0.hasSuffix(" UTC") }, text)
        XCTAssertTrue(lines.contains("Attempt status: Passed"), text)
        XCTAssertTrue(lines.contains("Attempt sign-in: Failed (HTTP 401)"), text)
        XCTAssertTrue(lines.contains("Attempt live handshake: Not checked"), text)
        for secret in ["example.com", "Studio Mac", "operator", "secret"] {
            XCTAssertFalse(text.contains(secret), text)
        }

        let other = SupportReport(server: Self.account(kind: .hermes, serverVersion: nil, url: "https://other.example.com"),
                                  connections: connections)
        XCTAssertFalse(other.text.localizedCaseInsensitiveContains("attempt"), other.text)
        connections.retire(server: server)
        let retired = SupportReport(server: Self.account(kind: .hermes, serverVersion: nil), connections: connections)
        XCTAssertFalse(retired.text.localizedCaseInsensitiveContains("attempt"), retired.text)
    }

    private static func account(kind: ServerKind, serverVersion: String?,
                                url: String = "https://hermes.example.com") -> ServerAccount {
        ServerAccount(id: url, urlString: url,
                      displayName: "Studio Mac", initials: "SM", headerLogoColorHex: "#000000",
                      createdAt: .distantPast, updatedAt: .distantPast, kind: kind, serverVersion: serverVersion)
    }
}
