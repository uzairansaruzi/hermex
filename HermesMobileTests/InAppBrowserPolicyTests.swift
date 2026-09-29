import XCTest
@testable import HermesMobile

/// Web links open in the in-app Safari sheet; every other link keeps going to
/// the system, which also keeps unsupported schemes away from
/// `SFSafariViewController`.
final class InAppBrowserPolicyTests: XCTestCase {
    func testWebLinksOpenInApp() {
        for link in ["http://example.com", "https://example.com/docs?page=2#setup", "HTTPS://Example.com"] {
            XCTAssertTrue(InAppBrowserPolicy.opensInApp(URL(string: link)!), link)
        }
    }

    func testOtherSchemesGoToTheSystem() {
        let links = [
            "mailto:someone@example.com",
            "tel:+15555550100",
            "sms:+15555550100",
            "file:///Users/hermes/projects/app/README.md",
            "slack://open?team=T123",
        ]
        for link in links {
            XCTAssertFalse(InAppBrowserPolicy.opensInApp(URL(string: link)!), link)
        }
    }

    func testAWebLinkWithoutAHostGoesToTheSystem() {
        XCTAssertFalse(InAppBrowserPolicy.opensInApp(URL(string: "https:")!))
    }
}
