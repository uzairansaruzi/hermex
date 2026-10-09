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
            (.sessionNew(profile: "triage"), "session.create", ["profile": .string("triage")]),
            (.sessionNew(profile: "triage", cwd: "/work", model: .init(id: "gpt-6", provider: "openai")), "session.create",
             ["profile": .string("triage"), "cwd": .string("/work"), "model": .string("gpt-6"), "provider": .string("openai")]),
            (.sessionTitle(sessionID: "runtime"), "session.title", ["session_id": .string("runtime"), "title": .string("Bot Chat")]),
            (.sessionRename(runtime: "runtime", title: "Plan"), "session.title",
             ["session_id": .string("runtime"), "title": .string("Plan")]),
            (.sessionClose(runtime: "runtime"), "session.close", ["session_id": .string("runtime")]),
            (.sessionDelete(profile: "triage", storedKey: "tip"), "session.delete",
             ["session_id": .string("tip"), "profile": .string("triage")]),
            (.sessionBranch(runtime: "runtime", name: nil, count: 6), "session.branch",
             ["session_id": .string("runtime"), "count": .number(6)]),
            (.sessionBranch(runtime: "runtime", name: "Experiment", count: nil), "session.branch",
             ["session_id": .string("runtime"), "name": .string("Experiment")]),
            (.sessionWorkspaceMove(profile: "triage", storedKey: "tip", cwd: "/work"), "session.workspace.move",
             ["session_key": .string("tip"), "cwd": .string("/work"), "profile": .string("triage")]),
            (.projectsTree(profile: "triage"), "projects.tree", ["profile": .string("triage")]),
            (.projectsCreate(profile: "triage", name: "Launch", folder: "/work", color: "#7cb9ff"), "projects.create",
             ["profile": .string("triage"), "name": .string("Launch"), "folders": .array([.string("/work")]),
              "primary_path": .string("/work"), "color": .string("#7cb9ff")]),
            (.projectsCreate(profile: "triage", name: "Launch", folder: "/work", color: nil), "projects.create",
             ["profile": .string("triage"), "name": .string("Launch"), "folders": .array([.string("/work")]),
              "primary_path": .string("/work")]),
            (.projectsUpdate(profile: "triage", id: "p_1", name: "Launch", color: "#f5c542"), "projects.update",
             ["profile": .string("triage"), "id": .string("p_1"), "name": .string("Launch"), "color": .string("#f5c542")]),
            (.projectsUpdate(profile: "triage", id: "p_1", name: "Launch", color: nil), "projects.update",
             ["profile": .string("triage"), "id": .string("p_1"), "name": .string("Launch")]),
            (.projectsDelete(profile: "triage", id: "p_1"), "projects.delete", ["profile": .string("triage"), "id": .string("p_1")]),
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
            (.sessionUndo(runtime: "runtime"), "session.undo", ["session_id": .string("runtime")]),
            (.sessionCompress(runtime: "runtime", focus: nil, profile: "triage"), "session.compress",
             ["session_id": .string("runtime"), "profile": .string("triage")]),
            (.sessionCompress(runtime: "runtime", focus: "the API", profile: "triage"), "session.compress",
             ["session_id": .string("runtime"), "profile": .string("triage"), "focus_topic": .string("the API")]),
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
            (.profileModelOptions(profile: "research"), "model.options", ["profile": .string("research")]),
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
            // The one Profile-wide write: no scope, which the host ignores for it.
            (.configSet(sessionID: "runtime", profile: "triage", setting: .personality("pirate")), "config.set",
             ["session_id": .string("runtime"), "profile": .string("triage"),
              "key": .string("personality"), "value": .string("pirate")]),
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
            (.completeFolder(word: "~/src/ap", profile: "triage"), "complete.path",
             ["word": .string("~/src/ap"), "profile": .string("triage")]),
            (.completeSlash(text: "/approvals ", sessionID: "runtime"), "complete.slash",
             ["text": .string("/approvals "), "session_id": .string("runtime")]),
            (.slashExec(sessionID: "runtime", command: "/context all"), "slash.exec",
             ["session_id": .string("runtime"), "command": .string("/context all")]),
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
            (.commitMessage(diff: "+a", recentCommits: "fix: b", avoid: nil, sessionID: nil, profile: "triage"), "llm.oneshot",
             ["template": .string("commit_message"), "temperature": .number(0.8), "profile": .string("triage"),
              "variables": .object(["diff": .string("+a"), "recent_commits": .string("fix: b")])]),
            (.commitMessage(diff: "+a", recentCommits: "", avoid: "feat: a", sessionID: "runtime", profile: "triage"), "llm.oneshot",
             ["template": .string("commit_message"), "temperature": .number(0.8), "profile": .string("triage"),
              "session_id": .string("runtime"),
              "variables": .object(["diff": .string("+a"), "recent_commits": .string(""), "avoid": .string("feat: a")])]),
            (.clientCapabilities, "client.capabilities", ["server_requests": .bool(true)])
        ]
        for (call, method, params) in cases {
            XCTAssertEqual(call.method, method)
            XCTAssertEqual(try call.params(), params, method)
        }
    }

    /// A rename needs a runtime and a title, and a delete names its Profile and stored key (#1048);
    /// a branch names its runtime, and any name or count it carries is real (#1051).
    func testSessionLifecycleCallsRefuseAnEmptyTarget() {
        XCTAssertThrowsError(try HermesCall.sessionBranch(runtime: "", name: nil, count: nil).params())
        XCTAssertThrowsError(try HermesCall.sessionBranch(runtime: "runtime", name: " \n", count: nil).params())
        XCTAssertThrowsError(try HermesCall.sessionBranch(runtime: "runtime", name: nil, count: 0).params())
        XCTAssertThrowsError(try HermesCall.sessionRename(runtime: "runtime", title: " \n").params())
        XCTAssertThrowsError(try HermesCall.sessionRename(runtime: "", title: "Plan").params())
        XCTAssertThrowsError(try HermesCall.sessionClose(runtime: "").params())
        XCTAssertThrowsError(try HermesCall.sessionDelete(profile: "", storedKey: "tip").params())
        XCTAssertThrowsError(try HermesCall.sessionDelete(profile: "triage", storedKey: "").params())
    }

    /// A compaction names its runtime and Profile, and a focus only when there is one; a new
    /// session's folder and model are never blank (#1050).
    func testCompressAndNewSessionCallsRefuseBlankValues() {
        XCTAssertThrowsError(try HermesCall.sessionCompress(runtime: "", focus: nil, profile: "triage").params())
        XCTAssertThrowsError(try HermesCall.sessionCompress(runtime: "runtime", focus: nil, profile: "").params())
        XCTAssertThrowsError(try HermesCall.sessionCompress(runtime: "runtime", focus: " \n", profile: "triage").params())
        XCTAssertThrowsError(try HermesCall.sessionNew(profile: "triage", cwd: "").params())
        XCTAssertThrowsError(try HermesCall.sessionNew(profile: "triage", model: .init(id: "gpt-6", provider: "")).params())
    }

    /// A project names its Profile, a name and a folder, and a move a stored session and a
    /// folder; a folder is completed only from the host's root or home (#1052).
    func testProjectAndMoveCallsRefuseBlankValues() {
        let refused: [HermesCall] = [
            .projectsTree(profile: ""),
            .projectsCreate(profile: "triage", name: " ", folder: "/work", color: nil),
            .projectsCreate(profile: "triage", name: "Launch", folder: "", color: nil),
            .projectsCreate(profile: "triage", name: "Launch", folder: "/work", color: ""),
            .projectsUpdate(profile: "triage", id: "p_1", name: "", color: nil),
            .projectsUpdate(profile: "triage", id: "", name: "Launch", color: nil),
            .projectsDelete(profile: "triage", id: ""),
            .sessionWorkspaceMove(profile: "triage", storedKey: "", cwd: "/work"),
            .sessionWorkspaceMove(profile: "triage", storedKey: "tip", cwd: " "),
            .sessionWorkspaceMove(profile: "", storedKey: "tip", cwd: "/work"),
            .completeFolder(word: "src/app", profile: "triage"),
            .completeFolder(word: "~", profile: "triage"),
            .completeFolder(word: "/work", profile: "")
        ]
        for call in refused {
            XCTAssertThrowsError(try call.params(), "\(call)")
        }
    }

    /// A commit message is asked for a real diff, under a Profile; the runtime and the message to
    /// avoid are sent only when there are ones (#1115).
    func testACommitMessageRefusesBlankValues() {
        let refused: [HermesCall] = [
            .commitMessage(diff: " \n", recentCommits: "", avoid: nil, sessionID: nil, profile: "triage"),
            .commitMessage(diff: "+a", recentCommits: "", avoid: " ", sessionID: nil, profile: "triage"),
            .commitMessage(diff: "+a", recentCommits: "", avoid: nil, sessionID: "", profile: "triage"),
            .commitMessage(diff: "+a", recentCommits: "", avoid: nil, sessionID: nil, profile: "")
        ]
        for call in refused {
            XCTAssertThrowsError(try call.params(), "\(call)")
        }
    }

    /// Slash commands go out one typed line at a time, and completion only at a command's
    /// argument stage (#1036).
    func testSlashCallsAdmitOnlyOneNamedLine() {
        XCTAssertNoThrow(try HermesCall.slashExec(sessionID: "runtime", command: "/context").params())
        XCTAssertNoThrow(try HermesCall.slashExec(sessionID: "runtime", command: "/queue hi there").params())
        for command in ["", "/", "context", "/ context", "/queue hi\nthere"] {
            XCTAssertThrowsError(try HermesCall.slashExec(sessionID: "runtime", command: command).params(), command)
        }
        XCTAssertThrowsError(try HermesCall.slashExec(sessionID: "", command: "/context").params())

        XCTAssertNoThrow(try HermesCall.completeSlash(text: "/approvals ", sessionID: "runtime").params())
        XCTAssertNoThrow(try HermesCall.completeSlash(text: "/queue list e", sessionID: "runtime").params())
        for text in ["/con", "/", "/ approvals", "approvals ", "/approvals \nx"] {
            XCTAssertThrowsError(try HermesCall.completeSlash(text: text, sessionID: "runtime").params(), text)
        }
        XCTAssertThrowsError(try HermesCall.completeSlash(text: "/approvals ", sessionID: "").params())
    }

    /// The host hands a Git write's `file` to git as a pathspec, where `*` matches other files and
    /// `.`, a blank or no file the whole tree (#1115): a file goes out literal, and one that isn't a
    /// single path inside the repository is refused before anything is sent.
    func testAGitWriteNamesOneExactFile() throws {
        let base = URL(string: "https://hermes.example")!
        for file in ["", " ", " \n", ".", "./", "a/./b", "a/..", "../a", "/a", "a//b"] {
            XCTAssertThrowsError(try HermesREST.gitStage(repository: "/r", file: file).request(base: base), file)
            XCTAssertThrowsError(try HermesREST.gitUnstage(repository: "/r", file: file).request(base: base), file)
            XCTAssertThrowsError(try HermesREST.gitRevert(repository: "/r", file: file).request(base: base), file)
        }
        XCTAssertThrowsError(try HermesREST.gitRevert(repository: "", file: "a").request(base: base))
        for file in ["*", " a.txt", "a.txt ", "Sources/", ":(glob)x"] {
            let request = try HermesREST.gitRevert(repository: "/r", file: file).request(base: base)
            let body = try request.httpBody.map { try JSONDecoder().decode(BotJSON.self, from: $0) }
            XCTAssertEqual(body?["file"], .string(":(literal)" + file))
        }
    }

    /// The host rewrites a branch name before `git switch` (`_sanitize_branch`), so a name it
    /// would change, which could reach another branch, is refused before anything is sent (#1116).
    func testABranchSwitchSendsOnlyANameTheHostKeeps() throws {
        let base = URL(string: "https://hermes.example")!
        // A decomposed accent (U+0301) or zero-width joiner is stripped by the host, so "cafe\u{301}"
        // would switch to "cafe"; the precomposed "café" and other letters and numerals pass.
        for name in ["", "feat+x", "my branch", "-x", "x/", ".x", "a..b", "a//b", "a--b", "a@{1}", "x~1",
                     "cafe\u{301}", "a\u{200D}b", "x\u{903}"] {
            XCTAssertThrowsError(try HermesREST.gitSwitchBranch(repository: "/r", branch: name).request(base: base), name)
        }
        XCTAssertThrowsError(try HermesREST.gitSwitchBranch(repository: "", branch: "dev").request(base: base))
        for name in ["dev", "feature/x-1", "release_2.0", "caf\u{E9}", "x\u{663}", "\u{216B}", "\u{2B0}x"] {
            let request = try HermesREST.gitSwitchBranch(repository: "/r", branch: name).request(base: base)
            let body = try JSONDecoder().decode(BotJSON.self, from: XCTUnwrap(request.httpBody))
            // String equality is canonical, so compare scalars: the name goes out unnormalized.
            guard case .object(let fields) = body, case .string(let sent) = fields["branch"] else { return XCTFail(name) }
            XCTAssertEqual(fields["path"], .string("/r"))
            XCTAssertEqual(Array(sent.unicodeScalars), Array(name.unicodeScalars), name)
        }
    }

    func testEveryRESTRequestKeepsItsMethodPathQueryAndBody() throws {
        let base = URL(string: "https://hermes.example:9120")!
        let json = ["Content-Type": "application/json"]
        let imported = BotJSON.object(["sessions": .array([.object(["id": .string("20261008_002420_fb927d")])]),
                                       "profile": .string("triage")])
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
             "https://hermes.example:9120/api/sessions/bg_0a5110/messages?profile=triage", nil, [:]),
            (.sessionList(profile: "triage", offset: 100, archived: true), "GET",
             "https://hermes.example:9120/api/sessions?profile=triage&order=recent&archived=only&limit=100&offset=100&exclude_sources=cron,kanban,oneshot,subagent,tool",
             nil, [:]),
            (.updateSession(key: "tip", profile: "triage", change: .title("Plan")), "PATCH",
             "https://hermes.example:9120/api/sessions/tip", .object(["title": .string("Plan"), "profile": .string("triage")]), json),
            (.sessionExport(key: "tip", profile: "triage"), "GET",
             "https://hermes.example:9120/api/sessions/tip/export?profile=triage", nil, [:]),
            (.sessionRow(key: "tip", profile: "triage"), "GET", "https://hermes.example:9120/api/sessions/tip?profile=triage", nil, [:]),
            (.importSessions(body: try JSONEncoder().encode(imported)), "POST", "https://hermes.example:9120/api/sessions/import",
             imported, json),
            (.cronJobs, "GET", "https://hermes.example:9120/api/cron/jobs", nil, [:]),
            (.cronCreate(profile: "research", fields: ["schedule": .string("0 9 * * *")]), "POST",
             "https://hermes.example:9120/api/cron/jobs?profile=research", .object(["schedule": .string("0 9 * * *")]), json),
            (.cronCreate(profile: nil, fields: [:]), "POST", "https://hermes.example:9120/api/cron/jobs", .object([:]), json),
            (.cronUpdate(id: "d804e8d67342", profile: "research", updates: ["name": .string("Digest")]), "PUT",
             "https://hermes.example:9120/api/cron/jobs/d804e8d67342?profile=research",
             .object(["updates": .object(["name": .string("Digest")])]), json),
            (.cronPause(id: "d804e8d67342", profile: "research"), "POST",
             "https://hermes.example:9120/api/cron/jobs/d804e8d67342/pause?profile=research", nil, [:]),
            (.cronResume(id: "d804e8d67342", profile: nil), "POST",
             "https://hermes.example:9120/api/cron/jobs/d804e8d67342/resume", nil, [:]),
            (.cronDelete(id: "d804e8d67342", profile: "research"), "DELETE",
             "https://hermes.example:9120/api/cron/jobs/d804e8d67342?profile=research", nil, [:]),
            (.cronTrigger(id: "d804e8d67342", profile: "research"), "POST",
             "https://hermes.example:9120/api/cron/jobs/d804e8d67342/trigger?profile=research", nil, [:]),
            (.cronRuns(id: "d804e8d67342", profile: "research", limit: 100), "GET",
             "https://hermes.example:9120/api/cron/jobs/d804e8d67342/runs?profile=research&limit=100", nil, [:]),
            (.cronDeliveryTargets(profile: "research"), "GET",
             "https://hermes.example:9120/api/cron/delivery-targets?profile=research", nil, [:]),
            (.skills(profile: "research"), "GET", "https://hermes.example:9120/api/skills?profile=research", nil, [:]),
            (.fsReadText(path: "/h/a+b c/MEMORY.md"), "GET",
             "https://hermes.example:9120/api/fs/read-text?path=/h/a%2Bb%20c/MEMORY.md", nil, [:]),
            (.fsWriteText(path: "/h/memories/MEMORY.md", content: "a\n§\nb"), "POST", "https://hermes.example:9120/api/fs/write-text",
             .object(["path": .string("/h/memories/MEMORY.md"), "content": .string("a\n§\nb")]), json),
            (.filesMkdir(path: "/h/memories"), "POST", "https://hermes.example:9120/api/files/mkdir",
             .object(["path": .string("/h/memories")]), json),
            (.gitStage(repository: "/r/a+b", file: "Sources/A.swift"), "POST", "https://hermes.example:9120/api/git/review/stage",
             .object(["path": .string("/r/a+b"), "file": .string(":(literal)Sources/A.swift")]), json),
            (.gitUnstage(repository: "/r", file: "A.swift"), "POST", "https://hermes.example:9120/api/git/review/unstage",
             .object(["path": .string("/r"), "file": .string(":(literal)A.swift")]), json),
            (.gitUnstage(repository: "/r", file: nil), "POST", "https://hermes.example:9120/api/git/review/unstage",
             .object(["path": .string("/r")]), json),
            (.gitRevert(repository: "/r", file: "notes.txt"), "POST", "https://hermes.example:9120/api/git/review/revert",
             .object(["path": .string("/r"), "file": .string(":(literal)notes.txt")]), json),
            (.gitCommit(repository: "/r", message: "fix: a"), "POST", "https://hermes.example:9120/api/git/review/commit",
             .object(["path": .string("/r"), "message": .string("fix: a"), "push": .bool(false)]), json),
            (.gitPush(repository: "/r"), "POST", "https://hermes.example:9120/api/git/review/push",
             .object(["path": .string("/r")]), json),
            (.gitHead(repository: "/r/a+b"), "GET", "https://hermes.example:9120/api/git/review/rev-parse?path=/r/a%2Bb", nil, [:]),
            (.gitCommitContext(repository: "/r"), "GET", "https://hermes.example:9120/api/git/review/commit-context?path=/r",
             nil, [:]),
            (.gitBranches(repository: "/r/a+b"), "GET", "https://hermes.example:9120/api/git/branches?path=/r/a%2Bb", nil, [:]),
            (.gitSwitchBranch(repository: "/r", branch: "feature/x"), "POST", "https://hermes.example:9120/api/git/branch/switch",
             .object(["path": .string("/r"), "branch": .string("feature/x")]), json),
            (.config(profile: "research"), "GET", "https://hermes.example:9120/api/config?profile=research", nil, [:]),
            (.profileSoul(name: "research"), "GET", "https://hermes.example:9120/api/profiles/research/soul", nil, [:]),
            (.setProfileSoul(name: "research", content: "Be direct."), "PUT", "https://hermes.example:9120/api/profiles/research/soul",
             .object(["content": .string("Be direct.")]), json),
            (.speak(text: "Hi there.", profile: "research"), "POST", "https://hermes.example:9120/api/audio/speak?profile=research",
             .object(["text": .string("Hi there.")]), json),
            (.kanbanConfig, "GET", "https://hermes.example:9120/api/plugins/kanban/config", nil, [:]),
            (.kanbanBoards, "GET", "https://hermes.example:9120/api/plugins/kanban/boards", nil, [:]),
            (.kanbanBoard(board: "default", tenant: nil, includeArchived: false), "GET",
             "https://hermes.example:9120/api/plugins/kanban/board?board=default", nil, [:]),
            (.kanbanBoard(board: "ops", tenant: "app", includeArchived: true), "GET",
             "https://hermes.example:9120/api/plugins/kanban/board?board=ops&tenant=app&include_archived=true", nil, [:]),
            (.kanbanStats(board: "ops"), "GET", "https://hermes.example:9120/api/plugins/kanban/stats?board=ops", nil, [:]),
            (.kanbanAssignees(board: "ops"), "GET", "https://hermes.example:9120/api/plugins/kanban/assignees?board=ops", nil, [:]),
            (.kanbanTask(id: "t_6307395e", board: "ops"), "GET",
             "https://hermes.example:9120/api/plugins/kanban/tasks/t_6307395e?board=ops", nil, [:]),
            (.kanbanTaskLog(id: "t_6307395e", board: "ops", tailBytes: 65_536), "GET",
             "https://hermes.example:9120/api/plugins/kanban/tasks/t_6307395e/log?board=ops&tail=65536", nil, [:]),
            (.kanbanCreateTask(board: "ops", body: ["title": .string("A")]), "POST",
             "https://hermes.example:9120/api/plugins/kanban/tasks?board=ops", .object(["title": .string("A")]), json),
            (.kanbanUpdateTask(id: "t_6307395e", board: "ops", body: ["status": .string("ready")]), "PATCH",
             "https://hermes.example:9120/api/plugins/kanban/tasks/t_6307395e?board=ops", .object(["status": .string("ready")]), json),
            (.kanbanComment(id: "t_6307395e", board: "ops", body: "Hi"), "POST",
             "https://hermes.example:9120/api/plugins/kanban/tasks/t_6307395e/comments?board=ops", .object(["body": .string("Hi")]), json),
            (.kanbanLink(board: "ops", parent: "t_1", child: "t_2"), "POST", "https://hermes.example:9120/api/plugins/kanban/links?board=ops",
             .object(["parent_id": .string("t_1"), "child_id": .string("t_2")]), json),
            (.kanbanUnlink(board: "ops", parent: "t_1", child: "t_2"), "DELETE",
             "https://hermes.example:9120/api/plugins/kanban/links?board=ops&parent_id=t_1&child_id=t_2", nil, [:]),
            (.kanbanBulk(board: "ops", body: ["ids": .array([.string("t_1")]), "archive": .bool(true)]), "POST",
             "https://hermes.example:9120/api/plugins/kanban/tasks/bulk?board=ops",
             .object(["ids": .array([.string("t_1")]), "archive": .bool(true)]), json),
            (.kanbanDispatch(board: "ops", dryRun: true), "POST",
             "https://hermes.example:9120/api/plugins/kanban/dispatch?board=ops&dry_run=true&max=8", .object([:]), json),
            (.kanbanCreateBoard(body: ["slug": .string("ops")]), "POST", "https://hermes.example:9120/api/plugins/kanban/boards",
             .object(["slug": .string("ops")]), json),
            (.kanbanEditBoard(slug: "ops", body: ["name": .string("Ops")]), "PATCH",
             "https://hermes.example:9120/api/plugins/kanban/boards/ops", .object(["name": .string("Ops")]), json),
            (.kanbanArchiveBoard(slug: "ops"), "DELETE", "https://hermes.example:9120/api/plugins/kanban/boards/ops?delete=false",
             nil, [:]),
            (.kanbanSwitchBoard(slug: "ops"), "POST", "https://hermes.example:9120/api/plugins/kanban/boards/ops/switch",
             .object([:]), json)
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
        XCTAssertThrowsError(try HermesREST.speak(text: "Hi.", profile: "").request(base: base))
        XCTAssertThrowsError(try HermesREST.sessionRow(key: "../profiles", profile: "triage").request(base: base))
        XCTAssertThrowsError(try HermesREST.cronPause(id: "../profiles", profile: "research").request(base: base))
        XCTAssertThrowsError(try HermesREST.cronDelete(id: "", profile: "research").request(base: base))
        XCTAssertThrowsError(try HermesCall.profileModelOptions(profile: "").params())
        XCTAssertThrowsError(try HermesREST.kanbanTask(id: "../config", board: "ops").request(base: base))
        XCTAssertThrowsError(try HermesREST.kanbanTaskLog(id: "", board: "ops", tailBytes: 1).request(base: base))
        XCTAssertThrowsError(try HermesREST.kanbanUpdateTask(id: "../bulk", board: "ops", body: [:]).request(base: base))
        XCTAssertThrowsError(try HermesREST.kanbanArchiveBoard(slug: "../config").request(base: base))
        XCTAssertThrowsError(try HermesREST.profileSoul(name: "../config").request(base: base))
        XCTAssertThrowsError(try HermesREST.setProfileSoul(name: "", content: "x").request(base: base))
        XCTAssertThrowsError(try HermesREST.config(profile: "").request(base: base))
        let upgrade = try HermesREST.gatewayUpgrade(base: base, ticket: "t1")
        XCTAssertEqual(upgrade.url?.absoluteString, "wss://hermes.example:9120/api/ws")
        XCTAssertEqual(upgrade.allHTTPHeaderFields ?? [:], ["Sec-WebSocket-Protocol": "hermes-gateway-v1, hermes-gateway-ticket.t1"])
        XCTAssertEqual(try HermesREST.gatewayUpgrade(base: URL(string: "http://192.168.1.2:9120")!, ticket: "t1").url?.absoluteString,
                       "ws://192.168.1.2:9120/api/ws")
    }
}
