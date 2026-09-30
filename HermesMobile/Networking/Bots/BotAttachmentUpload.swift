import Foundation

/// Uploading stores bytes only. The returned reference travels in one prompt;
/// no RPC adds an image to the gateway's shared next-prompt queue.
enum BotAttachmentUpload {
    /// Stores one image over `http`'s signed-in session. Being nonisolated and async, it
    /// builds the base64 body off the main actor. `validateDispatch` is as in
    /// `HermesConnection.authorized`.
    static func image(data: Data, filename: String, profile: String, via http: HermesConnection,
                      validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> String {
        let request = try Self.request(data: data, filename: filename, profile: profile, base: await http.connection.address)
        return try await http.authorized(request, validateDispatch: validateDispatch) { request, session in
            try await Self.send(request, on: session)
        }
    }

    static func request(data: Data, filename: String, profile: String, base: URL) throws -> URLRequest {
        guard !data.isEmpty, data.count <= BotAttachmentDraft.maximumFileBytes else { throw BotAttachmentFailure.limit }
        let mime = URL(fileURLWithPath: filename).pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        return try HermesREST.uploadImage(profile: profile, filename: filename,
                                          dataURL: "data:\(mime);base64," + data.base64EncodedString()).request(base: base)
    }

    /// Sends one upload and returns the verified stored path. Redirects are refused.
    static func send(_ request: URLRequest, on session: URLSession) async throws -> String {
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

    /// A sent prompt without the references `BotConversation.attachmentPrompt`
    /// appended to it, one `\n\n` block per file: `imageReference`, or
    /// `file.attach`'s one-line `@file:` ref, whose file name keeps the UUID
    /// prefix `fileAttach` gave it. What is left is what the user typed, which
    /// is what ↑ recalls; an attachment-only prompt comes back empty. A typed
    /// `@file:` line has no such prefix, so it stays.
    static func typedText(of prompt: String) -> String {
        let image = /\[The user attached an image: [^\n]*\]\n\[Examine it with the vision_analyze tool using image_url: \/[^\n]*\]/
        let file = /@file:[`"']?(?:[^\n]*\/)?[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}-[^\n\/]+/
        var blocks = prompt.components(separatedBy: "\n\n")
        while let last = blocks.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              last.wholeMatch(of: file) != nil || last.wholeMatch(of: image) != nil {
            blocks.removeLast()
        }
        return blocks.joined(separator: "\n\n")
    }
}
