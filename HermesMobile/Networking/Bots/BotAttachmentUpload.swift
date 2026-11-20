import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BotAttachmentFailure: Error, LocalizedError {
    case limit, unreadable
    var errorDescription: String? {
        switch self {
        case .limit: return String(localized: "Use up to 8 attachments, 25 MB each and 50 MB total.")
        case .unreadable: return String(localized: "Could not read this attachment. Remove it and select it again.")
        }
    }
}

struct BotUploadedImage: Equatable {
    let path: String
    let mime: String
}

enum BotAttachmentUpload {
    static let maximumFileBytes = 25 * 1024 * 1024
    static let maximumTotalBytes = 50 * 1024 * 1024

    static func prepare(data: Data, filename: String) throws -> (data: Data, name: String, mime: String, image: Bool) {
        let name = URL(fileURLWithPath: filename).lastPathComponent
        let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? .data
        if type.conforms(to: .image), let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 4096
           ] as CFDictionary) {
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
        return (data, name, type.preferredMIMEType ?? "application/octet-stream", false)
    }

    static func image(data: Data, filename: String, profile: String, via http: HermesConnection,
                      validateDispatch: (@MainActor () throws -> Void)? = nil) async throws -> BotUploadedImage {
        let request = try Self.request(data: data, filename: filename, profile: profile, base: await http.connection.address)
        return try await http.authorized(request, validateDispatch: validateDispatch) { request, session in
            try await Self.send(request, on: session)
        }
    }

    static func request(data: Data, filename: String, profile: String, base: URL) throws -> URLRequest {
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else { throw BotAttachmentFailure.limit }
        return try HermesREST.uploadImage(profile: profile, filename: filename,
                                          dataURL: "data:\(encodedMime(filename));base64," + data.base64EncodedString()).request(base: base)
    }

    static func encodedMime(_ filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
    }

    static func send(_ request: URLRequest, on session: URLSession) async throws -> BotUploadedImage {
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
        let path = try verifiedPath(reply["path"].text)
        let mime = reply["mime_type"].text.flatMap { $0.isEmpty ? nil : $0 } ?? encodedMime(path)
        return BotUploadedImage(path: path, mime: mime)
    }

    static func fileAttach(data: Data, runtime: String, filename: String, mime: String) async -> HermesCall {
        .fileAttach(sessionID: runtime, name: UUID().uuidString + "-" + filename,
                    dataURL: "data:" + mime + ";base64," + data.base64EncodedString())
    }

    static func verifiedPath(_ value: String?) throws -> String {
        guard let value, isHostAbsolute(value), !value.contains("\n"), !value.contains("\r"),
              !value.contains("\0") else { throw BotFailure.unsupported }
        return value
    }

    static func isHostAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") || path.prefixMatch(of: /[A-Za-z]:[\\\/]/) != nil
    }

    static func imageReference(path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        return "[The user attached an image: \(name)]\n"
            + "[Examine it with the vision_analyze tool using image_url: \(path)]"
    }

    static func typedText(of prompt: String) -> String {
        let image = /\[The user attached an image: [^\n]*\]\n\[Examine it with the vision_analyze tool using image_url: (?:\/|[A-Za-z]:[\\\/])[^\n]*\]/
        let file = /@file:[`"']?(?:[^\n]*\/)?[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}-[^\n\/]+/
        var blocks = prompt.components(separatedBy: "\n\n")
        while let last = blocks.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              last.wholeMatch(of: file) != nil || last.wholeMatch(of: image) != nil {
            blocks.removeLast()
        }
        return blocks.joined(separator: "\n\n")
    }
}
