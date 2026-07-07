import Foundation

extension APIClient {
    func transcriptMediaData(for reference: TranscriptMediaReference, sessionID: String) async throws -> Data {
        switch reference.source {
        case let .localPath(path):
            return try await mediaData(sessionID: sessionID, path: path)
        case let .remoteURL(url):
            return try await remoteTranscriptMediaData(from: url)
        }
    }
}
