import XCTest
@testable import HermesMobile

/// Every typed Hermes request keeps the exact wire shape the app sent before it
/// was typed, including the fields it omits. Admission rules live in `BotClientTests`.
final class HermesRequestTests: XCTestCase {
    func testEveryCallSendsItsExactWireShape() throws {
        let members = [HermesCall.RoomMember(memberID: "default", profile: "default", handle: "hermes", displayName: "Hermes"),
                       HermesCall.RoomMember(memberID: "dev", profile: "dev", handle: "dev")]
        let look: [String: BotJSON] = ["title": .string("Triage"), "desktop_only": .bool(true)]
        let edit = HermesCall.ProfileChanges(name: "triage", description: "Sorts mail", soul: "Be brief.",
                                             model: .init(id: "gpt-6", provider: "openai"), confirmExpensiveModel: true,
                                             disabledSkills: ["web"], enabledToolsets: [], enabledMCPServers: ["github"],
                                             look: .init(fields: look, revision: 3))
        let cases: [(HermesCall, String, [String: BotJSON])] = [
            (.profilesList(includeSessions: true), "profiles.list", ["include_sessions": .bool(true)]),
            (.profilesDescribe(name: "triage"), "profiles.describe", ["name": .string("triage")]),
            (.profilesGetAsset(name: "triage"), "profiles.get_asset", ["name": .string("triage"), "asset": .string("avatar")]),
            (.profilesSetAsset(name: "triage", avatar: .replace("data:image/jpeg;base64,YQ==")), "profiles.set_asset",
             ["name": .string("triage"), "asset": .string("avatar"), "data": .string("data:image/jpeg;base64,YQ==")]),
            (.profilesSetAsset(name: "triage", avatar: .clear), "profiles.set_asset",
             ["name": .string("triage"), "asset": .string("avatar"), "clear": .bool(true)]),
            (.profilesConfigure(edit), "profiles.configure", [
                "name": .string("triage"), "description": .string("Sorts mail"), "soul": .string("Be brief."),
                "model": .string("gpt-6"), "provider": .string("openai"), "confirm_expensive_model": .bool(true),
                "disabled_skills": .array([.string("web")]), "enabled_toolsets": .array([]),
                "enabled_mcp_servers": .array([.string("github")]),
                "ui_meta": .object(["hermes-bots": .object(look)]),
                "ui_meta_expected_revisions": .object(["hermes-bots": .number(3)])
            ]),
            (.profilesConfigure(.init(name: "triage", model: .init(id: "gpt-6", provider: "openai"))), "profiles.configure",
             ["name": .string("triage"), "model": .string("gpt-6"), "provider": .string("openai")]),
            (.profilesCreate(.init(name: "home-hunter", description: "Finds flats", cloneFrom: "triage",
                                   model: .init(id: "gpt-6", provider: "openai"), sharesCredentials: true)), "profiles.create",
             ["name": .string("home-hunter"), "description": .string("Finds flats"), "clone_from": .string("triage"),
              "model": .string("gpt-6"), "provider": .string("openai"), "share_auth": .bool(true)]),
            (.profilesCreate(.init(name: "chief", soul: "Keep my week.", skipsBundledSkills: true, sharesCredentials: false)),
             "profiles.create",
             ["name": .string("chief"), "soul": .string("Keep my week."), "no_skills": .bool(true), "mirror_credentials": .bool(false)]),
            (.sessionList(profile: "triage"), "session.list",
             ["profile": .string("triage"), "title": .string("Bot Chat"), "include_hidden": .bool(true)]),
            (.sessionCreate(profile: "triage"), "session.create",
             ["profile": .string("triage"), "title": .string("Bot Chat"), "hidden": .bool(true), "follow_profile_config": .bool(true)]),
            (.sessionTitle(sessionID: "runtime"), "session.title", ["session_id": .string("runtime"), "title": .string("Bot Chat")]),
            (.sessionResume(profile: "triage", sessionID: "tip", omitMessages: false), "session.resume",
             ["profile": .string("triage"), "session_id": .string("tip"), "close_on_disconnect": .bool(false)]),
            (.sessionResume(profile: "triage", sessionID: "tip", omitMessages: true), "session.resume",
             ["profile": .string("triage"), "session_id": .string("tip"), "close_on_disconnect": .bool(false),
              "omit_messages": .bool(true)]),
            (.sessionEventsSince(sessionID: "runtime", lastSeen: 7), "session.events.since",
             ["session_id": .string("runtime"), "last_seen": .number(7)]),
            (.sessionActiveList, "session.active_list", [:]),
            (.promptSubmit(sessionID: "runtime", text: "hi"), "prompt.submit",
             ["session_id": .string("runtime"), "text": .string("hi"), "queued": .bool(true)]),
            (.promptRewind(sessionID: "runtime", text: "hi", beforeRowID: 41), "prompt.submit",
             ["session_id": .string("runtime"), "text": .string("hi"), "truncate_before_row_id": .number(41),
              "confirm_truncate": .bool(true), "confirm_empty_truncate": .bool(true)]),
            (.sessionSteer(sessionID: "runtime", text: "hi"), "session.steer", ["session_id": .string("runtime"), "text": .string("hi")]),
            (.sessionRedirect(sessionID: "runtime", text: "hi"), "session.redirect", ["session_id": .string("runtime"), "text": .string("hi")]),
            (.sessionInterrupt(sessionID: "runtime"), "session.interrupt", ["session_id": .string("runtime")]),
            (.promptBtw(sessionID: "runtime", text: "why?"), "prompt.btw", ["session_id": .string("runtime"), "text": .string("why?")]),
            (.promptBackground(sessionID: "runtime", text: "sum up"), "prompt.background",
             ["session_id": .string("runtime"), "text": .string("sum up")]),
            (.fileAttach(sessionID: "runtime", name: "id-a.txt", dataURL: "data:text/plain;base64,YQ=="), "file.attach",
             ["session_id": .string("runtime"), "name": .string("id-a.txt"), "data_url": .string("data:text/plain;base64,YQ==")]),
            (.approvalRespond(sessionID: "runtime", requestID: "r1", choice: .session), "approval.respond",
             ["session_id": .string("runtime"), "request_id": .string("r1"), "choice": .string("session")]),
            (.requestAnswer(id: "srq", result: .value("secret")), "request.answer",
             ["id": .string("srq"), "result": .object(["value": .string("secret")])]),
            (.requestAnswer(id: "srq", result: .answer("yes")), "request.answer",
             ["id": .string("srq"), "result": .object(["answer": .string("yes")])]),
            (.clarifyLock(requestID: "srq", questionID: "q1", answer: "yes"), "clarify.lock",
             ["request_id": .string("srq"), "question_id": .string("q1"), "answer": .string("yes")]),
            (.modelOptions(sessionID: "runtime", profile: "triage"), "model.options",
             ["session_id": .string("runtime"), "profile": .string("triage")]),
            (.configuredModelOptions, "model.options", ["include_unconfigured": .bool(false)]),
            (.configSet(sessionID: "runtime", profile: "triage", setting: .model(value: "gpt-6 --provider openai --session", confirmExpensive: false)),
             "config.set", ["session_id": .string("runtime"), "profile": .string("triage"), "scope": .string("session"),
                            "key": .string("model"), "value": .string("gpt-6 --provider openai --session"),
                            "confirm_expensive_model": .bool(false)]),
            (.configSet(sessionID: "runtime", profile: "triage", setting: .reasoning("high")), "config.set",
             ["session_id": .string("runtime"), "profile": .string("triage"), "scope": .string("session"),
              "key": .string("reasoning"), "value": .string("high")]),
            (.configSet(sessionID: "runtime", profile: "triage", setting: .fast(false)), "config.set",
             ["session_id": .string("runtime"), "profile": .string("triage"), "scope": .string("session"),
              "key": .string("fast"), "value": .string("normal")]),
            (.sessionCwdSet(sessionID: "runtime", profile: "triage", cwd: "/work"), "session.cwd.set",
             ["session_id": .string("runtime"), "profile": .string("triage"), "cwd": .string("/work")]),
            (.sessionControlRead(sessionID: "runtime", profile: "triage"), "session.control.read",
             ["session_id": .string("runtime"), "profile": .string("triage")]),
            (.sessionControl(sessionID: "runtime", profile: "triage", action: "compress"), "session.control",
             ["session_id": .string("runtime"), "profile": .string("triage"), "action": .string("compress")]),
            (.commandsCatalog(sessionID: "runtime"), "commands.catalog", ["session_id": .string("runtime")]),
            (.commandDispatch(name: "work", argument: "fix it", sessionID: "runtime"), "command.dispatch",
             ["name": .string("work"), "arg": .string("fix it"), "session_id": .string("runtime")]),
            (.completePath(word: "src", sessionID: "runtime", profile: "triage"), "complete.path",
             ["word": .string("src"), "session_id": .string("runtime"), "profile": .string("triage")]),
            (.subagentList(sessionID: "runtime"), "subagent.list", ["session_id": .string("runtime")]),
            (.subagentTail(sessionID: "runtime", subagentID: "w1"), "subagent.tail",
             ["session_id": .string("runtime"), "subagent_id": .string("w1")]),
            (.subagentInterrupt(sessionID: "runtime", subagentID: "w1"), "subagent.interrupt",
             ["session_id": .string("runtime"), "subagent_id": .string("w1")]),
            (.groupsCapabilities, "groups.capabilities", [:]),
            (.groupsList(offset: 500), "groups.list", ["limit": .number(500), "offset": .number(500)]),
            (.groupsState(roomID: "room"), "groups.state", ["room_id": .string("room")]),
            (.groupsLog(roomID: "room", sinceSeq: 4, limit: 100), "groups.log",
             ["room_id": .string("room"), "since_seq": .number(4), "limit": .number(100)]),
            (.groupsSend(roomID: "room", eventID: "e1", text: "hi", threadID: "t1"), "groups.send",
             ["room_id": .string("room"), "event_id": .string("e1"),
              "payload": .object(["text": .string("hi"), "thread_id": .string("t1")])]),
            (.groupsStop(roomID: "room", cancelID: "c1"), "groups.stop", ["room_id": .string("room"), "cancel_id": .string("c1")]),
            (.groupsApprove(roomID: "room", memberID: "dev", taskID: "t1", executionGeneration: 2, requestID: "r1", choice: .deny),
             "groups.approve", ["room_id": .string("room"), "member_id": .string("dev"), "task_id": .string("t1"),
                                "execution_generation": .number(2), "request_id": .string("r1"), "choice": .string("deny")]),
            (.groupsRetry(roomID: "room", taskID: "t1"), "groups.retry", ["room_id": .string("room"), "task_id": .string("t1")]),
            (.groupsCreate(.init(roomID: "room", name: "Crew", members: members)), "groups.create", [
                "room_id": .string("room"), "name": .string("Crew"), "members": .array([
                    .object(["member_id": .string("default"), "profile": .string("default"), "handle": .string("hermes"),
                             "display_name": .string("Hermes")]),
                    .object(["member_id": .string("dev"), "profile": .string("dev"), "handle": .string("dev")])
                ])
            ]),
            (.groupsRename(roomID: "room", eventID: "e1", name: "Crew"), "groups.rename",
             ["room_id": .string("room"), "event_id": .string("e1"), "name": .string("Crew")]),
            (.groupsDisband(roomID: "room"), "groups.disband", ["room_id": .string("room")]),
            (.clientCapabilities, "client.capabilities", ["server_requests": .bool(true)])
        ]
        for (call, method, params) in cases {
            XCTAssertEqual(call.method, method)
            XCTAssertEqual(try call.params(), params, method)
        }
    }

    func testEveryRESTRequestKeepsItsMethodPathQueryAndBody() throws {
        let base = URL(string: "https://hermes.example:9120")!
        let json = ["Content-Type": "application/json"]
        let cases: [(HermesREST, String, String, BotJSON?, [String: String])] = [
            (.status, "GET", "https://hermes.example:9120/api/status", nil, [:]),
            (.login(username: "user", password: "pass"), "POST", "https://hermes.example:9120/auth/password-login",
             .object(["provider": .string("basic"), "username": .string("user"), "password": .string("pass")]), json),
            (.identity, "GET", "https://hermes.example:9120/api/auth/me", nil, [:]),
            (.ticket, "POST", "https://hermes.example:9120/api/auth/ws-ticket", .object([:]), json),
            (.deleteProfile(name: "home-hunter"), "DELETE", "https://hermes.example:9120/api/profiles/home-hunter", nil, [:]),
            (.uploadImage(profile: "triage", filename: "a.png", dataURL: "data:image/png;base64,YQ=="), "POST",
             "https://hermes.example:9120/api/chat/image-upload?profile=triage",
             .object(["filename": .string("a.png"), "data_url": .string("data:image/png;base64,YQ==")]), json),
            (.downloadArtifact(path: "/r/a b.pdf", profile: "triage", sessionID: "tip"), "GET",
             "https://hermes.example:9120/api/fs/download?path=/r/a%20b.pdf&profile=triage&session_id=tip", nil, [:]),
            (.setEnvironment(key: "HERMEX_PUSH_RELAY_URL", value: "https://relay.example"), "PUT", "https://hermes.example:9120/api/env",
             .object(["key": .string("HERMEX_PUSH_RELAY_URL"), "value": .string("https://relay.example")]), json),
            (.installPlugin(identifier: "https://github.com/o/r.git/plugin"), "POST",
             "https://hermes.example:9120/api/dashboard/agent-plugins/install",
             .object(["identifier": .string("https://github.com/o/r.git/plugin"), "enable": .bool(true), "force": .bool(true)]), json),
            (.setPlugin(name: "hermex-push", enabled: true), "POST",
             "https://hermes.example:9120/api/dashboard/agent-plugins/hermex-push/enable", .object([:]), json),
            (.setPlugin(name: "hermex-push", enabled: false), "POST",
             "https://hermes.example:9120/api/dashboard/agent-plugins/hermex-push/disable", .object([:]), json),
            (.restartGateway, "POST", "https://hermes.example:9120/api/gateway/restart", .object([:]), json),
            (.pushPairing, "GET", "https://hermes.example:9120/api/plugins/hermex-push/pairing", nil, [:]),
            (.restartDashboard, "POST", "https://hermes.example:9120/api/plugins/hermex-push/restart", .object([:]), json),
            (.pluginsHub, "GET", "https://hermes.example:9120/api/dashboard/plugins/hub", nil, [:]),
            (.sessionMessages(key: "bg_0a5110", profile: "triage"), "GET",
             "https://hermes.example:9120/api/sessions/bg_0a5110/messages?profile=triage", nil, [:])
        ]
        for (rest, method, url, body, headers) in cases {
            let request = try rest.request(base: base)
            XCTAssertEqual(request.httpMethod, method, url)
            XCTAssertEqual(request.url?.absoluteString, url)
            XCTAssertEqual(try request.httpBody.map { try JSONDecoder().decode(BotJSON.self, from: $0) }, body, url)
            XCTAssertEqual(request.allHTTPHeaderFields ?? [:], headers, url)
        }
        let artifact = try HermesREST.downloadArtifact(path: "a.pdf", profile: "triage", sessionID: "tip").request(base: base)
        XCTAssertEqual(artifact.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertThrowsError(try HermesREST.uploadImage(profile: "", filename: "a.png", dataURL: "data:,").request(base: base))
        XCTAssertThrowsError(try HermesREST.downloadArtifact(path: "a.pdf", profile: "triage", sessionID: "").request(base: base))
        XCTAssertThrowsError(try HermesREST.sessionMessages(key: "../profiles", profile: "triage").request(base: base))
        XCTAssertThrowsError(try HermesREST.sessionMessages(key: "bg_1", profile: "").request(base: base))
        let upgrade = try HermesREST.gatewayUpgrade(base: base, ticket: "t1")
        XCTAssertEqual(upgrade.url?.absoluteString, "wss://hermes.example:9120/api/ws")
        XCTAssertEqual(upgrade.allHTTPHeaderFields ?? [:], ["Sec-WebSocket-Protocol": "hermes-gateway-v1, hermes-gateway-ticket.t1"])
        XCTAssertEqual(try HermesREST.gatewayUpgrade(base: URL(string: "http://192.168.1.2:9120")!, ticket: "t1").url?.absoluteString,
                       "ws://192.168.1.2:9120/api/ws")
    }
}
