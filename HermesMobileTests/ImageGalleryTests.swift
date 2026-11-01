import SwiftUI
import XCTest
@testable import HermesMobile

/// A message's images open as one lightbox gallery at the tapped image; only the pages
/// around the selected one hold a loader, and a zoomed image keeps its zoom and stops the paging.
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

    /// Zooming a loaded image redraws the pager; the zoom must survive that, and a sideways
    /// drag must pan the image instead of turning the page.
    func testZoomingALoadedImageKeepsTheZoomAndStopsPaging() async throws {
        let session = SessionSummary(title: "Screenshots")
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let items = (0..<2).map {
            ChatAttachmentPreviewItem(
                message: MessageAttachment(name: "shot-\($0).png", isImage: true),
                localData: Self.photo
            )
        }
        let gallery = ImageLightboxGallery(tapped: items[0], siblings: items, isImage: \.inferredIsImage)
        let pager = try await host(ImageLightboxPager(gallery: gallery) { item, page in
            ChatAttachmentImageLightbox(session: session, server: server, item: item, page: page, onAPIError: { _ in })
        })
        let image = try XCTUnwrap(visibleZoomableImage())

        image.setZoomScale(2, animated: false)
        image.delegate?.scrollViewDidEndZooming?(image, with: nil, atScale: 2)
        await settle()
        XCTAssertEqual(try XCTUnwrap(visibleZoomableImage()).zoomScale, 2, accuracy: 0.01)
        XCTAssertFalse(pager.isScrollEnabled)

        image.setZoomScale(1, animated: false)
        image.delegate?.scrollViewDidEndZooming?(image, with: nil, atScale: 1)
        await settle()
        XCTAssertTrue(pager.isScrollEnabled)
    }

    /// A page the user swipes away from while its image is still downloading fetches it again
    /// on the way back, instead of sitting on "Loading media".
    func testAPageLeftWhileLoadingLoadsAgainWhenTheUserComesBack() async throws {
        let files = HeldFirstMedia(heldName: "shot-0.png", image: Self.photo)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let references = (0..<3).map { TranscriptMediaReference(rawReference: "/tmp/shots/shot-\($0).png") }
        let probe = PageProbe()
        _ = try await host(ImageLightboxPager(gallery: ImageLightboxGallery(tapped: references[0], in: references)) { item, page in
            let _ = (probe.pages[item.id] = page)
            TranscriptMediaImageLightbox(server: server, files: files, item: item, page: page, onAPIError: { _ in })
        })
        await fulfillment(of: [files.firstDownloadHeld], timeout: 5)

        for (from, step) in [(0, 1), (1, 1), (2, -1), (1, -1)] {
            try XCTUnwrap(probe.pages[references[from].id]?.onStep)(step)
            await settle()
        }

        await fulfillment(of: [files.downloadedAgain], timeout: 5)
        await files.finishFirstDownload()
    }

    // MARK: - Hosting

    private struct Page: Identifiable {
        let id: String
    }

    private func hostPager(startingAt start: Int, of count: Int, probe: PageProbe) async throws -> UIScrollView {
        let pages = (0..<count).map { Page(id: "page-\($0)") }
        let gallery = ImageLightboxGallery(tapped: pages[start], siblings: pages, isImage: { _ in true })
        return try await host(ImageLightboxPager(gallery: gallery) { page, context in
            let _ = (probe.pages[page.id] = context)
            GeometryReader { proxy in
                let _ = (probe.safeAreas[page.id] = proxy.safeAreaInsets)
                Color.clear
            }
        })
    }

    /// Shows `root` full screen on a phone-sized window and returns the pager's scroll view.
    private func host(_ root: some View) async throws -> UIScrollView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = UIHostingController(rootView: root.transaction { $0.disablesAnimations = true })
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        await settle()

        return try XCTUnwrap(Self.scrollViews(in: window).first)
    }

    /// The zooming scroll view of the image on screen.
    private func visibleZoomableImage() -> ZoomableScrollView? {
        guard let window else { return nil }
        return Self.scrollViews(in: window)
            .compactMap { $0 as? ZoomableScrollView }
            .first { abs($0.convert($0.bounds, to: nil).minX) < 1 }
    }

    private func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window?.layoutIfNeeded()
        }
    }

    /// Every scroll view under `view`, outermost first.
    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static let photo = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
    }
}

@MainActor
private final class PageProbe {
    var pages: [String: ImageLightboxPage] = [:]
    var safeAreas: [String: EdgeInsets] = [:]
}

/// Media whose first download of `heldName` waits until the test finishes it; every other
/// download answers with `image` at once.
private actor HeldFirstMedia: WorkspaceFileClient {
    nonisolated let scope = "held-first-media"
    nonisolated let opensTopLevelFolders = false
    nonisolated let firstDownloadHeld = XCTestExpectation(description: "the first download is held")
    nonisolated let downloadedAgain = XCTestExpectation(description: "the held image is fetched again")
    private let heldName: String
    private let image: Data
    private var heldDownloads = 0
    private var held: CheckedContinuation<Void, Never>?

    init(heldName: String, image: Data) {
        self.heldName = heldName
        self.image = image
    }

    func mediaData(path: String) async throws -> Data {
        guard path.hasSuffix(heldName) else { return image }
        heldDownloads += 1
        if heldDownloads == 1 {
            await withCheckedContinuation {
                held = $0
                firstDownloadHeld.fulfill()
            }
        } else if heldDownloads == 2 {
            downloadedAgain.fulfill()
        }
        return image
    }

    func finishFirstDownload() {
        held?.resume()
        held = nil
    }

    func directoryList(path: String) async throws -> DirectoryListResponse { throw URLError(.unsupportedURL) }
    func file(path: String) async throws -> FileResponse { throw URLError(.unsupportedURL) }
    func rawFileData(path: String) async throws -> Data { throw URLError(.unsupportedURL) }
    func rawFilePreviewData(path: String) async throws -> Data { throw URLError(.unsupportedURL) }
    func imagePreviewData(path: String) async throws -> Data { throw URLError(.unsupportedURL) }
    func mediaExportData(path: String) async throws -> Data { throw URLError(.unsupportedURL) }
}
