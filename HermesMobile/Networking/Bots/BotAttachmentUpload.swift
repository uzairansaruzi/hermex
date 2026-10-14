import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BotAttachmentFailure: Error, LocalizedError {
    case limit, type, unreadable
    var errorDescription: String? {
        switch self {
        case .limit: return String(localized: "Use up to 8 attachments, 25 MB each and 50 MB total.")
        case .type: return String(localized: "This attachment type is not supported. Choose an image, PDF, text, audio or document file.")
        case .unreadable: return String(localized: "Could not read this attachment. Remove it and select it again.")
        }
    }
}

/// Uploading stores bytes only. The returned reference travels in one prompt;
/// no RPC adds an image to the gateway's shared next-prompt queue.
enum BotAttachmentUpload {
    static let maximumFileBytes = 25 * 1024 * 1024
    static let maximumTotalBytes = 50 * 1024 * 1024

    /// A file as Hermes receives it: an image re-encoded as JPEG, or PNG when it has
    /// transparency, at most 4096 px on its longest edge; a PDF, text, audio or common
    /// document as it is. Throws for any other type. Slow on large images, so callers
    /// run it off the main actor.
    static func prepare(data: Data, filename: String) throws -> (data: Data, name: String, mime: String, image: Bool) {
        let name = URL(fileURLWithPath: filename).lastPathComponent
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) else { throw BotAttachmentFailure.type }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else { throw BotAttachmentFailure.unreadable }
            let alpha = image.alphaInfo
            let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst
                || alpha == .premultipliedLast || alpha == .alphaOnly
            let format = hasAlpha ? UTType.png : UTType.jpeg
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { throw BotAttachmentFailure.unreadable }
            let options: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= maximumFileBytes else { throw BotAttachmentFailure.limit }
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return (output as Data, base + (hasAlpha ? ".png" : ".jpg"), hasAlpha ? "image/png" : "image/jpeg", true)
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .audio)
                || ["json", "yaml", "yml", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip"].contains(ext)
        else { throw BotAttachmentFailure.type }
        return (data, name, type.preferredMIMEType ?? "application/octet-stream", false)
    }

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
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else { throw BotAttachmentFailure.limit }
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

    /// A sent prompt without the attachment references a Hermes chat's send
    /// (`HermesChatTurnCoordinator.upload`) appended to it, one `\n\n` block per file: `imageReference`, or
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
