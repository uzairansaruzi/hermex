import XCTest
@testable import HermesMobile

final class APIClientTranscribeTests: APIClientTestCase {
    func testTranscribeAudioSendsMultipartFileFieldAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/transcribe")
            XCTAssertEqual(request.httpMethod, "POST")

            let contentType = request.value(forHTTPHeaderField: "Content-Type")
            XCTAssertNotNil(contentType)
            XCTAssertTrue(contentType?.hasPrefix("multipart/form-data") == true)

            guard let body = apiTestBodyData(from: request) else {
                XCTFail("Missing request body")
                throw URLError(.badServerResponse)
            }

            let bodyString = String(data: body, encoding: .utf8) ?? ""
            XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"file\"; filename=\"voice-note.m4a\""))
            XCTAssertTrue(bodyString.contains("clip-bytes"))
            // Transcribe sends only the file field — no session_id (unlike upload).
            XCTAssertFalse(bodyString.contains("name=\"session_id\""))

            return apiTestJSONResponse("""
            {
              "ok": true,
              "transcript": "hello world"
            }
            """, for: request)
        }

        let response = try await client.transcribeAudio(data: Data("clip-bytes".utf8), filename: "voice-note.m4a")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.transcript, "hello world")
        XCTAssertNil(response.error)
    }

    func testTranscribeAudioDecodesServerErrorBodyOnServiceUnavailable() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"error": "Speech-to-text is unavailable on this server"}"#.utf8)
            return (response, data)
        }

        // A 503 with a JSON error body decodes into `.error` rather than throwing,
        // so the caller can show the server's message and abort cleanly.
        let response = try await client.transcribeAudio(data: Data("x".utf8), filename: "v.m4a")
        XCTAssertEqual(response.error, "Speech-to-text is unavailable on this server")
        XCTAssertNil(response.transcript)
    }

    func testTranscribeAudioMapsUnauthorized() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.transcribeAudio(data: Data("x".utf8), filename: "v.m4a")
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranscribeAudioEmptyBodyOnServerErrorThrowsHTTP() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }

        // All TranscribeResponse fields are optional, so `{}` decodes — but it
        // carries no ok/transcript/error signal, so a non-2xx status must surface
        // as `.http` rather than an all-nil "success".
        do {
            _ = try await client.transcribeAudio(data: Data("x".utf8), filename: "v.m4a")
            XCTFail("Expected APIError.http")
        } catch APIError.http(let statusCode, _) {
            XCTAssertEqual(statusCode, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranscribeAudioWrapsTransportErrorAsNetwork() async {
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.transcribeAudio(data: Data("x".utf8), filename: "v.m4a")
            XCTFail("Expected APIError.network")
        } catch APIError.network(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTranscribeAudioTolerantToUnknownFields() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "ok": true,
              "transcript": "hi",
              "future_field": 42
            }
            """, for: request)
        }

        let response = try await client.transcribeAudio(data: Data("x".utf8), filename: "v.m4a")
        XCTAssertEqual(response.transcript, "hi")
    }
}
