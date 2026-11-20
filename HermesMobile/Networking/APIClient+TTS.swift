import Foundation

enum TTSEngine: String, Encodable {
    case edge, openai, elevenlabs, browser

    init(savedValue: String?) {
        self = savedValue.flatMap {
            Self(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } ?? .edge
    }
}

struct TTSSynthesisRequest: Encodable {
    let text: String
    let voice: String?
    let engine: TTSEngine
}

extension APIClient {
    func synthesizeSpeech(text: String, voice: String?, engine: TTSEngine = .edge) async throws -> Data {
        try await sendData(
            endpoint: .tts,
            method: "POST",
            body: TTSSynthesisRequest(text: text, voice: voice, engine: engine)
        )
    }

    func listenSpeech(for text: String) async throws -> Data? {
        let settings = try? await settings()
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
