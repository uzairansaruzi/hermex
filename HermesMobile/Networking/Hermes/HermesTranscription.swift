import Foundation

/// Dictation's speech-to-text on a Hermes host (#1071): one `POST /api/audio/transcribe` for
/// the chat's Profile, on the sign-in the server's other Hermes screens share, read as the
/// webui's `TranscribeResponse` so `ComposerVoiceInputController` treats both servers alike.
/// It gets the long deadline: a provider can take more than 15 seconds on a long recording.
enum HermesTranscription {
    /// The controller always records AAC in an m4a container (`serverRecordingFileExtension`),
    /// which the host keeps as `.m4a`.
    static let mimeType = "audio/m4a"

    /// The transcriber a Hermes chat hands its composer: `chat`'s Profile on its saved
    /// connection, looked up in `connections` (the app's shared one when nil) when a
    /// recording is sent.
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

    /// Built off the main actor: a long recording's base64 runs to megabytes.
    private static func request(_ audio: Data, profile: String, base: URL) async throws -> URLRequest {
        try HermesREST.transcribe(profile: profile, dataURL: "data:\(mimeType);base64," + audio.base64EncodedString(),
                                  mimeType: mimeType).request(base: base)
    }

    /// `{ok, transcript}` as it is, so silence stays an empty success. A refusal or provider
    /// failure the host explains in `detail` is the reply's `error`, which Server first falls
    /// back on-device from. Hermes never answers 403, 502-504 or 520-530 itself, so those get
    /// the Hermes connection's copy for the proxy or tunnel in front of it.
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
