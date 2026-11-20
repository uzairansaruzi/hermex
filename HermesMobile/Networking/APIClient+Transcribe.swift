import Foundation

extension APIClient {
    nonisolated var dictationTranscriber: ComposerTranscriber {
        { data, filename in
            let reply = try await self.transcribeAudio(data: data, filename: filename)
            guard reply.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return reply }
            return TranscribeResponse(ok: nil, transcript: reply.transcript, error: reply.error)
        }
    }

    func transcribeAudio(data: Data, filename: String) async throws -> TranscribeResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart(fileField: "file", filename: filename, data: data, boundary: boundary)
        body.appendMultipartClosingBoundary(boundary)

        let (responseData, httpResponse) = try await sendMultipart(
            endpoint: .transcribe,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            requireSuccess: false
        )
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
