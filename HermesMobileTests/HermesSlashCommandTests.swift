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
        XCTAssertEqual(slash.route("undo"), .held)
        XCTAssertEqual(slash.route("compact"), .held)
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

    func testAHeldCommandShowsTheNoticeAndSendsNothing() async {
        let chat = await openChat()
        let result = await chat.model.runHermesSlashCommand("/undo")
        XCTAssertEqual(result, .unsupported(friendlyMessage: "Hermex can't run /undo in a Hermes chat yet (#702)."))
        XCTAssertEqual(chat.writes("slash.exec"), [])
        XCTAssertEqual(chat.writes("prompt.submit"), [])
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

        let sent = await openChat(messages: [.object(["role": .string("user"), "text": .string("hi"), "content": .string("hi")])])
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

    /// A Hermes chat attached to an idle session on `runtime`, holding `messages`, with the
    /// recorded catalog read unless `catalog` is false.
    private func openChat(messages: [BotJSON] = [], catalog: Bool = true) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array(messages), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        if catalog, let reply = try? Self.fixture("commands.catalog") {
            host.always("commands.catalog", .init(result: reply))
        }
        let client = BotClient(http: host.connection(Self.connection))
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: .session(profile: "default", key: "tip"), wire: client)
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
}
