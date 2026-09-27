import Foundation

/// Uploading stores bytes only. The returned reference travels in one prompt;
/// no RPC adds an image to the gateway's shared next-prompt queue.
enum BotAttachmentUpload {
    static func image(session: URLSession, base: URL, data: Data, filename: String, profile: String) async throws -> String {
        guard !data.isEmpty, data.count <= BotAttachmentDraft.maximumFileBytes else { throw BotAttachmentFailure.limit }
        let mime = URL(fileURLWithPath: filename).pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        let request = try HermesREST.uploadImage(profile: profile, filename: filename,
                                                 dataURL: "data:\(mime);base64," + data.base64EncodedString()).request(base: base)
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

    /// Builds `file.attach` off the main actor: base64 of a large file is slow.
    static func fileAttach(data: Data, runtime: String, filename: String, mime: String) async -> HermesCall {
        .fileAttach(sessionID: runtime, name: UUID().uuidString + "-" + filename,
                    dataURL: "data:" + mime + ";base64," + data.base64EncodedString())
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
