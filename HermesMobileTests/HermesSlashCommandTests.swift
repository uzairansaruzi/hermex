import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesSlashCommandTests: XCTestCase {
    func testTheRecordedCatalogListsCommandsAliasesAndSkills() throws {
        let catalog = HermesSlashCatalog(try Self.fixture("commands.catalog"))
        let context = try XCTUnwrap(catalog.commands.first { $0.name == "context" })
        XCTAssertEqual(context.aliases, ["ctx"])
        XCTAssertEqual(catalog.command(named: "CTX"), "context")
        XCTAssertNotNil(catalog.commands.first { $0.name == "hello" }, "the user's quick command")
        XCTAssertTrue(catalog.skills.contains { $0.name == "demo-skill" })
        XCTAssertFalse(catalog.commands.contains { $0.name == "demo-skill" }, "a skill is never a command row")
        XCTAssertNil(catalog.command(named: "demo-skill"))

        XCTAssertTrue(catalog.hostArgumentNames.isSuperset(of: ["context", "ctx", "approvals", "hello"]))
        XCTAssertTrue(catalog.hostArgumentNames.isDisjoint(with: ["model", "personality", "undo", "compact", "reset"]),
                      "Hermex's own commands never ask the host")

        let ranked = AgentSlashCommandSuggestion.matching("ctx", in: catalog.commands, matchingAliases: true)
        XCTAssertEqual(ranked.first?.name, "context")
        XCTAssertEqual(ranked.filter { $0.name == "context" }.count, 1)
    }

    func testAStaleCatalogReplyIsDropped() async throws {
        let chat = await openChat(catalog: false)
        let slash = chat.turn.slashCommands
        chat.host.always("commands.catalog", .init(result: try Self.fixture("commands.catalog")))
        await slash.connect(runtime: "runtime", attempt: chat.turn.engine.generation - 1)
        XCTAssertTrue(slash.catalog.commands.isEmpty)
        await slash.connect(runtime: "runtime", attempt: chat.turn.engine.generation)
        XCTAssertFalse(slash.catalog.commands.isEmpty)
    }

    func testANameRoutesToTheAppTheSkillTheHostOrText() async throws {
        let slash = await openChat().turn.slashCommands
        XCTAssertEqual(slash.route("model"), .appOwned(SlashCommandCatalog.hermesCommand(named: "model")!))
        XCTAssertEqual(slash.route("reset"), .appOwned(SlashCommandCatalog.hermesCommand(named: "new")!), "an alias of /new")
        XCTAssertEqual(slash.route("yolo"), .appOwned(SlashCommandCatalog.hermesCommand(named: "yolo")!))
        XCTAssertEqual(slash.route("title"), .appOwned(SlashCommandCatalog.command(named: "title")!), "#1048")
        XCTAssertEqual(slash.route("undo"), .appOwned(SlashCommandCatalog.command(named: "undo")!), "#1049")
        XCTAssertEqual(slash.route("retry"), .appOwned(SlashCommandCatalog.command(named: "retry")!), "#1049")
        XCTAssertEqual(slash.route("compress"), .appOwned(SlashCommandCatalog.command(named: "compress")!), "#1050")
        XCTAssertEqual(slash.route("compact"), .appOwned(SlashCommandCatalog.command(named: "compact")!), "#1050")
        XCTAssertEqual(slash.route("clear").appOwnedHandler, .clientSide(.clear), "#1050")
        XCTAssertEqual(slash.route("sessions").appOwnedName, "sessions", "#1053")
        XCTAssertEqual(slash.route("resume").appOwnedName, "resume", "#1053")
        XCTAssertEqual(slash.route("branch"), .appOwned(SlashCommandCatalog.command(named: "branch")!), "#1051")
        XCTAssertEqual(slash.route("fork"), .appOwned(SlashCommandCatalog.command(named: "fork")!), "#1051")
        XCTAssertEqual(slash.route("workspace"), .appOwned(SlashCommandCatalog.command(named: "workspace")!), "#1673")
        XCTAssertEqual(slash.route("interrupt"), .appOwned(SlashCommandCatalog.command(named: "interrupt")!), "#1673")
        XCTAssertEqual(slash.route("rollback").appOwnedHandler, .serverSide(.rollback), "#1728")
        XCTAssertEqual(slash.route("demo-skill").isSkill, true)
        XCTAssertEqual(slash.route("context"), .host)
        XCTAssertEqual(slash.route("ctx"), .host)
        XCTAssertEqual(slash.route("hello"), .host)
        XCTAssertEqual(slash.route("notacommand"), .text)
    }

    func testAHostCommandShowsTheHostsOutputAsANotice() async throws {
        let chat = await openChat()
        chat.host.always("slash.exec", .init(result: try Self.fixture("slash.exec /hello")))

        let result = await chat.model.runHermesSlashCommand("/hello")
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("slash.exec"), [["session_id": .string("runtime"), "command": .string("/hello")]])
        XCTAssertEqual(chat.writes("prompt.submit"), [])
        XCTAssertEqual(chat.model.messages.map(\.role), ["local_notice"])
        XCTAssertEqual(chat.model.messages.map(\.content), ["```text\nhermex-quick\n```"])
    }

    func testTitleRenamesTheSessionOnItsRuntime() async {
        let chat = await openChat()
        chat.host.always("session.title", .init(result: .object(["pending": .bool(false), "title": .string("Launch plan")])))

        let result = await chat.model.runHermesSlashCommand("/title  Launch plan ")

        XCTAssertEqual(result, .executed(message: "Title set to **Launch plan**."))
        XCTAssertEqual(chat.writes("session.title"), [["session_id": .string("runtime"), "title": .string("Launch plan")]])
        XCTAssertEqual(chat.writes("slash.exec"), [])
        XCTAssertEqual(chat.model.displayTitle, "Launch plan")
    }

    func testATitleTheHostRefusesShowsItsMessage() async {
        let chat = await openChat()
        let refusal = "Title 'Plan' is already in use by session 20261007_003046_925526"
        chat.host.always("session.title", .init(error: 4022, message: refusal))

        let result = await chat.model.runHermesSlashCommand("/title Plan")

        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, refusal)
    }

    func testASkillSubmitsItsExpansionUnderTheTypedLine() async throws {
        let chat = await openChat()
        let expansion = try Self.fixture("command.dispatch demo-skill")
        chat.host.always("command.dispatch", .init(result: expansion))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

        let result = await chat.model.runHermesSlashCommand("/demo-skill do it")
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("command.dispatch"), [
            ["name": .string("demo-skill"), "arg": .string("do it"), "session_id": .string("runtime")]
        ])
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [expansion["message"]])
        XCTAssertEqual(chat.model.messages.map(\.content), ["/demo-skill do it"])
    }

    func testNewOpensANewChatInTheProfile() async {
        let chat = await openChat()
        guard case .openedHermesSession(let opened)? = await chat.model.runHermesSlashCommand("/new") else {
            return XCTFail("Expected a new chat")
        }
        XCTAssertEqual(opened.target, .new(profile: "default"))
    }

    func testABotChatRefusesCommandsThatLeaveOrRewriteIt() async {
        let chat = await openChat(target: .canonicalChat(profile: "default"))
        let refused = ["/new", "/reset", "/clear", "/resume Launch plan", "/sessions", "/branch Idea", "/fork",
                       "/title Renamed", "/undo", "/retry", "/rollback 1"]
        let sent = chat.host.requests.count
        for line in refused {
            let result = await chat.model.runHermesSlashCommand(line)
            guard case .unsupported = result else { return XCTFail("\(line) ran: \(String(describing: result))") }
        }
        XCTAssertEqual(chat.host.requests.dropFirst(sent).compactMap { $0["method"].text }, [], "nothing reaches the host")
    }

    func testABotChatsPanelOffersOnlyWhatItRuns() async {
        let refused: Set<String> = ["new", "clear", "resume", "sessions", "branch", "fork", "title", "undo", "retry"]
        let bot = await openChat(target: .canonicalChat(profile: "default"))
        let builtins = Set((bot.model.hermesSlashCommands?.scope.builtins ?? []).map(\.name))
        XCTAssertTrue(builtins.isDisjoint(with: refused), "\(builtins.intersection(refused))")
        XCTAssertTrue(builtins.isSuperset(of: ["btw", "background", "goal", "yolo", "compress", "compact", "stop", "model"]))
        let hostCommands = Set(bot.model.composerAgentCommands.map(\.name))
        XCTAssertTrue(hostCommands.isDisjoint(with: refused), "\(hostCommands.intersection(refused))")
        XCTAssertTrue(hostCommands.contains("context"))

        let session = await openChat()
        XCTAssertTrue(Set((session.model.hermesSlashCommands?.scope.builtins ?? []).map(\.name)).isSuperset(of: refused))
        XCTAssertTrue(Set(session.model.composerAgentCommands.map(\.name)).isSuperset(of: ["new", "title", "branch"]))
    }

    func testABotChatOffersNoRewindForkOrOtherProfile() async throws {
        let rows = [Self.row(1, "user", "Hello"), Self.row(2, "assistant", "Hi there.")]
        let profiles: BotJSON = .object(["profiles": .array([.object(["name": .string("default")]),
                                                             .object(["name": .string("coder")])])])
        let bot = await openChat(messages: rows, target: .canonicalChat(profile: "default"), profiles: profiles)
        await waitUntil("the Profiles") { bot.turn.settings.profiles.count == 2 }
        for (index, message) in bot.model.messages.enumerated() {
            let context = try XCTUnwrap(bot.model.actionContext(for: message, visibleIndex: index))
            XCTAssertFalse(context.offersHistoryActions, "Edit and Regenerate rewind the bot's one chat")
            XCTAssertFalse(context.offersFork)
        }
        XCTAssertTrue(bot.model.composerIsSingleProfileMode, "the chip shows the bot's Profile and picks no other")

        let session = await openChat(messages: rows, profiles: profiles)
        await waitUntil("the Profiles") { session.turn.settings.profiles.count == 2 }
        let context = try XCTUnwrap(session.model.actionContext(for: session.model.messages[0], visibleIndex: 0))
        XCTAssertTrue(context.offersHistoryActions)
        XCTAssertTrue(context.offersFork)
        XCTAssertFalse(session.model.composerIsSingleProfileMode)
    }

    func testABotChatRowOpensWithBotChatsRules() {
        func opened(_ row: HermesSessionRow) -> HermesSessionChat? {
            row.summary(in: "default").hermesChat(on: URL(string: "https://hermes.example")!, connection: Self.connection,
                                                  listedIn: "default")
        }
        let bot = opened(HermesSessionRow(id: "bot", title: "Bot Chat", hidden: true, profile: "default"))
        XCTAssertEqual(bot?.target, .session(profile: "default", key: "bot"))
        XCTAssertEqual(bot?.policy, .botChat)
        let tip = opened(HermesSessionRow(id: "tip", title: "Bot Chat (continued)", archived: true, hidden: true,
                                          profile: "default", lineageRootID: "root"))
        XCTAssertEqual(tip?.target, .session(profile: "default", key: "tip"))
        XCTAssertEqual(tip?.policy, .botChat)
        XCTAssertEqual(opened(HermesSessionRow(id: "tip", title: "Notes (continued)", hidden: true,
                                               lineageRootID: "root"))?.policy, .session)
        XCTAssertEqual(opened(HermesSessionRow(id: "a", title: "Plan"))?.policy, .session)
    }

    func testResumeOpensTheOneSessionTitledExactlyThat() async throws {
        let chat = await openChat(search: [Self.searchResult("20261007_090000_aaaaaa", title: "Launch plan",
                                                             root: "cron_job_20261007_080000"),
                                           Self.searchResult("20261007_090000_bbbbbb", title: "Launch plan draft")])

        let result = await chat.model.runHermesSlashCommand("/resume launch PLAN")

        guard case .openedHermesSession(let opened)? = result else {
            return XCTFail("Expected the session titled Launch plan, got \(String(describing: result))")
        }
        XCTAssertEqual(opened.target, .session(profile: "default", key: "20261007_090000_aaaaaa"))
        XCTAssertTrue(opened.isCronRun)
        let searches = HermesHostFixture.requests.filter { $0.url?.path == "/api/sessions/search" }
        XCTAssertEqual(searches.count, 1)
        let query = try XCTUnwrap(searches.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "launch PLAN")
        XCTAssertEqual(query.first { $0.name == "profile" }?.value, "default")
        XCTAssertEqual(chat.writes("slash.exec"), [], "the host's own /resume never runs")
    }

    func testResumeOpensTheSessionWithThatIDBeforeAnyTitle() async {
        let renamed: BotJSON = .object(["id": .string("k-19"), "title": .string("Successor"), "profile": .string("default"),
                                        "parent_session_id": .string("k-07")])
        let chat = await openChat(search: [Self.searchResult("k-81", title: "K-19")], sessionRows: ["k-19": renamed])

        let result = await chat.model.runHermesSlashCommand("/resume k-19")

        guard case .openedHermesSession(let opened)? = result else {
            return XCTFail("Expected session k-19, got \(String(describing: result))")
        }
        XCTAssertEqual(opened.target, .session(profile: "default", key: "k-19"))
        XCTAssertEqual(opened.parentKey, "k-07")
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/search"), 0)
    }

    func testResumeWithoutOneExactTitleOpensTheListSearchingIt() async {
        let chat = await openChat(search: [Self.searchResult("a", title: "Launch plan"), Self.searchResult("b", title: "launch PLAN"),
                                           Self.searchResult("c", title: "Bot Chat")])
        let lines = [("/resume launch", "launch"), ("/resume Launch plan", "Launch plan"), ("/resume Bot Chat", "Bot Chat"),
                     ("/resume", ""), ("/sessions", "")]
        for (line, query) in lines {
            let result = await chat.model.runHermesSlashCommand(line)
            guard case .openedHermesSessionList(let entry)? = result else {
                XCTFail("\(line): expected the Sessions list, got \(String(describing: result))")
                continue
            }
            XCTAssertEqual(entry.query, query, line)
            XCTAssertEqual(entry.profile, "default", line)
            XCTAssertEqual(entry.connection, Self.connection, line)
        }
        XCTAssertEqual(HermesHostFixture.count("/api/sessions/search"), 3, "only a named /resume searches")
        XCTAssertEqual(chat.writes("slash.exec"), [])
    }

    func testAHostCommandWithoutAConnectionIsNotSent() async {
        let chat = await openChat()
        chat.model.suspendStreamForNavigation()
        let result = await chat.model.runHermesSlashCommand("/context")
        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "Reconnect to the server to run /context.")
        XCTAssertEqual(chat.writes("slash.exec"), [])
    }

    func testSendSubmitsTheMessage() async throws {
        let chat = await openChat()
        chat.host.always("slash.exec", .init(result: try Self.fixture("slash.exec /queue hi")))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))

        let result = await chat.model.runHermesSlashCommand("/queue hi")
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [.string("hi")])
        XCTAssertEqual(chat.model.messages.map(\.content), ["hi"])
    }

    func testPrefillReplacesTheDraft() async {
        let chat = await openChat()
        chat.host.always("slash.exec", .init(result: .object(["type": .string("prefill"), "message": .string("try again")])))
        let result = await chat.model.runHermesSlashCommand("/prompt")
        XCTAssertEqual(result, .prefill("try again"))
        XCTAssertEqual(chat.writes("prompt.submit"), [])
    }

    func testAnAliasRunsItsTargetOnce() async {
        let chat = await openChat()
        chat.host.next("slash.exec", .init(result: .object(["type": .string("alias"), "target": .string("context")])))
        chat.host.next("slash.exec", .init(result: .object(["output": .string("Context: 12%")])))

        let result = await chat.model.runHermesSlashCommand("/hello all")
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("slash.exec").map { $0["command"] }, [.string("/hello all"), .string("/context all")])
        XCTAssertEqual(chat.model.messages.map(\.content), ["```text\nContext: 12%\n```"])

        chat.host.next("slash.exec", .init(result: .object(["type": .string("alias"), "target": .string("hello")])))
        chat.host.next("slash.exec", .init(result: .object(["type": .string("alias"), "target": .string("hello")])))
        let looped = await chat.model.runHermesSlashCommand("/hello")
        XCTAssertEqual(looped, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "/hello points to another alias, so Hermex didn't run it.")
        XCTAssertEqual(chat.writes("slash.exec").count, 4)
    }

    func testAHostRefusalShowsItsMessage() async throws {
        let refusal = try Self.fixture("slash.exec /steer")
        let reply = BotSocketHost.Reply(error: refusal["code"].integer, message: refusal["message"].text ?? "")

        let sent = await openChat(messages: [.object(["id": .number(1), "role": .string("user"), "content": .string("hi")])])
        XCTAssertEqual(sent.model.messages.map(\.role), ["user"])
        sent.host.always("slash.exec", reply)
        let refused = await sent.model.runHermesSlashCommand("/steer")
        XCTAssertEqual(refused, .notDelivered)
        XCTAssertEqual(sent.model.sendErrorMessage, "usage: /steer <prompt>")

        let unsent = await openChat()
        unsent.host.always("slash.exec", reply)
        _ = await unsent.model.runHermesSlashCommand("/steer")
        XCTAssertEqual(unsent.model.sendErrorMessage, "Send a message first, then run /steer.")
    }

    func testARollbackFilePathKeepsItsSpaces() {
        XCTAssertEqual(HermesRollbackCommand("1 dir/my  notes.txt"), .restore("1", filePath: "dir/my  notes.txt"))
    }

    func testAListedNumberNamesTheCheckpointItShows() throws {
        let reply = BotJSON.object(["enabled": .bool(true), "checkpoints": .array([
            .object(["message": .string("no hash")]),
            .object(["hash": .string("abcdef0123"), "message": .string("before write_file")])
        ])])
        let listed = try XCTUnwrap(HermesCheckpoint.list(reply))
        let shown = try XCTUnwrap(listed.first)
        XCTAssertEqual(HermesCheckpoint.named(String(shown.number), in: listed)?.hash, "abcdef0123")
    }

    func testRollbackListsTheRuntimesCheckpoints() async throws {
        let chat = await openChat()
        chat.host.always("rollback.list", .init(result: try Self.fixture("rollback.list")))
        chat.host.always("slash.exec", .init(result: .object(["output": .string("Command refused")])))

        let result = await chat.model.runHermesSlashCommand("/rollback")

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("rollback.list"), [["session_id": .string("runtime")]])
        XCTAssertEqual(chat.writes("slash.exec"), [])
        XCTAssertEqual(chat.model.messages.map(\.role), ["local_notice"])
    }

    func testConfirmingARestoreSendsTheListedHash() async throws {
        let chat = await openChat()
        let listed = try Self.fixture("rollback.list")["checkpoints"].list ?? []
        XCTAssertEqual(listed.count, 2)
        chat.host.always("rollback.list", .init(result: .object(["enabled": .bool(true), "checkpoints": .array(listed)])))
        chat.host.always("rollback.restore", .init(result: try Self.fixture("rollback.restore whole tree, nothing rewound")))

        _ = await chat.model.runHermesSlashCommand("/rollback 2 notes.txt")
        XCTAssertEqual(chat.writes("rollback.restore"), [], "nothing is restored before the user confirms")
        _ = await chat.model.confirmHermesRollback(try XCTUnwrap(chat.model.pendingHermesRollback))
        _ = await chat.model.runHermesSlashCommand("/rollback 1")
        _ = await chat.model.confirmHermesRollback(try XCTUnwrap(chat.model.pendingHermesRollback))

        XCTAssertEqual(chat.writes("rollback.restore"), [
            ["session_id": .string("runtime"), "hash": listed[1]["hash"], "file_path": .string("notes.txt")],
            ["session_id": .string("runtime"), "hash": listed[0]["hash"]]
        ])
        XCTAssertNil(chat.model.pendingHermesRollback)
    }

    func testARestoreTheHostCouldNotDoShowsItsError() async throws {
        let chat = await openChat()
        let failed = try Self.fixture("rollback.restore unknown hash")
        chat.host.always("rollback.list", .init(result: try Self.fixture("rollback.list")))
        chat.host.always("rollback.restore", .init(result: failed))

        _ = await chat.model.runHermesSlashCommand("/rollback 1")
        let result = await chat.model.confirmHermesRollback(try XCTUnwrap(chat.model.pendingHermesRollback))

        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, failed["error"].text)
    }

    func testCancellingARestoreSendsNothing() async throws {
        let chat = await openChat()
        chat.host.always("rollback.list", .init(result: try Self.fixture("rollback.list")))

        _ = await chat.model.runHermesSlashCommand("/rollback 1")
        XCTAssertNotNil(chat.model.pendingHermesRollback)
        chat.model.cancelHermesRollback()

        XCTAssertNil(chat.model.pendingHermesRollback)
        XCTAssertEqual(chat.writes("rollback.restore"), [])
    }

    func testADiffSendsTheListedHashAndNothingForAnUnknownCheckpoint() async throws {
        let chat = await openChat()
        let listed = try Self.fixture("rollback.list")["checkpoints"].list ?? []
        chat.host.always("rollback.list", .init(result: try Self.fixture("rollback.list")))
        chat.host.always("rollback.diff", .init(result: .object(["stat": .string(""), "diff": .string("")])))

        for unknown in ["/rollback diff 9", "/rollback diff deadbeef"] {
            let result = await chat.model.runHermesSlashCommand(unknown)
            XCTAssertEqual(result, .notDelivered, unknown)
        }
        XCTAssertEqual(chat.writes("rollback.diff"), [])

        _ = await chat.model.runHermesSlashCommand("/rollback diff 2")
        XCTAssertEqual(chat.writes("rollback.diff").map { $0["hash"] }, [listed[1]["hash"]])
    }

    func testOnlyAGoneRuntimeReattachesOnARollbackRefusal() async throws {
        let chat = await openChat()
        let resumes = { chat.writes("session.resume").count }
        let attached = resumes()

        chat.host.next("rollback.list", .init(error: 4001, message: "unsupported_terminal_backend"))
        let refused = await chat.model.runHermesSlashCommand("/rollback")
        await chat.turn.activate()
        XCTAssertEqual(refused, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "unsupported_terminal_backend")
        XCTAssertEqual(resumes(), attached, "no reattach")

        for gone in ["not_found", "session not found"] {
            let before = resumes()
            chat.host.next("rollback.list", .init(error: 4001, message: gone))
            _ = await chat.model.runHermesSlashCommand("/rollback")
            await chat.turn.activate()
            XCTAssertGreaterThan(resumes(), before, gone)
        }
    }

    func testOnlyTheNewestCompletionApplies() async throws {
        let chat = await openChat()
        let slash = chat.turn.slashCommands
        slash.completionDelay = .milliseconds(1)
        chat.host.always("complete.slash", .init(result: try Self.fixture("complete.slash /approvals ")))

        let newer = Task { await slash.complete("/approvals ") }
        await slash.complete("/approvals x")
        await newer.value
        XCTAssertEqual(chat.writes("complete.slash").count, 2)
        XCTAssertEqual(slash.completion?.text, "/approvals ", "the older reply is dropped, whichever lands last")
        XCTAssertEqual(slash.completion?.items.map(\.text), ["manual", "smart", "off"])
        XCTAssertEqual(slash.completion.map { $0.applying($0.items[1]) }, "/approvals smart")

        await slash.complete(nil)
        XCTAssertNil(slash.completion)
    }

    func testSuggestionsFitOnlyTheWordTheyComplete() {
        let completion = HermesSlashCompletion(text: "/queue ", items: [.init(text: "list", display: "list", meta: "")],
                                               replaceFrom: 7)
        XCTAssertTrue(completion.applies(to: "/queue "))
        XCTAssertTrue(completion.applies(to: "/queue li"))
        XCTAssertFalse(completion.applies(to: "/queue edit 2 "))
        XCTAssertFalse(completion.applies(to: "/steer "))
        XCTAssertEqual(completion.applying(completion.items[0]), "/queue list")
    }

    func testCompletionWaitsForAPauseInTyping() async throws {
        let chat = await openChat()
        let slash = chat.turn.slashCommands
        chat.host.always("complete.slash", .init(result: try Self.fixture("complete.slash /approvals ")))
        slash.completionDelay = .seconds(60)
        let typing = Task { await slash.complete("/approvals") }
        typing.cancel()
        await typing.value
        slash.completionDelay = .zero
        await slash.complete("/approvals ")
        XCTAssertEqual(chat.writes("complete.slash"), [["text": .string("/approvals "), "session_id": .string("runtime")]])
    }

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/HermesAgent/slash-commands.json")

    private static func fixture(_ key: String) throws -> BotJSON {
        guard let data = try? Data(contentsOf: fixtures) else {
            throw XCTSkip("Could not read \(fixtures.path); the source tree is not present (physical device or remote runner).")
        }
        let reply = try JSONDecoder().decode(BotJSON.self, from: data)[key]
        guard reply != .null else { throw XCTSkip("No recorded \(key)") }
        return reply
    }

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private static func row(_ id: Int, _ role: String, _ content: String) -> BotJSON {
        .object(["id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role),
                 "content": .string(content), "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(1)])
    }

    private static func searchResult(_ id: String, title: String, root: String? = nil) -> BotJSON {
        .object(["snippet": .string("Session ID: \(id)"), "role": .null, "session_id": .string(id), "id": .string(id),
                 "lineage_root": .string(root ?? id), "profile": .string("default"), "title": .string(title),
                 "last_active": .number(1_791_400_927), "started_at": .number(1_791_400_926), "archived": .bool(false)])
    }

    private func openChat(messages: [BotJSON] = [], search: [BotJSON] = [], catalog: Bool = true,
                          target: ConversationTarget = .session(profile: "default", key: "tip"),
                          profiles: BotJSON? = nil, sessionRows: [String: BotJSON] = [:]) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        if let profiles { host.always("profiles.list", .init(result: profiles)) }
        if catalog, let reply = try? Self.fixture("commands.catalog") {
            host.always("commands.catalog", .init(result: reply))
        }
        let client = BotClient(http: host.connection(Self.connection))
        _ = HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/api/sessions/tip/messages": return .json(200, .object(["messages": .array(messages)]))
            case "/api/sessions/search": return .json(200, .object(["results": .array(search)]))
            case let path? where path.hasPrefix("/api/sessions/"):
                return sessionRows[String(path.dropFirst("/api/sessions/".count))].map { .json(200, $0) }
            default: return nil
            }
        }
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: target, wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        if catalog { await waitUntil("the catalog") { !turn.slashCommands.catalog.commands.isEmpty } }
        return Chat(model: model, turn: turn, host: host)
    }
}

private extension HermesSlashRoute {
    var isSkill: Bool { if case .skill = self { return true }; return false }
    var appOwnedHandler: SlashCommandHandler? { if case .appOwned(let command) = self { return command.handler }; return nil }
    var appOwnedName: String? { if case .appOwned(let command) = self { return command.name }; return nil }
}
