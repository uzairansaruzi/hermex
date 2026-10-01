import XCTest
@testable import HermesMobile

/// One saved connection's shared gateway socket, against a scripted host and scripted
/// sockets. The consumers are real `BotClient`s, one per screen, as the inbox, a chat,
/// a room and the editor hold them.
@MainActor final class HermesGatewayTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    /// Every socket the gateway opened, in order.
    private var sockets: [BotScriptedSocket] = []

    override func tearDown() {
        HermesHostFixture.reset()
        sockets = []
        super.tearDown()
    }

    func testConcurrentConsumersShareOneSignInTicketSocketAndHandshake() async throws {
        let http = connection()
        let inbox = BotClient(http: http), chat = BotClient(http: http), editor = BotClient(http: http)
        async let inboxConnected: Void = inbox.connect()
        async let chatConnected: Void = chat.connect()
        async let editorConnected: Void = editor.connect()
        _ = try await (inboxConnected, chatConnected, editorConnected)
        defer { inbox.close(); chat.close(); editor.close() }
        for client in [inbox, chat, editor] { _ = try await client.call(.profilesList(includeSessions: false)) }
        let room = BotClient(http: http)
        try await room.connect()
        defer { room.close() }
        _ = try await room.call(.groupsCapabilities)

        XCTAssertEqual(sockets.count, 1, "A screen that connects later joins the open socket")
        XCTAssertEqual(["/auth/password-login", "/api/auth/ws-ticket"].map(HermesHostFixture.count), [1, 1])
        XCTAssertEqual(sockets[0].outbound.map { $0["method"].text },
                       ["client.capabilities", "profiles.list", "profiles.list", "profiles.list", "groups.capabilities"])
    }

    func testLeavingEndsOnlyThatConsumersCallsAndCallbacks() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        defer { chat.close() }
        var chatHeard: [BotJSON] = [], inboxHeard: [BotJSON] = [], inboxLost = 0
        chat.onEvent = { chatHeard.append($0) }
        inbox.onEvent = { inboxHeard.append($0) }
        inbox.onDisconnect = { _ in inboxLost += 1 }
        let socket = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "both calls on the wire")
        sent.expectedFulfillmentCount = 2
        socket.withholdReply = { _ in sent.fulfill(); return true }
        let prompt = Task { try await chat.call(.promptSubmit(sessionID: "runtime", text: "hello")) }
        let roster = Task { try await inbox.call(.profilesList(includeSessions: true)) }
        await fulfillment(of: [sent], timeout: 2)

        inbox.close()
        do { _ = try await roster.value; XCTFail("A closed consumer's call must end") }
        catch { XCTAssertEqual(error as? BotFailure, .transport) }
        // The inbox's late reply reaches no one; the chat's event and reply still land.
        let delta = BotJSON.object(["session_id": .string("runtime"), "seq": .number(1), "type": .string("message.delta")])
        try answer(socket, "profiles.list", with: .object(["profiles": .array([])]))
        socket.enqueue(frame(["method": .string("event"), "params": delta]))
        try answer(socket, "prompt.submit", with: .object(["status": .string("queued")]))
        let accepted = try await prompt.value
        XCTAssertEqual(accepted["status"], .string("queued"))
        XCTAssertEqual(chatHeard, [delta])
        XCTAssertEqual(inboxHeard, [])
        XCTAssertEqual(inboxLost, 0, "Leaving is not a disconnect")
        XCTAssertFalse(socket.isClosed, "The chat still holds the socket")
        do { _ = try await inbox.call(.profilesList(includeSessions: false)); XCTFail("A closed consumer sends nothing") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
        XCTAssertEqual(socket.sentRequests.count, 2)
    }

    /// Replies settle only the call that sent them. Events and server requests go to every
    /// attached consumer, each once, in the host's order; each consumer admits its own.
    func testRepliesEventsAndServerRequestsInterleaveToTheirTargets() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        defer { chat.close(); inbox.close() }
        var chatHeard: [BotJSON] = [], inboxHeard: [BotJSON] = []
        chat.onEvent = { chatHeard.append($0) }
        inbox.onEvent = { inboxHeard.append($0) }
        let socket = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "both calls on the wire")
        sent.expectedFulfillmentCount = 2
        socket.withholdReply = { _ in sent.fulfill(); return true }
        let resume = Task { try await chat.call(.sessionResume(profile: "inbox-triage", sessionID: "tip", omitMessages: true)) }
        let roster = Task { try await inbox.call(.profilesList(includeSessions: false)) }
        await fulfillment(of: [sent], timeout: 2)

        let changed = BotJSON.object(["type": .string("sessions.changed")])
        let request = BotJSON.object(["jsonrpc": .string("2.0"), "id": .string("srq-1"), "method": .string("sudo"),
                                      "params": .object(["session_id": .string("runtime")])])
        try answer(socket, "profiles.list", with: .object(["profiles": .array([.object(["name": .string("inbox-triage")])])]))
        socket.enqueue(frame(["method": .string("event"), "params": changed]))
        socket.enqueue(frame(request.fields ?? [:]))
        try answer(socket, "session.resume", with: .object(["session_id": .string("runtime")]))

        let rows = try await roster.value["profiles"].list
        XCTAssertEqual(rows?.first?["name"], .string("inbox-triage"))
        let resumed = try await resume.value
        XCTAssertEqual(resumed["session_id"], .string("runtime"))
        XCTAssertEqual(chatHeard, [changed, request])
        XCTAssertEqual(inboxHeard, [changed, request])
    }

    func testASocketFaultTellsEachConsumerOnceAndTheirReconnectsShareOneReplacement() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        defer { chat.close(); inbox.close() }
        var lost: [String] = []
        let told = expectation(description: "both consumers told")
        told.expectedFulfillmentCount = 2
        chat.onDisconnect = { _ in lost.append("chat"); told.fulfill() }
        inbox.onDisconnect = { _ in lost.append("inbox"); told.fulfill() }
        let first = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "stop on the wire")
        first.withholdReply = { _ in sent.fulfill(); return true }
        let stop = Task { try await chat.call(.sessionInterrupt(sessionID: "runtime")) }
        await fulfillment(of: [sent], timeout: 2)

        first.cancel()
        await fulfillment(of: [told], timeout: 2)
        do { _ = try await stop.value; XCTFail("The stop's outcome is unknown") }
        catch { XCTAssertEqual(error as? BotFailure, .transport) }
        XCTAssertEqual(lost.sorted(), ["chat", "inbox"])

        async let chatBack: Void = chat.connect()
        async let inboxBack: Void = inbox.connect()
        _ = try await (chatBack, inboxBack)
        _ = try await inbox.call(.profilesList(includeSessions: false))
        XCTAssertEqual(sockets.count, 2, "One replacement for both")
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 2, "A fresh ticket for it")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 1, "On the same sign-in")
        XCTAssertEqual(sockets[1].outbound.map { $0["method"].text }, ["client.capabilities", "profiles.list"])
        XCTAssertEqual(first.sentRequests.filter { $0["method"].text == "session.interrupt" }.count, 1, "Never resent")
    }

    /// The socket fails both consumers' sends and then its reader: one report each. A
    /// consumer that has not reconnected stays out of the replacement: it sends nothing,
    /// hears nothing, and is not told when the replacement drops.
    func testOneSocketsFailuresReportOnceAndAStaleConsumerStaysOut() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        defer { chat.close(); inbox.close() }
        var reports = 0
        let told = expectation(description: "each consumer told once")
        told.expectedFulfillmentCount = 2
        chat.onDisconnect = { _ in reports += 1; told.fulfill() }
        inbox.onDisconnect = { _ in reports += 1; told.fulfill() }
        let first = try XCTUnwrap(sockets.first)
        first.sendFailure = URLError(.networkConnectionLost)
        let chatSend = Task { try await chat.call(.profilesList(includeSessions: false)) }
        let inboxSend = Task { try await inbox.call(.sessionActiveList) }
        for send in [chatSend, inboxSend] {
            do { _ = try await send.value; XCTFail("A failed send cannot succeed") }
            catch { XCTAssertEqual(error as? BotFailure, .transport) }
        }
        await fulfillment(of: [told], timeout: 2)

        try await chat.connect()
        XCTAssertEqual(sockets.count, 2)
        let second = try XCTUnwrap(sockets.last)
        var chatHeard: [BotJSON] = [], inboxHeard: [BotJSON] = []
        chat.onEvent = { chatHeard.append($0) }
        inbox.onEvent = { inboxHeard.append($0) }
        let changed = BotJSON.object(["type": .string("sessions.changed")])
        second.enqueue(frame(["method": .string("event"), "params": changed]))
        _ = try await chat.call(.profilesList(includeSessions: false))
        XCTAssertEqual(chatHeard, [changed])
        XCTAssertEqual(inboxHeard, [])
        do { _ = try await inbox.call(.profilesList(includeSessions: false)); XCTFail("The inbox has not reconnected") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }

        let chatTold = expectation(description: "the chat hears the replacement drop")
        chat.onDisconnect = { _ in chatTold.fulfill() }
        second.cancel()
        await fulfillment(of: [chatTold], timeout: 2)
        XCTAssertEqual(reports, 2, "The inbox is not told about a socket it never joined")
    }

    /// A call that may have reached the agent has an unknown outcome once cancelled, so its
    /// consumer ends as if closed. The socket and the other consumer's work stay.
    func testCancellingAnUncertainCallEndsOnlyItsConsumer() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        defer { inbox.close() }
        let socket = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "three calls on the wire")
        sent.expectedFulfillmentCount = 3
        socket.withholdReply = { _ in sent.fulfill(); return true }
        let prompt = Task { try await chat.call(.promptSubmit(sessionID: "runtime", text: "hello")) }
        let workers = Task { try await chat.call(.subagentList(sessionID: "runtime")) }
        let roster = Task { try await inbox.call(.profilesList(includeSessions: false)) }
        await fulfillment(of: [sent], timeout: 2)

        prompt.cancel()
        for call in [prompt, workers] {
            do { _ = try await call.value; XCTFail("The chat's calls end with it") }
            catch { XCTAssertEqual(error as? BotFailure, .transport) }
        }
        do { _ = try await chat.call(.profilesList(includeSessions: false)); XCTFail("The chat must reconnect first") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
        try answer(socket, "profiles.list", with: .object(["profiles": .array([])]))
        let rows = try await roster.value["profiles"].list
        XCTAssertEqual(rows, [])
        XCTAssertFalse(socket.isClosed)
        XCTAssertEqual(socket.sentRequests.filter { $0["method"].text == "prompt.submit" }.count, 1, "Never resent")
    }

    /// A required call left unanswered past its deadline ends only its consumer, which hears
    /// it once as a lost connection. The heartbeat and the silence deadline decide whether
    /// the socket itself is gone, so the other consumer stays and the reconnect joins it.
    func testARequiredCallsDeadlineEndsOnlyItsConsumer() async throws {
        let http = connection(rpcDeadline: .milliseconds(50))
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        defer { chat.close(); inbox.close() }
        var chatLost: [BotFailure?] = [], inboxLost = 0
        let told = expectation(description: "the chat told")
        chat.onDisconnect = { chatLost.append($0 as? BotFailure); told.fulfill() }
        inbox.onDisconnect = { _ in inboxLost += 1 }
        let socket = try XCTUnwrap(sockets.first)
        socket.withholdReply = { $0["method"].text == "session.resume" }

        do {
            _ = try await chat.call(.sessionResume(profile: "inbox-triage", sessionID: "tip", omitMessages: true))
            XCTFail("An unanswered call cannot succeed")
        } catch { XCTAssertEqual(error as? BotFailure, .transport) }
        await fulfillment(of: [told], timeout: 2)
        XCTAssertEqual(chatLost, [.transport])
        XCTAssertEqual(inboxLost, 0, "Another consumer's deadline is not a lost socket")
        XCTAssertFalse(socket.isClosed)
        _ = try await inbox.call(.profilesList(includeSessions: false))

        try await chat.connect()
        _ = try await chat.call(.profilesList(includeSessions: false))
        XCTAssertEqual(sockets.count, 1, "The reconnect joins the open socket")
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 1)
    }

    /// The socket closes with the last screen to leave, and the next screen opens a fresh
    /// one on the same sign-in.
    func testTheSocketLivesWhileAConsumerHoldsItAndReopensFresh() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        let first = try XCTUnwrap(sockets.first)
        chat.close()
        XCTAssertFalse(first.isClosed)
        inbox.close()
        XCTAssertTrue(first.isClosed)

        try await inbox.connect()
        defer { inbox.close() }
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(["/auth/password-login", "/api/auth/ws-ticket"].map(HermesHostFixture.count), [1, 2])
        XCTAssertEqual(sockets[1].outbound.map { $0["method"].text }, ["client.capabilities"])
    }

    /// The app going to the background closes the socket once and tells no screen (#902):
    /// each screen suspends on `.background` itself, and its return opens one fresh socket
    /// with a new ticket and one handshake.
    func testTheBackgroundClosesTheSocketOnceAndSilently() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        var lost = 0
        chat.onDisconnect = { _ in lost += 1 }
        inbox.onDisconnect = { _ in lost += 1 }
        let first = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "read on the wire")
        first.withholdReply = { _ in sent.fulfill(); return true }
        let read = Task { try await chat.call(.profilesList(includeSessions: false)) }
        await fulfillment(of: [sent], timeout: 2)

        http.gateway.closeForBackground()
        XCTAssertTrue(first.isClosed)
        XCTAssertEqual(lost, 0, "The background close is silent")
        do { _ = try await read.value; XCTFail("A closed socket answers nothing") }
        catch { XCTAssertEqual(error as? BotFailure, .transport) }
        // Then each screen suspends, which leaves nothing more to close.
        chat.close(); inbox.close()
        XCTAssertEqual(lost, 0)

        async let chatBack: Void = chat.connect()
        async let inboxBack: Void = inbox.connect()
        _ = try await (chatBack, inboxBack)
        defer { chat.close(); inbox.close() }
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(["/auth/password-login", "/api/auth/ws-ticket"].map(HermesHostFixture.count), [1, 2])
        XCTAssertEqual(sockets[1].outbound.map { $0["method"].text }, ["client.capabilities"])
    }

    func testLeavingWhileTheSocketOpensOpensNothing() async throws {
        let parked = expectation(description: "ticket in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        let http = connection { $0.url?.path == "/api/auth/ws-ticket" ? .park : nil }
        let chat = BotClient(http: http)
        let connecting = Task { try await chat.connect() }
        await fulfillment(of: [parked], timeout: 2)
        chat.close()
        HermesHostFixture.releaseParked()
        do { try await connecting.value; XCTFail("A closed consumer must not connect") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
        XCTAssertEqual(sockets.count, 0, "The late ticket opens no socket")
    }

    /// The connection is retired when its server, UUID or credentials are replaced.
    func testRetiringTheConnectionTellsEachConsumerOnceAndRefusesReconnects() async throws {
        let http = connection()
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        var reasons: [BotFailure?] = []
        chat.onDisconnect = { reasons.append($0 as? BotFailure) }
        inbox.onDisconnect = { reasons.append($0 as? BotFailure) }
        let socket = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "read on the wire")
        socket.withholdReply = { _ in sent.fulfill(); return true }
        let read = Task { try await chat.call(.profilesList(includeSessions: false)) }
        await fulfillment(of: [sent], timeout: 2)

        http.retire()
        XCTAssertEqual(reasons, [.stale, .stale])
        do { _ = try await read.value; XCTFail("A retired socket answers nothing") }
        catch { XCTAssertEqual(error as? BotFailure, .transport) }
        XCTAssertTrue(socket.isClosed)
        do { try await chat.connect(); XCTFail("A retired connection cannot reconnect") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
        XCTAssertEqual(HermesHostFixture.count("/api/auth/ws-ticket"), 1)
        XCTAssertEqual(reasons.count, 2)
    }

    /// A saved connection whose gateway opens scripted sockets, kept in `sockets`.
    private func connection(rpcDeadline: Duration = .seconds(30),
                            _ answer: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) -> HermesConnection {
        HermesConnection(connection: record, configuration: HermesHostFixture.configuration(answer),
                         gateway: .init(rpcDeadline: rpcDeadline) { [weak self] _ in
                             let socket = BotScriptedSocket()
                             self?.sockets.append(socket)
                             return socket
                         })
    }

    /// Answers the first sent request for `method`.
    private func answer(_ socket: BotScriptedSocket, _ method: String, with result: BotJSON) throws {
        let request = try XCTUnwrap(socket.sentRequests.first { $0["method"].text == method })
        socket.enqueue(frame(["id": request["id"], "result": result]))
    }

    private func frame(_ fields: [String: BotJSON]) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: (try? JSONEncoder().encode(BotJSON.object(fields))) ?? Data(), as: UTF8.self))
    }
}
