import XCTest
@testable import HermexCore

final class HermexAPIClientTests: XCTestCase {
    func testLoginBuildsPostRequestWithoutOriginOrReferer() async throws {
        let transport = RecordingTransport(json: #"{"ok":true}"#)
        let client = try makeClient(transport: transport, customHeaders: {
            [
                HermexCustomHeader(name: "Origin", value: "https://evil.test"),
                HermexCustomHeader(name: "Referer", value: "https://evil.test/path"),
                HermexCustomHeader(name: "X-Proxy-Token", value: " token ")
            ]
        })

        _ = try await client.login(password: "secret")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Proxy-Token"), "token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try jsonObject(from: request)["password"] as? String, "secret")
    }

    func testGitDiffUsesQueryItemsFromSharedEndpoint() async throws {
        let transport = RecordingTransport(json: #"{"files":[]}"#)
        let client = try makeClient(transport: transport)

        _ = try await client.gitDiff(sessionID: "s1", path: "Sources/App.swift", kind: "staged")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/git/diff")
        XCTAssertEqual(queryItems(for: request), [
            "kind": "staged",
            "path": "Sources/App.swift",
            "session_id": "s1"
        ])
    }

    func testChatStartBodyMatchesMobileContract() async throws {
        let transport = RecordingTransport(json: #"{"stream_id":"stream-1"}"#)
        let client = try makeClient(transport: transport)

        _ = try await client.chatStart(
            sessionID: "s1",
            message: "Hello",
            workspace: "Home",
            model: "gpt-5.5",
            modelProvider: "codex",
            profile: "default",
            explicitModelPick: true
        )

        let body = try jsonObject(from: try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["message"] as? String, "Hello")
        XCTAssertEqual(body["workspace"] as? String, "Home")
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["model_provider"] as? String, "codex")
        XCTAssertEqual(body["profile"] as? String, "default")
        XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)
    }

    func testTtsUsesAudioAcceptHeader() async throws {
        let transport = RecordingTransport(data: Data([0x01, 0x02]), statusCode: 200)
        let client = try makeClient(transport: transport)

        let data = try await client.synthesizeSpeech(text: "Hello", voice: "en-US-AriaNeural")

        XCTAssertEqual(data, Data([0x01, 0x02]))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/tts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "audio/mpeg")
        XCTAssertEqual(try jsonObject(from: request)["voice"] as? String, "en-US-AriaNeural")
    }

    func testUploadUsesMultipartContract() async throws {
        let transport = RecordingTransport(json: #"{"filename":"note.txt","path":"/tmp/note.txt"}"#)
        let client = try makeClient(transport: transport)

        let response = try await client.uploadFile(
            sessionID: "s1",
            data: Data("hello".utf8),
            filename: "note.txt",
            contentType: "text/plain"
        )

        XCTAssertEqual(response.filename, "note.txt")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/upload")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Boundary-") == true)
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertTrue(body?.contains("name=\"session_id\"") == true)
        XCTAssertTrue(body?.contains("s1") == true)
        XCTAssertTrue(body?.contains("name=\"file\"; filename=\"note.txt\"") == true)
        XCTAssertTrue(body?.contains("Content-Type: text/plain") == true)
        XCTAssertTrue(body?.contains("hello") == true)
    }

    func testTranscribeDecodesErrorJsonOnNonSuccessStatus() async throws {
        let transport = RecordingTransport(json: #"{"error":"speech-to-text disabled"}"#, statusCode: 503)
        let client = try makeClient(transport: transport)

        let response = try await client.transcribeAudio(data: Data([0x00]), filename: "voice.m4a", contentType: "audio/mp4")

        XCTAssertEqual(response.error, "speech-to-text disabled")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/transcribe")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
    }

    func testUnauthorizedStatusMapsToSharedError() async throws {
        let transport = RecordingTransport(json: #"{"error":"unauthorized"}"#, statusCode: 401)
        let client = try makeClient(transport: transport)

        do {
            _ = try await client.health()
            XCTFail("Expected unauthorized error")
        } catch HermexAPIError.unauthorized {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(
        transport: RecordingTransport,
        customHeaders: @escaping @Sendable () -> [HermexCustomHeader] = { [] }
    ) throws -> HermexAPIClient {
        HermexAPIClient(
            baseURL: try XCTUnwrap(URL(string: "https://example.test/root")),
            transport: transport,
            customHeaders: customHeaders
        )
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func queryItems(for request: URLRequest) -> [String: String] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { result, item in
                result[item.name] = item.value
            } ?? [:]
    }
}

private final class RecordingTransport: HermexHTTPTransport, @unchecked Sendable {
    private let data: Data
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(json: String, statusCode: Int = 200) {
        self.data = Data(json.utf8)
        self.statusCode = statusCode
    }

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}
