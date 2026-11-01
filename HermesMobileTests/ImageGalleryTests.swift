import SwiftUI
import XCTest
@testable import HermesMobile

/// A message's images open as one lightbox gallery at the tapped image; only the pages
/// around the selected one may hold an image, and a zoomed image stops the paging.
@MainActor
final class ImageGalleryTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testTappingAReplyImageOpensTheRepliesImagesInOrderAtTheTappedOne() {
        let before = TranscriptMediaReference(rawReference: "/tmp/shots/before.png")
        let after = TranscriptMediaReference(rawReference: "/tmp/shots/after.png")
        let report = TranscriptMediaReference(rawReference: "/tmp/shots/report.pdf")
        let chart = TranscriptMediaReference(rawReference: "https://example.test/chart.jpg")

        let gallery = ImageLightboxGallery(
            tapped: after,
            in: [before, after, report, TranscriptMediaReference(rawReference: after.rawReference, altText: "again"), chart]
        )

        XCTAssertEqual(gallery.items.map(\.id), [before.id, after.id, chart.id])
        XCTAssertEqual(gallery.items.firstIndex { $0.id == gallery.startID }, 1)
    }

    func testOnlyTheSelectedPageAndItsNeighboursMayLoad() {
        let admitted = (0..<10).filter { ImageLightboxAdmission.admits(index: $0, selectedIndex: 4) }

        XCTAssertEqual(admitted, [3, 4, 5])
    }

    func testThePagerOpensAtTheTappedImage() async throws {
        let probe = PageProbe()
        let scrollView = try await hostPager(startingAt: 2, of: 4, probe: probe)

        XCTAssertEqual(scrollView.contentOffset.x, scrollView.bounds.width * 2, accuracy: 1)
    }

    /// The pager runs edge to edge; a page's chrome must still clear the Dynamic Island
    /// and the home indicator.
    func testGalleryPagesKeepTheScreensSafeArea() async throws {
        let probe = PageProbe()
        _ = try await hostPager(startingAt: 0, of: 2, probe: probe)
        let screen = try XCTUnwrap(window?.rootViewController?.view.safeAreaInsets)
        let safeArea = try XCTUnwrap(probe.safeAreas["page-0"])

        XCTAssertGreaterThan(screen.top, 0)
        XCTAssertEqual(safeArea.top, screen.top, accuracy: 1)
        XCTAssertEqual(safeArea.bottom, screen.bottom, accuracy: 1)
    }

    func testZoomingTheSelectedImageStopsPaging() async throws {
        let probe = PageProbe()
        let scrollView = try await hostPager(startingAt: 1, of: 3, probe: probe)
        let selected = try XCTUnwrap(probe.pages["page-1"])

        selected.onZoomChange(true)
        await settle()
        XCTAssertFalse(scrollView.isScrollEnabled)

        selected.onZoomChange(false)
        await settle()
        XCTAssertTrue(scrollView.isScrollEnabled)
    }

    // MARK: - Hosting

    private struct Page: Identifiable {
        let id: String
    }

    private func hostPager(startingAt start: Int, of count: Int, probe: PageProbe) async throws -> UIScrollView {
        let pages = (0..<count).map { Page(id: "page-\($0)") }
        let gallery = ImageLightboxGallery(tapped: pages[start], siblings: pages, isImage: { _ in true })
        let pager = ImageLightboxPager(gallery: gallery) { page, context in
            let _ = (probe.pages[page.id] = context)
            GeometryReader { proxy in
                let _ = (probe.safeAreas[page.id] = proxy.safeAreaInsets)
                Color.clear
            }
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIHostingController(rootView: pager)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        await settle()

        return try XCTUnwrap(Self.firstScrollView(in: window))
    }

    private func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window?.layoutIfNeeded()
        }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private final class PageProbe {
    var pages: [String: ImageLightboxPage] = [:]
    var safeAreas: [String: EdgeInsets] = [:]
}
