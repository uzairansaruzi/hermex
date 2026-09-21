import Foundation

/// Uploading stores bytes only. The returned reference travels in one prompt;
/// no RPC adds an image to the gateway's shared next-prompt queue.
enum BotAttachmentUpload {
    static func image(session: URLSession, base: URL, data: Data, filename: String, profile: String) async throws -> String {
        guard !data.isEmpty, data.count <= BotAttachmentDraft.maximumFileBytes else { throw BotAttachmentFailure.limit }
        guard var parts = URLComponents(url: BotEndpoint.imageUpload.url(base: base), resolvingAgainstBaseURL: false),
              !profile.isEmpty else { throw BotFailure.invalidAddress }
        parts.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let mime = URL(fileURLWithPath: filename).pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        request.httpBody = try JSONEncoder().encode(BotJSON.object([
            "filename": .string(filename), "data_url": .string("data:\(mime);base64," + data.base64EncodedString())
        ]))
        let (bytes, response) = try await session.bytes(for: request, delegate: BotArtifactRedirectGuard())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw BotFailure.transport }
        guard response.statusCode == 200 else { throw BotFailure.rejected(response.statusCode) }
        var body = Data()
        for try await byte in bytes {
            guard body.count < 64 * 1024 else { throw BotFailure.unsupported }
            body.append(byte)
        }
        let reply = try JSONDecoder().decode(BotJSON.self, from: body)
        guard reply["ok"].flag == true else { throw BotFailure.unsupported }
        return try verifiedPath(reply["path"].text)
    }

    static func fileParams(data: Data, runtime: String, filename: String, mime: String) async -> [String: BotJSON] {
        ["session_id": .string(runtime), "name": .string(UUID().uuidString + "-" + filename),
         "data_url": .string("data:" + mime + ";base64," + data.base64EncodedString())]
    }

    static func verifiedPath(_ value: String?) throws -> String {
        guard let value, value.hasPrefix("/"), !value.contains("\n"), !value.contains("\r"),
              !value.contains("\0") else { throw BotFailure.unsupported }
        return value
    }

    /// Matches Hermes's text-mode image routing: let the agent call its vision tool.
    static func imageReference(path: String) -> String {
        "[The user attached an image: \(URL(fileURLWithPath: path).lastPathComponent)]\n"
            + "[Examine it with the vision_analyze tool using image_url: \(path)]"
    }
}
