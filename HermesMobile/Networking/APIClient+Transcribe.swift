import Foundation

extension APIClient {
    /// Uploads an audio clip to the server's speech-to-text endpoint and returns
    /// the tolerant `{ok, transcript, error}` payload. Mirrors `uploadFile`'s
    /// multipart shape but sends only the `file` field (no `session_id`).
    ///
    /// The server returns a JSON `{error: ...}` body even for 503/400/413
    /// responses, so we decode the body regardless of status and let the caller
    /// inspect `.error`. Only `401` maps to `.unauthorized`; a non-2xx body that
    /// isn't the expected shape — or carries none of `ok`/`transcript`/`error`,
    /// like a bare `{}` — surfaces as `.http`.
    func transcribeAudio(data: Data, filename: String) async throws -> TranscribeResponse {
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        body.appendMultipart(fileField: "file", filename: filename, data: data, boundary: boundary)
        body.appendMultipartClosingBoundary(boundary)

        // `requiring2xx: false` defers the success-status check: the body may
        // carry the server's error message even on a non-2xx status.
        let (responseData, httpResponse) = try await sendMultipartData(
            endpoint: .transcribe,
            multipartBody: body,
            boundary: boundary,
            requiring2xx: false
        )
        // Decode first: the server returns `{error: ...}` even for 503/400/413, so
        // surfacing `.error` is friendlier than a raw HTTP failure — but only when
        // the body actually carries a signal. All fields are optional, so a bare
        // `{}` (e.g. a generic 500) decodes to all-nil and must fall through to
        // the status check instead of masquerading as success.
        if let decoded = try? decode(TranscribeResponse.self, from: responseData),
           decoded.ok != nil || decoded.transcript != nil || decoded.error != nil {
            return decoded
        }
        try validate(httpResponse, data: responseData)
        return try decode(TranscribeResponse.self, from: responseData)
    }
}
