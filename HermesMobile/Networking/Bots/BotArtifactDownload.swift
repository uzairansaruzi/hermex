import Foundation

/// Native preview downloads are bounded even when the host omits Content-Length.
struct BotArtifactBuffer {
    static let maximumBytes = 25 * 1024 * 1024
    let limit: Int
    private(set) var data = Data()

    init(limit: Int = maximumBytes) { self.limit = limit }

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else { throw BotArtifactFailure.tooLarge }
        data.append(chunk)
    }
}

/// A redirect can point at a login page or another host. Neither is an artifact.
final class BotArtifactRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Reads one artifact from a `HermesREST.downloadArtifact` request, or one `HermesREST.speak`
/// reply, on the session `HermesConnection.authorized` passes in. No webui endpoint or shared
/// URLSession. `limit` caps a preview's bytes; nil reads the whole file, as an export does
/// (#1112). An empty body is a failed read unless `allowsEmpty`, which only a workspace file's
/// Save and Share pass: an empty file is a real file there, but never a real image or speech.
enum BotArtifactDownload {
    static func data(session: URLSession, request: URLRequest,
                     limit: Int? = BotArtifactBuffer.maximumBytes, allowsEmpty: Bool = false) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: BotArtifactRedirectGuard())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw BotArtifactFailure.unavailable }
        guard response.statusCode == 200 else {
            if [401, 403].contains(response.statusCode) { throw BotFailure.rejected(response.statusCode) }
            if response.statusCode == 400, await isFolderRefusal(bytes) { throw BotArtifactFailure.folder }
            throw BotArtifactFailure.unavailable
        }
        if let limit, response.expectedContentLength > Int64(limit) { throw BotArtifactFailure.tooLarge }
        var buffer = BotArtifactBuffer(limit: limit ?? .max)
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count == 64 * 1024 {
                try buffer.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        try buffer.append(chunk)
        guard allowsEmpty || !buffer.data.isEmpty else { throw BotArtifactFailure.unavailable }
        return buffer.data
    }

    /// Whether a 400's body is `fs_download`'s refusal of a folder (`_fs_regular_file` in
    /// `hermes_cli/web_routers/files.py` at the `HERMES_AGENT_TESTED_SHA` pin). Reads at most
    /// 1 KiB; an unreadable body is any other refusal.
    private static func isFolderRefusal(_ bytes: URLSession.AsyncBytes) async -> Bool {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count == 1024 { break }
            }
        } catch { return false }
        return (try? JSONDecoder().decode(BotJSON.self, from: body))?["detail"].text == "Path points to a directory"
    }
}
