import WebKit
import XCTest
@testable import HermesMobile

/// Inline HTML reports in Hermes replies (#1623).
@MainActor
final class HTMLReportTests: XCTestCase {
    func testAnHTMLFileRendersInPlaceOnlyInASettledHermesReply() {
        let hermes = TranscriptHTMLReportLoader()
        let report = TranscriptMediaReference(rawReference: "/tmp/out/weekly.HTML")
        let remote = TranscriptMediaReference(rawReference: "https://example.com/r/report.htm?token=1")

        XCTAssertTrue(HTMLReport.rendersInline(report, loader: hermes, isStreaming: false))
        XCTAssertTrue(HTMLReport.rendersInline(remote, loader: hermes, isStreaming: false))
        // webui publishes no loader, and a streaming reply keeps its card until it settles.
        XCTAssertFalse(HTMLReport.rendersInline(report, loader: nil, isStreaming: false))
        XCTAssertFalse(HTMLReport.rendersInline(report, loader: hermes, isStreaming: true))
        XCTAssertFalse(HTMLReport.rendersInline(
            TranscriptMediaReference(rawReference: "/tmp/out/weekly.pdf"), loader: hermes, isStreaming: false
        ))
    }

    func testAFileOverTheInlineLimitStaysACard() async {
        let loader = TranscriptHTMLReportLoader()
        loader.load = { _ in throw BotArtifactFailure.tooLarge }
        let model = TranscriptHTMLReportModel()

        await model.load(TranscriptMediaReference(rawReference: "/tmp/big.html"), using: loader)

        XCTAssertEqual(model.phase, .oversized)
    }

    func testAReportWaitsForTheChatToAttachInsteadOfFailing() async {
        let loader = TranscriptHTMLReportLoader()
        loader.load = { _ in throw BotFailure.stale }
        let model = TranscriptHTMLReportModel()

        await model.load(TranscriptMediaReference(rawReference: "/tmp/report.html"), using: loader)

        XCTAssertEqual(model.phase, .waiting)
    }

    func testAReportThatFailedToRenderLoadsAgainOnRetry() async {
        let loader = TranscriptHTMLReportLoader()
        loader.load = { _ in Data("<p>ok</p>".utf8) }
        let model = TranscriptHTMLReportModel()
        let report = TranscriptMediaReference(rawReference: "/tmp/report.html")
        await model.load(report, using: loader)
        model.renderFailed()

        model.retry()
        await model.load(report, using: loader)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.html, "<p>ok</p>")
    }

    func testAPageWhoseWebProcessDiesReloadsOnceThenFails() {
        var failures = 0
        let theme = HTMLReportTheme(appearance: .default, colorScheme: .dark, dynamicTypeSize: .large)
        let coordinator = HTMLReportWebView.Coordinator(
            HTMLReportWebView(html: "<p>ok</p>", theme: theme, scrolls: false, onFailure: { failures += 1 })
        )
        let webView = LoadCountingWebView()
        coordinator.webView = webView

        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.loads, 1)
        XCTAssertEqual(failures, 0)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.loads, 1)
        XCTAssertEqual(failures, 1)
    }

    func testOffScreenImagesPastTheLimitDropTheOldest() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        let bytes = Int(10 * image.scale * 10 * image.scale) * 4
        let snapshots = HTMLReportSnapshots(byteLimit: bytes * 2)

        snapshots.store(image, for: "a")
        snapshots.store(image, for: "b")
        snapshots.store(image, for: "c")

        XCTAssertNil(snapshots.image(for: "a"))
        XCTAssertNotNil(snapshots.image(for: "b"))
        XCTAssertNotNil(snapshots.image(for: "c"))
    }

    func testTheTopFrameNeverNavigatesAndTappedLinksGoToTheRouter() throws {
        let link = try XCTUnwrap(URL(string: "https://github.com/uzairansaruzi/hermex/issues/1623"))
        let blank = try XCTUnwrap(URL(string: "about:blank"))

        XCTAssertEqual(HTMLReportNavigation.decision(for: blank, isMainFrame: true, isLinkTap: false, hasLoaded: false), .allow)
        XCTAssertEqual(HTMLReportNavigation.decision(for: link, isMainFrame: true, isLinkTap: true, hasLoaded: true), .open(link))
        // A script can't move the page, to the web or back to a blank page.
        XCTAssertEqual(HTMLReportNavigation.decision(for: link, isMainFrame: true, isLinkTap: false, hasLoaded: true), .cancel)
        XCTAssertEqual(HTMLReportNavigation.decision(for: blank, isMainFrame: true, isLinkTap: false, hasLoaded: true), .cancel)
        // WebKit hands an in-page anchor over as a new page; the app scrolls to it instead.
        XCTAssertEqual(HTMLReportNavigation.decision(
            for: URL(string: "about:blank%23totals"), isMainFrame: true, isLinkTap: true, hasLoaded: true
        ), .anchor("totals"))
        XCTAssertEqual(HTMLReportNavigation.decision(
            for: URL(string: "data:text/html,hi"), isMainFrame: true, isLinkTap: true, hasLoaded: true
        ), .cancel)
        // Frames inside the page, such as an embedded chart, load freely.
        XCTAssertEqual(HTMLReportNavigation.decision(for: link, isMainFrame: false, isLinkTap: false, hasLoaded: true), .allow)
    }

    func testTheThemeReachesThePageAsVariablesThePagesOwnStylesOverride() {
        let appearance = AppAppearance(lightTheme: .default, darkTheme: .paper, accentHex: nil)
        let css = HTMLReportTheme(appearance: appearance, colorScheme: .dark, dynamicTypeSize: .large).css

        XCTAssertTrue(css.contains("--background:rgb(31 30 28 / 1.00)"), css)
        XCTAssertTrue(css.contains("--primary:rgb(224 162 94 / 1.00)"), css)
        XCTAssertTrue(css.contains("color-scheme:dark"), css)
        // Every rule is zero-specificity, so any rule of the page's own wins.
        let selectors = css.split(separator: "\n").map { $0.prefix(while: { $0 != "{" }) }
        XCTAssertTrue(selectors.allSatisfy { $0.hasPrefix(":where(") }, css)
    }
}

/// Counts the page loads `HTMLReportWebView.Coordinator` starts, without loading anything.
private final class LoadCountingWebView: WKWebView {
    private(set) var loads = 0

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loads += 1
        return nil
    }
}
