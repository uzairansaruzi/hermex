import Foundation

/// JSON body for `POST /api/tts`. Only `text` and `voice` are sent: the server
/// defaults `engine` to `edge` (no API key needed) and `rate`/`pitch` to neutral,
/// and a voice/engine picker is a non-goal of #15. `voice` must always be sent
/// explicitly — the server's own default is `zh-CN-XiaoxiaoNeural`.
struct TTSSynthesisRequest: Encodable {
    let text: String
    let voice: String
}

extension APIClient {
    /// Synthesizes `text` into speech via the server's neural TTS
    /// (`POST /api/tts`, edge engine) and returns the raw audio bytes
    /// (`audio/mpeg` for edge).
    ///
    /// The server fully buffers the response (`Content-Length` is set, not
    /// chunked), so a single-shot `Data` download is correct — no streaming
    /// logic. Reuses `sendData`, which maps 401 → `.unauthorized` and every
    /// other non-2xx to `.http` carrying the server's `{"error": ...}` body
    /// text (400 invalid input, 429 rate limit, 503 missing engine key).
    /// Callers treat any thrown error as "fall back to the on-device
    /// synthesizer" (#15).
    func synthesizeSpeech(text: String, voice: String) async throws -> Data {
        try await sendData(
            endpoint: .tts,
            method: "POST",
            body: TTSSynthesisRequest(text: text, voice: voice)
        )
    }
}
