import XCTest
@testable import HermesMobile

final class TerminalAPITests: XCTestCase {
    func testStatusUsesPluginAndStoredIdentity() throws {
        let request = try HermesREST.terminalStatus(sessionID: "chat+one", profile: "work").request(base: URL(string: "https://example.test")!)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/plugins/hermex-push/terminal/shell/status")
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(parts?.queryItems, [URLQueryItem(name: "session_id", value: "chat+one"), URLQueryItem(name: "profile", value: "work")])
        XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
    }
    func testUpgradeCarriesTicketSizeProfileAndRestart() throws {
        let request = try TerminalWire.upgrade(base: URL(string: "https://example.test")!, sessionID: "a b", profile: "default",
                                               rows: 40, cols: 90, restart: true, ticket: "single+use")
        let parts = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "wss")
        XCTAssertEqual(parts.path, "/api/plugins/hermex-push/terminal/shell")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value!) })
        XCTAssertEqual(query, ["session_id": "a b", "profile": "default", "rows": "40", "cols": "90", "restart": "1", "ticket": "single+use"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"))
    }
    func testNormalAttachOmitsRestartAndDefaultProfile() throws {
        let request = try TerminalWire.upgrade(base: URL(string: "http://localhost:9199")!, sessionID: "s1", profile: nil,
                                               rows: 24, cols: 80, restart: false, ticket: "ticket")
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(parts?.scheme, "ws")
        XCTAssertFalse(parts!.queryItems!.contains { ["restart", "profile"].contains($0.name) })
    }
    func testResizeIsExactlyThePluginFrame() {
        guard case .string(let text) = TerminalWire.resize(rows: 33, cols: 77) else { return XCTFail("text control frame") }
        XCTAssertEqual(text, "\u{1B}[RESIZE:77;33]")
    }
    func testInputPreservesBytesIncludingSplitUTF8AndControlKeys() {
        let bytes = Data([0x1b, 0x5b, 0x41, 0x03, 0xff, 0xc3])
        guard case .data(let actual) = TerminalWire.input(bytes) else { return XCTFail("binary input") }
        XCTAssertEqual(actual, bytes)
    }
    func testCloseCodesAndHandshakeAuthenticationPolicy() {
        XCTAssertEqual(TerminalConnectionFailure.closed(4410).message, "Shell exited")
        XCTAssertEqual(TerminalConnectionFailure.closed(1013).message, "Too many terminals open")
        XCTAssertTrue(TerminalConnectionFailure.closed(4401).isAuthenticationFailure)
        XCTAssertTrue(TerminalConnectionFailure.handshake(403).isAuthenticationFailure)
        XCTAssertFalse(TerminalConnectionFailure.closed(4410).isAuthenticationFailure)
        XCTAssertFalse(TerminalConnectionFailure.closed(1013).isAuthenticationFailure)
    }
}

@MainActor private final class ScriptedTerminalTransport: TerminalTransport {
    var running = true
    var statusError: Error?
    var connectionErrors: [Error] = []
    var connections: [(rows: Int, cols: Int, restart: Bool)] = []
    var frames: [URLSessionWebSocketTask.Message] = []
    var operations: [String] = []
    var onEvent: ((TerminalEvent) async -> Void)?
    var onConnect: (() async -> Void)?
    var statusGate: CheckedContinuation<Bool, Error>?
    var statusRequested: (() -> Void)?
    var parkStatus = false
    func status() async throws -> Bool {
        operations.append("status")
        if let statusError { throw statusError }
        if parkStatus {
            return try await withCheckedThrowingContinuation { statusGate = $0; statusRequested?() }
        }
        return running
    }
    func connect(rows: Int, cols: Int, restart: Bool, onEvent: @escaping (TerminalEvent) async -> Void) async throws {
        operations.append("connect"); connections.append((rows, cols, restart))
        if !connectionErrors.isEmpty { throw connectionErrors.removeFirst() }
        self.onEvent = onEvent; await onConnect?()
    }
    func send(_ frame: URLSessionWebSocketTask.Message) { frames.append(frame) }
    func disconnect() { operations.append("disconnect"); onEvent = nil }
}

@MainActor final class TerminalSessionControllerTests: XCTestCase {
    private var transport: ScriptedTerminalTransport!
    private var http: HermesConnection!
    private var controller: TerminalSessionController!
    private var output = Data()
    private var resets = 0
    override func setUp() async throws {
        TerminalShellRegistry.reset(); output = Data(); resets = 0
        transport = ScriptedTerminalTransport()
        http = HermesConnection(connection: BotConnection(id: UUID(), name: "QA", address: URL(string: "https://example.test")!, username: "test", password: "fixture"))
        controller = TerminalSessionController(target: TerminalTarget(http: http, sessionID: "stored-chat", profile: "default"), transport: transport)
        controller.onOutput = { [weak self] in self?.output.append($0) }
        controller.onReset = { [weak self] in self?.resets += 1; self?.output.removeAll() }
    }
    override func tearDown() async throws { controller.dispose(); http.retire() }
    func testUnpresentedScreenInitializersDoNotRegisterObservers() {
        let before = http.retirementObserverCount
        let target = TerminalTarget(http: http, sessionID: "stored-chat", profile: "default")
        for _ in 0..<10 {
            _ = TerminalScreen(workspace: nil, target: target, server: http.connection.address)
        }
        XCTAssertEqual(http.retirementObserverCount, before)
    }
    func testOneObserverForOpenRestartAndDispose() async {
        XCTAssertEqual(http.retirementObserverCount, 0)
        await controller.open(rows: 24, cols: 80)
        XCTAssertEqual(http.retirementObserverCount, 1)
        await controller.restart()
        XCTAssertEqual(http.retirementObserverCount, 1)
        controller.dispose()
        XCTAssertEqual(http.retirementObserverCount, 0)
    }
    func testOpenReadsStatusThenConnectsAtMeasuredSize() async {
        await controller.open(rows: 33, cols: 77)
        XCTAssertEqual(transport.operations.filter { $0 != "disconnect" }, ["status", "connect"])
        XCTAssertEqual(transport.connections.first?.rows, 33); XCTAssertEqual(transport.connections.first?.cols, 77)
        XCTAssertEqual(controller.state, .live); XCTAssertEqual(resets, 1)
    }
    func testRestartPassesRestartAndResetsScreen() async {
        await controller.open(rows: 24, cols: 80)
        await transport.onEvent?(.output(Data("old".utf8)))
        await controller.restart()
        XCTAssertEqual(transport.connections.map(\.restart), [false, true])
        XCTAssertEqual(controller.state, .live); XCTAssertEqual(output, Data()); XCTAssertEqual(resets, 2)
    }
    func testBackgroundReturnClearsBeforeReplayWithoutRestart() async {
        await controller.open(rows: 24, cols: 80)
        await transport.onEvent?(.output(Data("one".utf8)))
        controller.suspend(); XCTAssertNil(transport.onEvent)
        let connected = expectation(description: "reattached")
        transport.onConnect = { [weak self] in
            await self?.transport.onEvent?(.output(Data("one\ntwo".utf8)))
            connected.fulfill()
        }
        controller.resume()
        await fulfillment(of: [connected], timeout: 2)
        XCTAssertEqual(output, Data("one\ntwo".utf8), "reset precedes replay")
        XCTAssertEqual(transport.connections.map(\.restart), [false, false])
    }
    func testExitedShellOffersRestartWithoutAutoStarting() async {
        await controller.open(rows: 24, cols: 80)
        await transport.onEvent?(.failed(.closed(4410)))
        XCTAssertEqual(controller.state, .ended(.exited(nil))); XCTAssertEqual(transport.connections.count, 1)
        await controller.restart(); XCTAssertTrue(transport.connections.last!.restart)
    }
    func testTooManyTerminalsMessage() async {
        await controller.open(rows: 24, cols: 80)
        await transport.onEvent?(.failed(.closed(1013)))
        XCTAssertEqual(controller.state, .ended(.disconnected("Too many terminals open")))
    }
    /// Only close code 4410 says the shell exited; any other loss leaves it running on the host.
    func testConnectionLossIsNotShellExit() async {
        for failure in [TerminalConnectionFailure.closed(1006), .closed(1001), .closed(4409), .handshake(502), .network("offline")] {
            await controller.restart()
            await transport.onEvent?(.failed(failure))
            XCTAssertEqual(controller.state, .ended(.disconnected(failure.message)), "\(failure)")
        }
    }
    /// Reconnect reattaches to the same shell (`restart: false`) and replays its output; Restart
    /// stays the separate action that replaces it.
    func testReconnectAfterADropKeepsTheShellAndRestartReplacesIt() async {
        await controller.open(rows: 24, cols: 80)
        await transport.onEvent?(.output(Data("sleep 600".utf8)))
        await transport.onEvent?(.failed(.network("The network connection was lost.")))
        XCTAssertEqual(controller.state, .ended(.disconnected("The network connection was lost.")))
        XCTAssertEqual(output, Data("sleep 600".utf8), "the drop leaves the screen as it was")
        transport.onConnect = { [weak self] in await self?.transport.onEvent?(.output(Data("sleep 600 (replayed)".utf8))) }
        await controller.reconnect()
        XCTAssertEqual(transport.operations.filter { $0 != "disconnect" }, ["status", "connect", "status", "connect"])
        XCTAssertEqual(transport.connections.map(\.restart), [false, false])
        XCTAssertEqual(controller.state, .live); XCTAssertEqual(output, Data("sleep 600 (replayed)".utf8))
        await transport.onEvent?(.failed(.closed(1006)))
        transport.onConnect = nil
        await controller.restart()
        XCTAssertEqual(transport.connections.map(\.restart), [false, false, true])
    }
    /// A restart whose socket never opens leaves the old output; the screen is cleared only
    /// once the new connection is open.
    func testFailedRestartKeepsTheOldOutput() async {
        await controller.open(rows: 24, cols: 80)
        await transport.onEvent?(.output(Data("old".utf8)))
        transport.connectionErrors = [TerminalConnectionFailure.handshake(502)]
        await controller.restart()
        XCTAssertEqual(output, Data("old".utf8)); XCTAssertEqual(resets, 1)
        await controller.restart()
        XCTAssertEqual(controller.state, .live); XCTAssertEqual(output, Data()); XCTAssertEqual(resets, 2)
    }
    /// A failed reconnect keeps the old output and the Reconnect action.
    func testFailedReconnectKeepsTheOldOutput() async {
        await controller.open(rows: 24, cols: 80)
        await transport.onEvent?(.output(Data("old".utf8)))
        await transport.onEvent?(.failed(.network("offline")))
        transport.statusError = URLError(.notConnectedToInternet)
        await controller.reconnect()
        XCTAssertEqual(controller.state, .ended(.disconnected(URLError(.notConnectedToInternet).localizedDescription)),
                       "a failed status read keeps Reconnect on the screen, not the unavailable page")
        transport.statusError = nil
        transport.connectionErrors = [TerminalConnectionFailure.network("offline")]
        await controller.reconnect()
        XCTAssertEqual(controller.state, .ended(.disconnected("offline")))
        XCTAssertEqual(output, Data("old".utf8)); XCTAssertEqual(resets, 1)
        await controller.reconnect()
        XCTAssertEqual(controller.state, .live); XCTAssertEqual(output, Data()); XCTAssertEqual(resets, 2)
    }
    /// A flood is read only as fast as the screen takes it: the reader waits while the batcher
    /// holds its limit, and every byte still reaches SwiftTerm in order.
    func testFloodStopsReadingWhileTheScreenIsBehindAndKeepsEveryByte() async {
        var fed = Data()
        let batcher = TerminalOutputBatcher(maxPerPass: 4, maxQueued: 8) { fed.append($0) }
        controller.onOutput = { await batcher.enqueue($0) }
        await controller.open(rows: 24, cols: 80)
        var expected = Data(), deepest = 0
        for index in 0..<50 {
            let chunk = Data(String(format: "%02d\u{1B}[0m", index).utf8)
            expected.append(chunk)
            await transport.onEvent?(.output(chunk))
            deepest = max(deepest, batcher.queuedBytes)
        }
        batcher.flush()
        XCTAssertLessThan(deepest, 8, "the next frame is read only once the queue is under its limit")
        XCTAssertEqual(fed, expected)
    }
    func testAuthenticationRetriesOnlyOnceFor4401AndHTTP403() async {
        for failure in [TerminalConnectionFailure.closed(4401), .handshake(403)] {
            transport.connectionErrors = [failure, failure]
            let before = transport.connections.count
            await controller.restart()
            XCTAssertEqual(transport.connections.count - before, 2)
            XCTAssertEqual(controller.state, .ended(.error("Sign in to Hermes again to open Terminal")))
        }
    }
    func testOneRefusedTicketThenAcceptedConnection() async {
        transport.connectionErrors = [TerminalConnectionFailure.handshake(403)]
        await controller.open(rows: 24, cols: 80)
        XCTAssertEqual(transport.connections.count, 2); XCTAssertEqual(controller.state, .live)
    }
    func testMissingPluginFailsWithoutOpeningSocket() async {
        transport.statusError = BotFailure.rejected(404)
        await controller.open(rows: 24, cols: 80)
        XCTAssertEqual(controller.state, .failed("Terminal needs the hermex-push companion plugin on Hermes"))
        XCTAssertTrue(transport.connections.isEmpty)
    }
    func testLeavingDuringStatusCannotOpenLateSocket() async {
        transport.parkStatus = true
        let requested = expectation(description: "status requested")
        transport.statusRequested = { requested.fulfill() }
        let opening = Task { await controller.open(rows: 24, cols: 80) }
        await fulfillment(of: [requested], timeout: 2)
        controller.detach(); transport.statusGate?.resume(returning: true)
        await opening.value
        XCTAssertTrue(transport.connections.isEmpty); XCTAssertEqual(controller.state, .idle)
    }
    func testReopenAfterShellEndedShowsNotice() async {
        await controller.open(rows: 24, cols: 80); controller.detach()
        transport.running = false
        await controller.open(rows: 24, cols: 80)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(TerminalSessionController.previousSessionNotice))
    }
    func testInputAndResizeAreSingleFramesNotResends() async {
        await controller.open(rows: 24, cols: 80); transport.frames.removeAll()
        controller.send(Data([0x03, 0xff])); controller.resize(rows: 30, cols: 100)
        XCTAssertEqual(transport.frames.count, 2)
        guard case .data(let bytes) = transport.frames[0], case .string(let resize) = transport.frames[1] else { return XCTFail("framing") }
        XCTAssertEqual(bytes, Data([0x03, 0xff])); XCTAssertEqual(resize, "\u{1B}[RESIZE:100;30]")
        controller.suspend(); controller.send("must not replay"); XCTAssertEqual(transport.frames.count, 2)
    }
    func testRetiredHermesConnectionClosesTerminal() async {
        await controller.open(rows: 24, cols: 80); http.retire()
        XCTAssertNil(transport.onEvent); XCTAssertTrue(controller.isRetired)
        XCTAssertEqual(controller.state, .failed("Sign in to Hermes again to open Terminal"))
    }
}

@MainActor final class TerminalAvailabilityTests: XCTestCase {
    override func tearDown() { HermesHostFixture.reset(); super.tearDown() }
    func testCapabilitiesHideTerminalUnlessItsRouteIsMounted() async {
        for (status, routes, expected) in [(404, [String](), TerminalAvailability.State.missing),
                                           (200, [], .missing),
                                           (200, ["GET /provider-quota"], .missing),
                                           (200, ["GET /terminal/shell/status"], .available)] {
            HermesHostFixture.reset()
            let http = HermesConnection(connection: BotConnection(id: UUID(), name: "QA", address: URL(string: "https://example.test")!, username: "test", password: "fixture"),
                configuration: HermesHostFixture.configuration { request in
                    request.url?.path == "/api/plugins/hermex-push/capabilities" ? .json(status, .object(["routes": .array(routes.map(BotJSON.string))])) : nil
                })
            let availability = TerminalAvailability()
            await availability.refresh(TerminalTarget(http: http, sessionID: "s1", profile: nil))
            XCTAssertEqual(availability.state, expected); http.retire()
        }
    }
    func testNetworkFailureDoesNotClaimMissingPlugin() async {
        let http = HermesConnection(connection: BotConnection(id: UUID(), name: "QA", address: URL(string: "https://example.test")!, username: "test", password: "fixture"),
            configuration: HermesHostFixture.configuration { request in
                request.url?.path == "/api/plugins/hermex-push/capabilities" ? .fail(URLError(.notConnectedToInternet)) : nil
            })
        let availability = TerminalAvailability()
        await availability.refresh(TerminalTarget(http: http, sessionID: "s1", profile: nil))
        guard case .failed = availability.state else { return XCTFail("Network failure is not plugin absence") }
        http.retire()
    }
    /// Only a reconnect reads a failed check again: a failure with the chat still up, or a route
    /// the host doesn't mount, stays as it is (no loop on a host that keeps failing).
    func testOnlyAReconnectRetriesAFailedCheck() async {
        var status = 503
        let http = HermesConnection(connection: BotConnection(id: UUID(), name: "QA", address: URL(string: "https://example.test")!, username: "test", password: "fixture"),
            configuration: HermesHostFixture.configuration { request in
                request.url?.path == "/api/plugins/hermex-push/capabilities" ? .json(status, .object(["routes": .array([])])) : nil
            })
        defer { http.retire() }
        let target = TerminalTarget(http: http, sessionID: "s1", profile: nil), availability = TerminalAvailability()
        availability.connectionChanged(isConnected: true)
        let first = availability.checkID(for: target)
        await availability.refresh(target)
        guard case .failed = availability.state else { return XCTFail("a 503 is a failed check") }
        XCTAssertEqual(availability.checkID(for: target), first, "a failure with no reconnect runs no new check")
        availability.connectionChanged(isConnected: false)
        XCTAssertEqual(availability.checkID(for: target), first)
        availability.connectionChanged(isConnected: true)
        let second = availability.checkID(for: target)
        XCTAssertNotEqual(second, first)

        HermesHostFixture.script { status = 404 }
        await availability.refresh(target)
        XCTAssertEqual(availability.state, .missing)
        availability.connectionChanged(isConnected: false); availability.connectionChanged(isConnected: true)
        XCTAssertEqual(availability.checkID(for: target), second, "a missing route is an answer, not a failure")
    }
    /// The chat reconnects while the check is still out, and the check then fails: it runs again.
    func testAReconnectDuringTheCheckRetriesItsFailure() async {
        let parked = expectation(description: "capability check out")
        HermesHostFixture.onPark = { parked.fulfill() }
        let http = HermesConnection(connection: BotConnection(id: UUID(), name: "QA", address: URL(string: "https://example.test")!, username: "test", password: "fixture"),
            configuration: HermesHostFixture.configuration { request in
                request.url?.path == "/api/plugins/hermex-push/capabilities" ? .park : nil
            })
        defer { http.retire() }
        let target = TerminalTarget(http: http, sessionID: "s1", profile: nil), availability = TerminalAvailability()
        let first = availability.checkID(for: target)
        let check = Task { await availability.refresh(target) }
        await fulfillment(of: [parked], timeout: 5)
        availability.connectionChanged(isConnected: true)
        XCTAssertEqual(availability.checkID(for: target), first, "a check still out is not retried")
        HermesHostFixture.releaseParked(.fail(URLError(.networkConnectionLost)))
        await check.value
        guard case .failed = availability.state else { return XCTFail("the dropped check failed") }
        XCTAssertNotEqual(availability.checkID(for: target), first)
    }
    func testEachUpgradeMintsItsOwnTicketAndUsesHermesHeaders() async throws {
        var tickets = 0
        let http = HermesConnection(connection: BotConnection(id: UUID(), name: "QA", address: URL(string: "https://example.test")!, username: "test", password: "fixture", headers: [CustomHeader(name: "X-QA", value: "fixture")]),
            configuration: HermesHostFixture.configuration { request in
                if request.url?.path == "/api/auth/ws-ticket" { tickets += 1; return .json(200, .object(["ticket": .string("t\(tickets)")])) }
                return nil
            })
        defer { http.retire() }
        for index in 1...2 {
            let request = try await http.terminalUpgrade(sessionID: "s1", profile: "default", rows: 24, cols: 80, restart: false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-QA"), "fixture")
            XCTAssertTrue(request.url!.absoluteString.contains("ticket=t\(index)"))
        }
        XCTAssertEqual(tickets, 2)
    }
}

@MainActor final class TerminalShellRegistryTests: XCTestCase {
    func testTerminalShellRegistryIsScopedPerServer() {
        let a = URL(string: "https://a.test")!, b = URL(string: "https://b.test")!
        XCTAssertNotEqual(TerminalShellRegistry.key(server: a, sessionID: "s1"), TerminalShellRegistry.key(server: b, sessionID: "s1"))
    }
}

final class TerminalLinksTests: XCTestCase {
    func testOnlyWebLinksOpen() {
        XCTAssertEqual(TerminalLinks.openableURL("https://example.com/x?y=1")?.host, "example.com")
        XCTAssertNotNil(TerminalLinks.openableURL("http://example.com"))
        XCTAssertNil(TerminalLinks.openableURL("file:///etc/passwd")); XCTAssertNil(TerminalLinks.openableURL("tel:123"))
        XCTAssertNil(TerminalLinks.openableURL("hermex://session/1")); XCTAssertNil(TerminalLinks.openableURL("https://"))
    }
}

@MainActor final class TerminalOutputBatcherTests: XCTestCase {
    func testChunksInOneTurnAreFedOnceInOrder() async {
        var fed: [Data] = []
        let batcher = TerminalOutputBatcher { fed.append($0) }
        batcher.append("a"); batcher.append("b"); batcher.append("c")
        XCTAssertEqual(fed, [])
        let done = expectation(description: "next turn"); DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(fed, [Data("abc".utf8)])
        batcher.append("d"); batcher.flush(); XCTAssertEqual(fed, [Data("abc".utf8), Data("d".utf8)])
    }
    func testFloodIsFedInBoundedSlicesInOrderWithoutLoss() {
        var fed: [Data] = []
        let batcher = TerminalOutputBatcher(maxPerPass: 1000) { fed.append($0) }
        var expected = Data()
        for i in 1...2000 {
            let line = Data("\(i) héllo 😀 \u{1B}[32mgreen\u{1B}[0m\r\n".utf8)
            expected.append(line); batcher.append(line)
        }
        var passes = 0
        while batcher.hasPending { batcher.drainOnePass(); passes += 1 }
        XCTAssertGreaterThan(passes, 50); XCTAssertTrue(fed.allSatisfy { $0.count <= 1000 })
        XCTAssertEqual(fed.reduce(into: Data()) { $0.append($1) }, expected)
    }
    func testResetDropsOldPendingReplayAndKeepsSplitUTF8() {
        var fed = Data()
        let batcher = TerminalOutputBatcher { fed.append($0) }
        batcher.append("old"); batcher.clear()
        batcher.append(Data([0xc3])); batcher.append(Data([0xa9])); batcher.flush()
        XCTAssertEqual(fed, Data("é".utf8))
    }
    func testFloodYieldsToTheRunLoopBetweenSlices() async {
        var fed: [Data] = []
        let batcher = TerminalOutputBatcher(maxPerPass: 10) { fed.append($0) }
        batcher.append(String(repeating: "x", count: 35))
        XCTAssertEqual(fed.count, 0); batcher.drainOnePass(); XCTAssertEqual(fed.count, 1); XCTAssertTrue(batcher.hasPending)
        let drained = expectation(description: "drained")
        func poll() { if batcher.hasPending { DispatchQueue.main.async { poll() } } else { drained.fulfill() } }
        poll(); await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(fed.map { String(decoding: $0, as: UTF8.self) }, ["xxxxxxxxxx", "xxxxxxxxxx", "xxxxxxxxxx", "xxxxx"])
    }
}
