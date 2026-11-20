import Foundation

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

final class BotArtifactRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum BotArtifactDownload {
    static func data(session: URLSession, request: URLRequest,
                     limit: Int? = BotArtifactBuffer.maximumBytes, allowsEmpty: Bool = false) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: BotArtifactRedirectGuard())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw BotArtifactFailure.unavailable }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 { throw BotFailure.rejected(401) }
            let detail = [400, 403].contains(response.statusCode) ? await refusalDetail(bytes) : nil
            if response.statusCode == 403, detail == nil { throw BotFailure.rejected(403) }
            if response.statusCode == 400, detail == "Path points to a directory" { throw BotArtifactFailure.folder }
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

    private static func refusalDetail(_ bytes: URLSession.AsyncBytes) async -> String? {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count == 1024 { break }
            }
        } catch { return nil }
        return (try? JSONDecoder().decode(BotJSON.self, from: body))?["detail"].text
    }
}
