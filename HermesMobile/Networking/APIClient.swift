import Foundation

actor APIClient {
    let baseURL: URL
    let session: URLSession
    let publicMediaSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let customHeaderProvider: @Sendable () -> [CustomHeader]

    init(
        baseURL: URL,
        session: URLSession? = nil,
        publicMediaSession: URLSession? = nil,
        customHeaderProvider: @escaping @Sendable () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() }
    ) {
        self.baseURL = baseURL
        self.customHeaderProvider = customHeaderProvider

        self.session = session ?? Self.sharedSession
        self.publicMediaSession = publicMediaSession ?? Self.sharedPublicMediaSession

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func health() async throws -> HealthResponse {
        try await send(endpoint: .health, method: "GET")
    }

    func authStatus() async throws -> AuthStatusResponse {
        try await send(endpoint: .authStatus, method: "GET")
    }

    func login(password: String) async throws -> LoginResponse {
        try await send(
            endpoint: .login,
            method: "POST",
            body: LoginRequest(password: password)
        )
    }

    func logout() async throws -> LoginResponse {
        try await send(endpoint: .logout, method: "POST", body: EmptyBody())
    }

    func send<Response: Decodable>(
        endpoint: Endpoint,
        method: String,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let data = try await sendData(endpoint: endpoint, method: method, encodedBody: nil, timeout: timeout)
        return try decode(Response.self, from: data)
    }

    func send<Response: Decodable, Body: Encodable>(
        endpoint: Endpoint,
        method: String,
        body: Body?,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let encodedBody = try body.map { try encoder.encode($0) }
        let data = try await sendData(endpoint: endpoint, method: method, encodedBody: encodedBody, timeout: timeout)
        return try decode(Response.self, from: data)
    }

    func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    func sendData(
        endpoint: Endpoint,
        method: String
    ) async throws -> Data {
        try await sendData(endpoint: endpoint, method: method, encodedBody: nil)
    }

    func sendData<Body: Encodable>(
        endpoint: Endpoint,
        method: String,
        body: Body?
    ) async throws -> Data {
        let encodedBody = try body.map { try encoder.encode($0) }
        return try await sendData(endpoint: endpoint, method: method, encodedBody: encodedBody)
    }

    func sendData(
        endpoint: Endpoint,
        method: String,
        encodedBody: Data?,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        try await sendDataReturningResponse(
            endpoint: endpoint,
            method: method,
            encodedBody: encodedBody,
            timeout: timeout
        ).0
    }

    func sendDataReturningResponse(
        endpoint: Endpoint,
        method: String,
        encodedBody: Data?,
        timeout: TimeInterval? = nil,
        accept: String = "application/json"
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.url(relativeTo: baseURL))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeout { request.timeoutInterval = timeout }
        let redirectGuard = applyCustomHeaders(to: &request)
        request.setValue(accept, forHTTPHeaderField: "Accept")

        if let encodedBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encodedBody
        }

        return try await sendPreparedRequest(request, redirectGuard: redirectGuard)
    }

    func sendBoundedData(endpoint: Endpoint, limit: Int) async throws -> Data {
        var request = URLRequest(url: endpoint.url(relativeTo: baseURL))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let redirectGuard = applyCustomHeaders(to: &request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        } catch {
            throw APIError.network(underlying: error)
        }
        defer { bytes.task.cancel() }

        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode),
           httpResponse.expectedContentLength > Int64(limit) {
            throw BotArtifactFailure.tooLarge
        }

        var buffer = BotArtifactBuffer(limit: limit)
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    try Task.checkCancellation()
                    try buffer.append(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
        } catch let error where !(error is BotArtifactFailure || error is CancellationError) {
            throw APIError.network(underlying: error)
        }
        try buffer.append(chunk)

        return try Self.mappedHTTPResponse(data: buffer.data, response: response, requireSuccess: true).0
    }

    func sendMultipart(
        endpoint: Endpoint,
        body: Data,
        contentType: String,
        requireSuccess: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.url(relativeTo: baseURL))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let redirectGuard = applyCustomHeaders(to: &request)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await sendPreparedRequest(request, redirectGuard: redirectGuard, requireSuccess: requireSuccess)
    }

    private func applyCustomHeaders(to request: inout URLRequest) -> CrossOriginHeaderStripper {
        let headers = customHeaderProvider()
        headers.apply(to: &request)
        return CrossOriginHeaderStripper(baseURL: baseURL, sentHeaders: headers)
    }

    private func sendPreparedRequest(
        _ request: URLRequest,
        redirectGuard: CrossOriginHeaderStripper,
        requireSuccess: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: redirectGuard)
        } catch {
            throw APIError.network(underlying: error)
        }

        return try Self.mappedHTTPResponse(
            data: data,
            response: response,
            requireSuccess: requireSuccess
        )
    }

    private static func mappedHTTPResponse(
        data: Data,
        response: URLResponse,
        requireSuccess: Bool
    ) throws -> (Data, HTTPURLResponse) {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        if requireSuccess {
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw APIError.http(
                    statusCode: httpResponse.statusCode,
                    body: String(data: data, encoding: .utf8)
                )
            }
        }

        return (data, httpResponse)
    }

    func downloadData(
        from url: URL,
        using session: URLSession,
        mapsUnauthorized: Bool
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let redirectGuard = Self.isSameOrigin(url, as: baseURL)
            ? applyCustomHeaders(to: &request)
            : CrossOriginHeaderStripper(baseURL: baseURL, sentHeaders: [])
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: redirectGuard)
        } catch {
            throw APIError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }

        if mapsUnauthorized && httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }

        return data
    }

    static func isSameOrigin(_ url: URL, as baseURL: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let baseScheme = baseURL.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased()
        else {
            return false
        }

        return scheme == baseScheme
            && host == baseHost
            && normalizedPort(for: url) == normalizedPort(for: baseURL)
    }

    private static func normalizedPort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }

        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

extension APIClient {
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }()

    static let sharedPublicMediaSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
}

private struct LoginRequest: Encodable {
    let password: String
}

private struct EmptyBody: Encodable {}

final class CrossOriginHeaderStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let sentHeaderNames: Set<String>

    init(baseURL: URL, sentHeaders: [CustomHeader]) {
        self.baseURL = baseURL
        sentHeaderNames = Set(sentHeaders.filter(\.isApplicable).map { $0.sanitizedName.lowercased() })
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              !APIClient.isSameOrigin(destination, as: baseURL) else {
            completionHandler(request)
            return
        }

        guard ["GET", "HEAD"].contains(request.httpMethod?.uppercased() ?? "GET") else {
            completionHandler(nil)
            return
        }

        guard !sentHeaderNames.isEmpty, let fields = request.allHTTPHeaderFields else {
            completionHandler(request)
            return
        }

        var sanitized = request
        for name in fields.keys where sentHeaderNames.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        completionHandler(sanitized)
    }
}
