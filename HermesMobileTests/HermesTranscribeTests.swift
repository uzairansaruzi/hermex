import XCTest
@testable import HermesMobile

@MainActor final class HermesTranscribeTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")


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

    private func transcriber(_ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> (ComposerTranscriber, HermesConnections) {
        let connections = HermesConnections(configuration: { HermesHostFixture.configuration(script) })
        let chat = HermesSessionChat(server: server, connection: record,
                                     target: .session(profile: "research", key: "20261006_120000_abc123"))
        return (HermesTranscription.transcriber(for: chat, connections: connections), connections)
    }
}
