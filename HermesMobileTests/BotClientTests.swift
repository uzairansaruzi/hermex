import XCTest
@testable import HermesMobile

@MainActor final class BotClientTests: XCTestCase {
    override func tearDown() {
        BotHTTPFixture.handler = nil
        super.tearDown()
    }

    func testPasswordGateIdentityAndFreshTicketsUseTextRPCOnEverySocket() async throws {
        var tickets = 0
        var paths: [String] = []
        BotHTTPFixture.handler = { request in
            let path = request.url!.path
            paths.append(path)
            switch path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login":
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, .object(["ok": .bool(true)]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic"), "future": .array([])]))
            case "/api/auth/ws-ticket":
                tickets += 1
                return (200, .object(["ticket": .string("ticket-\(tickets)")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        var protocols: [[String]] = []
        var sockets: [BotScriptedSocket] = []
        let client = BotClient(connection: connection(), configuration: configuration) { url, names in
            XCTAssertEqual(url.scheme, "wss")
            XCTAssertEqual(url.path, "/api/ws")
            XCTAssertNil(url.query)
            protocols.append(names)
            let socket = BotScriptedSocket()
            sockets.append(socket)
            return socket
        }
        for _ in 0..<2 {
            try await client.connect()
            let roster = try await client.call("profiles.list", [:])
            XCTAssertEqual(roster["profiles"].list, [])
            do {
                _ = try await client.call("session.interrupt", ["session_id": .string("runtime")]) { throw BotFailure.stale }
                XCTFail("A stale action must not dispatch")
            } catch { XCTAssertEqual(error as? BotFailure, .stale) }
            client.close()
        }
        XCTAssertEqual(tickets, 2)
        XCTAssertEqual(protocols, [["hermes-gateway-v1", "hermes-gateway-ticket.ticket-1"], ["hermes-gateway-v1", "hermes-gateway-ticket.ticket-2"]])
        XCTAssertEqual(paths.filter { $0 == "/api/auth/me" }.count, 2)
        XCTAssertEqual(sockets.map { $0.sentTextFrames }, [1, 1])
    }

    func testMissingPasswordGateFailsBeforeCredentialsOrSocket() async {
        BotHTTPFixture.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/status")
            return (200, .object(["auth_required": .bool(false)]))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in
            XCTFail("Must not open a socket")
            return BotScriptedSocket()
        }
        do { try await client.connect(); XCTFail("Expected unsupported gate") }
        catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        client.close()
    }

    func testExpiredIdentityStopsBeforeTicket() async {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (401, .object([:]))
            default: XCTFail("Must not request a ticket"); return (500, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration)
        do { try await client.connect(); XCTFail("Expected expired identity") }
        catch { XCTAssertEqual(error as? BotFailure, .rejected(401)) }
        client.close()
    }

    private func connection() -> BotConnection {
        BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://hermes.example")!, username: "user", password: "fixture")
    }
}

private final class BotHTTPFixture: URLProtocol {
    static var handler: ((URLRequest) -> (Int, BotJSON))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: BotFailure.transport); return }
        let (status, value) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Lock ownership protects the queued scripted frames and exactly one waiting reader.
private final class BotScriptedSocket: BotSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [URLSessionWebSocketTask.Message] = [
        .string(#"{"method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"epoch"}}}"#)
    ]
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var closed = false
    private(set) var sentTextFrames = 0
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: BotFailure.transport) }
            else if !frames.isEmpty { let frame = frames.removeFirst(); lock.unlock(); continuation.resume(returning: frame) }
            else { waiter = continuation; lock.unlock() }
        }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { XCTFail("JSON-RPC must use text frames"); throw BotFailure.unsupported }
        let request = try JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))
        let response = BotJSON.object(["id": request["id"], "result": .object(["profiles": .array([])])])
        let frame = URLSessionWebSocketTask.Message.string(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
        enqueue(frame)
    }
    private func enqueue(_ frame: URLSessionWebSocketTask.Message) {
        lock.lock(); sentTextFrames += 1
        let waiting = waiter; waiter = nil
        if waiting == nil { frames.append(frame) }
        lock.unlock()
        waiting?.resume(returning: frame)
    }
    func cancel() {
        lock.lock(); closed = true
        let waiting = waiter; waiter = nil
        lock.unlock()
        waiting?.resume(throwing: BotFailure.transport)
    }
}
