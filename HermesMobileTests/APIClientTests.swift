import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

class APIClientTestCase: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }

    func makeFilePreviewSession() throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "workspace": "/tmp/workspace"
            }
            """.utf8)
        )
    }
}

final class MockURLProtocol: URLProtocol {
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

final class InMemoryKeychainStore: KeychainStoring {
    private(set) var savedValues: [KeychainStore.Key: String] = [:]
    /// Per-key write count, so tests can assert no redundant writes occur.
    private(set) var saveCounts: [KeychainStore.Key: Int] = [:]
    /// Per-server-scoped storage, keyed by the same "raw::scope" string the real
    /// `KeychainStore` uses, so tests can assert on per-server credential keys (#16).
    private(set) var scopedValues: [String: String] = [:]

    func save(_ value: String, forKey key: KeychainStore.Key) throws {
        savedValues[key] = value
        saveCounts[key, default: 0] += 1
    }

    func load(_ key: KeychainStore.Key) throws -> String? {
        savedValues[key]
    }

    func delete(_ key: KeychainStore.Key) throws {
        savedValues.removeValue(forKey: key)
    }

    func save(_ value: String, forKey key: KeychainStore.Key, scope: String) throws {
        scopedValues[KeychainStore.scopedKey(key, scope: scope)] = value
    }

    func load(_ key: KeychainStore.Key, scope: String) throws -> String? {
        scopedValues[KeychainStore.scopedKey(key, scope: scope)]
    }

    func delete(_ key: KeychainStore.Key, scope: String) throws {
        scopedValues.removeValue(forKey: KeychainStore.scopedKey(key, scope: scope))
    }

    /// Convenience for assertions: the scoped value stored for `key` under `scope`.
    func scopedValue(_ key: KeychainStore.Key, scope: String) -> String? {
        scopedValues[KeychainStore.scopedKey(key, scope: scope)]
    }
}

// Test double: mutable counters are only ever touched serially (each call is
// awaited before the next), so unchecked Sendable conformance is safe here.
final class MockAuthAPIClient: AuthAPIClient, @unchecked Sendable {
    /// How `logout()` should behave, so tests can exercise sign-out against an
    /// unreachable (`fail`) or hung (`hang`) server, not just a happy path.
    enum LogoutBehavior {
        case succeed
        case fail(Error)
        case hang
    }

    private let authStatusResponse: AuthStatusResponse
    private let loginResponse: LoginResponse
    private let logoutBehavior: LogoutBehavior
    private(set) var loginPasswords: [String] = []
    private(set) var logoutCallCount = 0

    init(
        authStatus: AuthStatusResponse,
        loginResponse: LoginResponse = LoginResponse(ok: true, message: nil, error: nil),
        logoutBehavior: LogoutBehavior = .succeed
    ) {
        self.authStatusResponse = authStatus
        self.loginResponse = loginResponse
        self.logoutBehavior = logoutBehavior
    }

    func health() async throws -> HealthResponse {
        HealthResponse(status: "ok", sessions: nil, activeStreams: nil, uptimeSeconds: nil)
    }

    func authStatus() async throws -> AuthStatusResponse {
        authStatusResponse
    }

    func login(password: String) async throws -> LoginResponse {
        loginPasswords.append(password)
        return loginResponse
    }

    func logout() async throws -> LoginResponse {
        logoutCallCount += 1
        switch logoutBehavior {
        case .succeed:
            return LoginResponse(ok: true, message: nil, error: nil)
        case .fail(let error):
            throw error
        case .hang:
            // Block until the caller's timeout cancels this task, mimicking a
            // server that accepts the connection but never responds.
            try await Task.sleep(for: .seconds(3600))
            return LoginResponse(ok: true, message: nil, error: nil)
        }
    }
}

func apiTestJSONResponse(_ json: String, for request: URLRequest, status: Int = 200) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!

    return (response, Data(json.utf8))
}

func apiTestBodyData(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 {
            return nil
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }

    return data
}

func apiTestMultipartFilename(from request: URLRequest) throws -> String {
    let data = try XCTUnwrap(apiTestBodyData(from: request))
    let body = try XCTUnwrap(String(data: data, encoding: .utf8))
    let marker = try XCTUnwrap(body.range(of: "filename=\""))
    let afterMarker = body[marker.upperBound...]
    let end = try XCTUnwrap(afterMarker.firstIndex(of: "\""))
    return String(afterMarker[..<end])
}

func apiTestJSONBody(from request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(apiTestBodyData(from: request))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
