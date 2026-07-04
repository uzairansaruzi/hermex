import Foundation

extension APIClient {
    func uploadFile(sessionID: String, data: Data, filename: String) async throws -> UploadResponse {
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        body.appendMultipart(textField: "session_id", value: sessionID, boundary: boundary)
        body.appendMultipart(fileField: "file", filename: filename, data: data, boundary: boundary)
        body.appendMultipartClosingBoundary(boundary)

        let (responseData, _) = try await sendMultipartData(
            endpoint: .upload,
            multipartBody: body,
            boundary: boundary
        )
        return try decode(UploadResponse.self, from: responseData)
    }
}

