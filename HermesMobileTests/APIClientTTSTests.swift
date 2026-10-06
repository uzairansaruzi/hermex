import XCTest
@testable import HermesMobile

final class APIClientTTSTests: APIClientTestCase {
    func testSynthesizeSpeechPostsJSONAndReturnsRawAudioBytes() async throws {
        // Not valid MPEG audio — the client must return the bytes untouched,
        // never attempt to JSON-decode a 2xx TTS response.
        let audioBytes = Data([0xFF, 0xF3, 0x18, 0xC4, 0x00, 0x01])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/tts")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            guard let body = apiTestBodyData(from: request) else {
                XCTFail("Missing request body")
                throw URLError(.badServerResponse)
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["text"] as? String, "Hello from Hermex.")
            // The server defaults to `zh-CN-XiaoxiaoNeural`, so the voice must
            // always be sent explicitly.
            XCTAssertEqual(json["voice"] as? String, "en-US-AriaNeural")
            XCTAssertEqual(json["engine"] as? String, "edge")
            XCTAssertEqual(json.count, 3)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, audioBytes)
        }

        let data = try await client.synthesizeSpeech(text: "Hello from Hermex.", voice: "en-US-AriaNeural")

        XCTAssertEqual(data, audioBytes)
    }

    func testProviderEngineIsExplicitAndAbsentVoiceUsesProviderConfiguration() async throws {
        for engine in [TTSEngine.openai, .elevenlabs] {
            let client = makeClient { request in
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json, ["text": "Hello", "engine": engine.rawValue])
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([1]))
            }
            let audio = try await client.synthesizeSpeech(text: "Hello", voice: nil, engine: engine)
            XCTAssertEqual(audio, Data([1]))
        }
    }

    func testSettingsDecodesTTSPreferencesTolerantly() async throws {
        for (json, engine, voice) in [
            (#"{"tts_engine":"edge","tts_voice":"tr-TR-EmelNeural"}"#, "edge", "tr-TR-EmelNeural"),
            (#"{}"#, nil, nil),
            (#"{"tts_engine":null,"tts_voice":null}"#, nil, nil),
            (#"{"tts_engine":[],"tts_voice":{"future":true}}"#, nil, nil),
            (#"{"tts_engine":12,"tts_voice":false}"#, nil, nil)
        ] as [(String, String?, String?)] {
            let client = makeClient { request in
                XCTAssertEqual(request.url?.path, "/api/settings")
                return apiTestJSONResponse(json, for: request)
            }
            let settings = try await client.settings()
            XCTAssertEqual(settings.ttsEngine, engine)
            XCTAssertEqual(settings.ttsVoice, voice)
        }
    }

    func testSynthesizeSpeechThrowsHTTPCarryingServerErrorBodyOnRateLimit() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error": "rate limit exceeded — please wait"}"#.utf8))
        }

        do {
            _ = try await client.synthesizeSpeech(text: "Too fast.", voice: "en-US-AriaNeural")
            XCTFail("Expected APIError.http")
        } catch let APIError.http(statusCode, body) {
            // The caller treats any thrown error as "fall back to the on-device
            // synthesizer"; the status/body are only for diagnostics.
            XCTAssertEqual(statusCode, 429)
            XCTAssertEqual(body?.contains("rate limit exceeded"), true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSynthesizeSpeechMapsUnauthorized() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.synthesizeSpeech(text: "Hello.", voice: "en-US-AriaNeural")
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

/// Listen's speech from a Hermes host (#1072) over a connected `BotClient`, against a host
/// scripted with the replies `scripts/local-hermes` gave at the pin (0.21.5, ca678285).
@MainActor final class HermesSpeakTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    /// The host's provider picks the format; every format comes back as its bytes.
    func testSpeechIsTheTextSpokenInTheProfilesVoice() async throws {
        let client = try await connectedClient()
        defer { client.close() }
        var sent: URLRequest?
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/audio/speak" else { return nil }
            sent = request
            return .json(200, .object(["ok": .bool(true), "data_url": .string("data:audio/ogg;base64,T2dnUwACAA=="),
                                       "mime_type": .string("audio/ogg"), "provider": .string("openai")]))
        }

        let audio = try await client.speech(text: "Hi there.", profile: "research")

        XCTAssertEqual(audio, Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00]))
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.url?.query, "profile=research")
        XCTAssertEqual(try sent.flatMap(apiTestBodyData).map { try JSONDecoder().decode(BotJSON.self, from: $0) },
                       .object(["text": .string("Hi there.")]), "The host takes no voice, engine or rate")
    }

    func testARefusalOrAnUnreadableReplyThrows() async throws {
        let client = try await connectedClient()
        defer { client.close() }
        let refusals: [(String, HermesHostFixture.Reply)] = [
            ("empty text", .json(400, .object(["detail": .string("Text is required")]))),
            ("provider failure", .json(500, .object(["detail": .string("Speech synthesis failed")])))
        ]
        let unreadable: [(String, String?)] = [
            ("not base64", "data:audio/mpeg;base64,not*base64"),
            ("not base64-encoded", "data:audio/mpeg,T2dnUw=="),
            ("not a data URL", "https://hermes.example/speech.mp3"),
            ("no audio", "data:audio/mpeg;base64,"),
            ("no data_url", nil)
        ]
        let replies: [(String, HermesHostFixture.Reply)] = refusals + unreadable.map { label, url in
            var body: [String: BotJSON] = ["ok": .bool(true)]
            body["data_url"] = url.map(BotJSON.string)
            return (label, .json(200, .object(body)))
        }
        for (label, reply) in replies {
            _ = HermesHostFixture.configuration { $0.url?.path == "/api/audio/speak" ? reply : nil }
            do {
                _ = try await client.speech(text: "Hi.", profile: "research")
                XCTFail("\(label): expected a throw")
            } catch {
                if refusals.contains(where: { $0.0 == label }) {
                    XCTAssertEqual(error as? BotArtifactFailure, .unavailable, label)
                } else {
                    XCTAssertEqual(error as? BotFailure, .unsupported, label)
                }
            }
        }
    }

    private func connectedClient() async throws -> BotClient {
        let client = BotClient(http: BotSocketHost().connection(record))
        try await client.connect()
        return client
    }
}
