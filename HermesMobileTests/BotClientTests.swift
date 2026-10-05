import CryptoKit
import Network
import XCTest
@testable import HermesMobile

@MainActor final class BotClientTests: XCTestCase {
    override func tearDown() {
        BotHTTPFixture.handler = nil
        BotHTTPFixture.raw = nil
        BotHTTPFixture.redirect = nil
        BotHTTPFixture.requested = []
        super.tearDown()
    }

    func testPasswordGateIdentityAndFreshTicketsUseTextRPCOnEverySocket() async throws {
        var tickets = 0
        var paths: [String] = []
        BotHTTPFixture.handler = { request in
            let path = request.url!.path
            paths.append(path)
            switch path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]), "version": .string("0.22.0")]))
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
        var protocols: [String] = []
        var sockets: [BotScriptedSocket] = []
        let client = BotClient(connection: connection(), configuration: configuration) { upgrade in
            XCTAssertEqual(upgrade.url?.scheme, "wss")
            XCTAssertEqual(upgrade.url?.path, "/api/ws")
            XCTAssertNil(upgrade.url?.query)
            protocols.append(upgrade.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? "")
            let socket = BotScriptedSocket()
            sockets.append(socket)
            return socket
        }
        for _ in 0..<2 {
            try await client.connect()
            XCTAssertEqual(client.serverVersion, "0.22.0")
            let roster = try await client.call(.profilesList(includeSessions: false))
            XCTAssertEqual(roster["profiles"].list, [])
            do {
                _ = try await client.call(.sessionInterrupt(sessionID: "runtime")) { throw BotFailure.stale }
                XCTFail("A stale action must not dispatch")
            } catch { XCTAssertEqual(error as? BotFailure, .stale) }
            client.close()
        }
        XCTAssertEqual(tickets, 2)
        XCTAssertEqual(protocols, ["hermes-gateway-v1, hermes-gateway-ticket.ticket-1", "hermes-gateway-v1, hermes-gateway-ticket.ticket-2"])
        XCTAssertEqual(paths.filter { $0 == "/api/auth/me" }.count, 1, "The second socket reuses the sign-in")
        XCTAssertEqual(sockets.map { $0.sentTextFrames }, [1, 1])
    }

    /// A reconnect mints a fresh ticket on the cookie the first sign-in stored. A ticket
    /// the host refuses as unauthenticated signs in once more and is minted again.
    func testReconnectsReuseTheSignInAndRecoverAnExpiredSessionOnce() async throws {
        var logins = 0
        var tickets = 0
        var expireNextTicket = false
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/auth/password-login": logins += 1; return (200, .object([:]))
            case "/api/auth/ws-ticket":
                if expireNextTicket { expireNextTicket = false; return (401, .object(["error": .string("session_expired")])) }
                tickets += 1
                return (200, .object(["ticket": .string("ticket-\(tickets)")]))
            default: return Self.signIn(request)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration) { _ in BotScriptedSocket() }
        for _ in 0..<2 {
            try await client.connect()
            client.close()
        }
        XCTAssertEqual(logins, 1, "A reconnect reuses the stored sign-in")
        expireNextTicket = true
        try await client.connect()
        client.close()
        XCTAssertEqual(logins, 2, "An expired session signs in once more")
        XCTAssertEqual(tickets, 3)
    }

    /// Without `client.capabilities` the host withdraws every approval, answers
    /// every clarify empty and skips sudo/secret, so it goes first on every
    /// socket — reconnects included — with exactly the contract's one key.
    func testClientCapabilitiesIsTheFirstFrameAfterReadyOnEverySocket() async throws {
        BotHTTPFixture.handler = Self.signIn
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        var sockets: [BotScriptedSocket] = []
        let client = BotClient(connection: connection(), configuration: configuration) { _ in
            let socket = BotScriptedSocket()
            sockets.append(socket)
            return socket
        }
        for _ in 0..<2 {
            try await client.connect()
            _ = try await client.call(.profilesList(includeSessions: false))
            client.close()
        }
        XCTAssertEqual(sockets.count, 2)
        for socket in sockets {
            XCTAssertEqual(socket.outbound.map { $0["method"].text }, ["client.capabilities", "profiles.list"])
            XCTAssertEqual(socket.outbound.first?["params"], .object(["server_requests": .bool(true)]))
            XCTAssertNotNil(socket.outbound.first?["id"].integer)
        }
        // The handshake is the client's own and `HermesCall.clientCapabilities` has no
        // parameter to widen. The pre-0.21.2 answer methods (`clarify.respond`,
        // `sudo.respond`, `secret.respond`, `mcp.setup.respond`) have no case at all.
    }

    /// A host older than the capability answers -32601. It has nothing to
    /// withhold, so the socket connects and works as before.
    func testAHostWithoutClientCapabilitiesStillConnects() async throws {
        BotHTTPFixture.handler = Self.signIn
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        socket.capabilitiesReply = { request in
            .object(["id": request["id"], "error": .object(["code": .number(-32601), "message": .string("unknown method")])])
        }
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }
        _ = try await client.call(.profilesList(includeSessions: false))
        XCTAssertEqual(socket.outbound.map { $0["method"].text }, ["client.capabilities", "profiles.list"])
    }

    /// The host sends no JSON heartbeat, so an idle socket would hit the 45 s
    /// silence deadline. The client pings on its own cadence, only after the
    /// handshake, and the pong's string id never settles an RPC.
    func testGatewayPingKeepsAnIdleSocketAliveOnTheInjectedCadence() async throws {
        BotHTTPFixture.handler = Self.signIn
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let pinged = expectation(description: "two keepalive pings")
        pinged.expectedFulfillmentCount = 2
        pinged.assertForOverFulfill = false
        socket.onPing = { pinged.fulfill() }
        let client = BotClient(connection: connection(), configuration: configuration,
                               heartbeatInterval: .milliseconds(10)) { _ in socket }
        var disconnects = 0
        client.onDisconnect = { _ in disconnects += 1 }
        try await client.connect()
        defer { client.close() }
        await fulfillment(of: [pinged], timeout: 2)
        let pings = socket.outbound.filter { $0["method"].text == "gateway.ping" }
        XCTAssertEqual(socket.outbound.first?["method"].text, "client.capabilities")
        XCTAssertEqual(Array(pings.prefix(2).map { $0["id"] }), [.string("heartbeat-1"), .string("heartbeat-2")])
        XCTAssertTrue(pings.allSatisfy { $0["params"] == .object([:]) })
        _ = try await client.call(.profilesList(includeSessions: false))
        XCTAssertEqual(disconnects, 0)
    }

    private static let signIn: (URLRequest) -> (Int, BotJSON) = { request in
        switch request.url!.path {
        case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
        case "/auth/password-login": return (200, .object([:]))
        case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
        case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
        default: return (404, .null)
        }
    }

    func testCancelFileUploadKeepsSocketAvailableWithoutResendingIt() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let started = expectation(description: "file upload dispatched")
        socket.withholdReply = { request in
            guard request["method"].text == "file.attach" else { return false }
            started.fulfill(); return true
        }
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }
        let upload = Task { try await client.call(.fileAttach(sessionID: "runtime", name: "a.txt", dataURL: "data:text/plain;base64,aGVsbG8=")) }
        await fulfillment(of: [started], timeout: 2)
        upload.cancel()
        do { _ = try await upload.value; XCTFail("Cancelled upload succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.call(.profilesList(includeSessions: false))
        XCTAssertEqual(socket.sentRequests.filter { $0["method"].text == "file.attach" }.count, 1)
        XCTAssertEqual(socket.sentRequests.last?["method"].text, "profiles.list")
    }

    func testProfileEditorAllowlistAdmitsOnlyTypedScopedCalls() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }
        _ = try await client.call(.profilesGetAsset(name: "inbox-triage"))
        XCTAssertEqual(socket.sentTextFrames, 1)
        _ = try await client.call(.profilesDescribe(name: "inbox-triage"))
        _ = try await client.call(.profilesConfigure(.init(name: "inbox-triage", look: .init(fields: ["title": .string("Triage")], revision: 0))))
        _ = try await client.call(.profilesSetAsset(name: "inbox-triage", avatar: .clear))
        XCTAssertEqual(socket.sentTextFrames, 4)

        // Extra keys, a look without its revision, another asset and data with clear
        // have no typed shape. The value rules remain.
        let model = HermesCall.Model(id: "gpt-6", provider: "openai")
        let rejected: [HermesCall] = [
            .profilesDescribe(name: ""),
            .profilesConfigure(.init(name: "inbox-triage")),
            .profilesConfigure(.init(name: "", soul: "Keep my week in order.")),
            .profilesConfigure(.init(name: "inbox-triage", look: .init(fields: [:], revision: -1))),
            .profilesConfigure(.init(name: "inbox-triage", model: .init(id: "gpt-6", provider: ""))),
            .profilesConfigure(.init(name: "inbox-triage", soul: "", confirmExpensiveModel: true)),
            .profilesConfigure(.init(name: "inbox-triage", model: model, disabledSkills: ["web", ""])),
            .profilesSetAsset(name: "", avatar: .clear),
            .profilesSetAsset(name: "inbox-triage", avatar: .replace("")),
            .profilesSetAsset(name: "inbox-triage", avatar: .replace(String(repeating: "A", count: 3_000_001)))
        ]
        for call in rejected {
            do {
                _ = try await client.call(call)
                XCTFail("Invalid \(call.method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 4)
    }

    func testDelegatedWorkAllowlistAdmitsOnlySessionOwnedShapes() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        _ = try await client.call(.subagentList(sessionID: "runtime"))
        _ = try await client.call(.subagentTail(sessionID: "runtime", subagentID: "worker"))
        _ = try await client.call(.subagentInterrupt(sessionID: "runtime", subagentID: "worker"))
        XCTAssertEqual(socket.sentTextFrames, 3)

        // `subagent.steer`, a Profile scope and an `all` flag have no typed shape.
        let rejected: [HermesCall] = [
            .subagentList(sessionID: ""),
            .subagentTail(sessionID: "runtime", subagentID: ""),
            .subagentTail(sessionID: "", subagentID: "worker"),
            .subagentInterrupt(sessionID: "runtime", subagentID: "")
        ]
        for call in rejected {
            do {
                _ = try await client.call(call)
                XCTFail("Invalid \(call.method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 3)
    }

    /// The connection card answers one row or Continue, by `op_id`, and nothing
    /// else: no claimed outcome, no other settle reason, no connector RPC.
    func testConnectionAllowlistAdmitsOnlyOneRowOrContinue() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        func respond(_ result: BotJSON) -> BotJSON {
            .object(["owner": .object(["type": .string("session"), "session_id": .string("runtime")]),
                     "op_id": .string("op-1"), "result": result])
        }
        func row(_ fields: [String: BotJSON]) -> BotJSON { .object(["targets": .array([.object(fields)])]) }

        let admitted: [BotConnectionOperation.Answer] = [
            .continueWithout, .skip(target: "gmail"), .connect(target: "notion", env: [:]),
            .connect(target: "github", env: ["GITHUB_TOKEN": "ghp_1"])
        ]
        for answer in admitted { _ = try await client.call(.connectionRespond(sessionID: "runtime", opID: "op-1", answer: answer)) }
        XCTAssertEqual(socket.sentRequests.map { $0["params"] }, [
            respond(.object(["settled_by": .string("continue")])),
            respond(row(["name": .string("gmail"), "status": .string("skipped")])),
            respond(row(["name": .string("notion"), "status": .string("approved")])),
            respond(row(["name": .string("github"), "status": .string("approved"),
                         "env": .object(["GITHUB_TOKEN": .string("ghp_1")])]))
        ])

        // Another settle reason or outcome, a second row, env on a skip, a `detail`, a
        // Profile scope and the other connector RPCs have no typed shape.
        let rejected: [HermesCall] = [
            .connectionRespond(sessionID: "runtime", opID: "op-1", answer: .skip(target: "")),
            .connectionRespond(sessionID: "runtime", opID: "op-1", answer: .connect(target: "github", env: ["GITHUB_TOKEN": ""])),
            .connectionRespond(sessionID: "runtime", opID: "op-1", answer: .connect(target: "github", env: ["": "ghp_1"])),
            .connectionRespond(sessionID: "runtime", opID: "", answer: .continueWithout),
            .connectionRespond(sessionID: "", opID: "op-1", answer: .continueWithout)
        ]
        for call in rejected {
            do {
                _ = try await client.call(call)
                XCTFail("Invalid connection.respond dispatched: \(call)")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, admitted.count)
    }

    /// 0.21.5 names the answered session as an `owner`, 0.21.4 as a bare `session_id`, and
    /// each refuses the other's key, so the answer takes the shape of the release the host
    /// reported at sign-in. A canary reads as its base release; a missing, partial or
    /// unreadable version as the pin.
    func testConnectionRespondNamesTheSessionTheWayTheHostsReleaseTakesIt() async throws {
        let owner: BotJSON = .object(["type": .string("session"), "session_id": .string("runtime")])
        let releases: [(version: String?, key: String, session: BotJSON)] = [
            ("0.21.4", "session_id", .string("runtime")),
            ("0.21.4+canary.20260928T071354Z", "session_id", .string("runtime")),
            ("0.21.5", "owner", owner),
            ("0.22.0", "owner", owner),
            (nil, "owner", owner),
            ("0.21", "owner", owner),
            ("dev", "owner", owner)
        ]
        for release in releases {
            var status: [String: BotJSON] = ["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]
            status["version"] = release.version.map(BotJSON.string)
            BotHTTPFixture.handler = { request in
                switch request.url!.path {
                case "/api/status": return (200, .object(status))
                case "/auth/password-login": return (200, .object([:]))
                case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
                case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
                default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BotHTTPFixture.self]
            let socket = BotScriptedSocket()
            let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
            try await client.connect()
            _ = try await client.call(.connectionRespond(sessionID: "runtime", opID: "op-1", answer: .continueWithout))
            client.close()
            XCTAssertEqual(socket.sentRequests.last?["params"], .object([
                release.key: release.session, "op_id": .string("op-1"),
                "result": .object(["settled_by": .string("continue")])
            ]), "\(release.version ?? "missing")")
        }
    }

    func testCancellingDelegatedReadsKeepsTheConversationSocketAvailable() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        let calls: [HermesCall] = [
            .subagentList(sessionID: "runtime"), .subagentTail(sessionID: "runtime", subagentID: "worker"), .sessionActiveList
        ]
        for call in calls {
            let method = call.method
            let started = expectation(description: "\(method) dispatched")
            socket.withholdReply = { request in
                guard request["method"].text == method else { return false }
                started.fulfill()
                return true
            }
            let read = Task { try await client.call(call) }
            await fulfillment(of: [started], timeout: 2)

            read.cancel()
            do { _ = try await read.value; XCTFail("Cancelled \(method) succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }

            socket.withholdReply = nil
            _ = try await client.call(.profilesList(includeSessions: false))
            XCTAssertEqual(socket.sentRequests.last?["method"].text, "profiles.list")
        }
    }

    func testDelegatedReadTimeoutFailsOnlyTheOptionalRequest() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        socket.withholdReply = { ["subagent.list", "session.active_list"].contains($0["method"].text) }
        let client = BotClient(connection: connection(), configuration: configuration,
                               rpcDeadline: .milliseconds(50)) { _ in socket }
        var disconnects = 0
        client.onDisconnect = { _ in disconnects += 1 }
        try await client.connect()
        defer { client.close() }

        // The inbox's live-status read is optional the same way: a stall fails only it.
        for call in [HermesCall.subagentList(sessionID: "runtime"), .sessionActiveList] {
            do {
                _ = try await client.call(call)
                XCTFail("Timed-out \(call.method) succeeded")
            } catch {
                XCTAssertEqual(error as? BotFailure, .transport)
            }
        }

        socket.withholdReply = nil
        _ = try await client.call(.profilesList(includeSessions: false))
        XCTAssertEqual(disconnects, 0)
        XCTAssertEqual(socket.sentRequests.last?["method"].text, "profiles.list")
    }

    func testLifecycleAllowlistAdmitsOnlyTheCreateShapeAndCanonicalChatCalls() async throws {
        var deletes: [(String, String)] = []
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            case "/api/profiles/home-hunter":
                deletes.append((request.httpMethod ?? "", request.url!.path))
                return deletes.count == 1 ? (200, .object(["ok": .bool(true), "path": .string("/p")])) : (400, .object(["detail": .string("no")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }
        let model = HermesCall.Model(id: "gpt-6", provider: "openai")
        _ = try await client.call(.profilesCreate(.init(name: "home-hunter", description: "Finds flats", cloneFrom: "inbox-triage",
                                                         model: model, sharesCredentials: true)))
        _ = try await client.call(.profilesCreate(.init(name: "chief", soul: "Keep my week in order.", skipsBundledSkills: true,
                                                         sharesCredentials: false)))
        _ = try await client.call(.sessionCreate(profile: "home-hunter"))
        _ = try await client.call(.sessionTitle(sessionID: "runtime"))
        XCTAssertEqual(socket.sentTextFrames, 4)

        // A clone-all flag, another chat title and extra session fields have no typed shape.
        let rejected: [HermesCall] = [
            .profilesCreate(.init(name: "default", sharesCredentials: true)),
            .profilesCreate(.init(name: "Home Hunter", sharesCredentials: true)),
            .profilesCreate(.init(name: "home-hunter", model: .init(id: "gpt-6", provider: ""), sharesCredentials: true)),
            .profilesCreate(.init(name: "home-hunter", description: "", sharesCredentials: true)),
            .profilesCreate(.init(name: "home-hunter", cloneFrom: "inbox-triage", skipsBundledSkills: true, sharesCredentials: true)),
            .sessionCreate(profile: ""),
            .sessionTitle(sessionID: "")
        ]
        for call in rejected {
            do {
                _ = try await client.call(call)
                XCTFail("Invalid \(call.method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 4)

        try await client.deleteProfile("home-hunter")
        XCTAssertEqual(deletes.map(\.0), ["DELETE"]); XCTAssertEqual(deletes.first?.1, "/api/profiles/home-hunter")
        do {
            try await client.deleteProfile("home-hunter")
            XCTFail("a refused delete must throw")
        } catch { XCTAssertEqual(error as? BotFailure, .rejected(400)) }
        do {
            try await client.deleteProfile("../etc")
            XCTFail("an invalid name never reaches the wire")
        } catch { XCTAssertEqual(error as? BotFailure, .stale) }
        XCTAssertEqual(deletes.count, 2)
    }

    func testPromptActionsUseExplicitMethodsAndQueueParameters() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        for mode in BotPromptMode.allCases {
            _ = try await client.call(mode.call(runtime: "runtime", text: "one operation"))
        }
        XCTAssertEqual(socket.sentRequests.map { $0["method"].text },
                       ["prompt.submit", "session.steer", "prompt.submit", "session.redirect"])
        for (request, mode) in zip(socket.sentRequests, BotPromptMode.allCases) {
            XCTAssertEqual(request["params"]["session_id"], .string("runtime"))
            XCTAssertEqual(request["params"]["text"], .string("one operation"))
            XCTAssertEqual(request["params"]["queued"], mode == .send || mode == .queue ? .bool(true) : .null)
        }
        // `prompt.btw`, `prompt.background` and `slash.exec` have no typed shape.
        XCTAssertEqual(socket.sentTextFrames, 4)
        client.close()
    }

    /// The slash panel's two reads stay a narrow shape. `command.dispatch` in
    /// particular must never widen: the gateway resolves quick commands ahead of
    /// skills, and one of those can run a shell command on the host.
    func testSlashAllowlistAdmitsOnlyTheCatalogReadAndABareDispatchName() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        _ = try await client.call(.commandsCatalog(sessionID: "runtime"))
        _ = try await client.call(.commandDispatch(name: "work", argument: "fix the leak", sessionID: "runtime"))
        XCTAssertEqual(socket.sentTextFrames, 2)

        // `slash.exec`, a Profile scope, a missing `arg` and a `shell` flag have no typed shape.
        let rejected: [HermesCall] = [
            .commandsCatalog(sessionID: ""),
            .commandDispatch(name: "/work", argument: "", sessionID: "runtime"),
            .commandDispatch(name: "work fix", argument: "", sessionID: "runtime"),
            .commandDispatch(name: "work\n", argument: "", sessionID: "runtime"),
            .commandDispatch(name: "", argument: "", sessionID: "runtime"),
            .commandDispatch(name: "work", argument: "", sessionID: "")
        ]
        for call in rejected {
            do {
                _ = try await client.call(call)
                XCTFail("Invalid \(call.method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 2)
    }

    /// A rewind cuts one durable row and resends a prompt; an empty prompt or a
    /// row id the host never issued is refused before the socket.
    func testRewindAdmitsOnlyARowAndThePromptItResends() {
        let rejected: [HermesCall] = [
            .promptRewind(sessionID: "", text: "hi", beforeRowID: 41),
            .promptRewind(sessionID: "runtime", text: " \n", beforeRowID: 41),
            .promptRewind(sessionID: "runtime", text: "hi", beforeRowID: 0)
        ]
        for call in rejected {
            XCTAssertThrowsError(try call.params()) { XCTAssertEqual($0 as? BotFailure, .unsupported) }
        }
    }

    /// A side question or background task needs its session and some text (#1013); the host
    /// refuses empty text.
    func testSideTaskCallsAdmitOnlyASessionAndText() {
        let rejected: [HermesCall] = [
            .promptBtw(sessionID: "", text: "why?"),
            .promptBtw(sessionID: "runtime", text: " \n"),
            .promptBackground(sessionID: "", text: "sum up"),
            .promptBackground(sessionID: "runtime", text: "")
        ]
        for call in rejected {
            XCTAssertThrowsError(try call.params()) { XCTAssertEqual($0 as? BotFailure, .unsupported) }
        }
    }

    /// The inbox's live-status read is `session.active_list` with no parameters,
    /// exactly as Desktop's background sync sends it; anything else stays local.
    func testActiveListAllowlistAdmitsOnlyTheEmptyRead() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        // `current_session_id` and a Profile scope have no typed shape.
        _ = try await client.call(.sessionActiveList)
        XCTAssertEqual(socket.sentTextFrames, 1)
        XCTAssertEqual(socket.sentRequests.last?["method"], .string("session.active_list"))
        XCTAssertEqual(socket.sentRequests.last?["params"], .object([:]))
    }

    func testCompletionAllowlistAdmitsOneWordAndRejectsEverythingElse() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        _ = try await client.call(.completePath(word: "src/Ch", sessionID: "runtime", profile: "default"))
        XCTAssertEqual(socket.sentTextFrames, 1)

        // A caller-chosen `cwd` has no typed shape.
        let rejected: [HermesCall] = [
            .completePath(word: "", sessionID: "runtime", profile: "default"),
            .completePath(word: "src Ch", sessionID: "runtime", profile: "default"),
            .completePath(word: "src", sessionID: "", profile: "default"),
            .completePath(word: "src", sessionID: "runtime", profile: "")
        ]
        for call in rejected {
            do {
                _ = try await client.call(call)
                XCTFail("Invalid \(call.method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 1)
    }

    func testReactAllowlistAdmitsYourOwnReactionAndRejectsEverythingElse() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        _ = try await client.call(.messageReact(sessionID: "runtime", rowID: 42, emoji: "👍"))
        _ = try await client.call(.messageReact(sessionID: "runtime", rowID: 42, emoji: nil))
        XCTAssertEqual(socket.sentRequests.map { $0["params"] }, [
            .object(["session_id": .string("runtime"), "row_id": .number(42), "emoji": .string("👍")]),
            .object(["session_id": .string("runtime"), "row_id": .number(42), "emoji": .null])
        ])

        // `author`, `newest_role`, a non-integer row and a non-string emoji have no typed shape.
        let rejected: [HermesCall] = [
            .messageReact(sessionID: "runtime", rowID: 42, emoji: "  "),
            .messageReact(sessionID: "", rowID: 42, emoji: "👍")
        ]
        for call in rejected {
            do {
                _ = try await client.call(call)
                XCTFail("Invalid message.react call dispatched: \(call)")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 2)
    }

    func testCancelCompletionKeepsSocketAvailableWithoutResendingIt() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let started = expectation(description: "completion dispatched")
        socket.withholdReply = { request in
            guard request["method"].text == "complete.path" else { return false }
            started.fulfill(); return true
        }
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }

        let lookup = Task {
            try await client.call(.completePath(word: "src", sessionID: "runtime", profile: "default"))
        }
        await fulfillment(of: [started], timeout: 2)
        lookup.cancel()
        do { _ = try await lookup.value; XCTFail("Cancelled completion succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }

        _ = try await client.call(.profilesList(includeSessions: false))
        XCTAssertEqual(socket.sentRequests.filter { $0["method"].text == "complete.path" }.count, 1)
        XCTAssertEqual(socket.sentRequests.last?["method"].text, "profiles.list")
    }

    func testSettingsAllowlistRejectsUnscopedWritesAndPreservesHostError() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        socket.reply = { request in
            .object(["id": request["id"], "error": .object(["code": .number(4002), "message": .string("Provider unavailable")])])
        }
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }
        // A global scope, another key and a free-form fast value have no typed shape.
        func set(_ setting: HermesCall.SessionSetting, session: String = "runtime") -> HermesCall {
            .configSet(sessionID: session, profile: "default", setting: setting)
        }
        for setting: HermesCall.SessionSetting in [.reasoning("off"), .reasoning("show"), .model(value: "model --provider provider", confirmExpensive: false)] {
            do {
                _ = try await client.call(set(setting))
                XCTFail("Unsupported setting was dispatched")
            } catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
        do {
            _ = try await client.call(set(.fast(true), session: ""))
            XCTFail("An unscoped setting was dispatched")
        } catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        XCTAssertTrue(socket.sentRequests.isEmpty)
        do {
            _ = try await client.call(set(.model(value: "model --provider provider --session", confirmExpensive: false)))
            XCTFail("Rejected setting succeeded")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Provider unavailable")
        }
        for setting: HermesCall.SessionSetting in [.reasoning("none"), .reasoning("ultra"), .fast(false), .fast(true)] {
            do {
                _ = try await client.call(set(setting))
                XCTFail("Rejected setting succeeded")
            } catch { XCTAssertEqual(error.localizedDescription, "Provider unavailable") }
        }
        XCTAssertEqual(socket.sentRequests.count, 5)
        XCTAssertTrue(socket.sentRequests.allSatisfy { $0["params"]["scope"] == .string("session") && $0["params"]["session_id"] == .string("runtime") })
    }

    func testStatusWithoutVersionStillConnects() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration) { _ in BotScriptedSocket() }
        try await client.connect()
        XCTAssertNil(client.serverVersion)
        var record = connection()
        record.hermesVersion = client.serverVersion
        XCTAssertNil(record.hermesVersion)
        client.close()
    }

    func testMissingPasswordGateFailsBeforeCredentialsOrSocket() async {
        BotHTTPFixture.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/status")
            return (200, .object(["auth_required": .bool(false)]))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration) { _ in
            XCTFail("Must not open a socket")
            return BotScriptedSocket()
        }
        do { try await client.connect(); XCTFail("Expected unsupported gate") }
        catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        client.close()
    }

    func testAHostReportingAnotherInstallIDIsRefusedBeforeThePasswordIsSent() async {
        let saved = String(repeating: "a", count: 32), other = String(repeating: "b", count: 32)
        var paths: [String] = []
        BotHTTPFixture.handler = { request in
            paths.append(request.url!.path)
            return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                  "install_id": .string(other)]))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        var record = connection(); record.installID = saved
        let client = BotClient(connection: record, configuration: configuration) { _ in
            XCTFail("Must not open a socket")
            return BotScriptedSocket()
        }
        do { try await client.connect(); XCTFail("Expected a different host") }
        catch { XCTAssertEqual(error as? BotFailure, .differentHost) }
        XCTAssertEqual(paths, ["/api/status"], "No login request reaches the other host")
        client.close()
    }

    func testAMatchingOrMissingInstallIDConnectsAndReportsTheLiveOne() async throws {
        let known = String(repeating: "a", count: 32), fresh = String(repeating: "c", count: 32)
        // (stored, live): the same host, a host omitting it after a read error, and a legacy record.
        for (stored, live) in [(known, known), (known, nil), (nil, fresh)] as [(String?, String?)] {
            BotHTTPFixture.handler = { request in
                switch request.url!.path {
                case "/api/status":
                    var status: [String: BotJSON] = ["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]
                    if let live { status["install_id"] = .string(live) }
                    return (200, .object(status))
                case "/auth/password-login": return (200, .object([:]))
                case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
                case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
                default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BotHTTPFixture.self]
            var record = connection(); record.installID = stored
            let client = BotClient(connection: record, configuration: configuration) { _ in BotScriptedSocket() }
            try await client.connect()
            XCTAssertEqual(client.serverInstallID, live)
            client.close()
        }
    }

    func testAnAddressWhoseStatusIsRefusedOrMissingIsNotADashboard() async {
        for code in [401, 404] {
            var paths: [String] = []
            BotHTTPFixture.handler = { request in
                paths.append(request.url!.path)
                return (code, .object(["detail": .string("Not Found")]))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BotHTTPFixture.self]
            let client = BotClient(connection: connection(), configuration: configuration)
            do { try await client.connect(); XCTFail("Expected not a dashboard") }
            catch { XCTAssertEqual(error as? BotFailure, .notDashboard, "\(code)") }
            XCTAssertEqual(paths, ["/api/status"], "No password reaches an address that is not a dashboard")
            client.close()
        }
    }

    /// An access proxy such as Cloudflare Access redirects the public status read to its own
    /// sign-in page on another host. That page is not "not a dashboard", and no password goes out.
    func testAnAccessProxyRedirectIsBlockedBeforeThePasswordGoesOut() async {
        BotHTTPFixture.redirect = URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login")!
        BotHTTPFixture.raw = { _ in (200, Data("<html>Sign in</html>".utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration) { _ in
            XCTFail("Must not open a socket")
            return BotScriptedSocket()
        }
        do { try await client.connect(); XCTFail("Expected an access proxy") }
        catch { XCTAssertEqual(error as? BotFailure, .blocked) }
        XCTAssertEqual(BotHTTPFixture.requested.map(\.absoluteString),
                       ["https://hermes.example/api/status", "https://team.cloudflareaccess.com/cdn-cgi/access/login"])
        client.close()
    }

    /// Cloudflare Access can refuse the status read with its own 401 page instead of
    /// redirecting. Only a JSON 401, the webui's auth gate, reads as "not a dashboard".
    func testAStatusRefusedWithoutAJSONBodyIsBlocked() async {
        var paths: [String] = []
        BotHTTPFixture.raw = { request in
            paths.append(request.url!.path)
            return (401, Data("<html>Unauthorized</html>".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration)
        do { try await client.connect(); XCTFail("Expected an access proxy") }
        catch { XCTAssertEqual(error as? BotFailure, .blocked) }
        XCTAssertEqual(paths, ["/api/status"])
        client.close()
    }

    /// A host that only offers an OIDC provider supports Bot chat; Hermex just can't sign in
    /// there yet (#708), so it says that, and the password never goes out.
    func testAHostWithOnlyBrowserSignInSaysSoBeforeThePasswordGoesOut() async {
        var paths: [String] = []
        BotHTTPFixture.handler = { request in
            paths.append(request.url!.path)
            return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("nous")])]))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration)
        do { try await client.connect(); XCTFail("Expected browser sign-in only") }
        catch { XCTAssertEqual(error as? BotFailure, .browserSignIn) }
        XCTAssertEqual(paths, ["/api/status"])
        client.close()
    }

    /// A refused upgrade fails the socket's first read with a bare `URLError`; its HTTP status
    /// says what refused it. Proxy, rate-limit and timeout statuses keep today's retry.
    func testAGatewayUpgradeStatusNamesItsFailure() {
        XCTAssertNil(BotFailure(upgradeStatus: 101), "An accepted upgrade keeps the socket's own error")
        for status in [401, 403, 404] { XCTAssertEqual(BotFailure(upgradeStatus: status), .upgradeRefused(status)) }
        for status in [408, 429, 502, 503] { XCTAssertEqual(BotFailure(upgradeStatus: status), .rejected(status)) }
    }

    func testARefusedUpgradeFailsTheConnectWithItsFailure() async {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: XCTFail("Unexpected HTTP endpoint"); return (404, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration) { _ in
            let socket = BotScriptedSocket()
            socket.receiveFailure = BotFailure.upgradeRefused(403)
            return socket
        }
        do { try await client.connect(); XCTFail("Expected a refused upgrade") }
        catch { XCTAssertEqual(error as? BotFailure, .upgradeRefused(403)) }
        client.close()
    }

    /// A real handshake over loopback: URLSession keeps a refused upgrade's status on the
    /// task, and a socket that opened (101) and then dropped keeps its own error, so the
    /// inbox and chat still retry it quietly.
    func testANativeSocketNamesARefusedUpgradeButNotALaterDrop() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let refusing = try await BotHandshakeListener { _ in "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        defer { refusing.cancel() }
        let refused = refusing.socketTask(on: session)
        do { _ = try await NativeBotSocket(task: refused, label: "refused").receive(); XCTFail("Expected a refused upgrade") }
        catch { XCTAssertEqual(error as? BotFailure, .upgradeRefused(403)) }

        let dropping = try await BotHandshakeListener { key in
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        }
        defer { dropping.cancel() }
        let dropped = dropping.socketTask(on: session)
        do { _ = try await NativeBotSocket(task: dropped, label: "dropped").receive(); XCTFail("Expected the dropped socket's error") }
        catch {
            XCTAssertEqual((dropped.response as? HTTPURLResponse)?.statusCode, 101)
            XCTAssertNil(error as? BotFailure, "A drop after the upgrade must reach the transport retry unwrapped")
        }
    }

    func testARefusedPasswordStaysASignInFailure() async {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (401, .object(["detail": .string("Invalid credentials")]))
            default: XCTFail("Must stop at the login"); return (500, .null)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let client = BotClient(connection: connection(), configuration: configuration)
        do { try await client.connect(); XCTFail("Expected a refused login") }
        catch { XCTAssertEqual(error as? BotFailure, .rejected(401)) }
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

    func testArtifactDownloadUsesBotHTTPBoundaryAndRejectsWrongOrClosedConnection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let record = connection()
        BotHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: XCTFail("Unexpected endpoint during connect"); return (404, .null)
            }
        }
        let client = BotClient(connection: record, configuration: configuration) { _ in BotScriptedSocket() }
        try await client.connect()
        let context = BotArtifactContext(connectionID: record.id, profile: "same-profile", sessionID: "tip", generation: 1)
        let value = BotJSON.object(["artifact": .string("fixture")])
        BotHTTPFixture.handler = { request in
            XCTAssertEqual(request.url?.host, record.address.host)
            XCTAssertEqual(request.url?.path, "/api/fs/download")
            return (200, value)
        }
        let data = try await client.artifactData(path: "report.json", context: context)
        XCTAssertEqual(try JSONDecoder().decode(BotJSON.self, from: data), value)
        let wrong = BotArtifactContext(connectionID: UUID(), profile: "same-profile", sessionID: "tip", generation: 1)
        do { _ = try await client.artifactData(path: "report.json", context: wrong); XCTFail("Wrong connection") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
        client.close()
        do { _ = try await client.artifactData(path: "report.json", context: context); XCTFail("Closed connection") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
    }

    func testStringIDServerRequestDoesNotConsumeIntegerRPCReply() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/auth/password-login": return (200, .object([:]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            default: return (200, .object(["ticket": .string("ticket")]))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        let received = expectation(description: "String-id request forwarded")
        client.onEvent = { frame in
            XCTAssertEqual(frame["id"], .string("srq-live"))
            XCTAssertEqual(frame["method"], .string("sudo"))
            received.fulfill()
        }
        socket.enqueue(.string(#"{"jsonrpc":"2.0","id":"srq-live","method":"sudo","params":{"session_id":"runtime"}}"#))
        socket.reply = { request in .object(["id": request["id"], "result": .object(["status": .string("expired")])]) }
        let result = try await client.call(.requestAnswer(id: "srq-live", result: .value("")))
        XCTAssertEqual(result["status"], .string("expired"))
        let locked = try await client.call(.clarifyLock(requestID: "srq-batch", questionID: "q1", answer: "yes"))
        XCTAssertEqual(locked["status"], .string("expired"))
        await fulfillment(of: [received], timeout: 2)
        client.close()
    }

    func testRoomAllowlistRejectsAdministrationAndInvalidTypedParameters() async throws {
        BotHTTPFixture.handler = { request in
            switch request.url!.path {
            case "/api/status": return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]))
            case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
            case "/api/auth/ws-ticket": return (200, .object(["ticket": .string("ticket")]))
            default: return (200, .object([:]))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotHTTPFixture.self]
        let socket = BotScriptedSocket()
        let client = BotClient(connection: connection(), configuration: configuration) { _ in socket }
        try await client.connect()
        defer { client.close() }
        let members = ["default", "dev"].map { HermesCall.RoomMember(memberID: $0, profile: $0, handle: $0) }
        let valid: [HermesCall] = [
            .groupsCapabilities, .groupsList(offset: 0), .groupsState(roomID: "room:1"),
            .groupsSend(roomID: "room", eventID: "event", text: "hello", threadID: "thread"),
            .groupsStop(roomID: "room", cancelID: "cancel"),
            .groupsApprove(roomID: "room", memberID: "member", taskID: "task", executionGeneration: 1, requestID: "request", choice: .once),
            .groupsRetry(roomID: "room", taskID: "task"), .groupsDisband(roomID: "room"),
            .groupsRename(roomID: "room", eventID: "event", name: "Renamed"),
            .groupsCreate(.init(roomID: "room", name: "Created", members: members)),
            .groupsLog(roomID: "room:1", sinceSeq: 0, limit: 200)]
        for call in valid { _ = try await client.call(call) }
        // Peer administration (`promote`, `demote`, `replicate`, `replica_state`, `peer.*`),
        // a Profile scope and `include_disbanded` have no typed shape.
        let invalid: [HermesCall] = [
            .groupsList(offset: -1),
            .groupsState(roomID: ""), .groupsState(roomID: "../room"), .groupsState(roomID: "room\n"),
            .groupsState(roomID: String(repeating: "a", count: 129)),
            .groupsLog(roomID: "room", sinceSeq: -1, limit: 200), .groupsLog(roomID: "room", sinceSeq: 0, limit: 0),
            .groupsLog(roomID: "room", sinceSeq: 0, limit: 501),
            .groupsSend(roomID: "room", eventID: "", text: "hello", threadID: "thread"),
            .groupsRetry(roomID: "room", taskID: "../task"),
            .groupsCreate(.init(roomID: "room", name: "Created", members: Array(members.prefix(1)))),
            .groupsRename(roomID: "room", eventID: "event", name: " "),
            .groupsDisband(roomID: "room/other")]
        for call in invalid {
            do { _ = try await client.call(call); XCTFail("Invalid room call dispatched: \(call)") }
            catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
        XCTAssertEqual(socket.sentRequests.count, valid.count)
        socket.reply = { request in .object(["id": request["id"], "error": .object([
            "code": .number(4112), "message": .string("Expired"), "data": .object(["reason": .string("room_history_expired")])])]) }
        do { _ = try await client.call(.groupsLog(roomID: "room", sinceSeq: 0, limit: 200)); XCTFail("Expected room error") }
        catch { XCTAssertTrue((error as? BotRoomFailure)?.expired == true) }
    }

    /// Attachments, a partial approval tuple and an unknown choice have no typed shape.
    func testRoomParticipantValidationRejectsOversizedTextAndIncompleteApprovalTuples() throws {
        func send(_ text: String) -> HermesCall { .groupsSend(roomID: "room", eventID: "event", text: text, threadID: "thread") }
        let largest = String(repeating: "é", count: 32768)
        XCTAssertEqual(try send(largest).params()["payload"], .object(["text": .string(largest), "thread_id": .string("thread")]))
        for text in [" \n", String(repeating: "é", count: 32769)] {
            XCTAssertThrowsError(try send(text).params())
        }
        func approve(generation: Int = 1, choice: BotApprovalRequest.Choice = .once, ids: [String] = ["member", "task", "request"]) -> HermesCall {
            .groupsApprove(roomID: "room", memberID: ids[0], taskID: ids[1], executionGeneration: generation, requestID: ids[2], choice: choice)
        }
        XCTAssertEqual(try approve(choice: .deny).params()["choice"], .string("deny"))
        for generation in [0, -1] { XCTAssertThrowsError(try approve(generation: generation).params()) }
        for choice: BotApprovalRequest.Choice in [.session, .always] { XCTAssertThrowsError(try approve(choice: choice).params()) }
        for ids in [["", "task", "request"], ["member", "", "request"], ["member", "task", ""]] {
            XCTAssertThrowsError(try approve(ids: ids).params(), "\(ids)")
        }
        XCTAssertThrowsError(try HermesCall.groupsStop(roomID: "room", cancelID: "").params())
    }

    private func connection() -> BotConnection {
        BotConnection(id: UUID(), name: "Fixture", address: URL(string: "https://hermes.example")!, username: "user", password: "fixture")
    }
}

private final class BotHTTPFixture: URLProtocol {
    static var handler: ((URLRequest) -> (Int, BotJSON))?
    /// Answers instead of `handler` with a body that need not be JSON, such as a proxy's page.
    static var raw: ((URLRequest) -> (Int, Data))?
    /// When set, a request to any other host is answered with a 302 to this URL.
    static var redirect: URL?
    /// Every URL loaded, redirect targets included.
    static var requested: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requested.append(url)
        if let target = Self.redirect, url.host != target.host {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let status: Int, body: Data
        if let raw = Self.raw { (status, body) = raw(request) }
        else if let handler = Self.handler {
            let (code, value) = handler(request)
            (status, body) = (code, try! JSONEncoder().encode(value))
        } else { client?.urlProtocol(self, didFailWithError: BotFailure.transport); return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Lock ownership protects the queued scripted frames and exactly one waiting reader.
final class BotScriptedSocket: BotSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [URLSessionWebSocketTask.Message] = [
        .string(#"{"method":"event","params":{"type":"gateway.ready","payload":{"replay_epoch":"epoch"}}}"#)
    ]
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var closed = false
    var reply: ((BotJSON) -> BotJSON)?
    var withholdReply: ((BotJSON) -> Bool)?
    /// Answers `client.capabilities`; nil answers as a current host does.
    var capabilitiesReply: ((BotJSON) -> BotJSON)?
    var onPing: (() -> Void)?
    /// Thrown by every send, handshake and keepalive included, as a dropped connection would.
    var sendFailure: Error?
    /// Thrown by the next receive instead of its frame, as a refused upgrade fails the first read.
    var receiveFailure: Error?
    /// Replies to caller RPCs; the handshake and keepalive are not counted.
    private(set) var sentTextFrames = 0
    /// Caller RPCs only, so allowlist assertions ignore the handshake.
    private(set) var sentRequests: [BotJSON] = []
    /// Every frame the client sent, handshake and keepalive included, in order.
    private(set) var outbound: [BotJSON] = []
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: BotFailure.transport) }
            else if let failure = receiveFailure { receiveFailure = nil; lock.unlock(); continuation.resume(throwing: failure) }
            else if !frames.isEmpty { let frame = frames.removeFirst(); lock.unlock(); continuation.resume(returning: frame) }
            else { waiter = continuation; lock.unlock() }
        }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { XCTFail("JSON-RPC must use text frames"); throw BotFailure.unsupported }
        let request = try JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))
        logOutbound(request)
        if let sendFailure { throw sendFailure }
        switch request["method"].text {
        case "client.capabilities":
            let response = capabilitiesReply?(request)
                ?? .object(["id": request["id"], "result": .object(["server_requests": .array([.string("clarify")])])])
            enqueue(.string(String(decoding: try JSONEncoder().encode(response), as: UTF8.self)), counted: false)
            return
        case "gateway.ping":
            onPing?()
            let pong = BotJSON.object(["jsonrpc": .string("2.0"), "id": request["id"], "result": .object(["ok": .bool(true)])])
            enqueue(.string(String(decoding: try JSONEncoder().encode(pong), as: UTF8.self)), counted: false)
            return
        default: break
        }
        record(request)
        if withholdReply?(request) == true { return }
        let response = reply?(request) ?? BotJSON.object(["id": request["id"], "result": .object(["profiles": .array([])])])
        let frame = URLSessionWebSocketTask.Message.string(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
        enqueue(frame)
    }
    private func logOutbound(_ request: BotJSON) {
        lock.lock(); outbound.append(request); lock.unlock()
    }
    private func record(_ request: BotJSON) {
        lock.lock(); sentRequests.append(request); lock.unlock()
    }

    func enqueue(_ frame: URLSessionWebSocketTask.Message, counted: Bool = true) {
        lock.lock(); if counted { sentTextFrames += 1 }
        let waiting = waiter; waiter = nil
        if waiting == nil { frames.append(frame) }
        lock.unlock()
        waiting?.resume(returning: frame)
    }
    /// True once cancelled, by the client or by the test.
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func cancel() {
        lock.lock(); closed = true
        let waiting = waiter; waiter = nil
        lock.unlock()
        waiting?.resume(throwing: BotFailure.transport)
    }
}

/// A loopback listener that answers each gateway upgrade with a canned HTTP reply and
/// hangs up. `reply` gets the request's `Sec-WebSocket-Key`.
final class BotHandshakeListener: @unchecked Sendable {
    private let listener: NWListener
    private let port: UInt16

    init(reply: @escaping @Sendable (String) -> String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            BotHandshakeListener.readRequest(on: connection, received: Data()) { request in
                let key = request.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                    .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
                connection.send(content: Data(reply(key).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        self.listener = listener
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// A started gateway upgrade to this listener.
    func socketTask(on session: URLSession) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/api/ws")!)
        task.resume()
        return task
    }

    func cancel() { listener.cancel() }

    /// Reads until the blank line that ends the request's headers.
    private static func readRequest(on connection: NWConnection, received: Data, then answer: @escaping @Sendable (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            let request = received + (data ?? Data())
            let text = String(decoding: request, as: UTF8.self)
            if text.contains("\r\n\r\n") || isComplete || error != nil { answer(text) }
            else { readRequest(on: connection, received: request, then: answer) }
        }
    }
}
