import os
import UIKit
import XCTest
@testable import HermesMobile

/// Which preview a chat attachment opens in: Quick Look for documents and media,
/// the inline player for audio, and No Preview for archives.
@MainActor
final class ChatAttachmentPreviewViewModelTests: APIClientTestCase {
    func testPDFAttachmentOpensInQuickLook() async throws {
        let pdf = Data("%PDF-fixture".utf8)
        var requestedPaths: [String] = []
        let client = makeClient { request in
            requestedPaths.append(request.url?.path ?? "nil")
            return (try Self.response(for: request), pdf)
        }
        let viewModel = try makeViewModel(name: "report.pdf", size: pdf.count, client: client)

        await viewModel.load()

        guard case let .quickLook(file) = viewModel.preview else {
            return XCTFail("A PDF attachment opens in Quick Look, got \(String(describing: viewModel.preview))")
        }
        XCTAssertEqual(file.url.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: file.url), pdf)
        XCTAssertEqual(requestedPaths, ["/api/file/raw"])
    }

    func testAudioAttachmentKeepsTheInlinePlayer() async throws {
        let audio = Data("m4a-fixture".utf8)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file/raw")
            return (try Self.response(for: request), audio)
        }
        let viewModel = try makeViewModel(name: "memo.m4a", client: client)

        await viewModel.load()

        guard case let .audio(data) = viewModel.preview else {
            return XCTFail("An m4a attachment keeps the inline player, got \(String(describing: viewModel.preview))")
        }
        XCTAssertEqual(data, audio)
    }

    func testZipAttachmentStaysUnavailableWithoutARequest() async throws {
        let client = makeClient { request in
            XCTFail("A zip must not download: \(request.url?.path ?? "")")
            return apiTestJSONResponse("{}", for: request, status: 500)
        }
        let viewModel = try makeViewModel(name: "build.zip", client: client)

        await viewModel.load()

        guard case .unavailable = viewModel.preview else {
            return XCTFail("A zip keeps No Preview, got \(String(describing: viewModel.preview))")
        }
    }

    func testAttachmentOverTheCapSkipsTheDownload() async throws {
        let client = makeClient { request in
            XCTFail("A known size over the cap must not download: \(request.url?.path ?? "")")
            return apiTestJSONResponse("{}", for: request, status: 500)
        }
        let viewModel = try makeViewModel(name: "deck.pptx", size: BotArtifactBuffer.maximumBytes + 1, client: client)

        await viewModel.load()

        guard case .unavailable = viewModel.preview else {
            return XCTFail("Expected the too-large state, got \(String(describing: viewModel.preview))")
        }
    }

    /// A gallery page that leaves the admission window lets go of its image: a download
    /// still in flight lands nowhere, and the page loads again when the user swipes back.
    func testAReleasedImageDropsItsLateDownloadAndLoadsAgain() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let requestCount = OSAllocatedUnfairLock(initialState: 0)
        let firstDownloadStarted = expectation(description: "first download started")
        let finishFirstDownload = DispatchSemaphore(value: 0)
        let client = makeClient { request in
            let count = requestCount.withLock { count in
                count += 1
                return count
            }
            if count == 1 {
                firstDownloadStarted.fulfill()
                finishFirstDownload.wait()
            }
            return (try Self.response(for: request), image)
        }
        let viewModel = try ChatAttachmentPreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: ChatAttachmentPreviewItem(
                message: MessageAttachment(name: "after.png", path: "/tmp/workspace/after.png", isImage: true),
                localData: nil
            ),
            apiClient: client
        )

        let firstLoad = Task { await viewModel.load() }
        await fulfillment(of: [firstDownloadStarted], timeout: 5)
        viewModel.release()
        finishFirstDownload.signal()
        await firstLoad.value
        XCTAssertNil(viewModel.preview)

        await viewModel.load()
        guard case .image = viewModel.preview else {
            return XCTFail("A page back in the window loads again, got \(String(describing: viewModel.preview))")
        }
        XCTAssertEqual(requestCount.withLock { $0 }, 2)
    }

    private func makeViewModel(name: String, size: Int? = nil, client: APIClient) throws -> ChatAttachmentPreviewViewModel {
        try ChatAttachmentPreviewViewModel(
            session: makeFilePreviewSession(),
            server: XCTUnwrap(URL(string: "https://example.test")),
            item: ChatAttachmentPreviewItem(
                message: MessageAttachment(name: name, path: "/tmp/workspace/\(name)", size: size, isImage: false),
                localData: nil
            ),
            apiClient: client
        )
    }

    private static func response(for request: URLRequest) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:]))
    }
}
