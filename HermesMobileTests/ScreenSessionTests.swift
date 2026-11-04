import CoreGraphics
import XCTest
@testable import HermesMobile

/// The Screen's states over a scripted gateway and stream socket.
@MainActor final class ScreenSessionTests: XCTestCase {
    private let host = BotSocketHost()
    private var sockets: [ScriptedRFBSocket] = []
    private var upgrades: [URLRequest] = []

    private func makeSession(backoff: [Duration] = [.zero]) -> ScreenSession {
        let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "u", password: "p")
        var options = ScreenSession.Options()
        options.backoff = backoff
        options.socketFactory = { [unowned self] upgrade in
            upgrades.append(upgrade)
            let socket = ScriptedRFBSocket()
            sockets.append(socket)
            return socket
        }
        return ScreenSession(profile: "work", client: BotClient(http: host.connection(record)), options: options)
    }

    private func screen(running: Bool = true, supported: Bool = true) -> BotJSON {
        .object([
            "supported": .bool(supported), "running": .bool(running), "ticket": .string("ticket-1"),
            "viewer_id": .string("viewer"), "lease": .object(["holder": .string("agent")]),
            "some_future_field": .bool(true)
        ])
    }

    private func reach(_ phase: ScreenSession.Phase, on session: ScreenSession) async {
        while session.phase != phase {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = session.phase } onChange: { continuation.resume() }
            }
        }
    }

    private func socket(_ index: Int) async -> ScriptedRFBSocket {
        while sockets.count <= index { await Task.yield() }
        return sockets[index]
    }

    func testARunningScreenStreamsOnATicketAndPutsFramesOnTheStore() async throws {
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(result: screen()))
        let session = makeSession()
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        let image = try XCTUnwrap(session.frames.image)
        XCTAssertEqual(image.width, 2)
        let url = try XCTUnwrap(upgrades.first?.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/api/display/ws")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "display_ticket" }?.value, "ticket-1")
        let observe = try XCTUnwrap(host.requests.first { $0["method"].text == "display.observe" })
        XCTAssertEqual(observe["params"]["profile"].text, "work")
        session.close()
    }

    func testAStoppedScreenShowsItsStateWithoutSpendingATicket() async {
        host.always("display.status", .init(result: screen(running: false)))
        let session = makeSession()
        session.open()
        await reach(.stopped, on: session)
        XCTAssertFalse(host.requests.contains { $0["method"].text == "display.observe" })
        session.close()
    }

    func testAHostWithoutTheMethodsOrSupportSaysSo() async {
        host.always("display.status", .init(error: -32601))
        let lacking = makeSession()
        lacking.open()
        await reach(.unavailable, on: lacking)
        lacking.close()

        host.always("display.status", .init(result: screen(supported: false)))
        let unsupported = makeSession()
        unsupported.open()
        await reach(.unsupported, on: unsupported)
        unsupported.close()
    }

    /// 5300 with no `data.code` is a state: the screen stopped between the two calls.
    func testObserveRefusedWithNoCodeReadsAsAStoppedScreen() async {
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(error: 5300))
        let session = makeSession()
        session.open()
        await reach(.stopped, on: session)
        session.close()
    }

    func testASpentTicketOpensAgainOnANewOne() async {
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(result: screen()))
        let session = makeSession(backoff: [.seconds(3600)])
        session.open()
        await socket(0).end(code: 4401)
        // No wait: a backoff of an hour would stall this.
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.close()
    }

    func testAScreenThatGoesAwayStopsAndABrokenStreamFails() async {
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(result: screen()))
        let gone = makeSession()
        gone.open()
        await socket(0).end(code: 4001)
        await reach(.stopped, on: gone)
        gone.close()

        let broken = makeSession()
        broken.open()
        await socket(1).serve(Data("not rfb at all".utf8))
        await reach(.failed, on: broken)
        broken.close()
    }

    /// The last picture stays, dimmed by the view, until the retry's first frame.
    func testADroppedStreamRetriesAndKeepsThePicture() async throws {
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(result: screen()))
        let session = makeSession(backoff: [.milliseconds(1)])
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        await socket(0).end(error: URLError(.networkConnectionLost))
        await reach(.reconnecting, on: session)
        XCTAssertNotNil(session.frames.image)
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.close()
    }

    /// A proxy that refuses the upgrade won't start accepting it on its own.
    func testARefusedUpgradeStopsRetrying() async {
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(result: screen()))
        let session = makeSession()
        session.open()
        await socket(0).end(error: BotFailure.upgradeRefused(403))
        await reach(.failed, on: session)
        session.close()
    }

    /// A dead route can leave a read waiting forever, so a ping with no pong must end the stream.
    func testAPingThatFailsEndsAStreamWhoseReadIsParked() async {
        let socket = ScriptedRFBSocket()
        socket.pingFailure = URLError(.networkConnectionLost)
        var options = RFBClient.Options()
        options.keepalive = .milliseconds(1)
        let client = RFBClient(socket: socket, options: options) { _ in }
        do {
            try await client.run()
            XCTFail("run only returns by throwing")
        } catch {
            XCTAssertEqual(error as? RFBStreamEnd, .silent)
        }
    }
}

/// A stream socket scripted by the test, which answers each read in order.
private actor ScriptedRFBSocketState {
    var frames: [Result<Data, Error>] = []
    var waiter: CheckedContinuation<Data, Error>?
    var closed = false

    func next() async throws -> Data {
        if !frames.isEmpty { return try frames.removeFirst().get() }
        if closed { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func deliver(_ frame: Result<Data, Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: frame)
        } else {
            frames.append(frame)
        }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
    }
}

final class ScriptedRFBSocket: RFBSocket, @unchecked Sendable {
    private let state = ScriptedRFBSocketState()
    var pingFailure: Error?

    /// The handshake, then one 2x1 update of a Tight fill.
    static let oneFrame: Data = {
        var bytes = Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0]
        bytes += [0, 2, 0, 1, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0]
        bytes += [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 7, 0x80, 1, 2, 3]
        return Data(bytes)
    }()

    func serve(_ data: Data) async { await state.deliver(.success(data)) }
    func end(code: Int) async { await state.deliver(.failure(RFBStreamEnd.closed(code: code))) }
    func end(error: Error) async { await state.deliver(.failure(error)) }

    func receive() async throws -> Data { try await state.next() }
    func send(_ data: Data) async throws {}
    func ping() async throws { if let pingFailure { throw pingFailure } }
    func close() { Task { await state.close() } }
}
