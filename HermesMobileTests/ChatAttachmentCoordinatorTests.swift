import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class ChatAttachmentCoordinatorTests: APIClientTestCase {
    private var delegateSpies: [ChatAttachmentCoordinatorDelegateSpy] = []

    override func tearDown() {
        DeferredUploadMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testUploadSuccessAddsPendingAttachmentAndPreparesLocalPreview() async throws {
        let imageData = try XCTUnwrap(Self.imageData())
        var uploadedFilename: String?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadedFilename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "photo.png",
                  "path": "/tmp/workspace/photo.png",
                  "size": \(imageData.count),
                  "mime": "image/png",
                  "is_image": true
                }
                """,
                for: request
            )
        }
        let coordinator = makeCoordinator(client: client)

        await coordinator.uploadAttachment(data: imageData, filename: "/tmp/photo.png", previewData: imageData)

        XCTAssertEqual(uploadedFilename, "photo.png")
        XCTAssertNil(coordinator.uploadAttachmentErrorMessage)
        XCTAssertFalse(coordinator.isUploadingAttachment)
        let attachment = try XCTUnwrap(coordinator.pendingAttachments.first)
        XCTAssertEqual(attachment.name, "photo.png")
        XCTAssertEqual(attachment.path, "/tmp/workspace/photo.png")
        XCTAssertEqual(attachment.mime, "image/png")
        XCTAssertEqual(attachment.size, imageData.count)
        XCTAssertTrue(attachment.isImage)
        XCTAssertNotNil(attachment.thumbnailData)

        let preparation = coordinator.prepareForSend(localMessageID: "local-message")

        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
        XCTAssertEqual(preparation.attachments.count, 1)
        XCTAssertEqual(preparation.messageAttachments.first?.path, "/tmp/workspace/photo.png")
        XCTAssertEqual(preparation.apiPayloads?.count, 1)
        XCTAssertNotNil(coordinator.localAttachmentPreviews["local-message"]?["/tmp/workspace/photo.png"])
    }

    func testUploadFailurePreservesExistingPendingAttachment() async throws {
        var uploadCount = 0
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadCount += 1

            if uploadCount == 1 {
                return apiTestJSONResponse(
                    """
                    {
                      "filename": "notes.txt",
                      "path": "/tmp/workspace/notes.txt",
                      "size": 5,
                      "mime": "text/plain",
                      "is_image": false
                    }
                    """,
                    for: request
                )
            }

            return apiTestJSONResponse(#"{"error":"Upload failed."}"#, for: request)
        }
        let coordinator = makeCoordinator(client: client)

        await coordinator.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")
        await coordinator.uploadAttachment(data: Data("large".utf8), filename: "large.bin")

        XCTAssertEqual(uploadCount, 2)
        XCTAssertEqual(coordinator.pendingAttachments.count, 1)
        XCTAssertEqual(coordinator.pendingAttachments.first?.name, "notes.txt")
        XCTAssertEqual(coordinator.uploadAttachmentErrorMessage, "Upload failed.")
    }

    func testDraftCopyFailureStopsBeforeNetworkUpload() async {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            return apiTestJSONResponse(#"{"error":"unexpected upload"}"#, for: request)
        }
        let store = RecordingAttachmentStore(saveError: CocoaError(.fileWriteOutOfSpace))
        let coordinator = makeCoordinator(client: client, attachmentStore: store)

        let uploaded = await coordinator.uploadAttachment(
            data: Data("notes".utf8),
            filename: "notes.txt"
        )

        XCTAssertNil(uploaded)
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
        XCTAssertEqual(
            coordinator.uploadAttachmentErrorMessage,
            "Could not save the attachment on this device."
        )
    }

    func testConcurrentUploadsKeepUploadingStateUntilAllUploadsFinish() async throws {
        let firstUploadStarted = expectation(description: "first upload started")
        let uploadState = DeferredUploadState()

        let client = makeDeferredUploadClient { request, protocolClient in
            XCTAssertEqual(request.url?.path, "/api/upload")
            let filename = try Self.multipartFilename(from: request)
            let uploadIndex = uploadState.nextUploadIndex()

            let response = apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 4,
                  "mime": "text/plain",
                  "is_image": false
                }
                """,
                for: request
            )

            if uploadIndex == 1 {
                uploadState.setFirstUploadCompletion {
                    protocolClient.complete(with: response)
                }
                firstUploadStarted.fulfill()
                return
            }

            protocolClient.complete(with: response)
        }
        let coordinator = makeCoordinator(client: client)

        let firstUpload = Task {
            await coordinator.uploadAttachment(data: Data("one".utf8), filename: "one.txt")
        }
        await fulfillment(of: [firstUploadStarted], timeout: 2)
        XCTAssertTrue(coordinator.isUploadingAttachment)

        let secondUpload = Task {
            await coordinator.uploadAttachment(data: Data("two".utf8), filename: "two.txt")
        }
        await secondUpload.value

        XCTAssertTrue(coordinator.isUploadingAttachment)
        let finishFirst = try XCTUnwrap(
            uploadState.firstUploadCompletion(),
            "Expected the first upload completion to be deferred."
        )
        finishFirst()
        await firstUpload.value

        XCTAssertFalse(coordinator.isUploadingAttachment)
        XCTAssertEqual(coordinator.pendingAttachments.map(\.name).sorted(), ["one.txt", "two.txt"])
    }

    func testRemovePendingAttachmentRemovesOnlyMatchingAttachment() async throws {
        let client = makeClient { request in
            let filename = try apiTestMultipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 4,
                  "mime": "text/plain",
                  "is_image": false
                }
                """,
                for: request
            )
        }
        let coordinator = makeCoordinator(client: client)

        await coordinator.uploadAttachment(data: Data("one".utf8), filename: "one.txt")
        await coordinator.uploadAttachment(data: Data("two".utf8), filename: "two.txt")
        let firstID = try XCTUnwrap(coordinator.pendingAttachments.first?.id)

        coordinator.removePendingAttachment(id: firstID)

        XCTAssertEqual(coordinator.pendingAttachments.map(\.name), ["two.txt"])
    }

    func testTranscriptSameServerRemoteMediaUsesAuthenticatedSession() async throws {
        let mediaData = Data([0x01, 0x02, 0x03])
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/generated/media/image.png?variant=full"))
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "authenticated")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let thumbnail = await coordinator.transcriptMediaThumbnailData(
            for: TranscriptMediaReference(rawReference: remoteURL.absoluteString)
        )

        XCTAssertEqual(thumbnail, mediaData)
    }

    func testTranscriptLocalMediaIncludesSessionIDOnMediaEndpoint() async throws {
        let mediaData = try XCTUnwrap(Self.imageData())
        let mediaPath = "/Users/hermes/.hermes/browser_screenshots/example.png"
        let sessionID = "session-abc"
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], sessionID)
            XCTAssertEqual(query["path"], mediaPath)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let thumbnail = await coordinator.transcriptMediaThumbnailData(
            for: TranscriptMediaReference(rawReference: mediaPath)
        )

        XCTAssertNotNil(thumbnail)
    }

    func testTranscriptLocalAudioMediaIncludesSessionIDOnMediaEndpoint() async throws {
        let mediaData = Data("audio-bytes".utf8)
        let mediaPath = "/tmp/generated/clip.mp3"
        let sessionID = "session-abc"
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], sessionID)
            XCTAssertEqual(query["path"], mediaPath)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: mediaPath)
        )

        XCTAssertEqual(data, mediaData)
    }

    func testTranscriptExternalRemoteVideoUsesPublicMediaSession() async throws {
        let mediaData = Data("video-bytes".utf8)
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.test/generated/movie.mp4"))
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "public")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: remoteURL.absoluteString)
        )

        XCTAssertEqual(data, mediaData)
    }

    func testTranscriptLocalAudioWithoutSessionDoesNotRequestMediaEndpoint() async {
        var requestCount = 0
        let client = makeAuthenticatedMediaClient { request in
            requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("unexpected".utf8))
        }
        let coordinator = ChatAttachmentCoordinator(client: client)
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegate.attachmentSessionID = nil
        delegateSpies.append(delegate)
        coordinator.delegate = delegate

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: "/tmp/generated/clip.mp3")
        )

        XCTAssertNil(data)
        XCTAssertEqual(requestCount, 0)
    }

    func testUploadCarriesDraftFileNameIntoPendingAttachment() async throws {
        let client = makeClient { request in
            let filename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 5,
                  "mime": "text/plain",
                  "is_image": false
                }
                """,
                for: request
            )
        }
        let store = RecordingAttachmentStore()
        let coordinator = makeCoordinator(client: client, attachmentStore: store)

        let uploaded = await coordinator.uploadAttachment(
            data: Data("notes".utf8),
            filename: "notes.txt"
        )

        XCTAssertEqual(uploaded?.draftFileName, "saved-1-notes.txt")
        XCTAssertEqual(coordinator.pendingAttachments.first?.draftFileName, "saved-1-notes.txt")
        let savedNames = await store.savedNames()
        XCTAssertEqual(savedNames, ["saved-1-notes.txt"])
    }

    func testStandaloneUploadNeverCarriesADraftFileName() async throws {
        let client = makeClient { request in
            let filename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 5,
                  "mime": "audio/m4a",
                  "is_image": false
                }
                """,
                for: request
            )
        }
        let coordinator = makeCoordinator(client: client)

        let uploaded = await coordinator.uploadStandaloneAttachment(
            data: Data("audio".utf8),
            filename: "clip.m4a"
        )

        XCTAssertNil(uploaded?.draftFileName)
        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
    }

    func testReuploadDraftAttachmentPreservesDraftIdentity() async throws {
        let record = ChatDraftAttachment(
            id: UUID(),
            name: "notes.txt",
            mime: "text/plain",
            size: 5,
            isImage: false,
            file: "abc-notes.txt"
        )
        let client = makeClient { request in
            let filename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 5,
                  "mime": "text/plain",
                  "is_image": false
                }
                """,
                for: request
            )
        }
        let coordinator = makeCoordinator(client: client)

        let restored = await coordinator.reuploadDraftAttachment(
            data: Data("notes".utf8),
            draftAttachment: record
        )

        XCTAssertEqual(restored?.id, record.id)
        XCTAssertEqual(restored?.draftFileName, "abc-notes.txt")
        XCTAssertEqual(restored?.path, "/tmp/workspace/notes.txt")
        XCTAssertNil(coordinator.uploadAttachmentErrorMessage)
        XCTAssertEqual(coordinator.pendingAttachments.map(\.id), [record.id])
    }

    func testReuploadDraftAttachmentFailureStaysQuiet() async throws {
        let record = ChatDraftAttachment(
            id: UUID(),
            name: "notes.txt",
            mime: "text/plain",
            size: 5,
            isImage: false,
            file: "abc-notes.txt"
        )
        let client = makeClient { request in
            apiTestJSONResponse(#"{"error":"Upload failed."}"#, for: request)
        }
        let coordinator = ChatAttachmentCoordinator(client: client)
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegateSpies.append(delegate)
        coordinator.delegate = delegate

        let restored = await coordinator.reuploadDraftAttachment(
            data: Data("notes".utf8),
            draftAttachment: record
        )

        // Restore failures must not surface a per-item banner or delegate
        // error; the caller reports in aggregate and keeps the draft record.
        XCTAssertNil(restored)
        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
        XCTAssertNil(coordinator.uploadAttachmentErrorMessage)
        XCTAssertTrue(delegate.failedErrors.isEmpty)
    }

    private func makeCoordinator(
        client: APIClient,
        attachmentStore: (any ChatDraftAttachmentStoring)? = nil
    ) -> ChatAttachmentCoordinator {
        let coordinator = ChatAttachmentCoordinator(
            client: client,
            draftAttachmentStore: attachmentStore ?? RecordingAttachmentStore()
        )
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegateSpies.append(delegate)
        coordinator.delegate = delegate
        return coordinator
    }

    private func makeAuthenticatedMediaClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let authenticatedConfiguration = URLSessionConfiguration.ephemeral
        authenticatedConfiguration.protocolClasses = [MockURLProtocol.self]
        authenticatedConfiguration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "authenticated"]

        let publicConfiguration = URLSessionConfiguration.ephemeral
        publicConfiguration.protocolClasses = [MockURLProtocol.self]
        publicConfiguration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "public"]

        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: authenticatedConfiguration),
            publicMediaSession: URLSession(configuration: publicConfiguration)
        )
    }

    private func makeDeferredUploadClient(
        handler: @escaping (URLRequest, DeferredUploadMockURLProtocol) throws -> Void
    ) -> APIClient {
        DeferredUploadMockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredUploadMockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private static func imageData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

    private static func multipartFilename(from request: URLRequest) throws -> String {
        let data = try XCTUnwrap(apiTestBodyData(from: request))
        let marker = Data("filename=\"".utf8)
        let quote = Data("\"".utf8)
        let markerRange = try XCTUnwrap(data.range(of: marker))
        let filenameStart = markerRange.upperBound
        let filenameEnd = try XCTUnwrap(data[filenameStart...].range(of: quote)).lowerBound
        return String(decoding: data[filenameStart..<filenameEnd], as: UTF8.self)
    }
}

private actor RecordingAttachmentStore: ChatDraftAttachmentStoring {
    private let saveError: Error?
    private var saves: [String] = []
    private var deletes: [String] = []

    init(saveError: Error? = nil) {
        self.saveError = saveError
    }

    func save(data: Data, suggestedFilename: String) async throws -> String {
        if let saveError {
            throw saveError
        }
        let fileName = "saved-\(saves.count + 1)-\(URL(fileURLWithPath: suggestedFilename).lastPathComponent)"
        saves.append(fileName)
        return fileName
    }

    func data(named fileName: String) async throws -> Data {
        Data()
    }

    func delete(named fileName: String) async {
        deletes.append(fileName)
    }

    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {}

    func savedNames() -> [String] {
        saves
    }

    func deletedNames() -> [String] {
        deletes
    }
}

private final class DeferredUploadMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest, DeferredUploadMockURLProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            try requestHandler(request, self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    func complete(with response: (HTTPURLResponse, Data)) {
        client?.urlProtocol(self, didReceive: response.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DeferredUploadState {
    private let lock = NSLock()
    private var uploadCount = 0
    private var firstCompletion: (() -> Void)?

    func nextUploadIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        uploadCount += 1
        return uploadCount
    }

    func setFirstUploadCompletion(_ completion: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        firstCompletion = completion
    }

    func firstUploadCompletion() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return firstCompletion
    }
}

@MainActor
private final class ChatAttachmentCoordinatorDelegateSpy: ChatAttachmentCoordinatorDelegate {
    var attachmentSessionID: String? = "session-abc"
    var attachmentIsViewingCachedData = false
    private(set) var failedErrors: [Error] = []

    func attachmentCoordinatorWillUpload() {}

    func attachmentCoordinatorDidFail(_ error: Error) {
        failedErrors.append(error)
    }
}
