import Foundation

/// Server-supported engines; browser speech is performed on-device.
enum TTSEngine: String, Encodable {
    case edge, openai, elevenlabs, browser

    init(savedValue: String?) {
        self = savedValue.flatMap {
            Self(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } ?? .edge
    }
}

/// Send the engine explicitly for older servers. Non-Edge providers resolve
/// their voice from the server's provider configuration, not the Edge voice setting.
struct TTSSynthesisRequest: Encodable {
    let text: String
    let voice: String?
    let engine: TTSEngine
}

extension APIClient {
    /// Synthesizes `text` into speech via the server's neural TTS
    /// (`POST /api/tts`) and returns the raw audio bytes
    /// (`audio/mpeg` for edge).
    ///
    /// The server fully buffers the response (`Content-Length` is set, not
    /// chunked), so a single-shot `Data` download is correct — no streaming
    /// logic. Reuses `sendData`, which maps 401 → `.unauthorized` and every
    /// other non-2xx to `.http` carrying the server's `{"error": ...}` body
    /// text (400 invalid input, 429 rate limit, 503 missing engine key).
    /// Callers treat any thrown error as "fall back to the on-device
    /// synthesizer" (#15).
    func synthesizeSpeech(text: String, voice: String?, engine: TTSEngine = .edge) async throws -> Data {
        try await sendData(
            endpoint: .tts,
            method: "POST",
            body: TTSSynthesisRequest(text: text, voice: voice, engine: engine)
        )
    }

    /// Listen's speech on a webui server: the saved engine and voice, read from
    /// `/api/settings` for every Listen so a preference never outlives the request or
    /// crosses servers, then `/api/tts`. Nil when the saved engine is the browser's, which
    /// speaks on device. A missing or failed settings read means Edge and the default voice.
    func listenSpeech(for text: String) async throws -> Data? {
        let settings = try? await settings()
        // Stopped or superseded while settings were pending: `/api/tts` is never sent.
        try Task.checkCancellation()
        let engine = TTSEngine(savedValue: settings?.ttsEngine)
        guard engine != .browser else { return nil }
        let savedVoice = settings?.ttsVoice?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = engine == .edge
            ? (savedVoice?.isEmpty == false ? savedVoice : ServerTTSPolicy.defaultVoice)
            : nil
        return try await synthesizeSpeech(text: text, voice: voice, engine: engine)
    }
}
