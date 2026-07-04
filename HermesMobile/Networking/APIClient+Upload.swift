import Foundation

extension APIClient {
    func uploadFile(sessionID: String, data: Data, filename: String) async throws -> UploadResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Endpoint.upload.url(relativeTo: baseURL))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Custom headers first, then built-ins so the multipart Content-Type
        // always wins. Without them the upload is rejected by auth reverse
        // proxies that every other request path already passes (#61).
        customHeaderProvider().apply(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipart(textField: "session_id", value: sessionID, boundary: boundary)
        body.appendMultipart(fileField: "file", filename: filename, data: data, boundary: boundary)
        body.appendMultipartClosingBoundary(boundary)

        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: responseData, encoding: .utf8)
            )
        }
        return try decode(UploadResponse.self, from: responseData)
    }
}

