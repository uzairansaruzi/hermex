import XCTest
@testable import HermesMobile

/// Dictation on a Hermes host (#1071): a Hermes chat's transcriber against a scripted host.
/// The refusals are the shapes `scripts/local-hermes` answered at the pin (0.21.5, ca678285);
/// the success shape is read from the route at the same pin.
@MainActor final class HermesTranscribeTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testOneJSONUploadForTheChatsProfileCarriesTheRecording() async throws {
        let (transcribe, _) = transcriber { request in
            request.url?.path == "/api/audio/transcribe"
                ? .json(200, .object(["ok": .bool(true), "transcript": .string("Ship it"), "provider": .string("local")]))
                : nil
        }

        let reply = try await transcribe(Data("m4a-bytes".utf8), "dictation.m4a")

        XCTAssertEqual(reply.transcript, "Ship it")
        XCTAssertNil(reply.error)
        let uploads = HermesHostFixture.requests.filter { $0.url?.path == "/api/audio/transcribe" }
        XCTAssertEqual(uploads.count, 1)
        let upload = try XCTUnwrap(uploads.first)
        XCTAssertEqual(upload.httpMethod, "POST")
        XCTAssertEqual(upload.url?.query, "profile=research")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(HermesCronFixture.body(upload), .object([
            "data_url": .string("data:audio/m4a;base64,bTRhLWJ5dGVz"), "mime_type": .string("audio/m4a")
        ]))
        XCTAssertEqual(HermesHostFixture.count("/api/transcribe"), 0, "Never the webui's route")
    }

    func testTheUploadWaitsOnTheLongDeadline() async throws {
        let parked = expectation(description: "Upload in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        let (transcribe, connections) = transcriber { request in
            request.url?.path == "/api/audio/transcribe" ? .park : nil
        }

        let running = Task { try await transcribe(Data("clip".utf8), "dictation.m4a") }
        await fulfillment(of: [parked], timeout: 2)
        let http = connections.connection(for: record, server: server)
        let onStandard = await http.session.allTasks.contains { $0.originalRequest?.url?.path == "/api/audio/transcribe" }
        let onLong = await http.provisioningSession.allTasks.contains { $0.originalRequest?.url?.path == "/api/audio/transcribe" }
        HermesHostFixture.releaseParked(.json(200, .object(["ok": .bool(true), "transcript": .string("done")])))
        _ = try await running.value

        XCTAssertEqual([onStandard, onLong], [false, true])
    }

    /// The host's own silence: the controller inserts nothing and shows no error.
    func testSilenceIsAnEmptySuccess() async throws {
        let (transcribe, _) = transcriber { request in
            request.url?.path == "/api/audio/transcribe"
                ? .json(200, .object(["ok": .bool(true), "transcript": .string(""), "provider": .null]))
                : nil
        }

        let reply = try await transcribe(Data("quiet".utf8), "dictation.m4a")

        XCTAssertEqual(reply.ok, true)
        XCTAssertEqual(reply.transcript, "")
        XCTAssertNil(reply.error)
    }

    func testTheHostsDetailBecomesTheError() async throws {
        let refusals: [(status: Int, detail: String)] = [
            (400, "Local transcription failed: Unable to download faster-whisper model 'base'"),
            (404, "Profile 'research' does not exist."),
            (500, "Transcription failed: boom")
        ]
        for refusal in refusals {
            HermesHostFixture.reset()
            let (transcribe, _) = transcriber { request in
                request.url?.path == "/api/audio/transcribe"
                    ? .json(refusal.status, .object(["detail": .string(refusal.detail)]))
                    : nil
            }

            let reply = try await transcribe(Data("clip".utf8), "dictation.m4a")

            XCTAssertEqual(reply.ok, false, "\(refusal.status)")
            XCTAssertNil(reply.transcript, "\(refusal.status)")
            XCTAssertEqual(reply.error, refusal.detail)
        }
    }

    /// A slow transcription a Cloudflare tunnel gave up on reads as the tunnel's failure.
    func testATunnelTimeoutThrowsTheConnectionsCopy() async {
        let (transcribe, _) = transcriber { request in
            request.url?.path == "/api/audio/transcribe" ? .json(524, .string("A timeout occurred")) : nil
        }

        do {
            _ = try await transcribe(Data("clip".utf8), "dictation.m4a")
            XCTFail("A 524 is no transcript")
        } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(524))
        }
    }

    /// A Hermes chat on the `research` Profile, with its own connection registry over the scripted host.
    private func transcriber(_ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> (ComposerTranscriber, HermesConnections) {
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration(script) })
        let chat = HermesSessionChat(server: server, connection: record,
                                     target: .session(profile: "research", key: "20261006_120000_abc123"))
        return (HermesTranscription.transcriber(for: chat, connections: connections), connections)
    }
}
