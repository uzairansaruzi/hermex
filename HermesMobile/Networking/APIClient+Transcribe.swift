import Foundation

extension APIClient {
    /// Uploads an audio clip to the server's speech-to-text endpoint and returns
    /// the tolerant `{ok, transcript, error}` payload. Mirrors `uploadFile`'s
    /// multipart shape but sends only the `file` field (no `session_id`).
    ///
    /// The server returns a JSON `{error: ...}` body even for 503/400/413
    /// responses, so we decode the body regardless of status and let the caller
    /// inspect `.error`. Only `401` maps to `.unauthorized`; a body that isn't the
    /// expected shape on a non-2xx status surfaces as `.http`.
    func transcribeAudio(data: Data, filename: String) async throws -> TranscribeResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Endpoint.transcribe.url(relativeTo: baseURL))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Custom headers first, then built-ins so the multipart Content-Type
        // always wins. Same reverse proxy requirement as uploadFile (#61).
        customHeaderProvider().apply(to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
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
        // Decode first: the server returns `{error: ...}` even for 503/400/413, so
        // surfacing `.error` is friendlier than a raw HTTP failure. Fall back to a
        // thrown HTTP error only when the body isn't the expected JSON shape.
        if let decoded = try? decode(TranscribeResponse.self, from: responseData) {
            return decoded
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: responseData, encoding: .utf8)
            )
        }
        return try decode(TranscribeResponse.self, from: responseData)
    }
}
