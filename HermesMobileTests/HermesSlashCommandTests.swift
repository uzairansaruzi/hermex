import XCTest
import Observation
@testable import HermesMobile

/// Slash commands in a Hermes chat (#1036), over #901's socket-level host. Replies come
/// from `Fixtures/HermesAgent/slash-commands.json`, recorded from `scripts/local-hermes`
/// at the `HERMES_AGENT_TESTED_SHA` pin.
@MainActor final class HermesSlashCommandTests: XCTestCase {
    // MARK: Catalog

    /// Command rows are the `pairs` `canon` knows, with their aliases; skills stay apart,
    /// and an alias finds its command in the panel.
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
                      "Hermex's own and the held commands never ask the host")

        let ranked = AgentSlashCommandSuggestion.matching("ctx", in: catalog.commands, matchingAliases: true)
        XCTAssertEqual(ranked.first?.name, "context")
        XCTAssertEqual(ranked.filter { $0.name == "context" }.count, 1)
    }

    /// The composer's panel gets the host's commands and skills.
    func testTheComposerOffersTheHostsCatalog() async {
        let chat = await openChat()
        XCTAssertEqual(chat.model.composerAgentCommands, chat.turn.slashCommands.catalog.commands)
        XCTAssertTrue(chat.model.composerAgentCommands.contains { $0.name == "context" })
        XCTAssertTrue(chat.model.composerSkillSuggestions.contains { $0.name == "demo-skill" })
    }

    /// A catalog read for an attach that is no longer current is dropped.
    func testAStaleCatalogReplyIsDropped() async throws {
        let chat = await openChat(catalog: false)
        let slash = chat.turn.slashCommands
        chat.host.always("commands.catalog", .init(result: try Self.fixture("commands.catalog")))
        await slash.connect(runtime: "runtime", attempt: chat.turn.engine.generation - 1)
        XCTAssertTrue(slash.catalog.commands.isEmpty)
        await slash.connect(runtime: "runtime", attempt: chat.turn.engine.generation)
        XCTAssertFalse(slash.catalog.commands.isEmpty)
    }

    // MARK: Routing

    func testANameRoutesToTheAppTheHoldTheSkillTheHostOrText() async throws {
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
        XCTAssertEqual(slash.route("demo-skill").isSkill, true)
        XCTAssertEqual(slash.route("context"), .host)
        XCTAssertEqual(slash.route("ctx"), .host)
        XCTAssertEqual(slash.route("hello"), .host)
        XCTAssertEqual(slash.route("notacommand"), .text)
    }

    /// A host command runs once through `slash.exec`, and its output is a notice with its
    /// line breaks kept. Nothing reaches the model.
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

    /// `/title` renames the session on its runtime (#1048), never through `slash.exec`, and the
    /// header takes the title the host kept.
    func testTitleRenamesTheSessionOnItsRuntime() async {
        let chat = await openChat()
        chat.host.always("session.title", .init(result: .object(["pending": .bool(false), "title": .string("Launch plan")])))

        let result = await chat.model.runHermesSlashCommand("/title  Launch plan ")

        XCTAssertEqual(result, .executed(message: "Title set to **Launch plan**."))
        XCTAssertEqual(chat.writes("session.title"), [["session_id": .string("runtime"), "title": .string("Launch plan")]])
        XCTAssertEqual(chat.writes("slash.exec"), [])
        XCTAssertEqual(chat.model.displayTitle, "Launch plan")
    }

    /// A title the host refuses (4022: in use, or over 100 characters) shows its words and keeps
    /// the draft.
    func testATitleTheHostRefusesShowsItsMessage() async {
        let chat = await openChat()
        let refusal = "Title 'Plan' is already in use by session 20261007_003046_925526"
        chat.host.always("session.title", .init(error: 4022, message: refusal))

        let result = await chat.model.runHermesSlashCommand("/title Plan")

        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, refusal)
    }

    func testAnUnknownNameIsSentAsText() async {
        let chat = await openChat()
        let result = await chat.model.runHermesSlashCommand("/notacommand hi")
        XCTAssertNil(result)
        XCTAssertEqual(chat.writes("slash.exec"), [])
    }

    /// A skill expands through `command.dispatch`; its prompt goes out once, and the
    /// transcript shows the typed line, never the expanded skill.
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

    /// `/new` opens a new chat in the session's Profile.
    func testNewOpensANewChatInTheProfile() async {
        let chat = await openChat()
        guard case .openedHermesSession(let opened)? = await chat.model.runHermesSlashCommand("/new") else {
            return XCTFail("Expected a new chat")
        }
        XCTAssertEqual(opened.target, .new(profile: "default"))
    }

    // MARK: Bot Chat (#1145)

    /// A bot's Bot Chat is that bot's one conversation (#1127 decision 3): every command that
    /// would start, open, rename, branch or rewind a chat is refused with copy before anything
    /// is sent, aliases included, and `/clear` points at `/compress`.
    func testABotChatRefusesCommandsThatLeaveOrRewriteIt() async {
        let chat = await openChat(target: .canonicalChat(profile: "default"))
        let refusals: [(String, String)] = [
            ("/new", "A bot keeps one chat, so /new can’t start another."),
            ("/reset", "A bot keeps one chat, so /reset can’t start another."),
            ("/clear", "A bot keeps one chat, so /clear can’t start another. Run /compress to free up its context."),
            ("/resume Launch plan", "A bot keeps one chat, so /resume can’t open another."),
            ("/sessions", "A bot keeps one chat, so /sessions can’t open another."),
            ("/branch Idea", "A bot’s chat can’t be forked."),
            ("/fork", "A bot’s chat can’t be forked."),
            ("/title Renamed", "A bot’s chat keeps the bot’s name."),
            ("/undo", "A bot’s chat can’t be rewound."),
            ("/retry", "A bot’s chat can’t be rewound.")
        ]
        let sent = chat.host.requests.count
        for (line, copy) in refusals {
            let result = await chat.model.runHermesSlashCommand(line)
            XCTAssertEqual(result, .unsupported(friendlyMessage: copy), line)
        }
        XCTAssertEqual(chat.host.requests.dropFirst(sent).compactMap { $0["method"].text }, [], "nothing reaches the host")
    }

    /// The panel hides what a Bot Chat refuses, Hermex's and the host's alike, and keeps its side
    /// commands (`/btw`, `/background`, `/goal`, `/yolo`, `/compress`). A session keeps them all.
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

    /// A Bot Chat's saved rows offer no Edit, Regenerate or Fork From Here, and its Profile chip
    /// starts no other chat; a session's same rows offer all three.
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

    /// A Bot Chat row (Archived) opens by its key with Bot Chat's rules, so its compaction follows
    /// the key as any session's does; every other row opens as a session.
    func testABotChatRowOpensWithBotChatsRules() {
        let bot = HermesSessionRow(id: "bot", title: "Bot Chat", hidden: true, profile: "default").summary(in: "default")
        let opened = bot.hermesChat(on: URL(string: "https://hermes.example")!, connection: Self.connection, listedIn: "default")
        XCTAssertEqual(opened?.target, .session(profile: "default", key: "bot"))
        XCTAssertEqual(opened?.policy, .botChat)
        let plain = HermesSessionRow(id: "a", title: "Plan").summary(in: "default")
        XCTAssertEqual(plain.hermesChat(on: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        listedIn: "default")?.policy, .session)
    }

    // MARK: Sessions (#1053)

    /// `/resume <name>` searches the chat's Profile for the name and opens the one session
    /// titled exactly that, in any case; a title that only starts with it doesn't count.
    func testResumeOpensTheOneSessionTitledExactlyThat() async throws {
        let chat = await openChat(search: [Self.searchResult("20261007_090000_aaaaaa", title: "Launch plan"),
                                           Self.searchResult("20261007_090000_bbbbbb", title: "Launch plan draft")])

        let result = await chat.model.runHermesSlashCommand("/resume launch PLAN")

        guard case .openedHermesSession(let opened)? = result else {
            return XCTFail("Expected the session titled Launch plan, got \(String(describing: result))")
        }
        XCTAssertEqual(opened.target, .session(profile: "default", key: "20261007_090000_aaaaaa"))
        let searches = HermesHostFixture.requests.filter { $0.url?.path == "/api/sessions/search" }
        XCTAssertEqual(searches.count, 1)
        let query = try XCTUnwrap(searches.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "launch PLAN")
        XCTAssertEqual(query.first { $0.name == "profile" }?.value, "default")
        XCTAssertEqual(chat.writes("slash.exec"), [], "the host's own /resume never runs")
    }

    /// Anything but one exact title (none, two in different cases, or a Bot Chat, which opens
    /// in its bot) opens the Profile's Sessions list searching the name; `/sessions` and a bare
    /// `/resume` open it unsearched. The host's own commands never run.
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

    /// A chat that is not attached sends nothing and keeps the draft.
    func testAHostCommandWithoutAConnectionIsNotSent() async {
        let chat = await openChat()
        chat.model.suspendStreamForNavigation()
        let result = await chat.model.runHermesSlashCommand("/context")
        XCTAssertEqual(result, .notDelivered)
        XCTAssertEqual(chat.model.sendErrorMessage, "Reconnect to the server to run /context.")
        XCTAssertEqual(chat.writes("slash.exec"), [])
    }

    // MARK: Directives

    /// `send` goes out through the normal send path.
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

    /// An alias runs its target once with the typed argument; an alias to another alias is
    /// refused.
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

    /// A refusal shows the host's message and keeps the draft; in a chat with nothing sent
    /// yet it asks for a message first.
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

    // MARK: Argument completion

    /// Only the newest call's reply is kept, and closing the panel clears it.
    func testOnlyTheNewestCompletionApplies() async throws {
        let chat = await openChat()
        let slash = chat.turn.slashCommands
        slash.completionDelay = .milliseconds(1)
        chat.host.always("complete.slash", .init(result: try Self.fixture("complete.slash /approvals ")))

        async let older: Void = slash.complete("/approvals x")
        async let newer: Void = slash.complete("/approvals ")
        _ = await (older, newer)
        XCTAssertEqual(chat.writes("complete.slash").count, 2)
        XCTAssertEqual(slash.completion?.text, "/approvals ", "the older reply is dropped, whichever lands last")
        XCTAssertEqual(slash.completion?.items.map(\.text), ["manual", "smart", "off"])
        XCTAssertEqual(slash.completion.map { $0.applying($0.items[1]) }, "/approvals smart")

        await slash.complete(nil)
        XCTAssertNil(slash.completion)
    }

    /// Suggestions fit only while just the completed word follows their head, so a pick
    /// never deletes words typed after them.
    func testSuggestionsFitOnlyTheWordTheyComplete() {
        let completion = HermesSlashCompletion(text: "/queue ", items: [.init(text: "list", display: "list", meta: "")],
                                               replaceFrom: 7)
        XCTAssertTrue(completion.applies(to: "/queue "))
        XCTAssertTrue(completion.applies(to: "/queue li"))
        XCTAssertFalse(completion.applies(to: "/queue edit 2 "))
        XCTAssertFalse(completion.applies(to: "/steer "))
        XCTAssertEqual(completion.applying(completion.items[0]), "/queue list")
    }

    /// Typing within the pause sends one request, for the latest text.
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

    // MARK: Fixture

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/HermesAgent/slash-commands.json")

    /// One recorded reply by its key.
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

        /// The params of every `method` call the chat sent.
        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    /// One saved transcript row on `tip` (#1047).
    private static func row(_ id: Int, _ role: String, _ content: String) -> BotJSON {
        .object(["id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role),
                 "content": .string(content), "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(1)])
    }

    /// One `GET /api/sessions/search` id match in the pin's shape (#1053).
    private static func searchResult(_ id: String, title: String) -> BotJSON {
        .object(["snippet": .string("Session ID: \(id)"), "role": .null, "session_id": .string(id), "id": .string(id),
                 "lineage_root": .string(id), "profile": .string("default"), "title": .string(title),
                 "last_active": .number(1_791_400_927), "started_at": .number(1_791_400_926), "archived": .bool(false)])
    }

    /// A Hermes chat attached to an idle session on `runtime`, whose transcript page holds
    /// `messages` (#1047) and whose Profile's search answers `search` (#1053), with the
    /// recorded catalog read unless `catalog` is false. `profiles` answers `profiles.list`; a
    /// `.canonicalChat` target's title lookup finds root `root` at tip `tip`.
    private func openChat(messages: [BotJSON] = [], search: [BotJSON] = [], catalog: Bool = true,
                          target: ConversationTarget = .session(profile: "default", key: "tip"),
                          profiles: BotJSON? = nil) async -> Chat {
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

    /// Waits on observation, never a clock, until `condition` holds.
    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            let changed = XCTestExpectation(description: description)
            withObservationTracking { _ = condition() } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 5) == .completed else {
                return XCTFail("Nothing changed while waiting for: \(description)", file: file, line: line)
            }
        }
    }
}

private extension HermesSlashRoute {
    var isSkill: Bool { if case .skill = self { return true }; return false }
    /// The handler of an app-owned command; nil for any other route.
    var appOwnedHandler: SlashCommandHandler? { if case .appOwned(let command) = self { return command.handler }; return nil }
    /// The name of an app-owned command; nil for any other route.
    var appOwnedName: String? { if case .appOwned(let command) = self { return command.name }; return nil }
}
