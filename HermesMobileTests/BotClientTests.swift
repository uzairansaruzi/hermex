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
            XCTAssertEqual(client.serverVersion, "0.22.0")
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }
        let upload = Task { try await client.call("file.attach", ["session_id": .string("runtime"), "data_url": .string("aGVsbG8=")]) }
        await fulfillment(of: [started], timeout: 2)
        upload.cancel()
        do { _ = try await upload.value; XCTFail("Cancelled upload succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await client.call("profiles.list", [:])
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }
        _ = try await client.call("profiles.get_asset", ["name": .string("inbox-triage"), "asset": .string("avatar")])
        XCTAssertEqual(socket.sentTextFrames, 1)
        _ = try await client.call("profiles.describe", ["name": .string("inbox-triage")])
        _ = try await client.call("profiles.configure", [
            "name": .string("inbox-triage"),
            "ui_meta": .object(["hermes-bots": .object(["title": .string("Triage")])]),
            "ui_meta_expected_revisions": .object(["hermes-bots": .number(0)])
        ])
        _ = try await client.call("profiles.set_asset", [
            "name": .string("inbox-triage"), "asset": .string("avatar"), "clear": .bool(true)
        ])
        XCTAssertEqual(socket.sentTextFrames, 4)

        let rejected: [(String, [String: BotJSON])] = [
            ("profiles.describe", ["name": .string("inbox-triage"), "extra": .bool(true)]),
            ("profiles.configure", ["name": .string("inbox-triage"), "ui_meta": .object(["hermes-bots": .object([:])])]),
            ("profiles.configure", ["name": .string("inbox-triage"), "command": .string("raw")]),
            ("profiles.set_asset", ["name": .string("inbox-triage"), "clear": .bool(true)]),
            ("profiles.set_asset", ["name": .string("inbox-triage"), "asset": .string("soul"), "clear": .bool(true)]),
            ("profiles.set_asset", [
                "name": .string("inbox-triage"), "asset": .string("avatar"),
                "data": .string("data:image/jpeg;base64,YQ=="), "clear": .bool(true)
            ])
        ]
        for (method, params) in rejected {
            do {
                _ = try await client.call(method, params)
                XCTFail("Invalid \(method) call dispatched")
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }

        _ = try await client.call("subagent.list", ["session_id": .string("runtime")])
        _ = try await client.call("subagent.tail", ["session_id": .string("runtime"), "subagent_id": .string("worker")])
        _ = try await client.call("subagent.interrupt", ["session_id": .string("runtime"), "subagent_id": .string("worker")])
        XCTAssertEqual(socket.sentTextFrames, 3)

        let rejected: [(String, [String: BotJSON])] = [
            ("subagent.list", [:]),
            ("subagent.list", ["session_id": .string("runtime"), "profile": .string("default")]),
            ("subagent.tail", ["session_id": .string("runtime")]),
            ("subagent.tail", ["session_id": .string("runtime"), "subagent_id": .string("")]),
            ("subagent.interrupt", ["session_id": .string("runtime"), "subagent_id": .string("worker"), "all": .bool(true)]),
            ("subagent.steer", ["session_id": .string("runtime"), "subagent_id": .string("worker"), "text": .string("keep going")])
        ]
        for (method, params) in rejected {
            do {
                _ = try await client.call(method, params)
                XCTFail("Invalid \(method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 3)
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }

        let calls: [(String, [String: BotJSON])] = [
            ("subagent.list", ["session_id": .string("runtime")]),
            ("subagent.tail", ["session_id": .string("runtime"), "subagent_id": .string("worker")])
        ]
        for (method, params) in calls {
            let started = expectation(description: "\(method) dispatched")
            socket.withholdReply = { request in
                guard request["method"].text == method else { return false }
                started.fulfill()
                return true
            }
            let read = Task { try await client.call(method, params) }
            await fulfillment(of: [started], timeout: 2)

            read.cancel()
            do { _ = try await read.value; XCTFail("Cancelled \(method) succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }

            socket.withholdReply = nil
            _ = try await client.call("profiles.list", [:])
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
        socket.withholdReply = { $0["method"].text == "subagent.list" }
        let client = BotClient(connection: connection(), configuration: configuration,
                               rpcDeadline: .milliseconds(50)) { _, _ in socket }
        var disconnects = 0
        client.onDisconnect = { _ in disconnects += 1 }
        try await client.connect()
        defer { client.close() }

        do {
            _ = try await client.call("subagent.list", ["session_id": .string("runtime")])
            XCTFail("Timed-out delegated read succeeded")
        } catch {
            XCTAssertEqual(error as? BotFailure, .transport)
        }

        socket.withholdReply = nil
        _ = try await client.call("profiles.list", [:])
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }
        _ = try await client.call("profiles.create", [
            "name": .string("home-hunter"), "description": .string("Finds flats"), "clone_from": .string("inbox-triage"),
            "model": .string("gpt-6"), "provider": .string("openai"), "share_auth": .bool(true)
        ])
        _ = try await client.call("profiles.create", [
            "name": .string("chief"), "soul": .string("Keep my week in order."), "no_skills": .bool(true)
        ])
        _ = try await client.call("session.create", [
            "profile": .string("home-hunter"), "title": .string("Bot Chat"), "hidden": .bool(true), "follow_profile_config": .bool(true)
        ])
        _ = try await client.call("session.title", ["session_id": .string("runtime"), "title": .string("Bot Chat")])
        XCTAssertEqual(socket.sentTextFrames, 4)

        let rejected: [(String, [String: BotJSON])] = [
            ("profiles.create", ["name": .string("default")]),
            ("profiles.create", ["name": .string("Home Hunter")]),
            ("profiles.create", ["name": .string("home-hunter"), "clone_all": .bool(true)]),
            ("profiles.create", ["name": .string("home-hunter"), "model": .string("gpt-6")]),
            ("profiles.create", ["name": .string("home-hunter"), "no_skills": .bool(true), "clone_from": .string("inbox-triage")]),
            ("session.create", ["profile": .string("home-hunter"), "title": .string("Scratch"), "hidden": .bool(true), "follow_profile_config": .bool(true)]),
            ("session.create", ["profile": .string("home-hunter"), "title": .string("Bot Chat"), "hidden": .bool(true), "follow_profile_config": .bool(true), "messages": .array([])]),
            ("session.title", ["session_id": .string("runtime"), "title": .string("Renamed")])
        ]
        for (method, params) in rejected {
            do {
                _ = try await client.call(method, params)
                XCTFail("Invalid \(method) call dispatched")
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        for mode in BotPromptMode.allCases {
            _ = try await client.call(mode.method, mode.params(runtime: "runtime", text: "one operation"))
        }
        XCTAssertEqual(socket.sentRequests.map { $0["method"].text },
                       ["prompt.submit", "session.steer", "prompt.submit", "session.redirect"])
        for (request, mode) in zip(socket.sentRequests, BotPromptMode.allCases) {
            XCTAssertEqual(request["params"]["session_id"], .string("runtime"))
            XCTAssertEqual(request["params"]["text"], .string("one operation"))
            XCTAssertEqual(request["params"]["queued"], mode == .send || mode == .queue ? .bool(true) : .null)
        }
        for unsupported in ["prompt.btw", "prompt.background", "slash.exec"] {
            do { _ = try await client.call(unsupported, [:]); XCTFail("Unimplemented actions must not dispatch") }
            catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }

        _ = try await client.call("commands.catalog", [:])
        _ = try await client.call("command.dispatch", [
            "name": .string("work"), "arg": .string("fix the leak"), "session_id": .string("runtime")
        ])
        XCTAssertEqual(socket.sentTextFrames, 2)

        let rejected: [(String, [String: BotJSON])] = [
            ("slash.exec", ["command": .string("/deploy"), "session_id": .string("runtime")]),
            ("commands.catalog", ["session_id": .string("runtime")]),
            ("command.dispatch", ["name": .string("/work"), "arg": .string(""), "session_id": .string("runtime")]),
            ("command.dispatch", ["name": .string("work fix"), "arg": .string(""), "session_id": .string("runtime")]),
            ("command.dispatch", ["name": .string(""), "arg": .string(""), "session_id": .string("runtime")]),
            ("command.dispatch", ["name": .string("work"), "arg": .string(""), "session_id": .string("")]),
            ("command.dispatch", ["name": .string("work"), "session_id": .string("runtime")]),
            ("command.dispatch", ["name": .string("work"), "arg": .string(""), "session_id": .string("runtime"), "shell": .bool(true)])
        ]
        for (method, params) in rejected {
            do {
                _ = try await client.call(method, params)
                XCTFail("Invalid \(method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 2)
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }

        _ = try await client.call("complete.path", [
            "word": .string("src/Ch"), "session_id": .string("runtime"), "profile": .string("default")
        ])
        XCTAssertEqual(socket.sentTextFrames, 1)

        let rejected: [(String, [String: BotJSON])] = [
            ("complete.path", ["word": .string(""), "session_id": .string("runtime"), "profile": .string("default")]),
            ("complete.path", ["word": .string("src Ch"), "session_id": .string("runtime"), "profile": .string("default")]),
            ("complete.path", ["word": .string("src"), "session_id": .string(""), "profile": .string("default")]),
            ("complete.path", ["word": .string("src"), "session_id": .string("runtime")]),
            ("complete.path", ["word": .string("src"), "profile": .string("default")]),
            ("complete.path", ["word": .string("src"), "session_id": .string("runtime"), "profile": .string("default"), "cwd": .string("/tmp")]),
            ("slash.exec", ["command": .string("/deploy"), "session_id": .string("runtime")])
        ]
        for (method, params) in rejected {
            do {
                _ = try await client.call(method, params)
                XCTFail("Invalid \(method) call dispatched")
            } catch {
                XCTAssertEqual(error as? BotFailure, .unsupported)
            }
        }
        XCTAssertEqual(socket.sentTextFrames, 1)
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }

        let lookup = Task {
            try await client.call("complete.path", [
                "word": .string("src"), "session_id": .string("runtime"), "profile": .string("default")
            ])
        }
        await fulfillment(of: [started], timeout: 2)
        lookup.cancel()
        do { _ = try await lookup.value; XCTFail("Cancelled completion succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }

        _ = try await client.call("profiles.list", [:])
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }
        for key in ["reasoning", "fast", "model"] {
            do {
                _ = try await client.call("config.set", ["key": .string(key), "value": .string("high"), "session_id": .string("runtime")])
                XCTFail("Only explicit session settings are supported")
            } catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
        XCTAssertTrue(socket.sentRequests.isEmpty)
        do {
            _ = try await client.call("config.set", ["key": .string("model"), "value": .string("model --provider provider --session"), "scope": .string("session"), "session_id": .string("runtime")])
            XCTFail("Rejected setting succeeded")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Provider unavailable")
        }
        for (key, value) in [("reasoning", "none"), ("reasoning", "ultra"), ("fast", "normal"), ("fast", "fast")] {
            do {
                _ = try await client.call("config.set", ["key": .string(key), "value": .string(value), "scope": .string("session"), "session_id": .string("runtime")])
                XCTFail("Rejected setting succeeded")
            } catch { XCTAssertEqual(error.localizedDescription, "Provider unavailable") }
        }
        for (key, value) in [("reasoning", "off"), ("reasoning", "show"), ("fast", "toggle"), ("yolo", "on")] {
            do {
                _ = try await client.call("config.set", ["key": .string(key), "value": .string(value), "scope": .string("session"), "session_id": .string("runtime")])
                XCTFail("Unsupported setting was dispatched")
            } catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
        XCTAssertEqual(socket.sentRequests.count, 5)
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in BotScriptedSocket() }
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in
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
        let client = BotClient(connection: record, configuration: configuration) { _, _ in
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
            let client = BotClient(connection: record, configuration: configuration) { _, _ in BotScriptedSocket() }
            try await client.connect()
            XCTAssertEqual(client.serverInstallID, live)
            client.close()
        }
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
        let client = BotClient(connection: record, configuration: configuration) { _, _ in BotScriptedSocket() }
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        let received = expectation(description: "String-id request forwarded")
        client.onEvent = { frame in
            XCTAssertEqual(frame["id"], .string("srq-live"))
            XCTAssertEqual(frame["method"], .string("sudo"))
            received.fulfill()
        }
        socket.enqueue(.string(#"{"jsonrpc":"2.0","id":"srq-live","method":"sudo","params":{"session_id":"runtime"}}"#))
        socket.reply = { request in .object(["id": request["id"], "result": .object(["status": .string("expired")])]) }
        let result = try await client.call("request.answer", ["id": .string("srq-live"), "result": .object(["value": .string("")])])
        XCTAssertEqual(result["status"], .string("expired"))
        let locked = try await client.call("clarify.lock", ["request_id": .string("srq-batch"), "question_id": .string("q1"), "answer": .string("yes")])
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
        let client = BotClient(connection: connection(), configuration: configuration) { _, _ in socket }
        try await client.connect()
        defer { client.close() }
        let valid: [(String, [String: BotJSON])] = [
            ("groups.capabilities", [:]), ("groups.list", ["limit": .number(500), "offset": .number(0), "include_disbanded": .bool(false)]),
            ("groups.state", ["room_id": .string("room:1")]),
            ("groups.send", ["room_id": .string("room"), "event_id": .string("event"), "payload": .object(["text": .string("hello"), "thread_id": .string("thread")])]),
            ("groups.stop", ["room_id": .string("room")]),
            ("groups.approve", ["room_id": .string("room"), "member_id": .string("member"), "task_id": .string("task"), "request_id": .string("request"), "execution_generation": .number(1), "choice": .string("once")]),
            ("groups.retry", ["room_id": .string("room"), "task_id": .string("task")]),
            ("groups.disband", ["room_id": .string("room")]),
            ("groups.rename", ["room_id": .string("room"), "event_id": .string("event"), "name": .string("Renamed")]),
            ("groups.create", ["room_id": .string("room"), "name": .string("Created"), "members": .array(
                ["default", "dev"].map { .object(["member_id": .string($0), "profile": .string($0), "handle": .string($0)]) })]),
            ("groups.log", ["room_id": .string("room:1"), "since_seq": .number(0), "limit": .number(200)])]
        for (method, params) in valid { _ = try await client.call(method, params) }
        var invalid: [(String, [String: BotJSON])] = [
            ("groups.capabilities", ["profile": .string("default")]),
            ("groups.list", ["limit": .number(501)]), ("groups.list", ["offset": .number(-1)]),
            ("groups.list", ["limit": .number(1.5)]), ("groups.list", ["include_disbanded": .string("true")]),
            ("groups.state", [:]), ("groups.state", ["room_id": .string("../room")]),
            ("groups.state", ["room_id": .string("room\n")]),
            ("groups.state", ["room_id": .string(String(repeating: "a", count: 129))]),
            ("groups.log", ["room_id": .string("room"), "since_seq": .number(-1)]),
            ("groups.log", ["room_id": .string("room"), "limit": .bool(true)])]
        invalid += ["send", "approve", "retry", "create", "rename", "promote", "demote", "replicate", "replica_state", "peer.invite", "peer.register", "peer.revoke"].map { ("groups." + $0, ["room_id": .string("room")]) }
        for (method, params) in invalid {
            do { _ = try await client.call(method, params); XCTFail("Invalid room call dispatched: " + method) }
            catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
        XCTAssertEqual(socket.sentRequests.count, valid.count)
        socket.reply = { request in .object(["id": request["id"], "error": .object([
            "code": .number(4112), "message": .string("Expired"), "data": .object(["reason": .string("room_history_expired")])])]) }
        do { _ = try await client.call("groups.log", ["room_id": .string("room")]); XCTFail("Expected room error") }
        catch { XCTAssertTrue((error as? BotRoomFailure)?.expired == true) }
    }

    func testRoomParticipantValidationRejectsOversizedTextAndIncompleteApprovalTuples() throws {
        let send: [String: BotJSON] = ["room_id": .string("room"), "event_id": .string("event"),
            "payload": .object(["text": .string(String(repeating: "é", count: 32768)), "thread_id": .string("thread")])]
        XCTAssertNoThrow(try BotRoomRPC.validate("groups.send", send))
        for text in [" \n", String(repeating: "é", count: 32769)] {
            var invalid = send
            invalid["payload"] = .object(["text": .string(text), "thread_id": .string("thread")])
            XCTAssertThrowsError(try BotRoomRPC.validate("groups.send", invalid))
        }
        var invalid = send
        invalid["payload"] = .object(["text": .string("hello"), "thread_id": .string("thread"), "attachments": .array([])])
        XCTAssertThrowsError(try BotRoomRPC.validate("groups.send", invalid))
        let approval: [String: BotJSON] = ["room_id": .string("room"), "member_id": .string("member"),
            "task_id": .string("task"), "request_id": .string("request"), "execution_generation": .number(1), "choice": .string("once")]
        for key in approval.keys {
            var missing = approval; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try BotRoomRPC.validate("groups.approve", missing), key)
        }
        for value in [BotJSON.number(0), .number(-1), .number(1.5), .string("1")] {
            var bad = approval; bad["execution_generation"] = value
            XCTAssertThrowsError(try BotRoomRPC.validate("groups.approve", bad))
        }
        for value in ["session", "always", "future"] {
            var bad = approval; bad["choice"] = .string(value)
            XCTAssertThrowsError(try BotRoomRPC.validate("groups.approve", bad))
        }
        XCTAssertThrowsError(try BotRoomRPC.validate("groups.stop", ["room_id": .string("room"), "cancel_id": .number(1)]))
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
    var reply: ((BotJSON) -> BotJSON)?
    var withholdReply: ((BotJSON) -> Bool)?
    private(set) var sentTextFrames = 0
    private(set) var sentRequests: [BotJSON] = []
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
        record(request)
        if withholdReply?(request) == true { return }
        let response = reply?(request) ?? BotJSON.object(["id": request["id"], "result": .object(["profiles": .array([])])])
        let frame = URLSessionWebSocketTask.Message.string(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
        enqueue(frame)
    }
    private func record(_ request: BotJSON) {
        lock.lock(); sentRequests.append(request); lock.unlock()
    }

    func enqueue(_ frame: URLSessionWebSocketTask.Message) {
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
