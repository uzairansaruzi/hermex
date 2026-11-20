import Foundation

enum HermesTranscription {
    static let mimeType = "audio/m4a"

    @MainActor static func transcriber(for chat: HermesSessionChat,
                                       connections: HermesConnections? = nil) -> ComposerTranscriber {
        let (saved, server, profile) = (chat.connection, chat.server, chat.target.profile)
        let connections = connections ?? .shared
        return { audio, _ in
            let http = connections.connection(for: saved, server: server)
            let upload = try await Self.request(audio, profile: profile, base: http.connection.address)
            return try Self.response(try await http.reply(upload, deadline: .provisioning))
        }
    }

    private static func request(_ audio: Data, profile: String, base: URL) async throws -> URLRequest {
        try HermesREST.transcribe(profile: profile, dataURL: "data:\(mimeType);base64," + audio.base64EncodedString(),
                                  mimeType: mimeType).request(base: base)
    }

    private static func response(_ reply: (body: Data, status: Int)) throws -> TranscribeResponse {
        let body = try? JSONDecoder().decode(BotJSON.self, from: reply.body)
        switch reply.status {
        case 200..<300:
            return TranscribeResponse(ok: body?["ok"].flag, transcript: body?["transcript"].text, error: nil)
        case 403, 502...504, 520...530: throw BotFailure.rejected(reply.status)
        default:
            if let detail = body?["detail"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                return TranscribeResponse(ok: false, transcript: nil, error: detail)
            }
            throw APIError.http(statusCode: reply.status, body: String(data: reply.body, encoding: .utf8))
        }
    }
}
