import XCTest
@testable import HermesMobile

@MainActor final class HermesGatewayTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")
    private var sockets: [BotScriptedSocket] = []

    override func tearDown() {
        HermesHostFixture.reset()
        sockets = []
        super.tearDown()
    }

    func testAnUnansweredApprovalSummaryTimesOutWithoutDisconnectingChat() async throws {
        let chat = BotClient(http: connection(rpcDeadline: .milliseconds(50)))
        try await chat.connect()
        defer { chat.close() }
        var lost = 0
        chat.onDisconnect = { _ in lost += 1 }
        let socket = try XCTUnwrap(sockets.first)
        socket.withholdReply = { $0["method"].text == "llm.oneshot" }
        do {
            _ = try await chat.call(.approvalSummary(input: "Command: rm ./draft.txt", language: "English", sessionID: "runtime", profile: "default"))
            XCTFail("An unanswered summary must time out")
        } catch { XCTAssertEqual(error as? BotFailure, .transport) }
        XCTAssertEqual(lost, 0)
        XCTAssertFalse(socket.isClosed)
        let profiles = try await chat.call(.profilesList(includeSessions: false))["profiles"].list
        XCTAssertEqual(profiles, [], "the same consumer can still approve and read")
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

    func testACanonicalSessionIsDetachedOnlyWhenItsLastScreenLeaves() async throws {
        let http = connection(canonical: true)
        let older = BotClient(http: http), newer = BotClient(http: http), inbox = BotClient(http: http)
        for client in [older, newer, inbox] { try await client.connect() }
        defer { older.close(); newer.close(); inbox.close() }
        let socket = try XCTUnwrap(sockets.first)
        socket.reply = Self.canonicalReply
        _ = try await older.call(.sessionResume(profile: "default", sessionID: "tip", omitMessages: true))
        let sent = expectation(description: "the newer resume is on the wire")
        let detached = expectation(description: "the session is detached")
        socket.withholdReply = { request in
            if request["method"].text == "session.detach" { detached.fulfill() }
            guard request["method"].text == "session.resume" else { return false }
            sent.fulfill()
            return true
        }
        let attaching = Task { try await newer.call(.sessionResume(profile: "default", sessionID: "tip", omitMessages: true)) }
        await fulfillment(of: [sent], timeout: 2)

        older.close()
        _ = try await inbox.call(.sessionActiveList)
        XCTAssertFalse(socket.sentRequests.contains { $0["method"].text == "session.detach" })
        newer.close()
        await fulfillment(of: [detached], timeout: 2)
        let detaches = socket.sentRequests.filter { $0["method"].text == "session.detach" }.map { $0["params"] }
        XCTAssertEqual(detaches, [.object(["profile": .string("default"), "session_id": .string("tip"), "subscription_id": .string("sub-1")])])
        _ = try? await attaching.value
    }

    func testACanonicalAttachAnsweredAfterItsScreenLeftIsDetached() async throws {
        let http = connection(canonical: true)
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        for client in [chat, inbox] { try await client.connect() }
        defer { chat.close(); inbox.close() }
        let socket = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "the resume is on the wire")
        let detached = expectation(description: "the late subscription is detached")
        socket.withholdReply = { request in
            if request["method"].text == "session.detach" { detached.fulfill() }
            guard request["method"].text == "session.resume" else { return false }
            sent.fulfill()
            return true
        }
        let attaching = Task { try await chat.call(.sessionResume(profile: "default", sessionID: "tip", omitMessages: true)) }
        await fulfillment(of: [sent], timeout: 2)
        chat.close()
        let resume = try XCTUnwrap(socket.sentRequests.first { $0["method"].text == "session.resume" })
        socket.enqueue(frame(Self.canonicalReply(resume).fields ?? [:]))
        await fulfillment(of: [detached], timeout: 2)
        let detach = socket.sentRequests.first { $0["method"].text == "session.detach" }?["params"]
        XCTAssertEqual(detach?["subscription_id"].text, "sub-1")
        _ = try? await attaching.value
    }

    func testAStoredSessionEditReleasesItsReadAfterwards() async throws {
        let list = BotClient(http: connection(canonical: true))
        try await list.connect()
        defer { list.close() }
        let socket = try XCTUnwrap(sockets.first)
        let detached = expectation(description: "the session is detached")
        socket.withholdReply = { request in
            if request["method"].text == "session.detach" { detached.fulfill() }
            return false
        }
        socket.reply = { request in
            guard request["method"].text == "session.resume" else { return .object(["id": request["id"], "result": .object([:])]) }
            var snapshot = Self.canonicalReply(request)["result"].fields ?? [:]
            snapshot["revision"] = .number(1); snapshot["execution_generation"] = .number(1)
            return .object(["id": request["id"], "result": .object(snapshot)])
        }
        _ = try await list.mutateStoredSession(profile: "default", key: "tip", .workspace(cwd: "/work"))
        await fulfillment(of: [detached], timeout: 2)
        let detach = socket.sentRequests.first { $0["method"].text == "session.detach" }?["params"]
        XCTAssertEqual(detach?["subscription_id"].text, "sub-1")
    }

    static let duplicateBots = [("telegram", "TELEGRAM_BOT_TOKEN"), ("discord", "DISCORD_BOT_TOKEN")].map { platform, key in
        "Profiles 'default' and 'dev' both hold the same \(platform) credential (\(key)): one platform token can serve only one "
            + "gateway, so the bot answers from whichever profile claims it first and the other's adapter is parked. Give 'dev' "
            + "its own bot token, or remove \(key) from the profile that should not own it (or keep it in default and route dev's "
            + "chats with profile_routes — gateway.profile_routes in default's config.yaml), then run hermes gateway migrate --multiplex."
    }.joined(separator: "; ")

    func testAWebappsReasonIsSummarizedOnlyWhenEveryBlockerIsADuplicateBot() {
        XCTAssertEqual(HermesStandaloneReason(hostText: Self.duplicateBots).summary, "dev and default use the same Telegram and Discord bots.")
        let portBinder = "Profile 'ops' enables whatsapp, which binds its own port and has no /p/ops/ ingress on the default listener "
            + "yet; the multiplexer would skip the whole profile. Disable it there (platforms.whatsapp.enabled: false) or add a "
            + "/p/<profile>/ ingress for it first."
        XCTAssertNil(HermesStandaloneReason(hostText: Self.duplicateBots + "; " + portBinder).summary)
    }

    func testAWebappKeepsEachProfilesChatsOnTheirOwnSocket() async throws {
        for webapp in [true, false] {
            sockets = []
            HermesHostFixture.reset()
            var statuses = 0
            let http = connection(canonical: webapp, refuses: {
                $0.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")?.contains("bound-parked") == true
            }) { request in
                if request.url?.path == "/api/webapp/socket-ticket" {
                    let profile = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "profile" }?.value ?? ""
                    return .json(200, .object(["ticket": .string("bound-" + profile)]))
                }
                guard request.url?.path == "/api/status" else { return nil }
                statuses += 1
                let install: [String: BotJSON] = webapp && statuses == 1 ? [:] : ["install_id": .string("install"),
                                                                                  "multiplex_standalone_reason": .string(Self.duplicateBots)]
                return .json(200, .object(install.merging(["auth_required": .bool(true),
                                                           "auth_providers": .array([.string("basic")])]) { $1 }))
            }
            let inbox = BotClient(http: http), work = BotClient(http: http, profile: "work")
            let alsoWork = BotClient(http: http, profile: "work"), home = BotClient(http: http, profile: "home")
            for client in [inbox, work, alsoWork, home] { try await client.connect() }
            XCTAssertEqual(sockets.count, webapp ? 3 : 1, webapp ? "Webapp" : "dashboard")
            let bound = HermesHostFixture.requests.filter { $0.url?.path == "/api/webapp/socket-ticket" }
                .compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
            XCTAssertEqual(Set(bound.compactMap { $0.first { $0.name == "profile" }?.value }), webapp ? ["work", "home"] : [])
            if webapp {
                let parked = BotClient(http: http, profile: "parked")
                do { try await parked.connect(); XCTFail("the Webapp refused the parked Profile") }
                catch { XCTAssertEqual(error as? BotFailure, .profileNotServed("parked", HermesStandaloneReason(hostText: Self.duplicateBots))) }
                XCTAssertFalse(BotConnectionAdvice.isRetryable(BotFailure.profileNotServed("parked", nil)))
                parked.close()

                var proxied = 0
                let blocked = connection(canonical: true, refuses: { _ in true }) { request in
                    if request.url?.path == "/api/webapp/socket-ticket" { return .json(200, .object(["ticket": .string("bound")])) }
                    guard request.url?.path == "/api/status" else { return nil }
                    proxied += 1
                    let install: [String: BotJSON] = proxied == 1 ? [:] : ["install_id": .string("install")]
                    return .json(200, .object(install.merging(["auth_required": .bool(true),
                                                               "auth_providers": .array([.string("basic")])]) { $1 }))
                }
                let behindProxy = BotClient(http: blocked, profile: "work")
                do { try await behindProxy.connect(); XCTFail("the proxy refused the socket") }
                catch { XCTAssertEqual(error as? BotFailure, .upgradeRefused(403)) }
                behindProxy.close()
            }
            for client in [inbox, work, alsoWork, home] { client.close() }
        }
    }

    private nonisolated static func canonicalReply(_ request: BotJSON) -> BotJSON {
        let snapshot = BotJSON.object(["session_id": .string("tip"), "stored_session_id": .string("tip"),
                                       "subscription_id": .string("sub-1"), "replay_epoch": .string("session-epoch")])
        return .object(["id": request["id"], "result": request["method"].text == "session.resume" ? snapshot : .object([:])])
    }

    func testACanonicalRoomRetryCarriesItsFenceAndAStaleOneSaysToReopen() async throws {
        let client = BotClient(http: connection(canonical: true))
        try await client.connect()
        defer { client.close() }
        let socket = try XCTUnwrap(sockets.first)
        socket.reply = { request in .object(["id": request["id"], "error": .object(["code": .number(4001),
            "message": .string("stale_generation"), "data": .object(["reason": .string("stale_generation")])])]) }
        let retry = HermesCall.groupsRetry(roomID: "room", taskID: "task", attempt: .init(memberID: "dev", executionGeneration: 3))
        do { _ = try await client.call(retry); XCTFail("The stale retry was refused") } catch {
            XCTAssertEqual((error as? BotRoomFailure)?.reason, "stale_generation")
            XCTAssertTrue(error.localizedDescription.contains("Reopen it"))
        }
        let sent = try XCTUnwrap(socket.sentRequests.first { $0["method"].text == "groups.retry" })
        XCTAssertEqual(sent["params"]["member_id"].text, "dev")
        XCTAssertEqual(sent["params"]["execution_generation"].integer, 3)
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

    func testAProbeKeepsASocketThatAnswers() async throws {
        let http = connection()
        let chat = BotClient(http: http)
        try await chat.connect()
        defer { chat.close() }
        var lost = 0
        chat.onDisconnect = { _ in lost += 1 }

        await http.liveGateway?.probe()

        let socket = try XCTUnwrap(sockets.first)
        XCTAssertEqual(socket.outbound.filter { $0["method"].text == "gateway.ping" }.count, 1)
        XCTAssertFalse(socket.isClosed)
        XCTAssertEqual(lost, 0)
    }

    func testASilentSocketIsLostAtTheProbeDeadlineAndConsumersShareOneReplacement() async throws {
        let http = connection(probeDeadline: .milliseconds(50))
        let chat = BotClient(http: http), inbox = BotClient(http: http)
        try await chat.connect()
        try await inbox.connect()
        defer { chat.close(); inbox.close() }
        var lost: [String] = []
        chat.onDisconnect = { lost.append("chat"); XCTAssertEqual($0 as? BotFailure, .transport) }
        inbox.onDisconnect = { lost.append("inbox"); XCTAssertEqual($0 as? BotFailure, .transport) }
        let first = try XCTUnwrap(sockets.first)
        first.holdsSend = { $0["method"].text == "gateway.ping" }
        let gateway = try XCTUnwrap(http.liveGateway)

        async let probe: Void = gateway.probe()
        async let again: Void = gateway.probe()
        _ = await (probe, again)

        XCTAssertTrue(first.isClosed)
        XCTAssertEqual(lost.sorted(), ["chat", "inbox"])
        XCTAssertEqual(first.outbound.filter { $0["method"].text == "gateway.ping" }.count, 1)
        async let chatBack: Void = chat.connect()
        async let inboxBack: Void = inbox.connect()
        _ = try await (chatBack, inboxBack)
        XCTAssertEqual(sockets.count, 2, "One replacement for both")
    }

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

    func testCancellingAProfilesReadKeepsItsConsumer() async throws {
        let http = connection()
        let list = BotClient(http: http)
        try await list.connect()
        defer { list.close() }
        let socket = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "roster on the wire")
        socket.withholdReply = { _ in sent.fulfill(); return true }
        let roster = Task { try await list.call(.profilesList(includeSessions: false)) }
        await fulfillment(of: [sent], timeout: 2)

        roster.cancel()
        do { _ = try await roster.value; XCTFail("A cancelled read gets no reply") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        socket.withholdReply = nil
        let rows = try await list.call(.profilesList(includeSessions: false))["profiles"].list
        XCTAssertEqual(rows, [], "the screen still reads on the socket")
    }

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

    func testBotChatsUnansweredCompletionEndsItsConsumer() async throws {
        let http = connection(rpcDeadline: .milliseconds(50))
        let chat = BotClient(http: http)
        try await chat.connect()
        defer { chat.close() }
        var lost: [BotFailure?] = []
        let told = expectation(description: "the chat told")
        chat.onDisconnect = { lost.append($0 as? BotFailure); told.fulfill() }
        let socket = try XCTUnwrap(sockets.first)
        socket.withholdReply = { $0["method"].text == "complete.path" }

        do {
            _ = try await chat.call(.completePath(word: "Sou", sessionID: "runtime", profile: "default"))
            XCTFail("An unanswered call cannot succeed")
        } catch { XCTAssertEqual(error as? BotFailure, .transport) }
        await fulfillment(of: [told], timeout: 2)
        XCTAssertEqual(lost, [.transport])
    }

    func testACompressionOutlivesTheUsualDeadline() async throws {
        let http = connection(rpcDeadline: .milliseconds(50))
        let chat = BotClient(http: http), other = BotClient(http: http)
        try await chat.connect()
        try await other.connect()
        defer { chat.close(); other.close() }
        var chatLost = 0
        chat.onDisconnect = { _ in chatLost += 1 }
        let socket = try XCTUnwrap(sockets.first)
        let sent = expectation(description: "compress on the wire")
        socket.withholdReply = { request in
            if request["method"].text == "session.compress" { sent.fulfill(); return true }
            return request["method"].text == "session.resume"
        }

        let compress = Task { try await chat.call(.sessionCompress(runtime: "runtime", focus: nil, profile: "default")) }
        await fulfillment(of: [sent], timeout: 2)
        do {
            _ = try await other.call(.sessionResume(profile: "default", sessionID: "tip", omitMessages: true))
            XCTFail("An unanswered call cannot succeed")
        } catch { XCTAssertEqual(error as? BotFailure, .transport, "the usual deadline passed") }
        try answer(socket, "session.compress", with: .object(["status": .string("compressed"), "removed": .number(4)]))

        let reply = try await compress.value
        XCTAssertEqual(reply["removed"].integer, 4)
        XCTAssertEqual(chatLost, 0)
    }

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

    func testAUsableTicketNeverClaimsTheRefusedSocketConnected() async throws {
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil },
                                    gateway: .init { _ in
                                        let socket = BotScriptedSocket()
                                        socket.receiveFailure = BotFailure.upgradeRefused(403)
                                        return socket
                                    })
        let client = BotClient(http: http)
        do { try await client.connect(); XCTFail("The upgrade was refused") }
        catch { XCTAssertEqual(error as? BotFailure, .upgradeRefused(403)) }

        let attempt = try XCTUnwrap(http.lastAttempt)
        XCTAssertEqual(HermesAttemptRecord.Stage.allCases.map { attempt[$0] },
                       [.passed, .passed, .passed, .passed, .failed(.http(403))])
    }

    func testASocketLostMidHandshakeFailsTheLiveHandshake() async throws {
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration { _ in nil },
                                    gateway: .init { _ in
                                        let socket = BotScriptedSocket()
                                        socket.sendFailure = URLError(.networkConnectionLost)
                                        return socket
                                    })
        let client = BotClient(http: http)
        do { try await client.connect(); XCTFail("The socket dropped mid-handshake") } catch {}

        let attempt = try XCTUnwrap(http.lastAttempt)
        XCTAssertEqual(HermesAttemptRecord.Stage.allCases.map { attempt[$0] },
                       [.passed, .passed, .passed, .passed, .failed(.unreachable)])
    }

    func testATicketsRefusedReSignInIsASignInFailure() async throws {
        var logins = 0
        let client = BotClient(http: connection { request in
            switch request.url?.path {
            case "/api/auth/ws-ticket": return .json(401, .object(["detail": .string("Unauthorized")]))
            case "/auth/password-login":
                logins += 1
                return logins == 1 ? nil : .json(401, .object(["error": .string("invalid_credentials")]))
            default: return nil
            }
        })
        do { try await client.connect(); XCTFail("The second sign-in was refused") } catch {}

        let attempt = try XCTUnwrap(client.lastAttempt)
        XCTAssertEqual(HermesAttemptRecord.Stage.allCases.map { attempt[$0] },
                       [.passed, .failed(.http(401)), .notChecked, .notChecked, .notChecked])
    }

    private func connection(rpcDeadline: Duration = .seconds(30), probeDeadline: Duration = .seconds(30), canonical: Bool = false,
                            refuses: @escaping (URLRequest) -> Bool = { _ in false },
                            _ answer: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }) -> HermesConnection {
        let ready = canonical ? #"{"replay_epoch":"epoch","session_authority":true}"# : #"{"replay_epoch":"epoch"}"#
        return HermesConnection(connection: record, configuration: HermesHostFixture.configuration(answer),
                                gateway: .init(rpcDeadline: rpcDeadline, probeDeadline: probeDeadline, socketFactory: { [weak self] upgrade in
                                    let socket = BotScriptedSocket(ready: ready)
                                    if refuses(upgrade) { socket.receiveFailure = BotFailure.upgradeRefused(403) }
                                    self?.sockets.append(socket)
                                    return socket
                                }))
    }

    private func answer(_ socket: BotScriptedSocket, _ method: String, with result: BotJSON) throws {
        let request = try XCTUnwrap(socket.sentRequests.first { $0["method"].text == method })
        socket.enqueue(frame(["id": request["id"], "result": result]))
    }

    private func frame(_ fields: [String: BotJSON]) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: (try? JSONEncoder().encode(BotJSON.object(fields))) ?? Data(), as: UTF8.self))
    }
}
