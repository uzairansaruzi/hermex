import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

@MainActor
final class TranscriptMediaPreviewViewModelTests: XCTestCase {
    override func tearDown() {
        TranscriptMediaPreviewMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testLoadLocalImageUsesMediaEndpointAndCachesOriginalData() async throws {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let imageData = try XCTUnwrap(Self.imageData())
        let mediaPath = "/Users/hermes/.hermes/browser_screenshots/example.png"
        let sessionID = "session-123"
        let client = makeClient { request in
            recorder.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")
            return self.response(statusCode: 200, data: imageData, for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: sessionID,
            reference: .init(rawReference: mediaPath),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertNotNil(viewModel.previewData)
        XCTAssertEqual(viewModel.originalByteCount, imageData.count)
        XCTAssertTrue(viewModel.canSaveImageToPhotos)
        XCTAssertTrue(viewModel.canSaveMediaToPhotos)
        XCTAssertTrue(viewModel.canExportMedia)

        let queryItems = queryItems(for: try XCTUnwrap(recorder.firstURL))
        XCTAssertEqual(queryItems["session_id"], sessionID)
        XCTAssertEqual(queryItems["path"], mediaPath)

        let originalData = try await viewModel.originalImageData()
        XCTAssertEqual(originalData, imageData)
        let payload = try await viewModel.exportPayload()
        XCTAssertEqual(payload.data, imageData)
        XCTAssertEqual(payload.filename, "example.png")
        XCTAssertEqual(payload.contentType, .png)
        XCTAssertTrue(payload.isImage)
        XCTAssertFalse(payload.isVideo)
        XCTAssertEqual(recorder.requestCount, 1)
    }

    func testLoadSameServerRemoteImageUsesAuthenticatedSession() async throws {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let imageData = try XCTUnwrap(Self.imageData())
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/generated/media/image.png?variant=full"))

        let client = makeClient { request in
            recorder.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "authenticated")
            return self.response(statusCode: 200, data: imageData, for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: "session-123",
            reference: .init(rawReference: remoteURL.absoluteString),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.previewData)
        XCTAssertEqual(viewModel.originalByteCount, imageData.count)
        XCTAssertTrue(viewModel.canExportMedia)
        XCTAssertEqual(recorder.requestCount, 1)
    }

    func testLoadExternalRemoteImageDoesNotSendHermesCookies() async throws {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let imageData = try XCTUnwrap(Self.imageData())
        let externalURL = try XCTUnwrap(URL(string: "https://cdn.example.test/output/image.png"))
        let cookieStorage = HTTPCookieStorage()
        let cookie = try XCTUnwrap(Self.hermesCookie(domain: ".example.test"))
        cookieStorage.setCookie(cookie)

        let client = makeClient(cookieStorage: cookieStorage) { request in
            recorder.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, externalURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "public")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return self.response(statusCode: 200, data: imageData, for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: "session-123",
            reference: .init(rawReference: externalURL.absoluteString),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.previewData)
        XCTAssertEqual(viewModel.originalByteCount, imageData.count)
        XCTAssertTrue(viewModel.canExportMedia)
        XCTAssertEqual(recorder.requestCount, 1)
    }

    func testUnsupportedMediaSetsUnavailableStateWithoutRequest() async {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return self.response(statusCode: 200, data: Data(), for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: "session-123",
            reference: .init(rawReference: "/tmp/vector.svg"),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.errorMessage, "Preview is not available for this media type.")
        XCTAssertNil(viewModel.previewData)
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.canSaveImageToPhotos)
        XCTAssertFalse(viewModel.canSaveMediaToPhotos)
        XCTAssertFalse(viewModel.canExportMedia)
        XCTAssertEqual(recorder.requestCount, 0)
    }

    func testLoadLocalImageWithoutSessionIDDoesNotRequestMediaEndpoint() async {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return self.response(statusCode: 200, data: Data(), for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: nil,
            reference: .init(rawReference: "/tmp/generated.png"),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.previewData)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(recorder.requestCount, 0)
    }

    func testLoadLocalVideoUsesMediaEndpointAndCreatesPlayableFileURL() async throws {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let videoData = Data("video-bytes".utf8)
        let mediaPath = "/tmp/generated/movie.mp4"
        let sessionID = "session-123"
        let client = makeClient { request in
            recorder.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")
            return self.response(statusCode: 200, data: videoData, for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: sessionID,
            reference: .init(rawReference: mediaPath),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertNil(viewModel.previewData)
        let videoFileURL = try XCTUnwrap(viewModel.videoFileURL)
        XCTAssertEqual(videoFileURL.pathExtension, "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoFileURL.path))
        XCTAssertEqual(try Data(contentsOf: videoFileURL), videoData)
        XCTAssertEqual(viewModel.originalByteCount, videoData.count)
        XCTAssertFalse(viewModel.canSaveImageToPhotos)
        XCTAssertTrue(viewModel.canSaveVideoToPhotos)
        XCTAssertTrue(viewModel.canSaveMediaToPhotos)
        XCTAssertTrue(viewModel.canExportMedia)

        let payload = try await viewModel.exportPayload()
        XCTAssertEqual(payload.data, videoData)
        XCTAssertEqual(payload.filename, "movie.mp4")
        XCTAssertEqual(payload.contentType, .mpeg4Movie)
        XCTAssertFalse(payload.isImage)
        XCTAssertTrue(payload.isVideo)

        let queryItems = queryItems(for: try XCTUnwrap(recorder.firstURL))
        XCTAssertEqual(queryItems["session_id"], sessionID)
        XCTAssertEqual(queryItems["path"], mediaPath)
        XCTAssertEqual(recorder.requestCount, 1)

        viewModel.cleanupTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoFileURL.path))
        XCTAssertNil(viewModel.videoFileURL)
        XCTAssertFalse(viewModel.canSaveMediaToPhotos)
    }

    func testLoadLocalVideoWithoutSessionIDDoesNotRequestMediaEndpoint() async {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let client = makeClient { request in
            recorder.record(request)
            return self.response(statusCode: 200, data: Data(), for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: "   ",
            reference: .init(rawReference: "/tmp/generated/movie.mov"),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.previewData)
        XCTAssertNil(viewModel.videoFileURL)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(recorder.requestCount, 0)
    }

    func testExtensionlessRemoteMediaFallsBackToVideoFileWhenImageDecodeFails() async throws {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let videoData = Data("video-bytes".utf8)
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.test/media/abc123"))
        let client = makeClient { request in
            recorder.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "public")
            return self.response(statusCode: 200, data: videoData, for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: "session-123",
            reference: .init(rawReference: remoteURL.absoluteString),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertNil(viewModel.previewData)
        let videoFileURL = try XCTUnwrap(viewModel.videoFileURL)
        XCTAssertEqual(videoFileURL.pathExtension, "mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoFileURL.path))
        XCTAssertEqual(try Data(contentsOf: videoFileURL), videoData)
        XCTAssertEqual(viewModel.originalByteCount, videoData.count)
        XCTAssertTrue(viewModel.canSaveVideoToPhotos)
        XCTAssertTrue(viewModel.canSaveMediaToPhotos)
        XCTAssertEqual(recorder.requestCount, 1)

        let payload = try await viewModel.exportPayload()
        XCTAssertEqual(payload.data, videoData)
        XCTAssertEqual(payload.filename, "abc123.mp4")
        XCTAssertEqual(payload.contentType, .mpeg4Movie)
        XCTAssertFalse(payload.isImage)
        XCTAssertTrue(payload.isVideo)

        viewModel.cleanupTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoFileURL.path))
    }

    func testExtensionlessRemoteAudioUsesAudioPreviewInsteadOfVideoFallback() async throws {
        let recorder = TranscriptMediaPreviewRequestRecorder()
        let audioData = Self.wavData()
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.test/media/voice123"))
        let client = makeClient { request in
            recorder.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "public")
            return self.response(statusCode: 200, data: audioData, for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: "session-123",
            reference: .init(rawReference: remoteURL.absoluteString),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertNil(viewModel.previewData)
        XCTAssertNil(viewModel.videoFileURL)
        XCTAssertEqual(viewModel.audioData, audioData)
        XCTAssertEqual(viewModel.originalByteCount, audioData.count)
        XCTAssertFalse(viewModel.canSaveMediaToPhotos)
        XCTAssertTrue(viewModel.canExportMedia)
        XCTAssertEqual(recorder.requestCount, 1)

        let payload = try await viewModel.exportPayload()
        XCTAssertEqual(payload.data, audioData)
        XCTAssertEqual(payload.filename, "voice123.wav")
        XCTAssertEqual(payload.contentType, .wav)
        XCTAssertFalse(payload.isImage)
        XCTAssertFalse(payload.isVideo)
    }

    func testMediaEndpointErrorIsCaptured() async {
        let client = makeClient { request in
            self.response(statusCode: 403, data: Data("forbidden".utf8), for: request)
        }
        let viewModel = TranscriptMediaPreviewViewModel(
            server: Self.baseURL,
            sessionID: "session-123",
            reference: .init(rawReference: "/tmp/forbidden.png"),
            apiClient: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.previewData)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(viewModel.canSaveImageToPhotos)
        XCTAssertFalse(viewModel.canSaveMediaToPhotos)
        XCTAssertFalse(viewModel.canExportMedia)
    }

    private static let baseURL = URL(string: "https://example.test")!

    private func makeClient(
        cookieStorage: HTTPCookieStorage = HTTPCookieStorage(),
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        TranscriptMediaPreviewMockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranscriptMediaPreviewMockURLProtocol.self]
        configuration.httpCookieStorage = cookieStorage
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "authenticated"]
        let session = URLSession(configuration: configuration)

        let publicConfiguration = URLSessionConfiguration.ephemeral
        publicConfiguration.protocolClasses = [TranscriptMediaPreviewMockURLProtocol.self]
        publicConfiguration.httpCookieStorage = nil
        publicConfiguration.httpCookieAcceptPolicy = .never
        publicConfiguration.httpShouldSetCookies = false
        publicConfiguration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "public"]
        let publicSession = URLSession(configuration: publicConfiguration)

        return APIClient(baseURL: Self.baseURL, session: session, publicMediaSession: publicSession)
    }

    private func response(
        statusCode: Int,
        data: Data,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url ?? Self.baseURL,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!,
            data
        )
    }

    private func queryItems(for url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func imageData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

    private static func wavData() -> Data {
        let sampleRate: UInt32 = 8_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = 800
        let dataByteCount = sampleCount * Int(channelCount) * Int(bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8))
        data.appendLittleEndian(channelCount * (bitsPerSample / 8))
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(dataByteCount))
        data.append(Data(repeating: 0, count: dataByteCount))
        return data
    }

    private static func hermesCookie(domain: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: "hermes_session",
            .value: "secret",
            .secure: "TRUE"
        ])
    }
}

private final class TranscriptMediaPreviewRequestRecorder {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var firstURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first?.url
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }
}

private final class TranscriptMediaPreviewMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }
}
