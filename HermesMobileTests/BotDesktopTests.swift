import Network
import SwiftUI
import WebKit
import XCTest
@testable import HermesMobile

@MainActor final class BotDesktopTests: XCTestCase {
    func testAcquiringControlOnAnOpenViewerEnablesPointerInputInWebKit() async throws {
        let listening = expectation(description: "Local RFB server listening")
        let expectedMasks: [UInt8] = [1, 0, 4, 0, 4, 0, 16, 0]
        let sentInput = XCTestExpectation(description: "Viewer sent left click, mouse right click, two-finger tap and scroll")
        var receivedMasks: [UInt8] = []
        let server = try DesktopRFBFixture(onReady: listening.fulfill, pointerCount: expectedMasks.count) { masks in
            Task { @MainActor in
                receivedMasks = masks
                sentInput.fulfill()
            }
        }
        defer { server.close() }
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let connection = connection("http://127.0.0.1:\(port)")
        let model = BotDesktopSession(client: DesktopWire(), socketSession: URLSession(configuration: .ephemeral),
                                      connection: connection, profile: "triage", wait: { _ in })
        let ready = expectation(description: "Viewer painted the first framebuffer")
        let profile = try XCTUnwrap(BotProfile(.object(["name": .string("triage")])))
        let viewer = BotDesktopView(server: connection.address, connection: connection, profile: profile, session: model)
        let window = try host(DesktopHostedProbe(viewer: viewer, model: model, onLive: ready.fulfill))
        defer { unhost(window) }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(model.phase, .live)
        guard model.phase == .live else { return }
        let webView = try XCTUnwrap(find(WKWebView.self, in: window))

        await model.takeControl()?.value
        XCTAssertTrue(model.controlsDesktop)
        window.rootViewController?.view.setNeedsLayout()
        window.layoutIfNeeded()
        let hit = try XCTUnwrap(window.hitTest(webView.convert(CGPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: window), with: nil))
        XCTAssertTrue(hit === webView || hit.isDescendant(of: webView), "The desktop canvas receives touches between the toolbars")

        _ = try await webView.callAsyncJavaScript("""
            const overlay = document.getElementById('input');
            const rect = overlay.getBoundingClientRect();
            const x = rect.width / 2, y = rect.height / 2;
            const touch = (type, pointerId, dx = 0, dy = 0) => overlay.dispatchEvent(new PointerEvent(type, {
                pointerId, pointerType: 'touch', clientX: x + dx, clientY: y + dy
            }));
            touch('pointerdown', 1);
            touch('pointerup', 1);
            overlay.dispatchEvent(new MouseEvent('contextmenu', { button: 2, clientX: x, clientY: y }));
            touch('pointerdown', 1, -25);
            touch('pointerdown', 2, 25);
            touch('pointerup', 1);
            touch('pointerup', 2);
            touch('pointerdown', 1, -25);
            touch('pointerdown', 2, 25);
            touch('pointermove', 1, -25, -20);
            touch('pointermove', 2, 25, -20);
            touch('pointerup', 1);
            touch('pointerup', 2);
            """, contentWorld: .page)
        await fulfillment(of: [sentInput], timeout: 5)
        XCTAssertEqual(receivedMasks, expectedMasks)
    }

    func testKeyboardFocusRequestBeforeWindowAttachmentIsHonored() async throws {
        let field = BotDesktopKeyboard.Field()
        field.wantsFocus = true
        XCTAssertFalse(field.isFirstResponder)
        let window = try host(Color.clear)
        defer { unhost(window) }
        window.rootViewController?.view.addSubview(field)
        XCTAssertTrue(field.isFirstResponder)
        field.wantsFocus = false
        XCTAssertFalse(field.isFirstResponder)
        field.wantsFocus = true
        XCTAssertTrue(field.isFirstResponder)
        field.wantsFocus = false
    }

    private func host(_ content: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func unhost(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene?.windows.first { !$0.isHidden }?.makeKey()
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
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

    func testOpeningTheComputerStartsItOnceButForegroundingDoesNot() async {
        let wire = DesktopWire()
        wire.running = false
        let model = makeModel(wire, autoStart: true)
        await model.open(newPresentation: true)?.value
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertEqual(wire.calls.map(\.method), ["display.status", "display.start", "display.observe"])

        model.close()
        wire.running = false
        await model.open()?.value
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(wire.calls.last?.method, "display.status")
        model.close()
    }

    func testInputRequiresConfirmedLeaseAndStopsOnMatchingProfileRevocation() async throws {
        let wire = DesktopWire()
        let model = makeModel(wire)
        var commands: [String] = []
        model.sendInput = { command, _ in commands.append(command) }
        await model.open()?.value
        model.connected(generation: model.generation)
        model.input("key")
        XCTAssertTrue(commands.isEmpty)

        await model.takeControl()?.value
        let acquired = try XCTUnwrap(wire.calls.last)
        XCTAssertEqual(try acquired.params()["viewer_id"], .string("viewer-fixture"))
        XCTAssertEqual(try acquired.params()["profile"], .string("triage"))
        wire.announceOtherController(profileKey: "different-profile")
        model.input("key")
        model.receiveClipboard("local only", generation: model.generation)
        XCTAssertEqual(commands, ["key"])

        wire.announceOtherController(profileKey: "triage-home")
        model.input("key")
        XCTAssertEqual(commands, ["key"])
        XCTAssertTrue(model.someoneElseControls)
        XCTAssertTrue(model.clipboard.isEmpty)
        model.close()
    }

    func testVoluntaryExitHandsBackButRequestExitKeepsItsLease() async throws {
        for reason in ["", "Please sign in."] {
            let wire = DesktopWire()
            let model = makeModel(wire)
            await model.open()?.value
            model.connected(generation: model.generation)
            await model.takeControl(reason: reason)?.value
            let left = await model.leave()
            XCTAssertTrue(left)
            XCTAssertEqual(wire.calls.contains { $0.method == "display.lease.release" }, reason.isEmpty)
            XCTAssertEqual(model.controlsDesktop, !reason.isEmpty)
            model.close()
        }
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

    func testHandshakeForbiddenDoesNotRetryOrAskForAnotherTicket() async {
        let wire = DesktopWire()
        let model = makeModel(wire)
        await model.open()?.value
        // An HTTP rejection occurs before the socket can send any close frame.
        let retry = model.disconnected(code: 0, httpStatus: 403, generation: model.generation)
        await retry?.value
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.request)
        XCTAssertEqual(wire.calls.map(\.method), ["display.status", "display.observe"])
        model.close()
    }

    func testRetryAfterRendererFailureReplacesTheViewerAndItsTicket() async throws {
        let model = makeModel(DesktopWire())
        await model.open()?.value
        let first = try XCTUnwrap(model.request?.url)
        let generation = model.generation
        let renderer = model.rendererRevision
        model.rendererFailed(generation: generation)
        XCTAssertEqual(model.phase, .rendererFailed)
        XCTAssertNil(model.request)

        await model.retry()?.value
        model.rendererFailed(generation: generation)
        XCTAssertEqual(model.phase, .connecting)
        XCTAssertNotEqual(model.rendererRevision, renderer)
        XCTAssertNotEqual(try XCTUnwrap(model.request?.url), first)
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

    private func makeModel(_ wire: DesktopWire, autoStart: Bool = false) -> BotDesktopSession {
        BotDesktopSession(client: wire, socketSession: URLSession(configuration: .ephemeral),
                          connection: connection("https://one.example"), profile: "triage", autoStartOnOpen: autoStart, wait: { _ in })
    }

    private func connection(_ address: String) -> BotConnection {
        BotConnection(id: UUID(), name: "Fixture", address: URL(string: address)!, username: "", password: "")
    }
}

private struct DesktopHostedProbe: View {
    let viewer: BotDesktopView
    let model: BotDesktopSession
    let onLive: () -> Void

    var body: some View {
        viewer.environment(\.scenePhase, .active)
            .onChange(of: model.phase) { if model.phase == .live { onLive() } }
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
    func announceOtherController(profileKey: String) {
        onEvent?(.object(["type": .string("display.lease"), "payload": .object([
            "profile_key": .string(profileKey), "lease": .object([
                "holder": .string("human"), "viewer_hash": .string("other-viewer"), "epoch": .number(2)
            ])
        ])]))
    }

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        calls.append(call)
        if let failure { throw failure }
        if case .displayAcquire(_, _, let reason) = call {
            return .object(["lease": .object([
                "holder": .string("human"), "viewer_hash": .string("aaeef5ea3f1e"), "epoch": .number(1), "reason": .string(reason)
            ])])
        }
        if case .displayRelease = call {
            return .object(["lease": .object(["holder": .string("agent"), "epoch": .number(2)])])
        }
        if case .displayStart = call { running = true }
        var result: [String: BotJSON] = ["supported": .bool(true), "installed": .bool(installed), "running": .bool(running),
                                         "profile_key": .string("triage-home")]
        if case .displayObserve = call {
            await beforeObserve?()
            ticket += 1
            result["path"] = .string("/api/display/ws")
            result["ticket"] = .string("ticket-\(ticket)")
            result["viewer_id"] = .string("viewer-fixture")
        }
        return .object(result)
    }
}

/// A loopback WebSocket serving a single raw RFB framebuffer. The hosted viewer
/// uses its real WebKit bridge and URLSession transport; no Hermes host is involved.
private final class DesktopRFBFixture: @unchecked Sendable {
    private enum Stage { case version, security, clientInit, firstUpdate, input }
    let listener: NWListener
    private let queue = DispatchQueue(label: "BotDesktopTests.RFB")
    private var connection: NWConnection?
    private var pointerMasks: [UInt8] = []
    private let pointerCount: Int
    private var stage = Stage.version
    private let onInput: ([UInt8]) -> Void

    init(onReady: @escaping () -> Void, pointerCount: Int, onInput: @escaping ([UInt8]) -> Void) throws {
        self.pointerCount = pointerCount
        self.onInput = onInput
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        webSocket.setClientRequestHandler(queue) { _, _ in .init(status: .accept, subprotocol: nil) }
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { if case .ready = $0 { onReady() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func close() {
        listener.cancel()
        queue.async { [self] in connection?.cancel(); connection = nil }
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let self, let connection else { return }
            send(Data("RFB 003.008\n".utf8), on: connection)
            read(connection)
        }
        connection.start(queue: queue)
    }

    private func send(_ bytes: Data, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "RFB", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: bytes, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, let data, error == nil else { return }
            switch stage {
            case .version:
                stage = .security
                send(Data([1, 1]), on: connection)
            case .security:
                stage = .clientInit
                send(Data([0, 0, 0, 0]), on: connection)
            case .clientInit:
                stage = .firstUpdate
                send(Data([0, 2, 0, 2, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0]), on: connection)
            case .firstUpdate where data.first == 3:
                stage = .input
                let update = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0]) + Data(repeating: 255, count: 16)
                send(update, on: connection)
            case .input where data.count == 6 && data.first == 5:
                pointerMasks.append(data[1])
                if pointerMasks.count == pointerCount { onInput(pointerMasks); return }
            default: break
            }
            read(connection)
        }
    }
}
