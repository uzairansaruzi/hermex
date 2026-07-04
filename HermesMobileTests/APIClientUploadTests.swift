import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientUploadTests: APIClientTestCase {
    func testUploadFileSendsMultipartAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            XCTAssertEqual(request.httpMethod, "POST")

            let contentType = request.value(forHTTPHeaderField: "Content-Type")
            XCTAssertNotNil(contentType)
            XCTAssertTrue(contentType?.hasPrefix("multipart/form-data") == true)

            guard let body = apiTestBodyData(from: request) else {
                XCTFail("Missing request body")
                throw URLError(.badServerResponse)
            }

            let bodyString = String(data: body, encoding: .utf8) ?? ""
            XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"session_id\""))
            XCTAssertTrue(bodyString.contains("abc123"))
            XCTAssertTrue(bodyString.contains("Content-Disposition: form-data; name=\"file\"; filename=\"test.jpg\""))
            XCTAssertTrue(bodyString.contains("hello"))

            return apiTestJSONResponse("""
            {
              "filename": "test.jpg",
              "path": "/tmp/workspace/test.jpg",
              "size": 5,
              "mime": "image/jpeg",
              "is_image": true
            }
            """, for: request)
        }

        let response = try await client.uploadFile(sessionID: "abc123", data: Data("hello".utf8), filename: "test.jpg")

        XCTAssertEqual(response.filename, "test.jpg")
        XCTAssertEqual(response.path, "/tmp/workspace/test.jpg")
        XCTAssertEqual(response.size, 5)
        XCTAssertEqual(response.mime, "image/jpeg")
        XCTAssertEqual(response.isImage, true)
    }

    func testUploadFileWrapsTransportErrorAsNetwork() async {
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.uploadFile(sessionID: "abc123", data: Data("x".utf8), filename: "f.jpg")
            XCTFail("Expected APIError.network")
        } catch APIError.network(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
