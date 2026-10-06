import Foundation

/// Tolerant response for `POST /api/transcribe` (server speech-to-text).
///
/// The server returns `{ok, transcript}` on success and `{error}` on failure —
/// and it sends a JSON `{error: ...}` body even with a non-2xx status (e.g. 503
/// when STT isn't configured). Every field is optional and unknown keys are
/// ignored, so a future server addition never crashes decoding. A Hermes host's
/// `/api/audio/transcribe` reply is read into the same shape (`HermesTranscription`).
struct TranscribeResponse: Codable {
    let ok: Bool?
    let transcript: String?
    let error: String?
}
