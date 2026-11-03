import XCTest
@testable import HermesMobile

@MainActor final class BotDesktopTests: XCTestCase {
    func testOpeningAStoppedDesktopDoesNotStartItUntilAsked() async {
        let wire = DesktopWire()
        wire.running = false
        let model = makeModel(wire)
        await model.open()?.value
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(wire.calls.map(\.method), ["display.status"])
        await model.start()?.value
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertEqual(wire.calls.map(\.method), ["display.status", "display.start", "display.observe"])
        XCTAssertTrue(wire.calls.allSatisfy { (try? $0.params()["profile"]) == .string("triage") })
        model.close()
    }

    func testAViewerUsesANewTicketOnReopenAndNeverAcquiresControl() async throws {
        let wire = DesktopWire()
        let model = makeModel(wire)
        await model.open()?.value
        let first = try XCTUnwrap(model.request?.url)
        let oldGeneration = model.generation
        model.connected(generation: oldGeneration)
        XCTAssertEqual(model.phase, .live)
        model.close()
        XCTAssertNil(model.request)
        await model.open()?.value
        XCTAssertNotEqual(model.request?.url, first)
        model.connected(generation: oldGeneration)
        model.disconnected(code: 4001, generation: oldGeneration)
        XCTAssertEqual(model.phase, .connecting, "Old viewer callbacks cannot affect the new viewer")
        XCTAssertEqual(wire.calls.map(\.method), ["display.status", "display.observe", "display.status", "display.observe"])
        model.close()
    }

    func testClosingWhileObservingDropsTheLateTicket() async {
        let wire = DesktopWire()
        let observed = expectation(description: "observe started")
        var finish: CheckedContinuation<Void, Never>?
        wire.beforeObserve = {
            await withCheckedContinuation { continuation in
                finish = continuation
                observed.fulfill()
            }
        }
        let model = makeModel(wire)
        let opening = model.open()
        await fulfillment(of: [observed], timeout: 2)
        model.close()
        finish?.resume()
        await opening?.value
        XCTAssertNil(model.request)
        XCTAssertEqual(model.phase, .paused)
    }

    func testUnsupportedHostAndMissingInstallationNeverObserveOrStart() async {
        let wire = DesktopWire()
        wire.failure = BotFailure.rejected(-32601)
        let model = makeModel(wire)
        await model.open()?.value
        XCTAssertEqual(model.phase, .unsupported)
        XCTAssertNil(model.request)
        model.close()
        wire.failure = nil
        wire.installed = false
        await model.open()?.value
        XCTAssertEqual(model.phase, .notInstalled)
        XCTAssertEqual(wire.calls.map(\.method), ["display.status", "display.status"])
        model.close()
    }

    func testDesktopStopClosesTheViewerWithoutRestartingTheHost() async {
        let wire = DesktopWire()
        let model = makeModel(wire)
        await model.open()?.value
        wire.running = false
        await model.disconnected(code: 4001, generation: model.generation)?.value
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertNil(model.request)
        XCTAssertFalse(wire.calls.contains { $0.method == "display.start" })
        model.close()
    }

    func testARejectedTicketIsRenewedOnceThenRequiresAnExplicitRetry() async {
        let wire = DesktopWire()
        let model = makeModel(wire)
        await model.open()?.value
        let first = model.request?.url
        await model.disconnected(code: 4401, generation: model.generation)?.value
        XCTAssertNotEqual(model.request?.url, first)
        await model.disconnected(code: 4401, generation: model.generation)?.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.request)
        XCTAssertEqual(wire.calls.filter { $0.method == "display.observe" }.count, 2)
        await model.retry()?.value
        XCTAssertEqual(model.phase, .connecting)
        model.close()
    }

    func testRepeatedUnreachableDesktopStopsAtTheRetryBudget() async {
        let wire = DesktopWire()
        let model = makeModel(wire)
        await model.open()?.value
        for _ in 0..<6 {
            await model.disconnected(code: 4001, generation: model.generation)?.value
        }
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.request)
        XCTAssertEqual(wire.calls.filter { $0.method == "display.observe" }.count, 6)
        model.close()
    }

    func testGatewayLossQueuesRecoveryAndDismissalCancelsIt() async {
        let wire = DesktopWire()
        let model = makeModel(wire)
        await model.open()?.value
        wire.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertNil(model.request)
        model.close()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(wire.calls.count, 2)
    }

    func testServerAndProxyCredentialsStayOnTheirOwnOrigin() throws {
        var first = connection("https://one.example:9443")
        first.headers = [CustomHeader(name: "CF-Access-Client-Id", value: "fixture-id")]
        let reply: BotJSON = .object(["path": .string("/api/display/ws"), "ticket": .string("a&b= c")])
        let request = try BotDesktopEndpoint.request(reply, connection: first)
        XCTAssertEqual(request.url?.host, "one.example")
        XCTAssertEqual(request.url?.port, 9443)
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "fixture-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://one.example:9443")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "display_ticket", value: "a&b= c")])
        let second = try BotDesktopEndpoint.request(reply, connection: connection("https://two.example"))
        XCTAssertEqual(second.url?.host, "two.example")
        XCTAssertNil(second.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        for path in ["https://other.example/api/display/ws", "//other.example/api/display/ws", "/api/ws", "/api/display/ws?token=other"] {
            XCTAssertThrowsError(try BotDesktopEndpoint.request(.object(["path": .string(path), "ticket": .string("secret")]), connection: first))
        }
    }

    func testAnErrorContainingATicketIsNeverPresented() async {
        let wire = DesktopWire()
        wire.failure = BotFailure.outdated("wss://one.example?display_ticket=private")
        let model = makeModel(wire)
        await model.open()?.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.message.contains("private"))
        XCTAssertFalse(model.message.contains("display_ticket"))
        model.close()
    }

    private func makeModel(_ wire: DesktopWire) -> BotDesktopSession {
        BotDesktopSession(client: wire, socketSession: URLSession(configuration: .ephemeral),
                          connection: connection("https://one.example"), profile: "triage", wait: { _ in })
    }

    private func connection(_ address: String) -> BotConnection {
        BotConnection(id: UUID(), name: "Fixture", address: URL(string: address)!, username: "", password: "")
    }
}

@MainActor private final class DesktopWire: BotTransport {
    var replayEpoch: String? = "fixture"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var calls: [HermesCall] = []
    var running = true
    var installed = true
    var failure: Error?
    var beforeObserve: (() async -> Void)?
    private var ticket = 0

    func connect() async throws {}
    func close() {}
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append(call)
        if let failure { throw failure }
        if case .displayStart = call { running = true }
        var result: [String: BotJSON] = ["supported": .bool(true), "installed": .bool(installed), "running": .bool(running)]
        if case .displayObserve = call {
            await beforeObserve?()
            ticket += 1
            result["path"] = .string("/api/display/ws")
            result["ticket"] = .string("ticket-\(ticket)")
        }
        return .object(result)
    }
}
