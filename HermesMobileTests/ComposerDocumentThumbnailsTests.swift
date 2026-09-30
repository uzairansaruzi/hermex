import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ComposerDocumentThumbnailsTests: XCTestCase {
    private let size = CGSize(width: 58, height: 68)

    func testTwoRequestsForOneAttachmentGenerateOnce() async throws {
        let fixture = try await Fixture()
        let document = try await fixture.stageDocument(named: "report.pdf")

        let first = await fixture.thumbnails.thumbnail(for: document, size: size, scale: 3)
        let second = await fixture.thumbnails.thumbnail(for: document, size: size, scale: 3)

        XCTAssertIdentical(first, fixture.generator.image)
        XCTAssertIdentical(second, fixture.generator.image)
        XCTAssertIdentical(fixture.thumbnails.cachedThumbnail(for: document.id), fixture.generator.image)
        let requests = await fixture.generator.requests
        XCTAssertEqual(requests.map(\.url.lastPathComponent), [try XCTUnwrap(document.draftFileName)])
        XCTAssertEqual(requests.first?.size, size)
        XCTAssertEqual(requests.first?.scale, 3)
    }

    /// Images already carry their own thumbnail, and an attachment without a
    /// draft copy has no file to read.
    func testImagesAndAttachmentsWithoutADraftCopyNeverReachTheGenerator() async throws {
        let fixture = try await Fixture()
        let image = PendingAttachment(
            name: "photo.jpg", path: "", mime: "image/jpeg", isImage: true,
            thumbnailData: Data([0xFF]), draftFileName: "saved-photo.jpg"
        )
        let voiceNote = PendingAttachment(name: "note.m4a", path: "", mime: "audio/m4a", isImage: false)

        let imageResult = await fixture.thumbnails.thumbnail(for: image, size: size, scale: 3)
        let voiceNoteResult = await fixture.thumbnails.thumbnail(for: voiceNote, size: size, scale: 3)

        XCTAssertNil(imageResult)
        XCTAssertNil(voiceNoteResult)
        let requests = await fixture.generator.requests
        XCTAssertTrue(requests.isEmpty)
    }

    /// A document Quick Look can't draw keeps its icon, and isn't retried on
    /// every render.
    func testAFailureIsCachedAndNotRetried() async throws {
        let fixture = try await Fixture(image: nil)
        let archive = try await fixture.stageDocument(named: "logs.zip")

        let first = await fixture.thumbnails.thumbnail(for: archive, size: size, scale: 3)
        let second = await fixture.thumbnails.thumbnail(for: archive, size: size, scale: 3)

        XCTAssertNil(first)
        XCTAssertNil(second)
        let requests = await fixture.generator.requests
        XCTAssertEqual(requests.count, 1)
    }

    /// A tile that goes away mid-request leaves nothing behind, so the next
    /// tile to ask generates afresh.
    func testACancelledRequestStoresNoResult() async throws {
        let fixture = try await Fixture()
        let document = try await fixture.stageDocument(named: "report.pdf")
        let generating = expectation(description: "The generator has the request")
        await fixture.generator.holdNextRequest(signalling: generating)

        let request = Task { await fixture.thumbnails.thumbnail(for: document, size: size, scale: 3) }
        await fulfillment(of: [generating], timeout: 5)
        request.cancel()
        await fixture.generator.releaseHeldRequest()
        _ = await request.value

        XCTAssertNil(fixture.thumbnails.cachedThumbnail(for: document.id))
        let retried = await fixture.thumbnails.thumbnail(for: document, size: size, scale: 3)
        XCTAssertIdentical(retried, fixture.generator.image)
        let requests = await fixture.generator.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testTheOldestResultIsEvictedPastTheLimit() async throws {
        let fixture = try await Fixture(limit: 2)
        let first = try await fixture.stageDocument(named: "one.pdf")
        let second = try await fixture.stageDocument(named: "two.pdf")
        let third = try await fixture.stageDocument(named: "three.pdf")

        for document in [first, second, third] {
            _ = await fixture.thumbnails.thumbnail(for: document, size: size, scale: 3)
        }

        XCTAssertNil(fixture.thumbnails.cachedThumbnail(for: first.id))
        XCTAssertIdentical(fixture.thumbnails.cachedThumbnail(for: second.id), fixture.generator.image)
        XCTAssertIdentical(fixture.thumbnails.cachedThumbnail(for: third.id), fixture.generator.image)
    }
}

@MainActor
private struct Fixture {
    let directory: URL
    let store: ChatDraftAttachmentStore
    let generator: ScriptedThumbnailGenerator
    let thumbnails: ComposerDocumentThumbnails

    init(image: UIImage? = UIImage(), limit: Int = 32) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerDocumentThumbnailsTests-\(UUID().uuidString)", isDirectory: true)
        store = ChatDraftAttachmentStore(directoryURL: directory)
        generator = ScriptedThumbnailGenerator(image: image)
        thumbnails = ComposerDocumentThumbnails(store: store, generator: generator, limit: limit)
    }

    func stageDocument(named name: String) async throws -> PendingAttachment {
        let file = try await store.save(data: Data("document".utf8), suggestedFilename: name)
        return PendingAttachment(name: name, path: "/workspace/\(name)", mime: "application/pdf", isImage: false, draftFileName: file)
    }
}

private actor ScriptedThumbnailGenerator: ComposerThumbnailGenerating {
    struct Request: Equatable {
        let url: URL
        let size: CGSize
        let scale: CGFloat
    }

    nonisolated let image: UIImage?
    private(set) var requests: [Request] = []
    private var holdSignal: XCTestExpectation?
    private var held: CheckedContinuation<Void, Never>?

    init(image: UIImage?) {
        self.image = image
    }

    func thumbnail(ofFileAt url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        requests.append(Request(url: url, size: size, scale: scale))
        if let signal = holdSignal {
            holdSignal = nil
            // Like Quick Look, this one answers even after its caller gave up.
            await withCheckedContinuation { continuation in
                held = continuation
                signal.fulfill()
            }
        }
        return image
    }

    /// Parks the next request until `releaseHeldRequest`, fulfilling `signal`
    /// once it is parked.
    func holdNextRequest(signalling signal: XCTestExpectation) {
        holdSignal = signal
    }

    func releaseHeldRequest() {
        held?.resume()
        held = nil
    }
}
